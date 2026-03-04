import importlib.util
import subprocess
import sys

wanted = {
    "fastapi": "fastapi",
    "pydantic": "pydantic",
    "uvicorn": "uvicorn",
    "transformers": "transformers",
    "safetensors": "safetensors",
}
missing = [pkg for pkg, mod in wanted.items() if importlib.util.find_spec(mod) is None]
if missing:
    subprocess.check_call([
        sys.executable,
        "-m",
        "pip",
        "install",
        "--no-cache-dir",
        "--break-system-packages",
        *missing,
    ])
