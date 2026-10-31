"""MLX execution for the existing converted Pyannote segmentation weights."""


class PyannoteMLX:
    def __init__(self, weights):
        import mlx.core as mx
        import mlx.nn as nn

        self.numpy_weights = weights
        self.weights = {key: mx.array(value) for key, value in weights.items()}
        self.layers = []
        for layer in range(4):
            directions = []
            for direction in ("fwd", "bwd"):
                prefix = f"lstm_{direction}.layers.{layer}"
                wx = self.weights[f"{prefix}.Wx"]
                wh = self.weights[f"{prefix}.Wh"]
                recurrent = nn.LSTM(wx.shape[1], wh.shape[1])
                recurrent.Wx = wx
                recurrent.Wh = wh
                recurrent.bias = self.weights[f"{prefix}.bias"]
                directions.append(recurrent)
            def compiled_layer(forward, backward):
                def apply(x):
                    fwd, _ = forward(x)
                    bwd, _ = backward(x[..., ::-1, :])
                    return mx.concatenate((fwd, bwd[..., ::-1, :]), axis=-1)
                return mx.compile(apply)
            self.layers.append(compiled_layer(*directions))
        mx.eval(self.weights)

    def __call__(self, samples):
        import mlx.core as mx
        import numpy as np

        weights = self.weights

        def normalize(x, prefix):
            mean = mx.mean(x, axis=0, keepdims=True)
            variance = mx.var(x, axis=0, keepdims=True)
            return (x - mean) * mx.rsqrt(variance + 1e-5) * weights[f"{prefix}.weight"] + weights[f"{prefix}.bias"]

        def pool(x):
            length = x.shape[0] // 3
            return mx.max(x[:length * 3].reshape(length, 3, x.shape[1]), axis=1)

        def activate(x):
            return mx.where(x >= 0, x, x * 0.01)

        x = normalize(mx.array(samples, dtype=mx.float32).reshape(-1, 1), "sincnet.wav_norm")
        x = mx.conv1d(x[None], weights["sincnet.conv.0.weight"], stride=10)[0]
        x = activate(normalize(pool(mx.abs(x)), "sincnet.norm.0"))
        for layer in (1, 2):
            prefix = f"sincnet.conv.{layer}"
            x = mx.conv1d(x[None], weights[f"{prefix}.weight"])[0] + weights[f"{prefix}.bias"]
            x = activate(normalize(pool(x), f"sincnet.norm.{layer}"))
        mx.eval(x)
        for recurrent in self.layers:
            x = recurrent(x)
            # Bound the lazy recurrent graph to one bidirectional layer.
            mx.eval(x)
        for layer in (0, 1):
            x = activate(x @ weights[f"linear.{layer}.weight"].T + weights[f"linear.{layer}.bias"])
        logits = x @ weights["classifier.weight"].T + weights["classifier.bias"]
        speech = mx.clip(1.0 - mx.softmax(logits, axis=-1)[:, 0], 0.0, 1.0)
        mx.eval(speech)
        return np.asarray(speech, dtype=np.float32)


    def predict_batch(self, samples, *, frontend="numpy"):
        """Experimental fixed-window batches, capped at four; no production default change."""
        import mlx.core as mx
        import numpy as np

        samples = np.asarray(samples, dtype=np.float32)
        if samples.ndim != 2 or not 1 <= samples.shape[0] <= 4 or samples.shape[1] != 160000:
            raise ValueError("Pyannote batches require 1–4 fixed 10-second/16 kHz windows")
        weights = self.weights

        def normalize(x, prefix):
            mean = mx.mean(x, axis=-2, keepdims=True)
            variance = mx.var(x, axis=-2, keepdims=True)
            return (x - mean) * mx.rsqrt(variance + 1e-5) * weights[f"{prefix}.weight"] + weights[f"{prefix}.bias"]

        def pool(x):
            length = x.shape[1] // 3
            return mx.max(x[:, :length * 3].reshape(x.shape[0], length, 3, x.shape[2]), axis=2)

        def activate(x):
            return mx.where(x >= 0, x, x * 0.01)

        if frontend == "numpy":
            # Constant/silent inputs amplify tiny normalization differences in
            # the GPU sincnet frontend. Retain the exact CPU frontend while
            # batching the recurrent/dense layers on GPU.
            from .cli import pyannote_sincnet_features
            x = mx.array(np.stack([pyannote_sincnet_features(window, self.numpy_weights)
                                   for window in samples]))
        elif frontend == "mlx":
            x = normalize(mx.array(samples, dtype=mx.float32).reshape(samples.shape[0], -1, 1), "sincnet.wav_norm")
            x = mx.conv1d(x, weights["sincnet.conv.0.weight"], stride=10)
            x = activate(normalize(pool(mx.abs(x)), "sincnet.norm.0"))
            for layer in (1, 2):
                prefix = f"sincnet.conv.{layer}"
                x = mx.conv1d(x, weights[f"{prefix}.weight"]) + weights[f"{prefix}.bias"]
                x = activate(normalize(pool(x), f"sincnet.norm.{layer}"))
        else:
            raise ValueError("frontend must be numpy or mlx")
        mx.eval(x)
        for recurrent in self.layers:
            x = recurrent(x)
            # Bound the lazy recurrent graph to one bidirectional layer.
            mx.eval(x)
        for layer in (0, 1):
            x = activate(x @ weights[f"linear.{layer}.weight"].T + weights[f"linear.{layer}.bias"])
        logits = x @ weights["classifier.weight"].T + weights["classifier.bias"]
        speech = mx.clip(1.0 - mx.softmax(logits, axis=-1)[..., 0], 0.0, 1.0)
        mx.eval(speech)
        return np.asarray(speech, dtype=np.float32)


def make_pyannote_forward(weights, numpy_forward, backend="numpy"):
    """Retain a CPU reference/fallback for hosts without a Metal device."""
    if backend not in {"auto", "mlx", "mlx_batch", "numpy"}:
        raise ValueError("MSUB_PYANNOTE_MLX_BACKEND must be auto, mlx, or numpy (or experimental mlx_batch)")
    if backend == "numpy":
        return lambda samples: numpy_forward(samples, weights), "numpy"
    # MLX caches this process-level setting at first use. Require it at launch
    # rather than mutating another model's numeric policy midway through a job.
    import os
    if os.getenv("MLX_ENABLE_TF32") != "0":
        if backend in {"mlx", "mlx_batch"}:
            raise ValueError("Start the backend with MLX_ENABLE_TF32=0 for validated Pyannote MLX precision")
        return lambda samples: numpy_forward(samples, weights), "numpy"
    try:
        import mlx.core as mx
    except ImportError:
        if backend in {"mlx", "mlx_batch"}:
            raise
    else:
        if mx.metal.is_available():
            return PyannoteMLX(weights), "mlx_batch" if backend == "mlx_batch" else "mlx"
        if backend in {"mlx", "mlx_batch"}:
            raise RuntimeError("Pyannote MLX requires a Metal device")
    return lambda samples: numpy_forward(samples, weights), "numpy"
