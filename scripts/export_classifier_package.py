"""Export an existing verified experimental model as a data-only app package."""

import argparse
import hashlib
import json
from pathlib import Path

from groundkeeper.worker import MAX_PACKAGE_BYTES, POLICY_VERSION


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--backend", choices=("qwen_mlx", "laya_mps"), required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--prompt-version", choices=("v1", "v2"), default="v1")
    parser.add_argument(
        "--verified-fallback",
        type=Path,
        help="Recover changed source metadata only from files matching the original manifest hash",
    )
    args = parser.parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    if destination.exists() or destination.is_relative_to(source):
        parser.error("Destination must be new and outside source package")
    source_manifest = json.loads((source / "manifest.json").read_text())
    files = {}
    verified_sources = {}
    total = 0
    for name, recorded in source_manifest["files"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            parser.error("Invalid source manifest path")
        if relative.suffix not in (
            ".safetensors",
            ".json",
            ".jinja",
            ".model",
            ".txt",
            ".tiktoken",
        ):
            continue
        # Model code from experiment packages must never become executable app code.
        if relative.parts[0] == "groundkeeper":
            continue
        path = (source / relative).resolve()
        if not path.is_relative_to(source) or not path.is_file():
            parser.error("Source file missing or outside package")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while chunk := stream.read(4 * 1024 * 1024):
                digest.update(chunk)
        size = path.stat().st_size
        if digest.hexdigest() != recorded["sha256"] or size != recorded["bytes"]:
            fallback = (
                (args.verified_fallback / relative).resolve() if args.verified_fallback else None
            )
            if (
                fallback is None
                or not fallback.is_relative_to(args.verified_fallback.resolve())
                or not fallback.is_file()
            ):
                parser.error(f"Source package integrity mismatch: {name}")
            # Metadata recovery is bounded and explicit, never a bypass for weights.
            if relative.suffix != ".json" or fallback.stat().st_size > 65536:
                parser.error(f"Only small manifest-verified JSON metadata can be recovered: {name}")
            content = fallback.read_bytes()
            if (
                len(content) != recorded["bytes"]
                or hashlib.sha256(content).hexdigest() != recorded["sha256"]
            ):
                parser.error(f"Fallback integrity mismatch: {name}")
            path = fallback
            size = len(content)
            digest = hashlib.sha256(content)
            print(f"Recovered original manifest-verified metadata from checkpoint: {name}")
        total += size
        if total > MAX_PACKAGE_BYTES:
            parser.error("Model package exceeds 3 GB")
        files[name] = {"bytes": size, "sha256": digest.hexdigest()}
        verified_sources[name] = path
    destination.mkdir(parents=True)
    for name in files:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        # macOS copy-on-write clone avoids duplicating multi-GB weights on APFS.
        import subprocess

        subprocess.run(["/bin/cp", "-c", str(verified_sources[name]), str(target)], check=True)
    if args.backend == "laya_mps":
        # Normalize before hashing/export: Laya must not rewrite a read-only package.
        config = destination / "tokenizer/tokenizer_config.json"
        value = json.loads(config.read_text())
        if value.get("tokenizer_class") in (None, "TokenizersBackend"):
            value["tokenizer_class"] = "PreTrainedTokenizerFast"
            value.pop("backend", None)
            value.pop("is_local", None)
        if isinstance(value.get("extra_special_tokens"), list):
            value["extra_special_tokens"] = {
                f"extra_{i}": token for i, token in enumerate(value["extra_special_tokens"])
            }
        config.write_text(json.dumps(value, indent=2))
        files["tokenizer/tokenizer_config.json"] = {
            "bytes": config.stat().st_size,
            "sha256": hashlib.sha256(config.read_bytes()).hexdigest(),
        }
    manifest = {
        "format_version": 1,
        "model_id": args.model_id,
        "backend": args.backend,
        "policy_version": POLICY_VERSION,
        "prompt_version": args.prompt_version,
        "model_directory": "model" if args.backend == "qwen_mlx" else ".",
        "files": files,
    }
    if args.backend == "qwen_mlx" and (destination / "adapters").is_dir():
        manifest["adapter_directory"] = "adapters"
    encoded = json.dumps(manifest, indent=2) + "\n"
    package_bytes = sum(f["bytes"] for f in files.values()) + len(encoded.encode())
    if package_bytes > MAX_PACKAGE_BYTES:
        parser.error("Complete model package including manifest exceeds 3 GB")
    (destination / "classifier.json").write_text(encoded)
    print(json.dumps({"package": str(destination), "bytes": package_bytes, "files": len(files)}))


if __name__ == "__main__":
    main()
