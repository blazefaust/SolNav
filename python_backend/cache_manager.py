import hashlib, json, pathlib
from typing import Optional

class RenderCache:
    def __init__(self, cache_dir: pathlib.Path):
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.index_file = self.cache_dir / "index.json"
        self.index = json.loads(self.index_file.read_text()) if self.index_file.exists() else {}

    def key(self, kind: str, params: dict) -> str:
        payload = json.dumps({"kind": kind, **params}, sort_keys=True)
        return hashlib.sha1(payload.encode()).hexdigest()[:16]

    def lookup(self, k: str) -> Optional[str]:
        p = self.index.get(k)
        if p and pathlib.Path(p).exists():
            return p
        return None

    def store(self, k: str, path: str):
        self.index[k] = path
        self.index_file.write_text(json.dumps(self.index, indent=2))