"""Bundle the pinned model catalog and available Shortcut installers into the app."""

import os
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
destination = (
    Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "Setup"
)
destination.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "release/models.json", destination / "models.json")
shutil.copy2(root / "release/MODEL-NOTICES.txt", destination / "MODEL-NOTICES.txt")
shutil.copy2(root / "release/SQLCIPHER-LICENSE.md", destination / "SQLCIPHER-LICENSE.md")
for source in (root / "shortcuts").glob("*.shortcut"):
    shutil.copy2(source, destination / source.name)
shutil.copy2(root / "shortcuts/README.md", destination / "Shortcuts Guide.md")

# Xcode can refresh loose worker files during an incremental Copy Files step
# while retaining the previous XPC resource seal. Copy the complete signed
# product, including CodeResources, before the host app is signed.
for name in ("GroundKeeperClassifier.xpc", "GroundKeeperMerchantSearch.xpc"):
    service = Path(os.environ["TARGET_BUILD_DIR"]) / name
    embedded = destination.parents[1] / "XPCServices" / service.name
    embedded.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["/usr/bin/rsync", "-a", "--delete", str(service) + "/", str(embedded) + "/"], check=True
    )
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(embedded)], check=True)
