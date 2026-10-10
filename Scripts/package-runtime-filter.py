"""Rsync exclusions applied before copying the bundled Python runtime.

Keep rules here synchronized with packaging policy, not with arbitrary installed
packages. Patterns are rooted at the contents of .venv or sys.base_prefix.
"""
import argparse


CORE_PACKAGES = (
    'torch', 'torch-*.dist-info', 'torchgen', 'torchgen-*.dist-info',
    'torchaudio', 'torchaudio-*.dist-info', 'torchcodec', 'torchcodec-*.dist-info',
    'torch_complex', 'torch_complex-*.dist-info', 'functorch', 'torchmetrics',
    'torchmetrics-*.dist-info', 'torch_audiomentations', 'torch_audiomentations-*.dist-info', 'torch_pitch_shift',
    'torch_pitch_shift-*.dist-info', 'pytorch_lightning', 'pytorch_lightning-*.dist-info', 'pytorch_metric_learning',
    'pytorch_metric_learning-*.dist-info', 'pytorch_wpe.py', 'pytorch_wpe-*.dist-info', 'pyannote',
    'pyannote_*.dist-info', 'pyannoteai', 'pyannoteai_*.dist-info', 'julius',
    'julius-*.dist-info', 'primePy', 'primePy-*.dist-info', 'einops',
    'einops-*.dist-info', 'lightning_utilities', 'lightning_utilities-*.dist-info', 'funasr',
    'funasr-*.dist-info', 'modelscope', 'modelscope-*.dist-info', 'editdistance',
    'editdistance-*.dist-info', 'tiktoken', 'tiktoken-*.dist-info', 'tiktoken_ext',
    'requests', 'requests-*.dist-info', 'urllib3', 'urllib3-*.dist-info',
    'charset_normalizer', 'charset_normalizer-*.dist-info', 'fireredvad', 'fireredvad-*.dist-info',
    'pyaml', 'pyaml-*.dist-info', 'sounddevice.py', '_sounddevice.py',
    '_sounddevice_data', 'sounddevice-*.dist-info', 'httptools', 'httptools-*.dist-info',
    'uvloop', 'uvloop-*.dist-info', 'watchfiles', 'watchfiles-*.dist-info',
    'websockets', 'websockets-*.dist-info', 'dotenv', 'python_dotenv-*.dist-info',
    'lightning', 'lightning-*.dist-info', 'lightning_fabric', 'lightning_fabric-*.dist-info',
    'asteroid_filterbanks', 'asteroid_filterbanks-*.dist-info', 'speechbrain', 'speechbrain-*.dist-info',
    'numba', 'numba-*.dist-info', 'llvmlite', 'llvmlite-*.dist-info',
    'librosa', 'librosa-*.dist-info', 'audioread', 'audioread-*.dist-info',
    'soxr', 'soxr-*.dist-info', 'lazy_loader', 'lazy_loader-*.dist-info',
    'pooch', 'pooch-*.dist-info', 'platformdirs', 'platformdirs-*.dist-info',
    'joblib', 'joblib-*.dist-info', 'threadpoolctl.py', 'threadpoolctl-*.dist-info',
    'decorator.py', 'decorator-*.dist-info', 'msgpack', 'msgpack-*.dist-info',
    'sklearn', 'scikit_learn-*.dist-info', 'umap', 'umap_learn-*.dist-info',
    'pynndescent', 'pynndescent-*.dist-info', 'pandas', 'pandas-*.dist-info',
    'matplotlib', 'matplotlib-*.dist-info', 'mpl_toolkits', 'PIL',
    'pillow-*.dist-info', 'fontTools', 'fonttools-*.dist-info', 'contourpy',
    'contourpy-*.dist-info', 'cycler', 'cycler-*.dist-info', 'kiwisolver',
    'kiwisolver-*.dist-info', 'pyparsing', 'pyparsing-*.dist-info', 'dateutil',
    'python_dateutil-*.dist-info', 'six.py', 'six-*.dist-info', 'pylab.py',
    'grpc', 'grpcio-*.dist-info', 'opentelemetry', 'opentelemetry_*.dist-info',
    'Crypto', 'pycryptodome-*.dist-info', 'jieba', 'jieba-*.dist-info',
    'jamo', 'jamo-*.dist-info', 'jaconv', 'jaconv-*.dist-info',
    'hydra', 'hydra_core-*.dist-info', 'omegaconf', 'omegaconf-*.dist-info',
    'antlr4', 'antlr4_python3_runtime-*.dist-info', 'textgrid', 'textgrid-*.dist-info',
    'tensorboardX', 'tensorboardx-*.dist-info', 'oss2', 'oss2-*.dist-info',
    'aliyunsdkcore', 'aliyunsdkcore-*.dist-info', 'aliyunsdkkms', 'aliyun_python_sdk_*.dist-info',
    'crcmod', 'crcmod-*.dist-info', 'jmespath', 'jmespath-*.dist-info',
    'cryptography', 'cryptography-*.dist-info', 'aiohttp', 'aiohttp-*.dist-info',
    'aiohappyeyeballs', 'aiohappyeyeballs-*.dist-info', 'aiosignal', 'aiosignal-*.dist-info',
    'frozenlist', 'frozenlist-*.dist-info', 'multidict', 'multidict-*.dist-info',
    'propcache', 'propcache-*.dist-info', 'yarl', 'yarl-*.dist-info',
    'sqlalchemy', 'sqlalchemy-*.dist-info', 'SQLAlchemy-*.dist-info', 'alembic',
    'alembic-*.dist-info', 'mako', 'mako-*.dist-info', 'colorlog',
    'colorlog-*.dist-info', 'sortedcontainers', 'sortedcontainers-*.dist-info', 'optuna',
    'optuna-*.dist-info', 'networkx', 'networkx-*.dist-info', 'setuptools',
    'setuptools-*.dist-info', 'pkg_resources', '_distutils_hack', 'distutils-precedence.pth',
    'pydevd_plugins',
)


def exclusions(target, profile="core", slim=True):
    if target not in {"venv", "python"} or profile not in {"core", "full"}:
        raise ValueError("Unknown runtime target or bundle profile")
    rules = ["__pycache__/", "*.pyc", "*.pyo", ".DS_Store"]
    if target == "venv":
        rules.append("_editable_impl_*.pth")
        site = "/lib/python*/site-packages/"
        if profile == "core":
            rules.extend(site + name for name in CORE_PACKAGES)
        if slim:
            # Preserve public `testing` modules and *.pyi: lazy_loader uses
            # those stubs at runtime. These match the former post-copy trim.
            directories = ("include", "tests", "cmake", "share/man", "share/doc",
                           "examples", "example", "benchmarks", "benchmark", "docs", "doc",
                           "*.dSYM", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
                           ".ipynb_checkpoints")
            # Apple's openrsync treats **/ as requiring a directory component;
            # include the direct site-packages children explicitly as well.
            rules.extend(site + prefix + name + "/" for prefix in ("", "**/") for name in directories)
            extensions = ("a", "la", "o", "c", "cc", "cpp", "h", "hpp", "pyx", "pxd")
            rules.extend(site + prefix + "*." + extension for prefix in ("", "**/") for extension in extensions)
    elif slim:
        rules.extend("/lib/python*/" + name + "/" for name in
                     ("idlelib", "turtledemo", "tkinter", "lib2to3", "ensurepip", "test"))
        rules.extend(("/lib/python*/turtle.py", "/include/", "/share/man/", "/share/doc/"))
    return rules


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("venv", "python"))
    parser.add_argument("--profile", choices=("core", "full"), default="core")
    parser.add_argument("--slim", choices=("0", "1"), default="1")
    args = parser.parse_args()
    print("\n".join(exclusions(args.target, args.profile, args.slim == "1")))
