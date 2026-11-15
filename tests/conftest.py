import os
import sys
import importlib.util

ROOT = os.path.join(os.path.dirname(__file__), "..")
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "1")          # nothing listens here, so DB calls fail fast
os.environ.setdefault("API_URL", "http://127.0.0.1:1")
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-southeast-2")
sys.path.insert(0, os.path.join(ROOT, "services"))


def load(name, path):
    """Import a module from a file under a unique name (every tier has an app.py)."""
    folder = os.path.dirname(os.path.join(ROOT, path))
    sys.path.insert(0, folder)
    try:
        spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, path))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.path.remove(folder)
