"""Embed one physical CPython/dependency copy in the host app, shared by both XPCs."""

import hashlib
import os
import shutil
import subprocess
from pathlib import Path

from scripts.prepare_classifier_runtime import DEST, native


def main():
    bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    key = hashlib.sha256(
        (DEST / "runtime-lock.json").read_bytes() + identity.encode() + b"shared-runtime-v1"
    ).hexdigest()
    marker = bundle / "Resources/runtime-embedding.txt"
    if not marker.is_file() or marker.read_text() != key:
        target = bundle / "Resources/Python"
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "/usr/bin/rsync",
                "-a",
                "--delete",
                str(DEST / "Resources/Python") + "/",
                str(target) + "/",
            ],
            check=True,
        )
        framework = bundle / "Frameworks/libpython3.12.dylib"
        framework.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(DEST / "Frameworks/libpython3.12.dylib", framework)
        for path in [framework, *target.rglob("*")]:
            if native(path):
                subprocess.run(
                    [
                        "/usr/bin/codesign",
                        "--force",
                        "--sign",
                        identity,
                        "--options",
                        "runtime",
                        str(path),
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                )
        marker.write_text(key)
    shutil.copy2(DEST / "runtime-lock.json", bundle / "Resources/runtime-lock.json")


if __name__ == "__main__":
    main()
