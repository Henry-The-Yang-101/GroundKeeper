"""Exercise SMAppService in a disposable app/container without touching the real agent."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='background-check-', dir=root / '.local/releases') as temporary:
        app = Path(temporary) / 'GroundKeeper.app'
        subprocess.run(['ditto', str(args.app), str(app)], check=True, timeout=120)
        info = app / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = 'com.groundkeeper.macos.queue-smoke'
        info.write_bytes(plistlib.dumps(data))
        agent = app / 'Contents/Library/LaunchAgents/com.groundkeeper.macos.queue-processing.plist'
        data = plistlib.loads(agent.read_bytes())
        data['Label'] = 'com.groundkeeper.macos.queue-smoke'
        data['ProgramArguments'] = ['GroundKeeper', '--queue-smoke', '--background-smoke-agent']
        data.pop('StartInterval', None)
        agent.write_bytes(plistlib.dumps(data))
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier',
                        'com.groundkeeper.macos.queue-smoke', '--options', 'runtime',
                        '--entitlements', str(root / 'apps/macos/GroundKeeper.entitlements'),
                        str(app)], check=True, timeout=60)
        subprocess.run([str(app / 'Contents/MacOS/GroundKeeper'), '--background-smoke'],
                       check=True, timeout=60)


if __name__ == '__main__':
    main()
