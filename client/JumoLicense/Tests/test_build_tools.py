"""Build-time trust and version-lock checks, executable on Windows without an iOS SDK."""
import base64
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

CLIENT = Path(__file__).resolve().parent.parent
ROOT = CLIENT.parent.parent
spec = importlib.util.spec_from_file_location('jumo_build', CLIENT / 'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
sys.path.insert(0, str(ROOT / 'analysis'))
from prepare_jumo import EXPECTED, prepare


def test_accepts_real_spki(tmp_path):
    public = Ed25519PrivateKey.generate().public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    text = base64.b64encode(public).decode()
    path = tmp_path / 'public.b64'
    path.write_text(text + '\n', 'ascii')
    accepted, fingerprint = build.validate_key(path)
    assert accepted == text
    assert len(fingerprint) == 64


def test_configured_production_key_is_expected_ed25519_spki():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    path = CLIENT / 'Config' / 'license-public.b64'
    text, fingerprint = build.validate_key(path)
    expected = '77b448206f7390f82de60391f7d34480f28e24d15b0428991d42e9587f81d706'
    assert fingerprint == expected
    der = base64.b64decode(text, validate=True)
    public = serialization.load_der_public_key(der)
    assert isinstance(public, Ed25519PublicKey)
    assert public.public_bytes(serialization.Encoding.DER,
                               serialization.PublicFormat.SubjectPublicKeyInfo) == der


@pytest.mark.parametrize('text', ['', 'AAAA', 'missing-key',
    base64.b64encode(bytes(32)).decode(),
    base64.b64encode(bytes.fromhex('302a300506032b6570032100') + bytes(31)).decode(),
    base64.b64encode(bytes.fromhex('302a300506032b6571032100') + bytes(32)).decode(),
    base64.b64encode(bytes.fromhex('302a300506032b6570032100') + bytes(32)).decode()[:20] + '\nAAAA'])
def test_rejects_invalid_trust(tmp_path, text):
    path = tmp_path / 'bad.b64'
    path.write_text(text, 'ascii')
    with pytest.raises(ValueError):
        build.validate_key(path)


def test_rejects_documentation_test_key(tmp_path):
    fixture = json.loads((CLIENT / 'Tests' / 'java-test-vectors.json').read_text('utf-8'))
    path = tmp_path / 'test-key.b64'
    path.write_text(fixture['PUBLIC_KEY_B64'], 'ascii')
    with pytest.raises(ValueError, match='test key'):
        build.validate_key(path)


def test_missing_key_prevents_release_build():
    result = subprocess.run([sys.executable, str(CLIENT / 'build.py')], capture_output=True, text=True)
    assert result.returncode != 0
    assert '--public-key-file is required' in result.stderr


def test_native_tests_use_explicit_host_sdk(tmp_path, monkeypatch):
    """The resolved Xcode swiftc must get the macOS SDK even outside xcrun."""
    sdk = '/Applications/Xcode Test.app/Contents/Developer/SDKs/MacOSX.sdk'
    compiler = '/Applications/Xcode Test.app/Contents/Developer/usr/bin/swiftc'
    monkeypatch.setenv('SDKROOT', '/wrong/inherited/iPhoneOS.sdk')
    monkeypatch.setattr(build.platform, 'system', lambda: 'Darwin')
    monkeypatch.setattr(build.shutil, 'which', lambda name: '/usr/bin/xcrun')
    monkeypatch.setattr(build, 'OUT', tmp_path)
    monkeypatch.setattr(sys, 'argv', ['build.py', '--test-only'])
    queries = []
    commands = []

    def check_output(args, **kwargs):
        queries.append(args)
        assert args[:3] == ['xcrun', '--sdk', 'macosx']
        if args[3:] == ['--find', 'swiftc']:
            return compiler + '\n'
        assert args[3:] == ['--show-sdk-path']
        return sdk + '\n'

    def invoke(args, **kwargs):
        assert kwargs['check'] is True
        commands.append(args)

    monkeypatch.setattr(build.subprocess, 'check_output', check_output)
    monkeypatch.setattr(build.subprocess, 'run', invoke)
    build.main()
    compile_commands = [args for args in commands if '-parse-as-library' in args]
    assert len(compile_commands) == 1
    command = compile_commands[0]
    assert command[0] == compiler
    assert command[command.index('-sdk') + 1] == sdk
    assert commands[-1] == [str(tmp_path / 'build' / 'protocol-tests'),
                            str(CLIENT / 'Tests' / 'java-test-vectors.json')]
    assert len(queries) == 2


def test_cannot_overwrite_originals():
    with pytest.raises(ValueError, match='overwrite'):
        prepare(ROOT)


def test_cannot_overwrite_local_mode_experiment():
    with pytest.raises(ValueError, match='overwrite'):
        prepare(ROOT / 'output' / 'local-mode')


def test_modified_input_blocks_all_outputs(tmp_path, monkeypatch):
    import prepare_jumo
    source = tmp_path / 'inputs'
    source.mkdir()
    (source / 'Cam.dylib').write_bytes(b'changed input')
    monkeypatch.setattr(prepare_jumo, 'ROOT', source)
    target = tmp_path / 'prepared'
    with pytest.raises(ValueError, match='hash mismatch'):
        prepare_jumo.prepare(target)
    assert not target.exists()


def test_java_vectors_verify_independently():
    """Confirm the supplied server fixtures themselves, independently of native execution."""
    fixture = json.loads((CLIENT / 'Tests' / 'java-test-vectors.json').read_text('utf-8'))
    public = serialization.load_der_public_key(base64.b64decode(fixture['PUBLIC_KEY_B64']))
    for vector in fixture['vectors']:
        license = vector['response']['data']
        ok = int(license['status'] is True and license['canUse'] is True)
        canonical = '|'.join(map(str, ('v1', vector['key'], vector['machineCode'],
            license['serverTime'], license['graceUntil'], license['data']['expiresAt'], ok)))
        assert canonical == vector['canonical']
        public.verify(base64.b64decode(license['sig']), canonical.encode('utf-8'))


def test_branding_updates_cfstring_lengths_without_touching_inputs(tmp_path):
    import struct
    from inspect_macho import MachO
    from prepare_jumo import BRANDING, digest

    prepare(tmp_path / 'branded')
    for name, replacements in BRANDING.items():
        model = MachO(tmp_path / 'branded' / name)
        texts = []
        for section in model.sections:
            if section['name'] != '__cfstring':
                continue
            for offset in range(section['offset'], section['offset'] + section['size'], 32):
                _, flags, pointer, length = struct.unpack_from('<QQQQ', model.data, offset)
                pointer &= (1 << 36) - 1
                try:
                    start = model.offset(pointer)
                    size = length * (2 if flags & 0x10 else 1)
                    text = model.data[start:start + size].decode('utf-16le' if flags & 0x10 else 'utf-8')
                except (UnicodeError, ValueError):
                    continue
                texts.append(text)
        for before, after in replacements.items():
            assert before not in texts
            assert after in texts
            assert '\0' not in after
        assert digest((ROOT / name).read_bytes()) == EXPECTED[name]
