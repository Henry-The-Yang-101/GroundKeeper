"""Sign the reviewed, device-independent capture Shortcut sources for distribution."""
from pathlib import Path
import subprocess
import plistlib
import tempfile

root = Path(__file__).resolve().parents[1]
for source in sorted((root / "shortcuts/sources").glob("*.plist")):
    with tempfile.TemporaryDirectory() as temporary:
        unsigned = Path(temporary) / (source.stem + ".shortcut")
        unsigned.write_bytes(plistlib.dumps(plistlib.loads(source.read_bytes()), fmt=plistlib.FMT_BINARY))
        subprocess.run(["/usr/bin/shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned),
                        "--output", str(root / "shortcuts" / (source.stem + ".shortcut"))], check=True, timeout=90)
