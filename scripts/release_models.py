"""Freeze verified local model packages as bounded, checksum-pinned release assets."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import shlex
import subprocess
import tarfile
from pathlib import Path, PurePosixPath

from groundkeeper.worker import verify_package

PART_BYTES = 1_900_000_000  # Below GitHub's 2 GiB per-asset limit.
SOURCES = {"qwen-delaware": "qwen_mlx", "laya": "laya_mps"}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_catalog(path):
    data = json.loads(path.read_text())
    if data.get("format_version") != 1 or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", data.get("release_tag", "")
    ):
        raise ValueError("Invalid model catalog version or release tag")
    if {m["directory"] for m in data["models"]} != set(SOURCES) or len(data["models"]) != 2:
        raise ValueError("The release requires exactly Qwen and Laya")
    seen = set()
    for model in data["models"]:
        if model["backend"] != SOURCES[model["directory"]] or not model["parts"]:
            raise ValueError("Invalid model backend or missing parts")
        if not re.fullmatch(r"[0-9a-f]{64}", model["manifest_sha256"]):
            raise ValueError("Invalid model manifest checksum")
        for index, part in enumerate(model["parts"], 1):
            name = part["name"]
            if name != f"GroundKeeper-{model['directory']}.tar.gz.part{index:03d}" or name in seen:
                raise ValueError("Invalid or duplicate asset name")
            seen.add(name)
            if not 0 < part["bytes"] <= PART_BYTES or not re.fullmatch(
                r"[0-9a-f]{64}", part["sha256"]
            ):
                raise ValueError("Invalid asset size or checksum")
    return data


def split_file(archive, output, limit=PART_BYTES):
    if limit <= 0:
        raise ValueError("Part limit must be positive")
    parts = []
    with archive.open("rb") as source:
        while True:
            chunk = source.read(min(limit, 4 * 1024 * 1024))
            if not chunk:
                break
            path = output / f"{archive.name}.part{len(parts) + 1:03d}"
            sha = hashlib.sha256()
            size = 0
            with path.open("xb") as target:
                while chunk:
                    target.write(chunk)
                    sha.update(chunk)
                    size += len(chunk)
                    if size == limit:
                        break
                    chunk = source.read(min(limit - size, 4 * 1024 * 1024))
            parts.append({"name": path.name, "bytes": size, "sha256": sha.hexdigest()})
    return parts


def pack(source_root, output, catalog_path, tag):
    if output.exists() or catalog_path.exists():
        raise ValueError("Use a new output directory and catalog; published inputs are immutable")
    output.mkdir(parents=True)
    models = []
    for name, backend in SOURCES.items():
        source = (source_root / name).resolve()
        manifest, manifest_hash = verify_package(source, lambda: False)
        if manifest["backend"] != backend:
            raise ValueError(f"Wrong backend for {name}")
        print(f"Packaging {manifest['model_id']}", flush=True)
        archive = output / f"GroundKeeper-{name}.tar.gz"
        with (
            archive.open("xb") as raw,
            gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=6
            ) as compressed,
        ):
            with tarfile.open(fileobj=compressed, mode="w|", dereference=True) as tar:
                for relative in sorted(["classifier.json", *manifest["files"]]):
                    if (
                        PurePosixPath(relative).is_absolute()
                        or ".." in PurePosixPath(relative).parts
                        or "\\" in relative
                    ):
                        raise ValueError("Unsafe archive path")
                    path = source / relative
                    info = tar.gettarinfo(str(path), arcname=f"{name}/{relative}")
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.mode = 0o644
                    with path.open("rb") as stream:
                        tar.addfile(info, stream)
        # Ensure a concurrent training/export process did not change the package.
        if verify_package(source, lambda: False)[1] != manifest_hash:
            raise ValueError("Model manifest changed during packaging")
        parts = split_file(archive, output)
        archive.unlink()
        models.append(
            {
                "directory": name,
                "backend": backend,
                "model_id": manifest["model_id"],
                "manifest_sha256": manifest_hash,
                "parts": parts,
            }
        )
    data = {"format_version": 1, "release_tag": tag, "models": models}
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(json.dumps(data, indent=2) + "\n")
    write_install_files(load_catalog(catalog_path), output)


def verify_assets(data, output):
    for model in data["models"]:
        for part in model["parts"]:
            path = output / part["name"]
            if path.stat().st_size != part["bytes"] or digest(path) != part["sha256"]:
                raise ValueError(f"Release asset failed verification: {part['name']}")


def write_install_files(data, output):
    checksums = "".join(f"{p['sha256']}  {p['name']}\n" for m in data["models"] for p in m["parts"])
    (output / "MODEL_SHA256SUMS.txt").write_text(checksums)
    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        'cd "$(dirname "$0")"',
        "shasum -a 256 -c MODEL_SHA256SUMS.txt",
        f'destination="$HOME/Library/Application Support/GroundKeeper/Models/{data["release_tag"]}"',
        'if [[ -e "$destination" ]]; then',
        '  echo "Destination already exists: $destination. Move it aside before reinstalling." >&2',
        "  exit 1",
        "fi",
        'mkdir -p "$destination"',
    ]
    for model in data["models"]:
        parts = " ".join(shlex.quote(p["name"]) for p in model["parts"])
        lines.append(f'cat {parts} | tar -xzf - -C "$destination"')
    lines += [
        'echo "Models installed at: $destination"',
        'echo "In GroundKeeper Settings, choose the qwen-delaware or laya folder."',
        'open "$destination"',
    ]
    script = output / "Install Models.command"
    script.write_text("\n".join(lines) + "\n")
    script.chmod(0o755)


def download(data, output, repository):
    output.mkdir(parents=True, exist_ok=True)
    for model in data["models"]:
        for part in model["parts"]:
            subprocess.run(
                [
                    "gh",
                    "release",
                    "download",
                    data["release_tag"],
                    "--repo",
                    repository,
                    "--pattern",
                    part["name"],
                    "--dir",
                    str(output),
                ],
                check=True,
                timeout=1800,
            )
    verify_assets(data, output)
    write_install_files(data, output)


def main():
    parser = argparse.ArgumentParser(__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("pack")
    package.add_argument("--source", type=Path, default=Path(".local/macos/models"))
    package.add_argument("--output", type=Path, required=True)
    package.add_argument("--catalog", type=Path, default=Path("release/models.json"))
    package.add_argument("--tag", required=True)
    fetch = commands.add_parser("download")
    fetch.add_argument("--catalog", type=Path, default=Path("release/models.json"))
    fetch.add_argument("--output", type=Path, required=True)
    fetch.add_argument("--repo", required=True)
    args = parser.parse_args()
    if args.command == "pack":
        pack(args.source, args.output, args.catalog, args.tag)
    else:
        download(load_catalog(args.catalog), args.output, args.repo)


if __name__ == "__main__":
    main()
