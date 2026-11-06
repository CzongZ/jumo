"""Prepare version-locked Cam/MM/Sky components for the new JUMO license module.

These components require a separately compiled JumoLicense.dylib. Originals and
the earlier local-mode experiment are never overwritten.
"""
import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path

from inspect_macho import MachO

ROOT = Path(__file__).resolve().parent.parent
DEPENDENCY = '@loader_path/JumoLicense.dylib'
EXPECTED = {
    'Cam.dylib': '0d43b551d427f5873c27bb2f825a3ba241a69c1e652315256340ddcd7c427b76',
    'MM.dylib': '6c055aac7ac6304ec4836b468ec6f98ec89754ce867316fc0050005108110a68',
    'Sky.dylib': 'e45acfea88106c9621fc9b589b063ef09bbb19953e7f7cb21b4e7ec4592b9ed4',
}
BRANDING = {
    'Cam.dylib': {'打开 Tang 抖音': '百鸣科技工具', '       ': '百鸣科技',
                  'jì shù': '百鸣科技', 'Tang 抖音授权': '百鸣科技授权'},
    'Sky.dylib': {'jì shù': '百鸣科技', 'SKY LAB · 增强项': '百鸣科技 · 增强项', 'SkyCam': 'BM Cam'},
    'MM.dylib': {},
}


def rebrand_strings(model, modified, replacements):
    """Rewrite only complete, version-locked CFStrings, keeping allocation sizes."""
    allowed, entries, found = set(), [], set()
    for section in model.sections:
        if section['name'] != '__cfstring':
            continue
        for offset in range(section['offset'], section['offset'] + section['size'], 32):
            _, flags, pointer, length = struct.unpack_from('<QQQQ', model.data, offset)
            pointer &= (1 << 36) - 1
            try:
                start = model.offset(pointer)
                encoding = 'utf-16le' if flags & 0x10 else 'utf-8'
                size = length * (2 if flags & 0x10 else 1)
                text = model.data[start:start + size].decode(encoding)
            except (ValueError, UnicodeError):
                continue
            if text not in replacements:
                continue
            replacement = replacements[text]
            raw = replacement.encode(encoding)
            if len(raw) > size:
                raise ValueError('Brand text exceeds its original CFString storage')
            modified[start:start + size] = raw.ljust(size, b'\0')
            new_length = len(raw) // (2 if flags & 0x10 else 1)
            struct.pack_into('<Q', modified, offset + 24, new_length)
            allowed.update(range(start, start + size))
            allowed.update(range(offset + 24, offset + 32))
            entries.append(dict(cfstring_offset=hex(offset), original_text=text,
                                branded_text=replacement, reason='Baiming product branding.'))
            found.add(text)
    if found != set(replacements):
        raise ValueError('Expected branding strings missing: ' + repr(set(replacements) - found))
    return allowed, entries


def adrp(register, pc, target):
    immediate = ((target >> 12) - (pc >> 12)) & 0x1fffff
    return struct.pack('<I', 0x90000000 | ((immediate & 3) << 29)
                       | ((immediate >> 2) << 5) | register)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(output, runtime=None):
    output = Path(output).resolve()
    if output == ROOT or output == ROOT / 'output' / 'local-mode':
        raise ValueError('Refusing to overwrite originals or local-mode files')
    # Validate all inputs before making any outputs.
    inputs = {}
    for name, expected in EXPECTED.items():
        data = (ROOT / name).read_bytes()
        if digest(data) != expected:
            raise ValueError(name + ': hash mismatch; re-analyze this version first')
        inputs[name] = MachO(ROOT / name)
    if runtime:
        runtime = Path(runtime).resolve()
        raw_runtime = runtime.read_bytes()
        if len(raw_runtime) < 32 or struct.unpack_from('<IIII', raw_runtime) != (
                0xfeedfacf, 0x100000c, 0, 6):
            raise ValueError('Expected a thin arm64 MH_DYLIB JumoLicense runtime')
    output.mkdir(parents=True, exist_ok=True)
    cam = inputs['Cam.dylib']
    patches = {name: [] for name in inputs}

    def method_patch(name, address, symbol, expected, replacement, reason):
        model = inputs[name]
        if symbol not in model.by_addr.get(address, []):
            raise ValueError('Unexpected method at ' + hex(address))
        patches[name].append((address, bytes.fromhex(expected), bytes.fromhex(replacement), reason))

    # Restore the actual ivar getter, removing the supplied constant-true patch.
    # The original remaining body already reads authorization byte [self + 8].
    method_patch('Cam.dylib', 0x52e90, '-[VCamAuthorization isAuthorized]',
                 '20008052c0035fd6', 'ff4300d1e00700f9',
                 'Restore original authorization ivar getter; initial value is false.')
    # Keep startWithCompletion: intact: it retains the existing startup callback.
    # The new runtime replaces the cache/prompt methods after class registration.
    for address, symbol, before in (
        (0x4f0e4, '-[VCamAuthorization verifyCachedLicenseAtStartup]', 'ffc307d1'),
        (0x50ce4, '-[VCamAuthorization presentCardPromptWithMessage:]', 'ff4302d1'),
        (0x4fbe0, '-[VCamAuthorization activateCard:]', 'ff0306d1'),
        (0x4e030, '-[VCamAuthorization postPath:body:signature:completion:]', 'ff4305d1'),
        (0x4a178, '-[VCamAuthorization finishAuthorized]', 'ffc301d1'),
    ):
        method_patch('Cam.dylib', address, symbol, before, 'c0035fd6',
                     'Disable old licensing route; JUMO runtime owns authorization.')
    method_patch('MM.dylib', 0x6b14, '_WeiYanUI_entry', 'ff0303d1', 'c0035fd6',
                 'Disable legacy WeiYan startup, auth hooks and timers.')
    sky_init = adrp(8, 0x1abc4, 0x6ce7f) + bytes.fromhex('29008052')
    sky_init += struct.pack('<I', 0x39000000 | (0xe7f << 10) | (8 << 5) | 9)
    sky_init += bytes.fromhex('c0035fd6')
    patches['Sky.dylib'].append((0x1abc4, bytes.fromhex('200200d000d841f9210200d021c03a91'), sky_init,
                                'Retain Sky style initializer and outer UI gate; disable old network engine.'))
    report = dict(software_id='JUMO', endpoint='https://back.czongz.site/ai/ai_key/card_vip/detail',
                  ios_runtime_tested=False, runtime_included=bool(runtime),
                  installable_bundle=False, requires_resigning=True, brand='百鸣科技',
                  shared_access_group=None, authorization_mode='manual-pairing',
                  requires_backend_pairing_v2=True, files=[])
    for name, model in inputs.items():
        modified = bytearray(model.data)
        allowed = set()
        entries = []
        for address, before, after, reason in patches[name]:
            offset = model.offset(address)
            if len(before) != len(after) or modified[offset:offset + len(before)] != before:
                raise ValueError('Patch precondition failed: ' + name + ' ' + hex(address))
            modified[offset:offset + len(after)] = after
            allowed.update(range(offset, offset + len(after)))
            entries.append(dict(address=hex(address), offset=hex(offset), before=before.hex(),
                                after=after.hex(), reason=reason))
        branding_allowed, branding_entries = rebrand_strings(model, modified, BRANDING[name])
        allowed.update(branding_allowed)
        entries.extend(branding_entries)
        if name == 'Cam.dylib':
            command_end = 32 + struct.unpack_from('<I', model.data, 20)[0]
            path = DEPENDENCY.encode('ascii') + b'\0'
            size = (24 + len(path) + 7) & ~7
            first_section = min(s['offset'] for s in model.sections if s['offset'] > 0 and s['size'])
            if command_end + size > first_section or any(modified[command_end:command_end + size]):
                raise ValueError('No verified zero-filled Mach-O header space for dependency')
            payload = struct.pack('<IIIIII', 0xc, size, 24, 0, 0x10000, 0x10000)
            payload = (payload + path).ljust(size, b'\0')
            modified[command_end:command_end + size] = payload
            ncmds, sizeofcmds = struct.unpack_from('<II', modified, 16)
            struct.pack_into('<II', modified, 16, ncmds + 1, sizeofcmds + size)
            allowed.update(range(16, 24))
            allowed.update(range(command_end, command_end + size))
            entries.append(dict(load_command_offset=hex(command_end), dependency=DEPENDENCY,
                                reason='Hard dependency: missing JUMO runtime prevents loading this Cam.'))
        if any(i not in allowed for i, (a, b) in enumerate(zip(model.data, modified)) if a != b):
            raise AssertionError('Undeclared modifications')
        target = output / name
        target.write_bytes(modified)
        checked = MachO(target)
        assert checked.sections == model.sections
        assert len(modified) == len(model.data)
        assert checked.dependencies == model.dependencies + ([DEPENDENCY] if name == 'Cam.dylib' else [])
        report['files'].append(dict(name=name, original_sha256=EXPECTED[name],
                                    prepared_sha256=digest(modified), patches=entries))
    if runtime:
        target = output / 'JumoLicense.dylib'
        if runtime != target:
            shutil.copyfile(runtime, target)
        report['files'].append(dict(name=target.name, prepared_sha256=digest(target.read_bytes())))
    for name, expected in EXPECTED.items():
        assert digest((ROOT / name).read_bytes()) == expected
    (output / 'integration-manifest.json').write_text(json.dumps(report, indent=2) + '\n', 'utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'output' / 'jumo-integration' / 'prepared')
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    report = prepare(args.output, args.runtime)
    print('Prepared:', args.output)
    print('Runtime included:', report['runtime_included'])
    print('Device validation and injection signing are still required.')


if __name__ == '__main__':
    main()
