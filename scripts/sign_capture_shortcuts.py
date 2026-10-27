"""Sign the reviewed, device-independent capture Shortcut sources for distribution."""

import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--names", nargs="+", help="Sign only these source stems; defaults to all sources"
)
args = parser.parse_args()
sources = sorted((root / "shortcuts/sources").glob("*.plist"))
if args.names:
    if set(args.names) - {source.stem for source in sources}:
        parser.error("Unknown Shortcut source name")
    sources = [source for source in sources if source.stem in args.names]
for source in sources:
    with tempfile.TemporaryDirectory() as temporary:
        unsigned = Path(temporary) / (source.stem + ".shortcut")
        unsigned.write_bytes(
            plistlib.dumps(plistlib.loads(source.read_bytes()), fmt=plistlib.FMT_BINARY)
        )
        subprocess.run(
            [
                "/usr/bin/shortcuts",
                "sign",
                "--mode",
                "anyone",
                "--input",
                str(unsigned),
                "--output",
                str(root / "shortcuts" / (source.stem + ".shortcut")),
            ],
            check=True,
            timeout=90,
        )
