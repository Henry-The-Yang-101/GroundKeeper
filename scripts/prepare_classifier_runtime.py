"""Stage a relocatable, offline CPython/MLX/MPS runtime from pinned local installs.

Does not mutate source environments or download models. Run once before Xcode.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / ".local/macos/classifier-runtime"


def inventory(python):
    code = """import sys,sysconfig,json,importlib.metadata as m
print(json.dumps({"version":list(sys.version_info[:3]),"home":sys.base_prefix,"include":sysconfig.get_path("include"),
"packages":{d.metadata["Name"].lower().replace("_","-"):{"name":d.metadata["Name"],"version":d.version,"requires":d.requires or [],"files":[str(f) for f in d.files or []],"root":str(d.locate_file(""))} for d in m.distributions()}}))"""
    return json.loads(subprocess.check_output([str(python), "-I", "-c", code], text=True))


def native(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as f:
        return f.read(4) in (
            b"\xcf\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xca\xfe\xba\xbe",
            b"\xbe\xba\xfe\xca",
        )


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--python", type=Path, default=ROOT / ".venv/bin/python")
    parser.add_argument("--laya-python", type=Path, default=ROOT / ".local/laya/.venv/bin/python")
    parser.add_argument(
        "--search-python", type=Path, default=ROOT / ".local/merchant-search-ddgs/venv/bin/python"
    )
    parser.add_argument("--rebuild", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The embedded classifier requires Apple silicon macOS")
    mlx_env, laya_env, search_env = (
        inventory(args.python),
        inventory(args.laya_python),
        inventory(args.search_python),
    )
    if mlx_env["version"] != laya_env["version"] or mlx_env["version"][:2] != [3, 12]:
        parser.error("Both source environments must use the same CPython 3.12 runtime")
    if search_env["version"] != mlx_env["version"]:
        parser.error("The search environment must use the same CPython runtime")
    # Resolve the actual installed dependency closure, not the entire research venv.
    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name

    selected = {}
    queue = ["mlx", "mlx-metal", "mlx-lm", "torch", "laya", "ddgs", "primp", "lxml"]
    while queue:
        name = canonicalize_name(queue.pop())
        if name in selected:
            continue
        source = (
            search_env
            if name in ("ddgs", "primp", "lxml")
            else mlx_env
            if name in ("mlx", "mlx-metal", "mlx-lm", "sentencepiece", "protobuf")
            else laya_env
        )
        package = source["packages"].get(name) or mlx_env["packages"].get(name)
        if not package:
            parser.error(f"Missing installed dependency: {name}")
        selected[name] = package
        for text in package["requires"]:
            requirement = Requirement(text)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                queue.append(requirement.name)
    for package in selected.values():
        for text in package["requires"]:
            requirement = Requirement(text)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                if (
                    selected[canonicalize_name(requirement.name)]["version"]
                    not in requirement.specifier
                ):
                    parser.error(
                        f"Incompatible installed versions: {package['name']} requires {requirement}"
                    )
    lock = {
        "format_version": 2,
        "architecture": "arm64",
        "python": mlx_env["version"],
        "packages": {name: p["version"] for name, p in sorted(selected.items())},
    }
    expected = ROOT / "contracts/classifier/runtime-lock.json"
    if json.loads(expected.read_text()) != lock:
        parser.error(
            "Installed runtime differs from contracts/classifier/runtime-lock.json; resolve and review pinned versions before bundling"
        )
    marker = DEST / "runtime-lock.json"
    if marker.exists() and json.loads(marker.read_text()) == lock and not args.rebuild:
        print(f"Runtime already staged: {DEST}")
        return
    temporary = DEST.with_name(DEST.name + ".building")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    home = Path(mlx_env["home"])
    python_root = temporary / "Resources/Python"
    shutil.copytree(
        home / "lib/python3.12",
        python_root / "lib/python3.12",
        ignore=shutil.ignore_patterns(
            "__pycache__", "site-packages", "test", "tests", "idlelib", "tkinter", "ensurepip"
        ),
    )
    shutil.copytree(mlx_env["include"], temporary / "include")
    frameworks = temporary / "Frameworks"
    frameworks.mkdir()
    shutil.copy2(home / "lib/libpython3.12.dylib", frameworks / "libpython3.12.dylib")
    site = python_root / "site-packages"
    site.mkdir()
    for name, package in sorted(selected.items()):
        for filename in package["files"]:
            relative = Path(filename)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or relative.suffix in (".pyc", ".a")
                or "__pycache__" in relative.parts
            ):
                continue
            source = Path(package["root"]) / relative
            if not source.is_file():
                continue
            target = site / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target, follow_symlinks=True)
    library = frameworks / "libpython3.12.dylib"
    subprocess.run(
        ["install_name_tool", "-id", "@rpath/libpython3.12.dylib", str(library)], check=True
    )
    machos = [p for p in temporary.rglob("*") if native(p)]
    for path in machos:
        architectures = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
        if "arm64" not in architectures:
            raise RuntimeError(f"Missing Apple silicon slice: {path.name}")
        if len(architectures) > 1:
            thinned = path.with_name(path.name + ".arm64")
            subprocess.run(
                ["lipo", str(path), "-thin", "arm64", "-output", str(thinned)], check=True
            )
            thinned.replace(path)
        dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
        identities = {
            line.strip()
            for line in subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()
            if line.strip() and not line.rstrip().endswith(":")
        }
        if identities:
            subprocess.run(
                ["install_name_tool", "-id", "@rpath/" + path.name, str(path)], check=True
            )
        original = str(home / "lib/libpython3.12.dylib")
        if original in dependencies:
            subprocess.run(
                ["install_name_tool", "-change", original, "@rpath/libpython3.12.dylib", str(path)],
                check=True,
            )
        for line in dependencies.splitlines()[1:]:
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency in identities:
                continue
            if dependency == str(path):
                subprocess.run(
                    ["install_name_tool", "-id", "@rpath/" + path.name, str(path)], check=True
                )
                continue
            if (
                dependency.startswith("/")
                and not dependency.startswith(("/usr/lib/", "/System/Library/"))
                and dependency != original
            ):
                raise RuntimeError(
                    f"Non-relocatable native dependency in {path.name}: {dependency}"
                )
    # Sign only copied files. Xcode re-signs them with the app identity on embedding.
    for path in machos:
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--options", "runtime", str(path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    (temporary / "runtime-lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    if DEST.exists():
        shutil.rmtree(DEST)
    temporary.rename(DEST)
    print(f"Staged {len(selected)} distributions, {len(machos)} native libraries: {DEST}")


if __name__ == "__main__":
    main()
