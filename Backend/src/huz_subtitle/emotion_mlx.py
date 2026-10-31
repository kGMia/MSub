from __future__ import annotations

import json
import math
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from safetensors import safe_open


EMOTION_MLX_MODEL_ID = "mlx-community/emotion2vec-plus-large-mlx"
EMOTION_MLX_CONFIG = "emotion2vec_large_config.json"
EMOTION_MLX_WEIGHTS = "emotion2vec_large.safetensors"


def is_emotion_mlx_model_path(path: str | Path) -> bool:
    model_path = Path(path).expanduser()
    return (
        model_path.is_dir()
        and (model_path / EMOTION_MLX_CONFIG).is_file()
        and (model_path / EMOTION_MLX_WEIGHTS).is_file()
    )


def looks_like_emotion_mlx_model(model_id: str | Path | None) -> bool:
    if model_id is None:
        return False
    text = str(model_id).strip()
    if not text:
        return False
    if is_emotion_mlx_model_path(text):
        return True
    return "emotion2vec-plus-large-mlx" in text or text == EMOTION_MLX_MODEL_ID


def resolve_emotion_mlx_model_path(model_id: str | Path) -> Path:
    text = str(model_id).strip()
    if is_emotion_mlx_model_path(text):
        return Path(text).expanduser()
    if text in {"", "."}:
        raise RuntimeError("Empty emotion MLX model path.")
    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        raise RuntimeError(
            "Downloading the MLX emotion model requires huggingface-hub."
        ) from exc
    try:
        return Path(
            snapshot_download(
                repo_id=text,
                allow_patterns=[EMOTION_MLX_CONFIG, EMOTION_MLX_WEIGHTS, "README.md"],
            )
        )
    except Exception as exc:  # noqa: BLE001 - surface the configured id.
        raise RuntimeError(f"Could not resolve MLX emotion model {text!r}.") from exc


@lru_cache(maxsize=1)
def load_emotion_mlx_model(model_id: str | Path) -> Emotion2VecMLX:
    return Emotion2VecMLX(resolve_emotion_mlx_model_path(model_id))


class Emotion2VecMLX:
    """Small MLX runtime for the emotion2vec-plus-large conversion."""

    def __init__(self, model_dir: Path):
        import mlx.core as mx

        self.mx = mx
        self.model_dir = model_dir
        with (model_dir / EMOTION_MLX_CONFIG).open("r", encoding="utf-8") as handle:
            self.config: dict[str, Any] = json.load(handle)
        self.labels: list[str] = list(self.config.get("emotion_labels") or [])
        if not self.labels:
            self.labels = [
                "angry",
                "disgusted",
                "fearful",
                "happy",
                "neutral",
                "other",
                "sad",
                "surprised",
                "unknown",
            ]
        self.sample_rate = int(self.config.get("sample_rate") or 16_000)
        self.max_seconds = max(2.0, float(os.getenv("MSUB_EMOTION_MLX_MAX_SECONDS", "30")))
        self.weights = self._load_weights(model_dir / EMOTION_MLX_WEIGHTS)
        self.num_layers = int(self.config.get("num_layers") or 12)
        self.num_heads = int(self.config.get("num_heads") or 16)
        self.num_extra_tokens = int(self.config.get("num_extra_tokens") or 10)
        self.hidden_dim = int(self.config.get("hidden_dim") or 1024)
        self.head_dim = self.hidden_dim // self.num_heads

    def _load_weights(self, path: Path) -> dict[str, Any]:
        tensors: dict[str, Any] = {}
        with safe_open(path, framework="np") as handle:
            for key in handle.keys():
                tensors[key] = self.mx.array(handle.get_tensor(key))
        return tensors

    def generate(self, input: str | Path, **_: Any) -> list[dict[str, Any]]:
        labels, scores = self.classify(input)
        return [{"labels": labels, "scores": scores}]

    def classify(self, audio_path: str | Path) -> tuple[list[str], list[float]]:
        samples, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        if sample_rate != self.sample_rate:
            samples = self._resample(samples, sample_rate, self.sample_rate)
        samples = self._trim_for_memory(samples)
        if samples.size < self.sample_rate // 10:
            samples = np.pad(samples, (0, max(0, self.sample_rate // 10 - samples.size)))
        std = float(np.std(samples))
        if std > 1e-6:
            samples = (samples - float(np.mean(samples))) / std
        source = self.mx.array(samples[None, :].astype(np.float32, copy=False))
        logits = self._forward(source)
        probs = self.mx.softmax(logits.astype(self.mx.float32), axis=-1)
        self.mx.eval(probs)
        scores = np.array(probs[0], dtype=np.float32).tolist()
        return self.labels, [float(score) for score in scores]

    def _trim_for_memory(self, samples: np.ndarray) -> np.ndarray:
        limit = int(self.max_seconds * self.sample_rate)
        if limit <= 0 or samples.size <= limit:
            return samples
        start = max(0, (samples.size - limit) // 2)
        return samples[start : start + limit]

    @staticmethod
    def _resample(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
        if source_rate <= 0 or target_rate <= 0 or samples.size == 0:
            return samples.astype(np.float32, copy=False)
        duration = samples.size / float(source_rate)
        target_length = max(1, int(round(duration * target_rate)))
        source_x = np.linspace(0.0, duration, num=samples.size, endpoint=False)
        target_x = np.linspace(0.0, duration, num=target_length, endpoint=False)
        return np.interp(target_x, source_x, samples).astype(np.float32, copy=False)

    def _forward(self, source):
        x = source[:, :, None]
        for idx, layer_cfg in enumerate(self.config.get("conv_feature_layers") or []):
            _, _, _, stride = layer_cfg
            x = self._conv1d(
                x,
                self.weights[f"feature_extractor.layers.{idx}.conv.weight"],
                stride=int(stride),
            )
            x = self._layer_norm(
                x,
                self.weights[f"feature_extractor.layers.{idx}.norm.weight"],
                self.weights[f"feature_extractor.layers.{idx}.norm.bias"],
            )
            x = self._gelu(x)

        x = self._layer_norm(
            x,
            self.weights["feature_projection.norm.weight"],
            self.weights["feature_projection.norm.bias"],
        )
        x = self._linear(
            x,
            self.weights["feature_projection.projection.weight"],
            self.weights["feature_projection.projection.bias"],
        )
        x = x + self._positional_conv(x)

        alibi = self._alibi_bias(x.shape[0], x.shape[1])
        if self.num_extra_tokens > 0 and "encoder.extra_tokens" in self.weights:
            extra = self.weights["encoder.extra_tokens"]
            if x.shape[0] != extra.shape[0]:
                extra = self.mx.broadcast_to(extra, (x.shape[0], extra.shape[1], extra.shape[2]))
            x = self.mx.concatenate([extra, x], axis=1)
            alibi = self._pad_alibi_for_extra_tokens(alibi, self.num_extra_tokens)

        x = self._layer_norm(
            x,
            self.weights.get("encoder.context_norm.weight"),
            self.weights.get("encoder.context_norm.bias"),
        )

        for idx in range(self.num_layers):
            x = self._transformer_block(x, idx, alibi)

        if self.num_extra_tokens > 0:
            x = x[:, self.num_extra_tokens :, :]
        pooled = self.mx.mean(x, axis=1)
        return self._linear(
            pooled,
            self.weights["classifier.weight"],
            self.weights["classifier.bias"],
        )

    def _positional_conv(self, x):
        y = x
        for idx in range(int(self.config.get("pos_conv_depth") or 5)):
            y = self._conv1d(
                y,
                self.weights[f"encoder.pos_conv.{idx}.weight"],
                bias=self.weights.get(f"encoder.pos_conv.{idx}.bias"),
                padding=int((self.config.get("pos_conv_kernel") or 19) // 2),
                groups=int(self.config.get("pos_conv_groups") or 16),
            )
            y = self._layer_norm(y, None, None)
            y = self._gelu(y)
        return y

    def _transformer_block(self, x, idx: int, alibi):
        residual = x
        x = residual + self._attention(x, idx, alibi)
        x = self._layer_norm(
            x,
            self.weights[f"encoder.layers.{idx}.attn_norm.weight"],
            self.weights[f"encoder.layers.{idx}.attn_norm.bias"],
        )
        residual = x
        x = self._linear(
            x,
            self.weights[f"encoder.layers.{idx}.ffn.fc1.weight"],
            self.weights[f"encoder.layers.{idx}.ffn.fc1.bias"],
        )
        x = self._gelu(x)
        x = self._linear(
            x,
            self.weights[f"encoder.layers.{idx}.ffn.fc2.weight"],
            self.weights[f"encoder.layers.{idx}.ffn.fc2.bias"],
        )
        return self._layer_norm(
            residual + x,
            self.weights[f"encoder.layers.{idx}.ffn_norm.weight"],
            self.weights[f"encoder.layers.{idx}.ffn_norm.bias"],
        )

    def _attention(self, x, idx: int, alibi):
        batch, length, channels = x.shape
        q = self._linear(
            x,
            self.weights[f"encoder.layers.{idx}.attention.q_proj.weight"],
            self.weights[f"encoder.layers.{idx}.attention.q_proj.bias"],
        )
        k = self._linear(
            x,
            self.weights[f"encoder.layers.{idx}.attention.k_proj.weight"],
            self.weights[f"encoder.layers.{idx}.attention.k_proj.bias"],
        )
        v = self._linear(
            x,
            self.weights[f"encoder.layers.{idx}.attention.v_proj.weight"],
            self.weights[f"encoder.layers.{idx}.attention.v_proj.bias"],
        )
        q = self.mx.transpose(q.reshape(batch, length, self.num_heads, self.head_dim), (0, 2, 1, 3))
        k = self.mx.transpose(k.reshape(batch, length, self.num_heads, self.head_dim), (0, 2, 1, 3))
        v = self.mx.transpose(v.reshape(batch, length, self.num_heads, self.head_dim), (0, 2, 1, 3))
        attn = (q * (self.head_dim**-0.5)) @ self.mx.transpose(k, (0, 1, 3, 2))
        if alibi is not None:
            attn = attn.astype(alibi.dtype) + alibi
        probs = self.mx.softmax(attn.astype(self.mx.float32), axis=-1).astype(v.dtype)
        out = probs @ v
        out = self.mx.transpose(out, (0, 2, 1, 3)).reshape(batch, length, channels)
        return self._linear(
            out,
            self.weights[f"encoder.layers.{idx}.attention.out_proj.weight"],
            self.weights[f"encoder.layers.{idx}.attention.out_proj.bias"],
        )

    def _alibi_bias(self, batch: int, length: int):
        positions = np.arange(length, dtype=np.float32)
        pos_bias = -np.abs(positions[:, None] - positions[None, :])
        slopes = np.array(self._alibi_slopes(self.num_heads), dtype=np.float32)
        bias = slopes[:, None, None] * pos_bias[None, :, :]
        bias = bias[None, :, :, :]
        bias_mx = self.mx.array(bias)
        scale = self.weights.get("encoder.alibi_scale")
        if scale is not None:
            scale = self.mx.maximum(scale, self.mx.array(0, dtype=scale.dtype))
            if scale.shape[0] == 1:
                bias_mx = bias_mx * scale.reshape(1, self.num_heads, 1, 1)
        if batch != 1:
            bias_mx = self.mx.broadcast_to(bias_mx, (batch, self.num_heads, length, length))
        return bias_mx

    def _pad_alibi_for_extra_tokens(self, alibi, extra_count: int):
        batch, heads, length, _ = alibi.shape
        full_length = length + extra_count
        left = self.mx.zeros((batch, heads, length, extra_count), dtype=alibi.dtype)
        bottom = self.mx.concatenate([left, alibi], axis=-1)
        top = self.mx.zeros((batch, heads, extra_count, full_length), dtype=alibi.dtype)
        return self.mx.concatenate([top, bottom], axis=-2)

    @staticmethod
    def _alibi_slopes(heads: int) -> list[float]:
        def power_of_2_slopes(value: int) -> list[float]:
            start = 2 ** (-(2 ** -(math.log2(value) - 3)))
            ratio = start
            return [start * ratio**idx for idx in range(value)]

        if math.log2(heads).is_integer():
            return power_of_2_slopes(heads)
        closest = 2 ** math.floor(math.log2(heads))
        return power_of_2_slopes(closest) + Emotion2VecMLX._alibi_slopes(2 * closest)[
            0::2
        ][: heads - closest]

    def _conv1d(self, x, weight, *, bias=None, stride: int = 1, padding: int = 0, groups: int = 1):
        weight = self.mx.transpose(weight, (0, 2, 1))
        y = self.mx.conv1d(x, weight, stride=stride, padding=padding, groups=groups)
        if bias is not None:
            y = y + bias
        return y

    def _linear(self, x, weight, bias=None):
        y = x @ self.mx.transpose(weight, (1, 0))
        if bias is not None:
            y = y + bias
        return y

    def _layer_norm(self, x, weight, bias, eps: float = 1e-5):
        return self.mx.fast.layer_norm(x, weight, bias, eps)

    def _gelu(self, x):
        return 0.5 * x * (
            1.0
            + self.mx.tanh(math.sqrt(2.0 / math.pi) * (x + 0.044715 * (x * x * x)))
        )
