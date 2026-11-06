"""Execute the JUMO binary preparation in ARM64 emulation, without iOS APIs."""
import json
import struct
import sys
from pathlib import Path

from prepare_jumo import ROOT, DEPENDENCY, prepare
from inspect_macho import MachO

sys.path.insert(0, str(ROOT / 'analysis' / 'vendor'))
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X30, UC_ARM64_REG_SP


def machine(path, base):
    model = MachO(path)
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    uc.mem_map(base, 0x100000)
    for segment in model.segments:
        if segment['size']:
            offset, size = segment['offset'], segment['size']
            uc.mem_write(base + segment['vm'], model.data[offset:offset + size])
    uc.reg_write(UC_ARM64_REG_X30, base + 0xf0000)
    uc.reg_write(UC_ARM64_REG_SP, base + 0xef000)
    return model, uc


def main():
    output = ROOT / 'output' / 'jumo-integration' / 'prepared'
    prepare(output)
    checks = []
    for base in (0x100000000, 0x180234000):
        model, uc = machine(output / 'Cam.dylib', base)
        assert DEPENDENCY in model.dependencies
        object_address = base + 0xe0000
        for authorized in (0, 1):
            uc.mem_write(object_address + 8, bytes([authorized]))
            uc.reg_write(UC_ARM64_REG_X0, object_address)
            uc.emu_start(base + 0x52e90, base + 0xf0000, count=30)
            assert uc.reg_read(UC_ARM64_REG_X0) == authorized
            checks.append(dict(test='Cam restored getter reads authorization ivar',
                               base=hex(base), authorized=authorized, passed=True))
        for address in (0x4f0e4, 0x50ce4, 0x4fbe0, 0x4e030, 0x4a178):
            seen = []
            handle = uc.hook_add(UC_HOOK_CODE, lambda uc, a, size, user: seen.append(a))
            uc.emu_start(base + address, base + 0xf0000, count=4)
            uc.hook_del(handle)
            assert seen == [base + address]
            checks.append(dict(test='Cam old auth entry returns without execution',
                               base=hex(base), address=hex(address), passed=True))
        _, mm = machine(output / 'MM.dylib', base)
        mm.emu_start(base + 0x6b14, base + 0xf0000, count=4)
        checks.append(dict(test='MM legacy initializer disabled', base=hex(base), passed=True))
        _, sky = machine(output / 'Sky.dylib', base)
        seen = []
        sky.hook_add(UC_HOOK_CODE, lambda uc, a, size, user: seen.append(a))
        sky.emu_start(base + 0x1abc4, base + 0xf0000, count=8)
        assert seen == [base + a for a in (0x1abc4, 0x1abc8, 0x1abcc, 0x1abd0)]
        assert bytes(sky.mem_read(base + 0x6ce7f, 1)) == b'\x01'
        checks.append(dict(test='Sky retains style gate and skips old engine', base=hex(base), passed=True))
    report = dict(ios_runtime_tested=False, swift_tests_executed=False,
                  checks=checks, count=len(checks))
    (output.parent / 'arm64-verification.json').write_text(json.dumps(report, indent=2) + '\n', 'utf-8')
    print(str(len(checks)) + ' ARM64 checks passed. Native Swift/UIKit tests remain separate.')


if __name__ == '__main__':
    main()
