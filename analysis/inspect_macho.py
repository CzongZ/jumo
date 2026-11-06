import argparse
import hashlib
import json
import struct
from pathlib import Path

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN


class MachO:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.segments = []
        self.sections = []
        self.dependencies = []
        self.symbols = []
        self.commands = []
        if self.data[:4] != bytes.fromhex('cffaedfe'):
            raise ValueError('Expected thin 64-bit little endian Mach-O')
        offset = 32
        for _ in range(struct.unpack_from('<I', self.data, 16)[0]):
            cmd, size = struct.unpack_from('<II', self.data, offset)
            self.commands.append((cmd, offset, size))
            if cmd == 0x19:
                name, vm, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags = struct.unpack_from('<16sQQQQiiII', self.data, offset + 8)
                name = name.rstrip(b'\0').decode()
                self.segments.append(dict(name=name, vm=vm, vmsize=vmsize, offset=fileoff, size=filesize))
                for i in range(nsects):
                    p = offset + 72 + i * 80
                    sect, seg, addr, length, off = struct.unpack_from('<16s16sQQI', self.data, p)
                    flags, reserved1, reserved2 = struct.unpack_from('<III', self.data, p + 64)
                    self.sections.append(dict(name=sect.rstrip(b'\0').decode(), segment=seg.rstrip(b'\0').decode(), vm=addr, size=length, offset=off, flags=flags, reserved1=reserved1, reserved2=reserved2))
            elif cmd in (0xc, 0xd, 0x18, 0x80000018, 0x8000001f, 0x80000023):
                start = offset + struct.unpack_from('<I', self.data, offset + 8)[0]
                self.dependencies.append(self.cstring_offset(start))
            elif cmd == 2:
                symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', self.data, offset + 8)
                for i in range(nsyms):
                    strx, typ, sect, desc, addr = struct.unpack_from('<IBBHQ', self.data, symoff + i * 16)
                    self.symbols.append(dict(name=self.cstring_offset(stroff + strx), type=typ, section=sect, vm=addr))
            offset += size
        self.by_addr = {}
        for s in self.symbols:
            if s['vm'] and s['name']:
                names = self.by_addr.setdefault(s['vm'], [])
                if s['name'] not in names:
                    names.append(s['name'])
        self.recover_names()

    def ptr_at(self, addr):
        raw = struct.unpack_from('<Q', self.data, self.offset(addr))[0]
        return 0 if raw >> 63 else raw & ((1 << 36) - 1)

    def recover_names(self):
        for cmd, off, _ in self.commands:
            if cmd == 0xb:
                indirectoff, count = struct.unpack_from('<II', self.data, off + 56)
                indirect = struct.unpack_from('<' + 'I' * count, self.data, indirectoff)
                for s in self.sections:
                    if s['name'] == '__stubs' and s['reserved2']:
                        for i in range(s['size'] // s['reserved2']):
                            idx = indirect[s['reserved1'] + i]
                            if idx < len(self.symbols):
                                self.by_addr.setdefault(s['vm'] + i * s['reserved2'], []).append(self.symbols[idx]['name'])
        for s in self.sections:
            if s['name'] == '__objc_stubs':
                md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
                md.detail = True
                for i in range(0, s['size'], 32):
                    ops = list(md.disasm(self.data[s['offset']+i:s['offset']+i+8],s['vm']+i))
                    if len(ops) == 2 and ops[0].mnemonic == 'adrp' and ops[1].mnemonic == 'ldr':
                        addr = ops[0].operands[1].imm + ops[1].operands[1].mem.disp
                        try:
                            name = self.cstring_offset(self.offset(self.ptr_at(addr)))
                            self.by_addr.setdefault(s['vm']+i,[]).append('_objc_msgSend$'+name)
                        except ValueError:
                            pass
        for s in self.sections:
            if s['name'] == '__objc_classlist':
                for i in range(0,s['size'],8):
                    cls = self.ptr_at(s['vm']+i)
                    ro = self.ptr_at(cls+32) & ~7
                    name = self.cstring_offset(self.offset(self.ptr_at(ro+24)))
                    self.by_addr.setdefault(cls,[]).append('_OBJC_CLASS_$_'+name)
                    self.recover_methods(self.ptr_at(ro+32),name,'-')
                    meta = self.ptr_at(cls)
                    if meta:
                        mr = self.ptr_at(meta+32) & ~7
                        self.recover_methods(self.ptr_at(mr+32),name,'+')

    def recover_methods(self, addr, clsname, prefix):
        if not addr:
            return
        flags,count = struct.unpack_from('<II',self.data,self.offset(addr))
        size = flags & 0xffff
        for i in range(count):
            entry = addr+8+i*size
            if flags & 0x80000000:
                n,t,imp = struct.unpack_from('<iii',self.data,self.offset(entry))
                nameptr = entry+n
                if not flags & 0x40000000:
                    nameptr = self.ptr_at(nameptr)
                target = entry+8+imp
            else:
                nameptr = self.ptr_at(entry)
                target = self.ptr_at(entry+16)
            name = f'{prefix}[{clsname} {self.cstring_offset(self.offset(nameptr))}]'
            if name not in self.by_addr.setdefault(target,[]):
                self.by_addr[target].append(name)

    def cstring_offset(self, off):
        end = self.data.find(b'\0', off)
        return self.data[off:end if end >= 0 else len(self.data)].decode('utf8', errors='replace')

    def offset(self, addr):
        for s in self.segments:
            if s['vm'] <= addr < s['vm'] + s['size']:
                return s['offset'] + addr - s['vm']
        raise ValueError(f'Unmapped address {addr:#x}')

    def describe(self, addr):
        names = self.by_addr.get(addr)
        if names:
            return ' | '.join(names)
        for s in self.sections:
            if s['vm'] <= addr < s['vm'] + s['size']:
                if s['name'] in ('__cstring', '__objc_methname', '__objc_classname'):
                    off = self.offset(addr)
                    return repr(self.cstring_offset(off)[:180])
                if s['name'] == '__cfstring' and (addr - s['vm']) % 32 == 0:
                    off = self.offset(addr)
                    isa, flags, ptr, length = struct.unpack_from('<QQQQ', self.data, off)
                    ptr &= (1 << 36) - 1
                    try:
                        p = self.offset(ptr)
                        return repr(self.data[p:p+length*2].decode('utf-16-le') if flags & 0x10 else self.data[p:p+length].decode('utf8'))
                    except (ValueError, UnicodeError):
                        pass
                return s['name'] + f'+{addr-s["vm"]:#x}'
        return ''

    def disassemble(self):
        md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        md.detail = True
        lines = []
        for sec in self.sections:
            if sec['name'] not in ('__text', '__stubs', '__auth_stubs'):
                continue
            lines.append(f'\nSECTION {sec["name"]}')
            pages = {}
            for ins in md.disasm(self.data[sec['offset']:sec['offset']+sec['size']], sec['vm']):
                if ins.address in self.by_addr:
                    lines.append('\n' + '\n'.join(self.by_addr[ins.address]))
                    pages = {}
                comments = []
                operands = ins.operands
                if ins.mnemonic in ('bl', 'b') and operands and operands[0].type == 2:
                    comments.append(self.describe(operands[0].imm))
                if ins.mnemonic in ('adr', 'adrp') and len(operands) == 2 and operands[1].type == 2:
                    pages[operands[0].reg] = operands[1].imm
                    comments.append(self.describe(operands[1].imm))
                if ins.mnemonic == 'add' and len(operands) == 3 and operands[1].type == 1 and operands[2].type == 2:
                    if operands[1].reg in pages:
                        addr = pages[operands[1].reg] + operands[2].imm
                        comments.append(f'{addr:#x} {self.describe(addr)}')
                if ins.mnemonic.startswith(('ldr','str')) and len(operands) >= 2 and operands[1].type == 3:
                    mem = operands[1].mem
                    if mem.base in pages:
                        addr = pages[mem.base] + mem.disp
                        comments.append(f'{addr:#x} {self.describe(addr)}')
                        if ins.mnemonic.startswith('ldr'):
                            try:
                                ptr = self.ptr_at(addr)
                                desc = self.describe(ptr)
                                if desc:
                                    comments.append(f'-> {ptr:#x} {desc}')
                            except (ValueError,struct.error):
                                pass
                lines.append(f'{ins.address:012x} {ins.bytes.hex():8s} {ins.mnemonic:9s} {ins.op_str}' + (' ; ' + '; '.join(c for c in comments if c) if any(comments) else ''))
        return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('files', nargs='+')
    args = parser.parse_args()
    out = Path(__file__).parent
    for file in args.files:
        m = MachO(file)
        info = dict(path=str(m.path), sha256=hashlib.sha256(m.data).hexdigest(), dependencies=m.dependencies, segments=m.segments, sections=m.sections, symbols=m.symbols)
        (out / (m.path.name + '.macho.json')).write_text(json.dumps(info, ensure_ascii=False, indent=2),encoding='utf8')
        (out / (m.path.name + '.asm.txt')).write_text(m.disassemble(),encoding='utf8')
        print(m.path, 'dependencies:', m.dependencies)
        for cmd, off, size in m.commands:
            if cmd in (0x21, 0x2c):
                print('encryption',struct.unpack_from('<III',m.data,off+8))
        print('symbols',len(m.symbols),'sections',len(m.sections))


if __name__ == '__main__':
    main()
