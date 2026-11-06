"""Create a reviewable source kit from an explicit allowlist; no old API secrets."""
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    names = {'.gitignore', 'BUILD.zh-CN.md', 'Cam.dylib', 'MM.dylib', 'Sky.dylib',
             'analysis/inspect_macho.py', 'analysis/prepare_jumo.py', 'analysis/verify_jumo.py',
             'client/package_source.py'}
    for folder in ('client/JumoLicense',):
        for path in (ROOT / folder).rglob('*'):
            if (path.is_file() and '__pycache__' not in path.parts and '.pytest_cache' not in path.parts
                    and path.name != 'BACKEND-PROMPT.zh-CN.md'):
                if path.suffix in ('.py', '.swift', '.h', '.m', '.md', '.txt', '.png'):
                    names.add(path.relative_to(ROOT).as_posix())
    names.update({'client/JumoLicense/Config/license-public.b64',
                  'client/JumoLicense/Tests/java-test-vectors.json'})
    names.add('.github/workflows/build-jumo-ios.yml')
    out = ROOT / 'output/jumo-integration'
    out.mkdir(parents=True, exist_ok=True)
    for name in ('STATUS.zh-CN.md', 'arm64-verification.json', 'swift-syntax-check.json'):
        if (out / name).is_file():
            names.add('output/jumo-integration/' + name)
    manifest = {}
    for name in sorted(names):
        path = ROOT / name
        if not path.resolve().is_relative_to(ROOT) or not path.is_file():
            raise ValueError('Invalid source kit input: ' + name)
        manifest[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    destination = out / 'BAIMING-independent-source.zip'
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(names):
            archive.write(ROOT / name, name)
        archive.writestr('source-manifest.json', json.dumps(dict(
            brand='百鸣科技', revision='baiming-independent-v4', source_package_not_installable=True,
            requires_backend_pairing_v2=False, original_injector_supported=True,
            requires_native_build_and_device_validation=True, sha256=manifest), ensure_ascii=False, indent=2) + '\n')
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError('Source ZIP integrity check failed')
        for name, expected in manifest.items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == expected
    for alias in ('BAIMING-integration-source.zip', 'JUMO-integration-source.zip'):
        shutil.copyfile(destination, out / alias)
    status = dict(source_archive=destination.name, sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
        entries=len(names) + 1, revision='baiming-independent-v4', source_package_not_installable=True,
        requires_native_build_and_device_validation=True)
    (out / 'source-package-status.json').write_text(json.dumps(status, indent=2) + '\n', 'utf-8')
    print(json.dumps(status, indent=2))


if __name__ == '__main__':
    main()
