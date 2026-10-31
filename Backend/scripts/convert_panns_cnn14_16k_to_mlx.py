#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from urllib.request import urlretrieve

import numpy as np
from safetensors.numpy import save_file


CHECKPOINT_URL = (
    "https://zenodo.org/record/3987831/files/"
    "Cnn14_16k_mAP%3D0.438.pth?download=1"
)
LABELS_URL = (
    "https://raw.githubusercontent.com/qiuqiangkong/"
    "audioset_tagging_cnn/master/metadata/class_labels_indices.csv"
)
KEEP_PREFIXES = ("bn0.", "conv_block", "fc1.", "fc_audioset.")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_labels(path: Path | None, root: Path) -> list[str]:
    if path is not None and path.exists():
        return read_label_csv(path)

    ast_config = root / "models" / "ast-finetuned-audioset-10-10-0.4593" / "config.json"
    if ast_config.exists():
        with ast_config.open("r", encoding="utf-8") as handle:
            config = json.load(handle)
        id_to_label = config.get("id2label") or {}
        if id_to_label:
            return [
                str(id_to_label[str(index)])
                for index in range(len(id_to_label))
                if str(index) in id_to_label
            ]

    labels_cache = root / ".cache" / "panns" / "class_labels_indices.csv"
    labels_cache.parent.mkdir(parents=True, exist_ok=True)
    if not labels_cache.exists():
        print(f"Downloading AudioSet labels to {labels_cache}", file=sys.stderr)
        urlretrieve(LABELS_URL, labels_cache)
    return read_label_csv(labels_cache)


def read_label_csv(path: Path) -> list[str]:
    labels: list[str] = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            labels.append(row["display_name"])
    if len(labels) != 527:
        raise RuntimeError(f"Expected 527 AudioSet labels, got {len(labels)} from {path}.")
    return labels


def resolve_checkpoint(path: Path, download: bool) -> Path:
    if path.exists():
        return path
    if not download:
        raise RuntimeError(f"{path} does not exist. Re-run with --download.")
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading PANNs Cnn14_16k checkpoint to {path}", file=sys.stderr)
    urlretrieve(CHECKPOINT_URL, path)
    return path


def load_checkpoint(path: Path) -> dict[str, np.ndarray]:
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("Converting the official .pth checkpoint requires torch.") from exc

    checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    state = checkpoint.get("model") or checkpoint.get("state_dict") or checkpoint
    tensors: dict[str, np.ndarray] = {}
    for raw_key, value in state.items():
        key = str(raw_key)
        if key.startswith("module."):
            key = key[len("module.") :]
        if not key.startswith(KEEP_PREFIXES):
            continue
        if not hasattr(value, "detach"):
            continue
        tensors[key] = value.detach().cpu().numpy()
    required = [
        "bn0.weight",
        "conv_block1.conv1.weight",
        "conv_block6.conv2.weight",
        "fc1.weight",
        "fc_audioset.weight",
    ]
    missing = [key for key in required if key not in tensors]
    if missing:
        raise RuntimeError(f"Checkpoint is missing expected Cnn14_16k tensors: {missing}")
    return tensors


def cast_tensors(tensors: dict[str, np.ndarray], dtype: str) -> dict[str, np.ndarray]:
    if dtype == "float32":
        return {key: np.asarray(value, dtype=np.float32) for key, value in tensors.items()}
    if dtype == "float16":
        return {
            key: np.asarray(value, dtype=np.float16 if value.dtype.kind == "f" else value.dtype)
            for key, value in tensors.items()
        }
    raise RuntimeError(f"Unsupported dtype {dtype!r}.")


def main() -> None:
    root = repo_root()
    parser = argparse.ArgumentParser(
        description="Convert the official PANNs Cnn14_16k PyTorch checkpoint to a local MLX safetensors directory."
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=root / "models" / "panns-cnn14-16k-pytorch" / "Cnn14_16k_mAP=0.438.pth",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=root / "models" / "panns-cnn14-16k-mlx",
    )
    parser.add_argument("--labels", type=Path, default=None)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()

    checkpoint = resolve_checkpoint(args.checkpoint.expanduser(), args.download)
    labels = load_labels(args.labels.expanduser() if args.labels else None, root)
    tensors = cast_tensors(load_checkpoint(checkpoint), args.dtype)

    args.output.mkdir(parents=True, exist_ok=True)
    weights_path = args.output / "panns_cnn14_16k.safetensors"
    save_file(tensors, weights_path, metadata={"format": "pt", "source": "PANNs Cnn14_16k"})

    config = {
        "model_type": "panns_cnn14_16k",
        "source_checkpoint": str(checkpoint),
        "sample_rate": 16000,
        "window_size": 512,
        "hop_size": 160,
        "mel_bins": 64,
        "fmin": 50,
        "fmax": 8000,
        "classes_num": 527,
        "dtype": args.dtype,
        "labels": labels,
    }
    with (args.output / "panns_cnn14_16k_config.json").open("w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"Wrote {weights_path}")


if __name__ == "__main__":
    main()
