"""Mesh containers and sweep helpers shared by the human generators (pure Python + mathutils, no bpy).

A Part is a list of vertices (position, attribute masks, uv2, bone weights) and faces with per-corner
UVs. Generators add grids and rings; parts can be split (face predicate) into separate game pieces
that keep identical seam positions and normals.
"""
import math
from mathutils import Vector, Matrix

TAU = math.tau

# per-vertex float masks the procedural materials read (not exported to the game)
ATTRS = [
    # cloth
    'scrubs', 'pants', 'shoe', 'sole', 'cap', 'mask', 'tie', 'gown', 'sock', 'grip', 'uniform', 'reflect',
    'boot', 'belt', 'metal', 'tint', 'pocket', 'seam', 'lace', 'band', 'patch', 'zip',
    # shared dirt
    'blood', 'grime', 'crease',
    # skin
    'lip', 'brow', 'hair', 'scalp', 'beard', 'eye', 'iris', 'lid', 'nail', 'knuckle', 'vein', 'cheek',
    'socket', 'flesh', 'bone', 'inner', 'ear', 'nostril', 'gashz', 'woundz', 'veinz', 'stumpz', 'palm',
    'sole_skin', 'nipple', 'navel', 'moust', 'tear',
]


def smooth01(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def lerp(a, b, t):
    return a + (b - a) * t


def clamp(x, a, b):
    return max(a, min(b, x))


def gauss3(p, c, s):
    return math.exp(-(((p.x - c[0]) / s[0]) ** 2 + ((p.y - c[1]) / s[1]) ** 2 + ((p.z - c[2]) / s[2]) ** 2))


def pchip(xs, ys):
    """Monotone cubic interpolation (Fritsch-Carlson). Returns f(x)."""
    n = len(xs)
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    d = [(ys[i + 1] - ys[i]) / h[i] for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])

    def f(x):
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]
        lo, hi = 0, n - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if xs[mid] <= x:
                lo = mid
            else:
                hi = mid
        i = lo
        t = (x - xs[i]) / h[i]
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h[i] * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h[i] * m[i + 1])
    return f


def mirror_bone(b):
    if b.endswith('.L'):
        return b[:-2] + '.R'
    if b.endswith('.R'):
        return b[:-2] + '.L'
    return b


class Part:
    def __init__(self, name, mat, rigid=None, uv_boost=1.0):
        self.name, self.mat, self.uv_boost = name, mat, uv_boost
        self.rigid = rigid          # bone name when the whole part follows one bone
        self.v = []
        self.f = []
        self.fuv = []
        self.attr = {k: [] for k in ATTRS}
        self.w = []                 # per vertex {bone: weight}
        self.uv2 = []               # per vertex (u, v)
        self.uv_off = 0.0
        self.const = {}
        self.attr_fn = None
        self.weight_fn = None       # f(point, extra) -> {bone: w}
        self.uv2_fn = None
        self.nrm = None             # per vertex custom normal (set by smooth_normals)
        self.shape_keys = {}        # name -> list of per-vertex offsets (Vector)
        self.meta = {}

    def add_v(self, p, extra=None, w=None, uv2=None):
        p = Vector(p)
        self.v.append(p)
        a = dict(self.const)
        if self.attr_fn:
            for k, val in self.attr_fn(p).items():
                a[k] = max(a.get(k, 0.0), val)
        if extra:
            for k, val in extra.items():
                if k.startswith('_'):
                    continue
                a[k] = max(a.get(k, 0.0), val)
        for k in ATTRS:
            self.attr[k].append(a.get(k, 0.0))
        if w is None:
            if self.rigid:
                w = {self.rigid: 1.0}
            elif self.weight_fn:
                w = self.weight_fn(p, extra or {})
            else:
                w = {}
        self.w.append(w)
        if uv2 is None:
            uv2 = self.uv2_fn(p, extra or {}) if self.uv2_fn else (0.0, 0.0)
        self.uv2.append(uv2)
        return len(self.v) - 1

    def face(self, idx, uvs):
        self.f.append(tuple(idx))
        self.fuv.append([tuple(u) for u in uvs])

    def next_uv_block(self, width):
        o = self.uv_off
        self.uv_off += width + 0.04
        return o

    def grid(self, P, extras=None, wrap=False, vcoords=None, flip=False, ucoords=None):
        """P: rows of points (rows x cols). wrap: columns close around. Returns vertex ids."""
        rows, cols = len(P), len(P[0])
        ids = []
        for r in range(rows):
            ids.append([self.add_v(P[r][c], extras[r][c] if extras else None) for c in range(cols)])
        if ucoords is None:
            ncol = cols if wrap else cols - 1
            U = []
            for r in range(rows):
                acc = [0.0]
                for c in range(ncol):
                    acc.append(acc[-1] + (P[r][(c + 1) % cols] - P[r][c]).length)
                U.append(acc)
            width = sum(u[-1] for u in U) / rows
            ucoords = [sum(U[r][c] for r in range(rows)) / rows for c in range(ncol + 1)]
        else:
            width = ucoords[-1]
        if vcoords is None:
            vcoords = [0.0]
            for r in range(1, rows):
                d = sum((P[r][c] - P[r - 1][c]).length for c in range(cols)) / cols
                vcoords.append(vcoords[-1] + max(d, 1e-4))
        u0 = self.next_uv_block(width)
        ncol = cols if wrap else cols - 1
        for r in range(rows - 1):
            for c in range(ncol):
                c2 = (c + 1) % cols
                q = (ids[r][c], ids[r][c2], ids[r + 1][c2], ids[r + 1][c])
                uv = [(u0 + ucoords[c], vcoords[r]), (u0 + ucoords[c + 1], vcoords[r]),
                      (u0 + ucoords[c + 1], vcoords[r + 1]), (u0 + ucoords[c], vcoords[r + 1])]
                if flip:
                    q, uv = q[::-1], uv[::-1]
                self.face(q, uv)
        return ids, (u0, ucoords, vcoords)

    def fan(self, ring_ids, center, extra=None, flip=False, uv_center=(0.0, 0.0), uv_scale=1.0):
        """Close a ring of existing vertex ids with a fan to a new centre vertex (planar UVs)."""
        cid = self.add_v(center, extra)
        u0 = self.next_uv_block(0.3 * uv_scale)
        c = Vector(center)
        pts = [self.v[i] for i in ring_ids]
        nrm = Vector()
        for k in range(len(pts)):
            nrm += (pts[k] - c).cross(pts[(k + 1) % len(pts)] - c)
        nrm.normalize()
        ax = (pts[0] - c)
        ax = (ax - nrm * ax.dot(nrm)).normalized()
        ay = nrm.cross(ax)

        def uvof(p):
            d = p - c
            return (u0 + 0.15 * uv_scale + d.dot(ax), 0.15 * uv_scale + d.dot(ay))
        n = len(ring_ids)
        for k in range(n):
            a, b = ring_ids[k], ring_ids[(k + 1) % n]
            q = (cid, a, b)
            uv = [uvof(c), uvof(self.v[a]), uvof(self.v[b])]
            if flip:
                q, uv = q[::-1], uv[::-1]
            self.face(q, uv)
        return cid

    def slab(self, P, Nrm, thick, extras=None):
        """A closed thin slab from a grid of mid-surface points and normals."""
        rows, cols = len(P), len(P[0])
        front = [[P[r][c] + Nrm[r][c] * (thick * 0.5) for c in range(cols)] for r in range(rows)]
        back = [[P[r][c] - Nrm[r][c] * (thick * 0.5) for c in range(cols)] for r in range(rows)]
        e1 = P[0][1] - P[0][0]
        e2 = P[1][0] - P[0][0]
        flip = e1.cross(e2).dot(Nrm[0][0]) < 0
        fid, _ = self.grid(front, extras, flip=flip)
        bid, _ = self.grid(back, extras, flip=not flip)
        loop = [(0, c) for c in range(cols)] + [(r, cols - 1) for r in range(1, rows)] + \
               [(rows - 1, c) for c in range(cols - 2, -1, -1)] + [(r, 0) for r in range(rows - 2, 0, -1)]
        u0 = self.next_uv_block(0.0)
        s = 0.0
        center = sum((P[r][c] for r in range(rows) for c in range(cols)), Vector()) / (rows * cols)
        for k in range(len(loop)):
            a, b = loop[k], loop[(k + 1) % len(loop)]
            seg = (P[b[0]][b[1]] - P[a[0]][a[1]]).length
            quad = [fid[a[0]][a[1]], fid[b[0]][b[1]], bid[b[0]][b[1]], bid[a[0]][a[1]]]
            uvs = [(u0 + s, 0.0), (u0 + s + seg, 0.0), (u0 + s + seg, thick * 1.5), (u0 + s, thick * 1.5)]
            pa, pb, pc = self.v[quad[0]], self.v[quad[1]], self.v[quad[2]]
            fn = (pb - pa).cross(pc - pa)
            mid = (P[a[0]][a[1]] + P[b[0]][b[1]]) * 0.5
            if fn.dot(mid - center) < 0:
                quad, uvs = quad[::-1], uvs[::-1]
            self.face(quad, uvs)
            s += seg
        self.uv_off = max(self.uv_off, u0 + s + 0.04)

    def tube(self, rings, extras=None, cap_start=None, cap_end=None, vcoords=None):
        """Closed rings (each a list of points) -> a tube, optionally capped with fans to points."""
        ids, (u0, uc, vc) = self.grid(rings, extras, wrap=True, vcoords=vcoords)
        if cap_start is not None:
            self.fan(ids[0], cap_start, flip=True)
        if cap_end is not None:
            self.fan(ids[-1], cap_end)
        return ids

    def mirrored(self, name):
        m = Part(name, self.mat, mirror_bone(self.rigid) if self.rigid else None, self.uv_boost)
        m.v = [Vector((-p.x, p.y, p.z)) for p in self.v]
        m.f = [tuple(reversed(f)) for f in self.f]
        m.fuv = [list(reversed(u)) for u in self.fuv]
        m.attr = {k: list(v) for k, v in self.attr.items()}
        m.w = [{mirror_bone(b): x for b, x in w.items()} for w in self.w]
        m.uv2 = list(self.uv2)
        if self.nrm:
            m.nrm = [Vector((-n.x, n.y, n.z)) for n in self.nrm]
        m.shape_keys = {k: [Vector((-d.x, d.y, d.z)) for d in v] for k, v in self.shape_keys.items()}
        m.meta = dict(self.meta)
        return m

    def fill_weights(self):
        """Vertices without weights (fan centres added after a generator restored its weight_fn) take
        the weights of the nearest weighted vertex of the same part."""
        empty = [i for i, w in enumerate(self.w) if not w]
        if not empty:
            return 0
        have = [i for i, w in enumerate(self.w) if w]
        if not have:
            return 0
        for i in empty:
            p = self.v[i]
            j = min(have, key=lambda k: (self.v[k] - p).length_squared)
            self.w[i] = dict(self.w[j])
        return len(empty)

    def tris(self):
        return sum(len(f) - 2 for f in self.f)

    def smooth_normals(self):
        n = [Vector() for _ in self.v]
        for f in self.f:
            pts = [self.v[i] for i in f]
            fn = Vector()
            for k in range(len(pts)):
                fn += pts[k].cross(pts[(k + 1) % len(pts)])
            for i in f:
                n[i] += fn
        # weld normals of coincident vertices (seams between separately generated rings)
        buckets = {}
        for i, p in enumerate(self.v):
            key = (round(p.x * 2000), round(p.y * 2000), round(p.z * 2000))
            buckets.setdefault(key, []).append(i)
        for ids in buckets.values():
            if len(ids) > 1:
                s = sum((n[i] for i in ids), Vector())
                for i in ids:
                    n[i] = s.copy()
        self.nrm = [x.normalized() if x.length > 1e-12 else Vector((0, 0, 1)) for x in n]

    def extract(self, face_pred, name, keep_in_self=False):
        """Move faces for which face_pred(face_index, verts) is true into a new part."""
        new = Part(name, self.mat, self.rigid, self.uv_boost)
        new.meta = dict(self.meta)
        keep_f, keep_uv = [], []
        remap = {}
        for fi, (f, uv) in enumerate(zip(self.f, self.fuv)):
            if face_pred(fi, [self.v[i] for i in f]):
                nf = []
                for i in f:
                    if i not in remap:
                        remap[i] = len(new.v)
                        new.v.append(self.v[i].copy())
                        for k in ATTRS:
                            new.attr[k].append(self.attr[k][i])
                        new.w.append(dict(self.w[i]))
                        new.uv2.append(self.uv2[i])
                    nf.append(remap[i])
                new.f.append(tuple(nf))
                new.fuv.append(list(uv))
                if keep_in_self:
                    keep_f.append(f)
                    keep_uv.append(uv)
            else:
                keep_f.append(f)
                keep_uv.append(uv)
        inv = sorted(remap.items(), key=lambda kv: kv[1])
        if self.nrm:
            new.nrm = [self.nrm[i].copy() for i, _ in inv]
        for k, offs in self.shape_keys.items():
            new.shape_keys[k] = [offs[i].copy() for i, _ in inv]
        self.f, self.fuv = keep_f, keep_uv
        self.compact()
        return new

    def compact(self):
        used = sorted({i for f in self.f for i in f})
        if len(used) == len(self.v):
            return
        remap = {old: new for new, old in enumerate(used)}
        self.v = [self.v[i] for i in used]
        for k in ATTRS:
            self.attr[k] = [self.attr[k][i] for i in used]
        self.w = [self.w[i] for i in used]
        self.uv2 = [self.uv2[i] for i in used]
        if self.nrm:
            self.nrm = [self.nrm[i] for i in used]
        for k in list(self.shape_keys):
            self.shape_keys[k] = [self.shape_keys[k][i] for i in used]
        self.f = [tuple(remap[i] for i in f) for f in self.f]

    def merge(self, other):
        base = len(self.v)
        self.v += [p.copy() for p in other.v]
        for k in ATTRS:
            self.attr[k] += other.attr[k]
        self.w += [dict(w) for w in other.w]
        self.uv2 += list(other.uv2)
        if self.nrm is not None or other.nrm is not None:
            a = self.nrm if self.nrm is not None else [Vector((0, 0, 1))] * base
            b = other.nrm if other.nrm is not None else [Vector((0, 0, 1))] * len(other.v)
            self.nrm = a + b
        keys = set(self.shape_keys) | set(other.shape_keys)
        for k in keys:
            a = self.shape_keys.get(k, [Vector()] * base)
            b = other.shape_keys.get(k, [Vector()] * len(other.v))
            self.shape_keys[k] = a + b
        off = self.uv_off
        self.f += [tuple(i + base for i in f) for f in other.f]
        self.fuv += [[(u + off, v) for u, v in uv] for uv in other.fuv]
        self.uv_off += other.uv_off + 0.04


# ---------------------------------------------------------------- polylines and sweeps
def resample(points, count, spacing_fn=None):
    L = [0.0]
    for i in range(1, len(points)):
        L.append(L[-1] + (points[i] - points[i - 1]).length)
    total = L[-1]
    out = []
    j = 0
    for k in range(count):
        t = k / (count - 1)
        if spacing_fn:
            t = spacing_fn(t)
        s = t * total
        while j < len(L) - 2 and L[j + 1] < s:
            j += 1
        seg = L[j + 1] - L[j]
        f = 0.0 if seg <= 0 else (s - L[j]) / seg
        out.append(points[j].lerp(points[j + 1], clamp(f, 0.0, 1.0)))
    return out, total


def chaikin(points, iters=2):
    for _ in range(iters):
        new = [points[0]]
        for i in range(len(points) - 1):
            a, b = points[i], points[i + 1]
            new.append(a.lerp(b, 0.25))
            new.append(a.lerp(b, 0.75))
        new.append(points[-1])
        points = new
    return points


def frames(path, up_hint):
    T = []
    for i in range(len(path)):
        a = path[max(0, i - 1)]
        b = path[min(len(path) - 1, i + 1)]
        T.append((b - a).normalized())
    N0 = (up_hint - T[0] * up_hint.dot(T[0])).normalized()
    Ns = [N0]
    for i in range(1, len(path)):
        rot = T[i - 1].rotation_difference(T[i])
        n = rot @ Ns[-1]
        n = (n - T[i] * n.dot(T[i])).normalized()
        Ns.append(n)
    Bs = [T[i].cross(Ns[i]) for i in range(len(path))]
    return T, Ns, Bs


def arclen(path):
    S = [0.0]
    for i in range(1, len(path)):
        S.append(S[-1] + (path[i] - path[i - 1]).length)
    return S


def sweep(path, segs, offset_fn, up_hint, theta0=0.0, S=None):
    """offset_fn(i, s, theta) -> (a, b) offsets along N and B. theta 0 = +N."""
    T, Ns, Bs = frames(path, up_hint)
    if S is None:
        S = arclen(path)
    rings = []
    for i, p in enumerate(path):
        ring = []
        for j in range(segs):
            th = theta0 + TAU * j / segs
            a, b = offset_fn(i, S[i], th)
            ring.append(p + Ns[i] * a + Bs[i] * b)
        rings.append(ring)
    return rings, S, (T, Ns, Bs)


def sell(th, ra, rb, n=2.0):
    c, s = math.cos(th), math.sin(th)
    e = 2.0 / n
    return (ra * math.copysign(abs(c) ** e, c), rb * math.copysign(abs(s) ** e, s))


def rotate_towards(d, target, ang):
    axis = d.cross(target)
    if axis.length < 1e-6:
        return d
    return (Matrix.Rotation(ang, 3, axis.normalized()) @ d).normalized()
