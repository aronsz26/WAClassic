#!/usr/bin/env python3
# dump a compiled NIBArchive: classes, frames, texts, fonts, colors, images
import struct, sys

def varint(b, i):
    v, shift = 0, 0
    while True:
        c = b[i]; i += 1
        v |= (c & 0x7F) << shift
        shift += 7
        if c & 0x80:
            return v, i

def parse(path):
    b = open(path, 'rb').read()
    assert b[:10] == b'NIBArchive'
    oc, oo, kc, ko, vc, vo, cc, co = struct.unpack_from('<8I', b, 18)
    keys = []
    i = ko
    for _ in range(kc):
        n, i = varint(b, i); keys.append(b[i:i+n].decode('utf-8', 'replace')); i += n
    classes = []
    i = co
    for _ in range(cc):
        n, i = varint(b, i); extra, i = varint(b, i); i += 4 * extra
        classes.append(b[i:i+n].rstrip(b'\0').decode()); i += n
    values = []
    i = vo
    for _ in range(vc):
        k, i = varint(b, i); t = b[i]; i += 1
        if t == 0: v = struct.unpack_from('<b', b, i)[0]; i += 1
        elif t == 1: v = struct.unpack_from('<h', b, i)[0]; i += 2
        elif t == 2: v = struct.unpack_from('<i', b, i)[0]; i += 4
        elif t == 3: v = struct.unpack_from('<q', b, i)[0]; i += 8
        elif t == 4: v = True
        elif t == 5: v = False
        elif t == 6: v = struct.unpack_from('<f', b, i)[0]; i += 4
        elif t == 7: v = struct.unpack_from('<d', b, i)[0]; i += 8
        elif t == 8:
            n, i = varint(b, i); v = b[i:i+n]; i += n
        elif t == 9: v = None
        elif t == 10: v = ('obj', struct.unpack_from('<I', b, i)[0]); i += 4
        else: raise ValueError(t)
        values.append((keys[k], v))
    objects = []
    i = oo
    for _ in range(oc):
        c, i = varint(b, i); vi, i = varint(b, i); n, i = varint(b, i)
        objects.append((classes[c], values[vi:vi+n]))
    return objects

def show(path):
    objs = parse(path)
    def val(v):
        if isinstance(v, bytes):
            if len(v) == 17:   # CGRect: type byte + 4 float32
                return 'rect(%g,%g,%g,%g)' % struct.unpack_from('<4f', v, 1)
            if len(v) == 9:    # CGPoint/CGSize: type byte + 2 float32
                return '(%g,%g)' % struct.unpack_from('<2f', v, 1)
            try:
                s = v.decode('utf-8')
                if s.isprintable(): return repr(s)
            except Exception: pass
            return 'data[%d]' % len(v)
        return v
    for n, (cls, vals) in enumerate(objs):
        interesting = []
        for k, v in vals:
            if isinstance(v, tuple):
                tcls = objs[v[1]][0]
                if tcls in ('NSString', 'NSMutableString'):
                    s = [x for kk, x in objs[v[1]][1] if kk == 'NS.bytes']
                    interesting.append('%s=%r' % (k, s[0].decode('utf-8', 'replace') if s else ''))
                elif k in ('UIFont', 'UITextColor', 'UIBackgroundColor', 'UIImage', 'UIText', 'UITitle', 'UINormalTitle',
                           'UIStyle', 'UISubviews', 'UIViewController', 'UIResourceName', 'UIFontName'):
                    interesting.append('%s->#%d %s' % (k, v[1], tcls))
            elif k not in ('UINibEncoderEmptyKey', 'NSInlinedValue'):
                interesting.append('%s=%s' % (k, val(v)))
        if cls.startswith('UI') or cls in ('NSString',) and False:
            print('#%d %s: %s' % (n, cls, ', '.join(interesting)[:600]))
        elif cls in ('UIColor', 'NSColor'):
            print('#%d %s: %s' % (n, cls, ', '.join(interesting)))

if __name__ == '__main__':
    for p in sys.argv[1:]:
        print('=====', p)
        show(p)
