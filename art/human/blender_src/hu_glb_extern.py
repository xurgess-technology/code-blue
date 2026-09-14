"""Split a .glb's embedded images out into PNG files next to it and point the glTF at them.

    python nn_glb_extern.py <in.glb> <out.glb> [--tex-dir=textures]

Godot imports external images as ordinary texture files, so their import settings (VRAM
compression, normal-map mode, size limit) can be set per file and survive re-imports; embedded
images are extracted with default (lossless, uncompressed) settings on every import.

Pure standard library: runs in any Python 3 and inside Blender's (hu_build.py calls it).
"""
import json
import os
import struct
import sys


def _pad4(b, fill=b'\x00'):
    return b + fill * ((4 - len(b) % 4) % 4)


def extern(src, dst, tex_dir='textures'):
    data = open(src, 'rb').read()
    magic, version, _length = struct.unpack('<III', data[:12])
    if magic != 0x46546C67 or version != 2:
        raise ValueError('%s is not a glTF 2 binary' % src)
    pos = 12
    gltf = None
    bin_chunk = b''
    while pos < len(data):
        clen, ctype = struct.unpack('<II', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(body.decode('utf-8'))
        elif ctype == 0x004E4942:
            bin_chunk = body
        pos += 8 + clen
    views = gltf.get('bufferViews', [])
    out_dir = os.path.dirname(os.path.abspath(dst))
    os.makedirs(os.path.join(out_dir, tex_dir), exist_ok=True)
    image_views = set()
    written = []
    for i, img in enumerate(gltf.get('images', [])):
        if 'bufferView' not in img:
            continue
        bv = views[img['bufferView']]
        blob = bin_chunk[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
        ext = '.png' if img.get('mimeType', 'image/png') == 'image/png' else '.jpg'
        name = img.get('name') or 'image_%d' % i
        rel = '%s/%s%s' % (tex_dir, name, ext)
        with open(os.path.join(out_dir, rel), 'wb') as f:
            f.write(blob)
        written.append((rel, len(blob)))
        image_views.add(img['bufferView'])
        del img['bufferView']
        img.pop('mimeType', None)
        img['uri'] = rel
    # Rebuild the binary buffer without the image views, renumbering every reference.
    remap = {}
    new_views = []
    new_bin = b''
    for i, bv in enumerate(views):
        if i in image_views:
            continue
        blob = bin_chunk[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
        new_bin = _pad4(new_bin)
        nbv = dict(bv)
        nbv['byteOffset'] = len(new_bin)
        new_bin += blob
        remap[i] = len(new_views)
        new_views.append(nbv)
    new_bin = _pad4(new_bin)
    gltf['bufferViews'] = new_views
    for acc in gltf.get('accessors', []):
        if 'bufferView' in acc:
            acc['bufferView'] = remap[acc['bufferView']]
        sparse = acc.get('sparse')
        if sparse:
            for key in ('indices', 'values'):
                sparse[key]['bufferView'] = remap[sparse[key]['bufferView']]
    gltf['buffers'] = [{'byteLength': len(new_bin)}]
    js = _pad4(json.dumps(gltf, separators=(',', ':')).encode('utf-8'), b' ')
    total = 12 + 8 + len(js) + 8 + len(new_bin)
    with open(dst, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total))
        f.write(struct.pack('<II', len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack('<II', len(new_bin), 0x004E4942))
        f.write(new_bin)
    return written, total


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    tdir = 'textures'
    for a in sys.argv[1:]:
        if a.startswith('--tex-dir='):
            tdir = a.split('=', 1)[1]
    files, size = extern(args[0], args[1], tdir)
    for rel, n in files:
        print('wrote %s (%d KB)' % (rel, n // 1024))
    print('wrote %s (%d KB)' % (args[1], size // 1024))
