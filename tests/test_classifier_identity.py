"""Native signature checks against disposable ad hoc apps with identical IDs."""
import plistlib
from pathlib import Path
import subprocess
import sys

import pytest

pytestmark = pytest.mark.skipif(sys.platform != 'darwin', reason='macOS Security framework')
ROOT = Path(__file__).resolve().parents[1]


def run(*args, check=True):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True, text=True, timeout=60)


@pytest.fixture(scope='module')
def checker(tmp_path_factory):
    root = tmp_path_factory.mktemp('native-identity')
    source = root / 'check.m'
    source.write_text(r'''
#import "ConnectionIdentity.h"
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *text = GKHostRequirement([NSURL fileURLWithPath:@(argv[1])]);
        if (!text) return 2;
        puts(text.UTF8String);
        if (argc < 3) return 0;
        SecRequirementRef requirement = NULL;
        SecStaticCodeRef code = NULL;
        OSStatus result = SecRequirementCreateWithString((__bridge CFStringRef)text, 0, &requirement);
        if (result == errSecSuccess) result = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], 0, &code);
        if (result == errSecSuccess) result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
        if (code) CFRelease(code);
        if (requirement) CFRelease(requirement);
        return result == errSecSuccess ? 0 : 3;
    }
}
''')
    binary = root / 'check'
    run('clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'Security',
        '-I', ROOT / 'apps/macos/ClassifierService', source, '-o', binary)
    return binary


def app_fixture(root, value):
    app = root / f'Host{value}.app'
    service = app / 'Contents/XPCServices/Classifier.xpc'
    source = root / f'program{value}.c'
    source.write_text(f'int main(void) {{ return {value}; }}')
    for bundle, identifier, kind in [(service, 'com.groundkeeper.macos.classifier', 'XPC!'),
                                      (app, 'com.groundkeeper.macos', 'APPL')]:
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Main', 'CFBundlePackageType': kind}))
        run('clang', source, '-o', bundle / 'Contents/MacOS/Main')
        run('codesign', '--force', '--sign', '-', bundle)
    return app, service


def test_exact_host_accepted_and_same_identifier_impostor_rejected(tmp_path, checker):
    host, service = app_fixture(tmp_path, 0)
    impostor, _ = app_fixture(tmp_path, 1)
    result = run(checker, service, host)
    assert 'cdhash H"' in result.stdout
    assert run(checker, service, impostor, check=False).returncode == 3


def test_unsigned_or_modified_host_fails_closed(tmp_path, checker):
    host, service = app_fixture(tmp_path, 0)
    info = host / 'Contents/Info.plist'
    original = info.read_bytes()
    info.write_bytes(original + b'\n')
    assert run(checker, service, check=False).returncode == 2
    info.write_bytes(original)
    run('codesign', '--remove-signature', host)
    assert run(checker, service, check=False).returncode == 2


def test_unsigned_service_and_wrong_layout_fail_closed(tmp_path, checker):
    _, service = app_fixture(tmp_path, 0)
    assert run(checker, service.parent, check=False).returncode == 2
    run('codesign', '--remove-signature', service)
    assert run(checker, service, check=False).returncode == 2
