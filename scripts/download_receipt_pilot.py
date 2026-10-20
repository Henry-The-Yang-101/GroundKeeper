"""Fetch a reproducible, attributed SROIE image sample without training on it."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import time
import urllib.request

REPOSITORY = "zzzDavid/ICDAR-2019-SROIE"
REVISION = "27be4271b251c256f695acbade9a801bffe85994"
BASE = f"https://raw.githubusercontent.com/{REPOSITORY}/{REVISION}"


def fetch(url):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=45) as response:
                return response.read(12_000_001)
        except OSError:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".local/receipts/sroie-100"))
    parser.add_argument("--count", type=int, default=100, choices=range(50, 101))
    args = parser.parse_args()
    root = args.output
    root.mkdir(parents=True, exist_ok=True)
    tree = json.loads(fetch(f"https://api.github.com/repos/{REPOSITORY}/git/trees/{REVISION}?recursive=1"))
    entries = {entry["path"]: entry for entry in tree["tree"] if entry["type"] == "blob"}
    # Distributed across the mirror, selected by a fixed hash, not by OCR/model quality.
    images = sorted((p for p in entries if p.startswith("data/img/") and p.endswith(".jpg")),
                    key=lambda p: hashlib.sha256(("groundkeeper-receipts-v1|" + p).encode()).hexdigest())[:args.count]

    def sample(path):
        sample_id = Path(path).stem
        files = []
        for source in [path, f"data/box/{sample_id}.csv", f"data/key/{sample_id}.json"]:
            if source not in entries:
                continue
            local = root / source.removeprefix("data/")
            local.parent.mkdir(parents=True, exist_ok=True)
            blob = local.read_bytes() if local.exists() else fetch(f"{BASE}/{source}")
            expected = entries[source]
            git_hash = hashlib.sha1(b"blob " + str(len(blob)).encode() + b"\0" + blob).hexdigest()
            if len(blob) != expected["size"] or git_hash != expected["sha"]:
                raise ValueError(f"Source hash mismatch: {source}")
            if not local.exists():
                local.write_bytes(blob)
            files.append({"path": str(local.relative_to(root)), "source_url": f"{BASE}/{source}",
                          "bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest()})
        return {"id": sample_id, "files": files}

    with ThreadPoolExecutor(max_workers=8) as pool:
        samples = list(pool.map(sample, images))
    manifest = {"dataset": "ICDAR 2019 SROIE", "mirror": f"https://github.com/{REPOSITORY}",
                "revision": REVISION, "license": "CC-BY-4.0 (dataset; mirror code license is separate)",
                "dataset_license_source": "https://rrc.cvc.uab.es/?ch=13&com=downloads",
                "license_documentation": "https://github.com/jsdnrs/ICDAR2019-SROIE/blob/77c4c11490e3c4179ee22f86611569c71c04b5f9/DATASET.md",
                "attribution": "Huang et al., ICDAR2019 Competition on Scanned Receipt OCR and Information Extraction, 2019, doi:10.1109/ICDAR.2019.00244",
                "selection": "First N image paths sorted by SHA256('groundkeeper-receipts-v1|' + path)",
                "use": "OCR and integration evaluation only; no GroundKeeper category ground truth; no training",
                "domain": "English-language Malaysian receipts; not a Canadian accuracy benchmark",
                "count": len(samples), "samples": samples}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (root / "ATTRIBUTION.txt").write_text(manifest["attribution"] + "\n" + manifest["license"] + "\n" + manifest["dataset_license_source"] + "\n")
    print(json.dumps({"downloaded_images": len(samples), "directory": str(root.resolve()),
                      "bytes": sum(f["bytes"] for s in samples for f in s["files"])}))


if __name__ == "__main__":
    main()
