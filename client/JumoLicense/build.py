"""Build and test the JUMO license dylib on a Mac with Xcode and Python 3.

Production trust is compiled in from --public-key-file (SPKI DER Base64).
Never supply a card on the command line; no license activation happens here.
"""
import argparse
import base64
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCES = HERE / 'Sources'
OUT = ROOT / 'output' / 'jumo-integration'


def run(*args):
    subprocess.run([str(x) for x in args], check=True)


def find(tool, sdk=None):
    args = ['xcrun'] + (['--sdk', sdk] if sdk else []) + ['--find', tool]
    return subprocess.check_output(args, text=True).strip()


def validate_key(path):
    text = Path(path).read_text('ascii').strip()
    try:
        der = base64.b64decode(text, validate=True)
    except ValueError:
        raise ValueError('Expected a standard Base64 Ed25519 SPKI public key') from None
    if len(der) != 44 or der[:12].hex() != '302a300506032b6570032100' or base64.b64encode(der).decode() != text:
        raise ValueError('Expected a standard Base64 Ed25519 SPKI public key')
    for name in ('java-test-vectors.json', 'pairing-test-vectors.json'):
        fixtures = json.loads((HERE / 'Tests' / name).read_text('utf-8'))
        if text == fixtures['PUBLIC_KEY_B64']:
            raise ValueError('The documentation test key cannot be used for a release build')
    return text, hashlib.sha256(der).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-key-file', type=Path)
    parser.add_argument('--test-only', action='store_true')
    args = parser.parse_args()
    if not args.test_only and not args.public_key_file:
        parser.error('--public-key-file is required; missing trust must never enable authorization')
    key, fingerprint = (None, None) if args.test_only else validate_key(args.public_key_file)
    if platform.system() != 'Darwin' or not shutil.which('xcrun'):
        parser.error('Native iOS builds require macOS + Xcode; no installable dylib has been built')
    build = OUT / 'build'
    build.mkdir(parents=True, exist_ok=True)
    print('Baiming license build: pairing-v3 / protocol v2 / original injector / 55-65 minute renewal', flush=True)
    swift = find('swiftc', 'macosx')
    mac_sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    print('macOS test SDK:', mac_sdk, flush=True)
    run(swift, '--version')
    test_binary = build / 'protocol-tests'
    # Calling the Xcode compiler by its resolved path bypasses the xcrun
    # launcher, so pass the host SDK explicitly, just as for the iOS build.
    run(swift, '-sdk', mac_sdk, '-swift-version', '5', '-parse-as-library',
        SOURCES / 'LicenseCore.swift', SOURCES / 'LicenseHTTPClient.swift',
        SOURCES / 'LicenseGate.swift', SOURCES / 'LicensePolicy.swift', SOURCES / 'LicensePairing.swift',
        HERE / 'Tests' / 'ProtocolTests.swift', '-o', test_binary)
    run(test_binary, HERE / 'Tests' / 'java-test-vectors.json', HERE / 'Tests' / 'pairing-test-vectors.json')
    if args.test_only:
        return
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    print('iOS library SDK:', sdk, flush=True)
    trust = build / 'JumoTrust.swift'
    trust.write_text('enum JumoTrust { static let publicKeyB64 = ' + json.dumps(key) + ' }\n', 'utf-8')
    bridge = build / 'JumoBridge.o'
    run(find('clang', 'iphoneos'), '-target', 'arm64-apple-ios14.0', '-isysroot', sdk,
        '-fobjc-arc', '-fblocks', '-fmodules', '-O2', '-c', SOURCES / 'JumoBridge.m', '-o', bridge)
    library = build / 'JumoLicense.dylib'
    run(swift, '-swift-version', '5', '-target', 'arm64-apple-ios14.0', '-sdk', sdk,
        '-emit-library', '-O', '-whole-module-optimization', '-module-name', 'JumoLicense',
        '-import-objc-header', SOURCES / 'JumoBridge.h',
        *sorted(SOURCES.glob('*.swift')), trust, bridge,
        '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'Security', '-framework', 'CryptoKit',
        '-Xlinker', '-install_name', '-Xlinker', '@loader_path/JumoLicense.dylib',
        '-Xlinker', '-rpath', '-Xlinker', '/usr/lib/swift', '-o', library)
    sys.path.insert(0, str(ROOT / 'analysis'))
    from prepare_jumo import prepare
    release = OUT / 'device-test'
    report = prepare(release, library)
    for name in ('JumoLicense.dylib', 'Cam.dylib', 'MM.dylib', 'Sky.dylib'):
        run('codesign', '--force', '--sign', '-', release / name)
        run('codesign', '--verify', '--strict', release / name)
    for entry in report['files']:
        entry['signed_sha256'] = hashlib.sha256((release / entry['name']).read_bytes()).hexdigest()
    report.update(native_core_tests_passed=True, public_key_spki_sha256=fingerprint,
                  client_revision='baiming-pairing-v3', protocol_version='v2', renewal_seconds=[3300, 3900],
                  maximum_lease_seconds=7200, requires_host_shared_keychain_entitlement=False,
                  requires_backend_pairing_v2=True, original_injector_supported=True,
                  requires_resigning=True, ready_for_device_test=True)
    (release / 'integration-manifest.json').write_text(json.dumps(report, indent=2) + '\n', 'utf-8')
    shutil.copyfile(HERE / 'README.zh-CN.md', release / 'README.zh-CN.md')
    archive = OUT / 'JUMO-device-test.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(release.iterdir()):
            if path.is_file():
                bundle.write(path, path.name)
    print('Built device-test package:', archive)
    print('Re-sign through the injection workflow and validate on the real device.')


if __name__ == '__main__':
    main()
