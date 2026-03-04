import importlib.util
import os
import subprocess
import sys

REQUIRED = {
    "fastapi==0.115.12": "fastapi",
    "pydantic==2.11.0": "pydantic",
    "uvicorn==0.34.0": "uvicorn",
    "transformers==4.51.3": "transformers",
    "safetensors==0.5.3": "safetensors",
}


def parse_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


missing = [pkg for pkg, mod in REQUIRED.items() if importlib.util.find_spec(mod) is None]
if not missing:
    raise SystemExit(0)

allow_runtime_install = parse_bool("OCI2GDS_ALLOW_RUNTIME_PIP_INSTALL", False)
if not allow_runtime_install:
    names = ", ".join(missing)
    raise SystemExit(
        "missing runtime Python dependencies: "
        f"{names}. Build/use an image with these preinstalled. "
        "For temporary debugging only, set OCI2GDS_ALLOW_RUNTIME_PIP_INSTALL=true."
    )

subprocess.check_call(
    [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--no-cache-dir",
        "--break-system-packages",
        *missing,
    ]
)
