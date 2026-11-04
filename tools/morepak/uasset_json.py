"""Reads the header of a cooked legacy .uasset (retoc to-legacy output, LegacyFileVersion -9) and writes the
subset of a UAssetGUI JSON that kismet.py needs: NameMap, Imports, Exports. UAssetGUI is not needed.
Usage: python -I uasset_json.py <asset.uasset> [out.json]   (stdout when out.json is omitted)
"""
import json, struct, sys

TAG = 0x9E2A83C1


class Reader:
    def __init__(self, data, p=0):
        self.d, self.p = data, p

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]; self.p += 4; return v

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ''
        if n < 0:  # UTF-16, -n code units including the terminator
            s = self.d[self.p:self.p - 2 * n].decode('utf-16-le'); self.p -= 2 * n
        else:
            s = self.d[self.p:self.p + n].decode('latin-1'); self.p += n
        return s.rstrip('\0')


def parse(data):
    r = Reader(data)
    if r.u32() != TAG:
        raise SystemExit('not a legacy package (no file tag)')
    legacy = r.i32()
    if legacy != -9:
        raise SystemExit('LegacyFileVersion %d, only -9 is handled' % legacy)
    r.i32()                      # LegacyUE3Version
    r.i32(); r.i32(); r.i32()    # FileVersionUE4, FileVersionUE5, FileVersionLicenseeUE4 (0: unversioned)
    r.p += 20                    # SavedHash
    total_header = r.i32()
    custom = r.i32()
    r.p += 20 * custom           # custom versions (Guid + int32)
    package = r.fstring()
    flags = r.u32()
    name_count, name_off = r.i32(), r.i32()
    r.i32(); r.i32()             # soft object paths count, offset
    if not flags & 0x80000000:   # PKG_FilterEditorOnly unset: LocalizationId follows
        r.fstring()
    r.i32(); r.i32()             # gatherable text data count, offset
    exp_count, exp_off, imp_count, imp_off = r.i32(), r.i32(), r.i32(), r.i32()
    if imp_off + imp_count * 32 != exp_off:
        raise SystemExit('summary layout not recognised (imports %X+%d*32 != exports %X)' % (imp_off, imp_count, exp_off))

    names = []
    n = Reader(data, name_off)
    for _ in range(name_count):
        names.append(n.fstring()); n.p += 4   # 2 x uint16 hashes

    def fname(p):
        idx, num = struct.unpack_from('<ii', data, p)
        return names[idx] + ('_%d' % (num - 1) if num else '')

    imports = []
    for i in range(imp_count):
        p = imp_off + 32 * i
        imports.append({'ClassPackage': fname(p), 'ClassName': fname(p + 8),
                        'OuterIndex': struct.unpack_from('<i', data, p + 16)[0], 'ObjectName': fname(p + 20)})
    exports = []
    for i in range(exp_count):
        p = exp_off + 96 * i
        cls, sup, tmpl, outer = struct.unpack_from('<4i', data, p)
        size, off = struct.unpack_from('<qq', data, p + 28)
        exports.append({'ClassIndex': cls, 'SuperIndex': sup, 'TemplateIndex': tmpl, 'OuterIndex': outer,
                        'ObjectName': fname(p + 16), 'SerialSize': size, 'SerialOffset': off})
    if exports and min(e['SerialOffset'] for e in exports) != total_header:
        raise SystemExit('first export at %X, header size %X' % (min(e['SerialOffset'] for e in exports), total_header))
    return {'PackageName': package, 'NameMap': names, 'Imports': imports, 'Exports': exports}


def main():
    j = parse(open(sys.argv[1], 'rb').read())
    text = json.dumps(j, indent=1)
    if len(sys.argv) > 2:
        open(sys.argv[2], 'w', encoding='utf-8').write(text)
    else:
        print(text)


if __name__ == '__main__':
    main()
