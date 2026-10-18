"""Bundle the pinned model catalog and available Shortcut installers into the app."""
import os
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "Setup"
destination.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "release/models.json", destination / "models.json")
for source in (root / "shortcuts").glob("*.shortcut"):
    shutil.copy2(source, destination / source.name)
shutil.copy2(root / "shortcuts/README.md", destination / "Shortcuts Guide.md")
