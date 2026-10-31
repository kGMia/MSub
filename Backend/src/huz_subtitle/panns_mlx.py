from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from safetensors import safe_open


PANNS_CNN14_16K_MODEL_ID = "panns-cnn14-16k-mlx"
PANNS_CNN14_16K_CONFIG = "panns_cnn14_16k_config.json"
PANNS_CNN14_16K_WEIGHTS = "panns_cnn14_16k.safetensors"


def is_panns_mlx_model_path(path: str | Path) -> bool:
    model_path = Path(path).expanduser()
    return (
        model_path.is_dir()
        and (model_path / PANNS_CNN14_16K_CONFIG).is_file()
        and (model_path / PANNS_CNN14_16K_WEIGHTS).is_file()
    )


def looks_like_panns_mlx_model(model_id: str | Path | None) -> bool:
    if model_id is None:
        return False
    text = str(model_id).strip()
    if not text:
        return False
    if is_panns_mlx_model_path(text):
        return True
    normalized = text.lower().replace("_", "-")
    return "panns" in normalized and "cnn14" in normalized and "mlx" in normalized


@lru_cache(maxsize=1)
def load_panns_mlx_model(model_dir: str | Path) -> PANNsCnn14MLX:
    model_path = Path(model_dir).expanduser()
    if not is_panns_mlx_model_path(model_path):
        raise RuntimeError(
            f"{model_path} is not a converted PANNs Cnn14_16k MLX model directory."
    )
    return PANNsCnn14MLX(model_path)


def clear_panns_mlx_model_cache() -> None:
    load_panns_mlx_model.cache_clear()
    try:
        import mlx.core as mx

        clear_cache = getattr(mx, "clear_cache", None)
        if callable(clear_cache):
            clear_cache()
    except Exception:
        pass


class PANNsCnn14MLX:
    def __init__(self, model_dir: Path):
        import mlx.core as mx

        self.mx = mx
        self.model_dir = model_dir
        with (model_dir / PANNS_CNN14_16K_CONFIG).open("r", encoding="utf-8") as handle:
            self.config: dict[str, Any] = json.load(handle)
        self.sample_rate = int(self.config.get("sample_rate") or 16_000)
        self.window_size = int(self.config.get("window_size") or 512)
        self.hop_size = int(self.config.get("hop_size") or 160)
        self.mel_bins = int(self.config.get("mel_bins") or 64)
        self.fmin = float(self.config.get("fmin") or 50.0)
        self.fmax = float(self.config.get("fmax") or 8000.0)
        self.max_seconds = max(1.0, float(os.getenv("MSUB_PANNS_MLX_MAX_SECONDS", "10")))
        labels = self.config.get("labels") or []
        self.id_to_label: dict[int, str] = {int(i): str(label) for i, label in enumerate(labels)}
        self.weights = self._load_weights(model_dir / PANNS_CNN14_16K_WEIGHTS)
        self.dtype = self.weights["conv_block1.conv1.weight"].dtype
        self.mel_filter = self._build_mel_filter()

    def _load_weights(self, path: Path) -> dict[str, Any]:
        weights: dict[str, Any] = {}
        with safe_open(path, framework="np") as handle:
            for key in handle.keys():
                weights[key] = self.mx.array(handle.get_tensor(key))
        return weights

    def predict_file(self, audio_path: str | Path) -> np.ndarray:
        audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        return self.predict([audio], sample_rate)[0]

    def predict(self, chunks: list[np.ndarray], sample_rate: int) -> np.ndarray:
        features = [self._logmel(chunk, sample_rate) for chunk in chunks]
        max_frames = max(feature.shape[0] for feature in features)
        padded = np.zeros((len(features), max_frames, self.mel_bins, 1), dtype=np.float32)
        for index, feature in enumerate(features):
            padded[index, : feature.shape[0], :, 0] = feature
        x = self.mx.array(padded).astype(self.dtype)
        scores = self._forward(x)
        self.mx.eval(scores)
        return np.array(scores, dtype=np.float32)

    def _logmel(self, samples: np.ndarray, sample_rate: int) -> np.ndarray:
        audio = np.asarray(samples, dtype=np.float32)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        if sample_rate != self.sample_rate:
            audio = self._resample(audio, sample_rate, self.sample_rate)
        audio = self._trim_for_memory(audio)
        if audio.size < self.window_size:
            audio = np.pad(audio, (0, self.window_size - audio.size))
        pad = self.window_size // 2
        if audio.size > 1:
            audio = np.pad(audio, (pad, pad), mode="reflect")
        else:
            audio = np.pad(audio, (pad, pad), mode="edge")
        frame_count = 1 + max(0, (audio.size - self.window_size) // self.hop_size)
        starts = np.arange(frame_count)[:, None] * self.hop_size
        offsets = np.arange(self.window_size)[None, :]
        frames = audio[starts + offsets]
        window = np.hanning(self.window_size).astype(np.float32)
        spectrum = np.fft.rfft(frames * window[None, :], n=self.window_size, axis=1)
        power = np.maximum((spectrum.real**2 + spectrum.imag**2).astype(np.float32), 1e-10)
        mel = np.maximum(power @ self.mel_filter, 1e-10)
        return (10.0 * np.log10(mel)).astype(np.float32)

    def _trim_for_memory(self, audio: np.ndarray) -> np.ndarray:
        limit = int(self.max_seconds * self.sample_rate)
        if limit <= 0 or audio.size <= limit:
            return audio
        start = max(0, (audio.size - limit) // 2)
        return audio[start : start + limit]

    @staticmethod
    def _resample(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
        if source_rate <= 0 or target_rate <= 0 or samples.size == 0:
            return samples.astype(np.float32, copy=False)
        duration = samples.size / float(source_rate)
        target_length = max(1, int(round(duration * target_rate)))
        source_x = np.linspace(0.0, duration, num=samples.size, endpoint=False)
        target_x = np.linspace(0.0, duration, num=target_length, endpoint=False)
        return np.interp(target_x, source_x, samples).astype(np.float32, copy=False)

    def _build_mel_filter(self) -> np.ndarray:
        try:
            import librosa

            return librosa.filters.mel(
                sr=self.sample_rate,
                n_fft=self.window_size,
                n_mels=self.mel_bins,
                fmin=self.fmin,
                fmax=self.fmax,
            ).T.astype(np.float32)
        except Exception:
            return self._fallback_mel_filter()

    def _fallback_mel_filter(self) -> np.ndarray:
        def hz_to_mel(hz: np.ndarray) -> np.ndarray:
            return 2595.0 * np.log10(1.0 + hz / 700.0)

        def mel_to_hz(mel: np.ndarray) -> np.ndarray:
            return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

        mel_points = np.linspace(
            hz_to_mel(np.array([self.fmin]))[0],
            hz_to_mel(np.array([self.fmax]))[0],
            self.mel_bins + 2,
        )
        hz_points = mel_to_hz(mel_points)
        bins = np.floor((self.window_size + 1) * hz_points / self.sample_rate).astype(int)
        filters = np.zeros((self.mel_bins, self.window_size // 2 + 1), dtype=np.float32)
        for index in range(1, self.mel_bins + 1):
            left, center, right = bins[index - 1], bins[index], bins[index + 1]
            if center > left:
                filters[index - 1, left:center] = (
                    np.arange(left, center, dtype=np.float32) - left
                ) / (center - left)
            if right > center:
                filters[index - 1, center:right] = (
                    right - np.arange(center, right, dtype=np.float32)
                ) / (right - center)
        return filters.T

    def _forward(self, x):
        x = self._batch_norm_mel(x, "bn0")
        for index, pool_size in enumerate([(2, 2), (2, 2), (2, 2), (2, 2), (2, 2), (1, 1)], 1):
            x = self._conv_block(x, f"conv_block{index}", pool_size)
        x = self.mx.mean(x, axis=2)
        x = self.mx.max(x, axis=1) + self.mx.mean(x, axis=1)
        x = self.mx.maximum(self._linear(x, "fc1"), self.mx.array(0, dtype=x.dtype))
        return self.mx.sigmoid(self._linear(x, "fc_audioset"))

    def _conv_block(self, x, prefix: str, pool_size: tuple[int, int]):
        x = self._conv2d(x, f"{prefix}.conv1.weight", padding=(1, 1))
        x = self.mx.maximum(self._batch_norm(x, f"{prefix}.bn1"), self.mx.array(0, dtype=x.dtype))
        x = self._conv2d(x, f"{prefix}.conv2.weight", padding=(1, 1))
        x = self.mx.maximum(self._batch_norm(x, f"{prefix}.bn2"), self.mx.array(0, dtype=x.dtype))
        return self._avg_pool2d(x, pool_size)

    def _conv2d(self, x, key: str, *, padding: tuple[int, int]):
        weight = self.mx.transpose(self.weights[key], (0, 2, 3, 1))
        return self.mx.conv2d(x, weight, padding=padding)

    def _batch_norm(self, x, prefix: str, eps: float = 1e-5):
        weight = self.weights[f"{prefix}.weight"]
        bias = self.weights[f"{prefix}.bias"]
        mean = self.weights[f"{prefix}.running_mean"]
        var = self.weights[f"{prefix}.running_var"]
        return (x - mean) * self.mx.rsqrt(var + eps) * weight + bias

    def _batch_norm_mel(self, x, prefix: str, eps: float = 1e-5):
        squeezed = x[:, :, :, 0]
        weight = self.weights[f"{prefix}.weight"]
        bias = self.weights[f"{prefix}.bias"]
        mean = self.weights[f"{prefix}.running_mean"]
        var = self.weights[f"{prefix}.running_var"]
        normalized = (squeezed - mean) * self.mx.rsqrt(var + eps) * weight + bias
        return normalized[:, :, :, None]

    def _avg_pool2d(self, x, pool_size: tuple[int, int]):
        kh, kw = pool_size
        if kh == 1 and kw == 1:
            return x
        batch, height, width, channels = x.shape
        pooled_h = max(1, height // kh)
        pooled_w = max(1, width // kw)
        x = x[:, : pooled_h * kh, : pooled_w * kw, :]
        x = x.reshape(batch, pooled_h, kh, pooled_w, kw, channels)
        return self.mx.mean(self.mx.mean(x, axis=4), axis=2)

    def _linear(self, x, prefix: str):
        weight = self.weights[f"{prefix}.weight"]
        bias = self.weights[f"{prefix}.bias"]
        return x @ self.mx.transpose(weight, (1, 0)) + bias
