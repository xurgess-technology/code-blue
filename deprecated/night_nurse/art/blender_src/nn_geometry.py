"""Night Nurse procedural geometry (pure Python + mathutils, no bpy).

Every part is generated from analytic shape functions at a resolution multiplier `res`:
res=1 is the game mesh, res=3 is the dense copy the normal/AO maps are baked from.
Blender axes: Z up, the character faces -Y, its left side is +X.
"""
import math
from mathutils import Vector, Matrix, noise

TAU = math.tau

ATTRS = ['apron', 'stocking', 'shoe', 'sole', 'belt', 'mask', 'cap', 'blood', 'crease',
         'sock', 'knuckle', 'nail', 'hair', 'eye', 'mouth', 'vein', 'tie']

# ---------------------------------------------------------------- joints (left side)
SHOULDER = Vector((0.160, 0.006, 1.735))
ELBOW = Vector((0.212, 0.030, 1.335))
WRIST = Vector((0.240, 0.014, 0.930))
HIP = Vector((0.086, 0.0, 1.12))
KNEE = Vector((0.089, -0.012, 0.62))
ANKLE = Vector((0.092, 0.028, 0.105))
HEAD_C = Vector((0.0, -0.012, 2.105))   # head centre (local origin of the head functions)
NECK_BASE = Vector((0.0, 0.018, 1.790))


def smooth01(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def lerp(a, b, t):
    return a + (b - a) * t


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
            return ys[0] + m[0] * (x - xs[0])
        if x >= xs[-1]:
            return ys[-1] + m[-1] * (x - xs[-1])
        i = 0
        while xs[i + 1] < x:
            i += 1
        t = (x - xs[i]) / h[i]
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h[i] * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h[i] * m[i + 1])
    return f


def densify(vals, res):
    """Insert res-1 evenly spaced values between each pair."""
    if res <= 1:
        return list(vals)
    out = []
    for i in range(len(vals) - 1):
        for k in range(res):
            out.append(lerp(vals[i], vals[i + 1], k / res))
    out.append(vals[-1])
    return out


# ---------------------------------------------------------------- mesh builder
class Part:
    def __init__(self, name, mat, bones, uv_boost=1.0):
        self.name, self.mat, self.bones, self.uv_boost = name, mat, bones, uv_boost
        self.v = []
        self.f = []      # tuples of vertex indices
        self.fuv = []    # per face list of (u, v)
        self.attr = {k: [] for k in ATTRS}
        self.uv_off = 0.0   # running offset so separate grids do not overlap in UV space
        self.const = {}
        self.attr_fn = None

    def add_v(self, p, extra=None):
        self.v.append(Vector(p))
        a = dict(self.const)
        if self.attr_fn:
            for k, val in self.attr_fn(Vector(p)).items():
                a[k] = max(a.get(k, 0.0), val)
        if extra:
            for k, val in extra.items():
                a[k] = max(a.get(k, 0.0), val)
        for k in ATTRS:
            self.attr[k].append(a.get(k, 0.0))
        return len(self.v) - 1

    def face(self, idx, uvs):
        self.f.append(tuple(idx))
        self.fuv.append([tuple(u) for u in uvs])

    def next_uv_block(self, width):
        o = self.uv_off
        self.uv_off += width + 0.05
        return o

    # rings: list of rings (each a list of points, equal length), wrapped closed around.
    def rings(self, rings, vcoords=None, extras=None, cap_start=None, cap_end=None):
        n = len(rings[0])
        if vcoords is None:
            vcoords = [0.0]
            for i in range(1, len(rings)):
                c0 = sum(rings[i - 1], Vector()) / n
                c1 = sum(rings[i], Vector()) / n
                vcoords.append(vcoords[-1] + max((c1 - c0).length, 0.002))
        circ = 0.0
        for r in rings:
            circ += sum((r[(j + 1) % n] - r[j]).length for j in range(n))
        circ /= len(rings)
        u0 = self.next_uv_block(circ)
        ids = []
        for i, r in enumerate(rings):
            row = []
            for j, p in enumerate(r):
                row.append(self.add_v(p, extras[i][j] if extras else None))
            ids.append(row)
        for i in range(len(rings) - 1):
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                self.face((ids[i][j], ids[i][j2], ids[i + 1][j2], ids[i + 1][j]),
                          [(ua, vcoords[i]), (ub, vcoords[i]), (ub, vcoords[i + 1]), (ua, vcoords[i + 1])])
        if cap_start is not None:
            pole = self.add_v(cap_start)
            vp = vcoords[0] - (cap_start - sum(rings[0], Vector()) / n).length
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                self.face((pole, ids[0][j2], ids[0][j]), [((ua + ub) / 2, vp), (ub, vcoords[0]), (ua, vcoords[0])])
        if cap_end is not None:
            pole = self.add_v(cap_end)
            vp = vcoords[-1] + (cap_end - sum(rings[-1], Vector()) / n).length
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                self.face((ids[-1][j], ids[-1][j2], pole), [(ua, vcoords[-1]), (ub, vcoords[-1]), ((ua + ub) / 2, vp)])
        return ids

    # grid: rows x cols points with outward normals -> closed thin slab.
    def slab(self, P, Nrm, thick, extras=None):
        rows, cols = len(P), len(P[0])
        W = sum((P[r][c + 1] - P[r][c]).length for r in range(rows) for c in range(cols - 1)) / rows
        H = sum((P[r + 1][c] - P[r][c]).length for r in range(rows - 1) for c in range(cols)) / cols
        u0 = self.next_uv_block(W * 2 + 0.05)
        front = [[self.add_v(P[r][c] + Nrm[r][c] * (thick * 0.5), extras[r][c] if extras else None) for c in range(cols)] for r in range(rows)]
        back = [[self.add_v(P[r][c] - Nrm[r][c] * (thick * 0.5), extras[r][c] if extras else None) for c in range(cols)] for r in range(rows)]
        e1 = P[0][1] - P[0][0]
        e2 = P[1][0] - P[0][0]
        flip = e1.cross(e2).dot(Nrm[0][0]) < 0

        def uvf(r, c, side):
            u = W * c / (cols - 1)
            if side:
                u = W * 2 + 0.05 - u
            return (u0 + u, H * r / (rows - 1))
        for r in range(rows - 1):
            for c in range(cols - 1):
                q = [(r, c), (r, c + 1), (r + 1, c + 1), (r + 1, c)]
                qf = q if not flip else q[::-1]
                self.face([front[a][b] for a, b in qf], [uvf(a, b, False) for a, b in qf])
                qb = q[::-1] if not flip else q
                self.face([back[a][b] for a, b in qb], [uvf(a, b, True) for a, b in qb])
        loop = [(0, c) for c in range(cols)] + [(r, cols - 1) for r in range(1, rows)] + \
               [(rows - 1, c) for c in range(cols - 2, -1, -1)] + [(r, 0) for r in range(rows - 2, 0, -1)]
        center = sum((P[r][c] for r in range(rows) for c in range(cols)), Vector()) / (rows * cols)
        s = 0.0
        vb = -0.05 - thick * 2
        u0b = self.next_uv_block(0.0)
        for k in range(len(loop)):
            a, b = loop[k], loop[(k + 1) % len(loop)]
            seg = (P[b[0]][b[1]] - P[a[0]][a[1]]).length
            quad = [front[a[0]][a[1]], front[b[0]][b[1]], back[b[0]][b[1]], back[a[0]][a[1]]]
            uvs = [(u0b + s, vb), (u0b + s + seg, vb), (u0b + s + seg, vb - thick * 3), (u0b + s, vb - thick * 3)]
            pa, pb, pc = self.v[quad[0]], self.v[quad[1]], self.v[quad[2]]
            fn = (pb - pa).cross(pc - pa)
            mid = (P[a[0]][a[1]] + P[b[0]][b[1]]) * 0.5
            if fn.dot(mid - center) < 0:
                quad, uvs = quad[::-1], uvs[::-1]
            self.face(quad, uvs)
            s += seg
        self.uv_off = max(self.uv_off, u0b + s + 0.05)

    def mirrored(self, name):
        m = Part(name, self.mat, [mirror_bone(b) for b in self.bones], self.uv_boost)
        m.v = [Vector((-p.x, p.y, p.z)) for p in self.v]
        m.f = [tuple(reversed(f)) for f in self.f]
        m.fuv = [list(reversed(u)) for u in self.fuv]
        m.attr = {k: list(v) for k, v in self.attr.items()}
        return m

    def tris(self):
        return sum(len(f) - 2 for f in self.f)


def mirror_bone(b):
    return b[:-2] + '.R' if b.endswith('.L') else b


# ---------------------------------------------------------------- sweeps
def resample(points, count, spacing_fn=None):
    """Resample a polyline to count points by arclength (optionally warped by spacing_fn(t))."""
    L = [0.0]
    for i in range(1, len(points)):
        L.append(L[-1] + (points[i] - points[i - 1]).length)
    total = L[-1]
    out = []
    for k in range(count):
        t = k / (count - 1)
        if spacing_fn:
            t = spacing_fn(t)
        s = t * total
        i = 0
        while i < len(L) - 2 and L[i + 1] < s:
            i += 1
        seg = L[i + 1] - L[i]
        f = 0.0 if seg <= 0 else (s - L[i]) / seg
        out.append(points[i].lerp(points[i + 1], f))
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


def sweep(path, segs, offset_fn, up_hint=Vector((0, -1, 0)), theta0=math.pi):
    """offset_fn(s, t, theta) -> (a, b) offsets along N (front) and B."""
    T, Ns, Bs = frames(path, up_hint)
    S = [0.0]
    for i in range(1, len(path)):
        S.append(S[-1] + (path[i] - path[i - 1]).length)
    total = S[-1] or 1.0
    rings = []
    for i, p in enumerate(path):
        ring = []
        for j in range(segs):
            th = theta0 + TAU * j / segs
            a, b = offset_fn(S[i], S[i] / total, th)
            ring.append(p + Ns[i] * a + Bs[i] * b)
        rings.append(ring)
    return rings, S, (T, Ns, Bs)


def sell(th, ra, rb, n=2.0):
    """Superellipse offsets for angle th (0 = +N)."""
    c, s = math.cos(th), math.sin(th)
    e = 2.0 / n
    return (ra * math.copysign(abs(c) ** e, c), rb * math.copysign(abs(s) ** e, s))


# ---------------------------------------------------------------- dress
DRESS_KEYS = [  # z, half-width (X), half-depth (Y), centre y, superellipse n
    (0.36, 0.205, 0.198, 0.016, 2.0),
    (0.60, 0.188, 0.176, 0.010, 2.0),
    (0.90, 0.166, 0.146, 0.004, 2.0),
    (1.12, 0.142, 0.112, 0.000, 2.1),
    (1.28, 0.110, 0.083, 0.000, 2.2),
    (1.42, 0.121, 0.089, -0.004, 2.2),
    (1.56, 0.135, 0.093, -0.002, 2.3),
    (1.66, 0.142, 0.090, 0.004, 2.4),
    (1.72, 0.150, 0.086, 0.008, 2.5),
    (1.765, 0.128, 0.078, 0.012, 2.3),
    (1.80, 0.094, 0.064, 0.016, 2.2),
    (1.83, 0.056, 0.052, 0.018, 2.0),
    (1.85, 0.050, 0.048, 0.018, 2.0),
]
_dz = [k[0] for k in DRESS_KEYS]
D_RX = pchip(_dz, [k[1] for k in DRESS_KEYS])
D_RY = pchip(_dz, [k[2] for k in DRESS_KEYS])
D_CY = pchip(_dz, [k[3] for k in DRESS_KEYS])
D_N = pchip(_dz, [k[4] for k in DRESS_KEYS])


def skirt_fold(th, z):
    A = 0.030 * smooth01((1.08 - z) / 0.70)
    g = 0.004 * smooth01(1.0 - abs(z - 1.20) / 0.09)   # gathers under the waistband
    if A <= 0 and g <= 0:
        return 0.0
    c, s = math.cos(th), math.sin(th)
    drift = noise.noise(Vector((c * 1.2, s * 1.2, z * 1.6 + 3.1)))
    x = th * 9.0 + drift * 2.4
    p = math.sin(x) + 0.35 * math.sin(2.0 * x + 1.3) + 0.55 * noise.noise(Vector((c * 2.4, s * 2.4, z * 2.8 + 7.0)))
    p = max(-1.0, min(1.0, p / 1.5))
    return A * p + g * math.sin(th * 26.0)


def dress_offset(th, z, fold=1.0, extra=0.0):
    ra, rb = D_RY(z), D_RX(z)
    a, b = sell(th, ra + extra, rb + extra, D_N(z))
    f = skirt_fold(th, z) * fold
    # gaunt chest: a sternum hollow and ribs pressing through the bodice
    if 1.34 < z < 1.64:
        side = abs(math.sin(th))
        front = max(0.0, math.cos(th))
        f -= 0.006 * front ** 6 * smooth01(1 - abs(z - 1.52) / 0.1)
        rib = 0.5 + 0.5 * math.sin((z - 1.36) * TAU / 0.036)
        f -= 0.0028 * rib * smooth01((side - 0.35) / 0.3) * front ** 0.3 * smooth01(1 - abs(z - 1.47) / 0.12)
        # shoulder blades press through the back
    if 1.50 < z < 1.74:
        back = max(0.0, -math.cos(th))
        f += 0.010 * smooth01(1 - abs(abs(math.sin(th)) - 0.45) / 0.25) * back * smooth01(1 - abs(z - 1.63) / 0.1)
    n = Vector((math.cos(th), math.sin(th), 0.0))
    return a + n.x * f, b + n.y * f


def dress_point(th, z, fold=1.0, extra=0.0):
    a, b = dress_offset(th, z, fold, extra)
    # N = -Y (front), B = +X for a vertical path
    return Vector((b, -a + D_CY(z), z))


def dress_attr(p):
    return {'crease': smooth01((1.1 - p.z) / 0.6) * 0.8 + 0.2,
            'blood': 0.25 + 0.55 * smooth01((0.75 - p.z) / 0.35)}


def build_dress(res):
    P = Part('dress', 'cloth', ['hips', 'spine', 'chest', 'upperchest', 'thigh.L', 'thigh.R', 'shin.L', 'shin.R'])
    P.attr_fn = dress_attr
    segs = 48 * res
    zs = [0.36, 0.43, 0.51, 0.59, 0.67, 0.75, 0.83, 0.91, 0.99, 1.06, 1.12, 1.17, 1.215, 1.25, 1.28, 1.315,
          1.355, 1.395, 1.435, 1.475, 1.515, 1.555, 1.595, 1.635, 1.675, 1.71, 1.74, 1.765, 1.787, 1.808,
          1.826]
    zs = densify(zs, res)
    rings = []
    th_of = [math.pi + TAU * j / segs for j in range(segs)]

    def hem_z(th):
        c, s = math.cos(th), math.sin(th)
        return 0.34 + 0.008 * noise.noise(Vector((c * 2.2, s * 2.2, 5.0)))
    # inner turn-up of the hem so the open bottom never shows a hole
    for zi, sc in [(0.50, 0.93), (0.37, 0.955)]:
        rings.append([Vector((q.x * sc, (q.y - D_CY(zi)) * sc + D_CY(zi), zi)) for q in (dress_point(th, zi, 1.0) for th in th_of)])
    rings.append([dress_point(th, hem_z(th), 1.0, 0.004) for th in th_of])
    for z in zs[1:]:
        ring = []
        for th in th_of:
            zz = z
            if z < 0.37:
                zz = hem_z(th)
            ring.append(dress_point(th, zz))
        rings.append(ring)
    # collar: roll outwards, then tuck back in towards the neck
    for zi, extra in [(1.838, 0.016), (1.842, 0.008), (1.836, -0.006)]:
        rings.append([dress_point(th, zi, 0.0, extra) for th in th_of])
    P.rings(rings)
    return P


# ---------------------------------------------------------------- apron, bib, straps, belt
def build_apron(res):
    P = Part('apron', 'cloth', ['hips', 'spine', 'thigh.L', 'thigh.R', 'shin.L', 'shin.R'])
    P.const = {'apron': 1.0}
    P.attr_fn = lambda p: {'blood': 0.55 + 0.45 * smooth01((1.15 - p.z) / 0.5), 'crease': 0.35}
    rows, cols = 10 * res + 1, 16 * res + 1
    Pts, Nr = [], []
    for r in range(rows):
        v = r / (rows - 1)
        row, nrow = [], []
        for c in range(cols):
            u = c / (cols - 1)
            th = lerp(-1.15, 1.15, u)
            ztop, zbot = 1.268, 0.45 + 0.012 * noise.noise(Vector((u * 4.0, 1.0, 2.0)))
            z = lerp(zbot, ztop, v)
            A = 0.030 * smooth01((1.08 - z) / 0.70)
            f = 0.5 * skirt_fold(th, z) + 0.5 * A + 0.010
            ra, rb = D_RY(z), D_RX(z)
            a, b = sell(th, ra, rb, D_N(z))
            n = Vector((math.cos(th), math.sin(th), 0))
            a, b = a + n.x * f, b + n.y * f
            p = Vector((b, -a + D_CY(z), z))
            row.append(p)
            nrow.append(Vector((math.sin(th), -math.cos(th), 0.0)))
        Pts.append(row)
        Nr.append(nrow)
    P.slab(Pts, Nr, 0.003)
    # bib
    rows, cols = 7 * res + 1, 9 * res + 1
    Pts, Nr = [], []
    for r in range(rows):
        v = r / (rows - 1)
        z = lerp(1.25, 1.575, v)
        half = lerp(0.62, 0.40, v)
        row, nrow = [], []
        for c in range(cols):
            th = lerp(-half, half, c / (cols - 1))
            p = dress_point(th, z, 0.0, 0.006 + 0.004 * (1 - v))
            row.append(p)
            nrow.append(Vector((math.sin(th), -math.cos(th), 0.0)))
        Pts.append(row)
        Nr.append(nrow)
    P.slab(Pts, Nr, 0.0025)
    return P


def surface_ribbon(P, pts_thz, width, lift, thick, res, count):
    """A strap lying on the dress: pts_thz is a list of (theta, z) control points."""
    ctrl = [dress_point(th, z, 0.0, lift) for th, z in pts_thz]
    ctrl = chaikin(ctrl, 3)
    path, _ = resample(ctrl, count * res + 1)
    rows = []
    nrows = []
    for i, p in enumerate(path):
        t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        out = Vector((p.x, p.y - D_CY(p.z), 0.0))
        if out.length < 1e-4:
            out = Vector((0, -1, 0))
        out.normalize()
        # near the shoulder top the surface normal turns upward
        up_w = smooth01((p.z - 1.70) / 0.06)
        n = (out * (1 - up_w) + Vector((0, 0, 1)) * up_w).normalized()
        side = t.cross(n).normalized()
        rows.append([p - side * width * 0.5, p + side * width * 0.5])
        nrows.append([n, n])
    P.slab(rows, nrows, thick)


def build_straps(res):
    P = Part('straps', 'cloth', ['spine', 'chest', 'upperchest', 'shoulder.L', 'shoulder.R', 'hips'])
    P.const = {'apron': 1.0}
    for sgn in (1, -1):
        ctrl = [(sgn * 0.40, 1.565), (sgn * 0.52, 1.69), (sgn * 0.95, 1.765), (sgn * 1.8, 1.76),
                (sgn * 2.45, 1.64), (sgn * 2.75, 1.42), (sgn * 2.85, 1.27)]
        surface_ribbon(P, ctrl, 0.022, 0.011, 0.0025, res, 20)
    return P


def build_belt(res):
    P = Part('belt', 'cloth', ['hips', 'spine'])
    P.const = {'belt': 1.0}
    segs = 40 * res
    th_of = [math.pi + TAU * j / segs for j in range(segs)]
    rings = []
    for z, e in [(1.246, 0.004), (1.247, 0.016), (1.297, 0.016), (1.298, 0.004)]:
        rings.append([dress_point(th, z, 0.0, e) for th in th_of])
    P.rings(rings)
    return P


# ---------------------------------------------------------------- arms
def build_sleeve_L(res):
    P = Part('sleeve.L', 'cloth', ['upperchest', 'shoulder.L', 'upperarm.L', 'forearm.L'])
    P.attr_fn = lambda p: {'crease': 1.0 - 0.6 * smooth01(abs(p.z - ELBOW.z) / 0.15),
                           'blood': 0.8 * smooth01((1.20 - p.z) / 0.08)}
    end = ELBOW.lerp(WRIST, 0.53)
    start = SHOULDER + Vector((-0.045, 0.0, 0.03))
    ctrl = chaikin([start, SHOULDER + Vector((0.004, 0, -0.02)), ELBOW, end], 2)
    path, L = resample(ctrl, 18 * res + 1, lambda t: t)
    segs = 16 * res
    s_el = (ELBOW - SHOULDER).length + 0.05

    def off(s, t, th):
        r = lerp(0.050, 0.041, smooth01(s / s_el)) - 0.006 * smooth01((s - s_el) / 0.3)
        r += 0.003 * math.exp(-((s - 0.05) / 0.06) ** 2)          # puffed sleeve head
        el = math.exp(-((s - s_el) / 0.07) ** 2)
        r += el * (0.004 * math.sin(th * 3 + s * 40) + 0.003 * math.sin(s * 95.0))
        r += 0.0025 * noise.noise(Vector((math.cos(th) * 2, math.sin(th) * 2, s * 12)))
        r += 0.004 * smooth01((s - (L - 0.03)) / 0.01)            # starched cuff
        return (r * math.cos(th), r * 0.92 * math.sin(th))
    rings, S, fr = sweep(path, segs, off, Vector((0, -1, 0)))
    # tuck the cuff back inside
    T, Ns, Bs = fr
    last = path[-1]
    inner = []
    for j in range(segs):
        th = math.pi + TAU * j / segs
        r = 0.034
        inner.append(last - T[-1] * 0.03 + Ns[-1] * r * math.cos(th) + Bs[-1] * r * math.sin(th))
    rings.append([p + T[-1] * 0.001 for p in rings[-1]])
    rings[-1] = [last + (p - last) * 0.9 for p in rings[-1]]
    rings.append(inner)
    P.rings(rings)
    return P


KNUCKLE_OFFS = [0.029, 0.0095, -0.0105, -0.028]            # along N (front) for index..pinky
FINGER_LEN = [0.165, 0.190, 0.176, 0.138]
FINGER_CURL = [(0.10, 0.22, 0.20), (0.08, 0.30, 0.26), (0.16, 0.38, 0.30), (0.26, 0.44, 0.34)]
FINGER_NAMES = ['index', 'middle', 'ring', 'pinky']
PALM_LEN = 0.105


def hand_frame():
    T = Vector((0.03, 0.0, -1.0)).normalized()     # slightly outward at the knuckles
    N = Vector((0, -1, 0))
    N = (N - T * N.dot(T)).normalized()
    B = T.cross(N)   # points towards the body (palm side) for the left hand
    return T, N, B


def build_forearm_L(res, joints):
    P = Part('forearm.L', 'skin', ['forearm.L', 'hand.L'] + ['%s1.L' % f for f in FINGER_NAMES] + ['thumb1.L'])
    T, N, B = hand_frame()
    knuck = WRIST + T * PALM_LEN
    top = ELBOW.lerp(WRIST, 0.42)
    ctrl = [top, WRIST, WRIST + T * 0.04, knuck + T * 0.008]
    path, L = resample(chaikin(ctrl, 2), 26 * res + 1)
    s_wr = (WRIST - top).length
    segs = 14 * res

    def off(s, t, th):
        c, sn = math.cos(th), math.sin(th)
        u = s - s_wr
        # forearm: thin, flattened, tendon ridges and a wrist bone
        ra = lerp(0.025, 0.019, smooth01(s / s_wr))
        rb = lerp(0.023, 0.0155, smooth01(s / s_wr))
        ra += 0.0012 * math.sin(th * 5) * smooth01(s / s_wr)
        # palm: wide and thin
        w = smooth01((u + 0.012) / 0.040)
        ra = lerp(ra, 0.041, w)
        rb = lerp(rb, 0.0135, w)
        a, b = sell(th, ra, rb, lerp(2.0, 2.6, w))
        bump = 0.0
        # ulna head on the back/outer side of the wrist
        bump += 0.004 * math.exp(-((u + 0.004) / 0.012) ** 2) * max(0.0, -sn) * max(0.0, -c) ** 0.5
        # knuckles on the back of the hand
        for k in KNUCKLE_OFFS:
            bump += 0.0045 * math.exp(-((u - PALM_LEN + 0.008) / 0.011) ** 2) * math.exp(-((a - k) / 0.008) ** 2) * max(0.0, -sn)
        # extensor tendons fanning to the knuckles
        for k in KNUCKLE_OFFS:
            ka = lerp(0.0, k, smooth01(u / PALM_LEN))
            bump += 0.0014 * math.exp(-((a - ka) / 0.0035) ** 2) * max(0.0, -sn) * smooth01(u / 0.03) * smooth01((PALM_LEN - u) / 0.02)
        # close the end
        end = smooth01((s - (L - 0.034)) / 0.034)
        a = a * lerp(1.0, 0.86, end)
        b = b * lerp(1.0, 0.72, end)
        cl = smooth01((s - (L - 0.007)) / 0.007)
        k = math.sqrt(max(0.0, 1.0 - cl * 0.8))
        return (a * k + c * bump, b * k + sn * bump)
    rings, S, fr = sweep(path, segs, off, Vector((0, -1, 0)))
    Tt, Ns, Bs = fr
    extras = []
    for i, ring in enumerate(rings):
        u = S[i] - s_wr
        ex = []
        for j in range(segs):
            th = math.pi + TAU * j / segs
            ex.append({'vein': 0.6 + 0.4 * smooth01(u / 0.05), 'knuckle': math.exp(-((u - PALM_LEN + 0.008) / 0.015) ** 2) * max(0.0, -math.sin(th)),
                       'blood': 0.3 * smooth01(u / 0.08)})
        extras.append(ex)
    P.rings(rings, S, extras, cap_start=path[0] - Tt[0] * 0.004, cap_end=path[-1] + Tt[-1] * 0.004)
    joints['hand.L'] = (WRIST, knuck)
    return P


def finger_tube(P, base, dirs_lens, radii, res, segs_base, name, joints, tip_nail=True):
    pts = [base]
    d_list = []
    for d, l in dirs_lens:
        pts.append(pts[-1] + d * l)
        d_list.append(d)
    for i in range(len(dirs_lens)):
        joints['%s%d.L' % (name, i + 1)] = (pts[i], pts[i + 1])
    jl = [0.0]
    for d, l in dirs_lens:
        jl.append(jl[-1] + l)
    Ltot = jl[-1]
    dense = chaikin(pts, 3)
    count = 16 * res + 1
    path, L = resample(dense, count, lambda t: 1 - (1 - t) ** 1.6)
    segs = segs_base * res
    T0 = d_list[0]
    B_hint = hand_frame()[2]
    up = (B_hint - T0 * B_hint.dot(T0)).normalized()

    def off(s, t, th):
        c, sn = math.cos(th), math.sin(th)
        sl = s * Ltot / L
        # buried base: start thin inside the palm so no end cap pokes through the skin
        r = lerp(radii[0], radii[1], t) * lerp(0.45, 1.0, smooth01(sl / 0.018))
        back = max(0.0, -c)
        for j in jl[1:-1]:
            # bony knuckles, thin shafts between them
            r += 0.0026 * math.exp(-((sl - j) / 0.008) ** 2) * (0.5 + 0.8 * back)
        for k in range(len(jl) - 1):
            mid = (jl[k] + jl[k + 1]) * 0.5
            r -= 0.0009 * math.exp(-((sl - mid) / ((jl[k + 1] - jl[k]) * 0.3)) ** 2)
        # round fingertip: close with a quarter circle over the last few millimetres
        rem = max(0.0, Ltot - sl)
        tip_len = radii[1] * 1.2
        if rem < tip_len:
            r *= math.sqrt(max(0.08, 1 - (1 - rem / tip_len) ** 2))
        # slightly flattened, pads on the palm side
        return (r * c * (1.0 + 0.08 * max(0.0, c)), r * sn * 0.88)
    rings, S, fr = sweep(path, segs, off, up, theta0=0.0)
    Tt, Ns, Bs = fr
    extras = []
    for i in range(len(rings)):
        t = S[i] / L
        ex = []
        for j in range(segs):
            th = TAU * j / segs
            # N here is the palm side; the nail is on the far side
            back = max(0.0, -math.cos(th))
            ex.append({'nail': smooth01((t - 0.84) / 0.05) * smooth01((back - 0.5) / 0.3) if tip_nail else 0.0,
                       'knuckle': max(math.exp(-((t * Ltot - j2) / 0.012) ** 2) for j2 in jl[1:-1]) * (0.4 + 0.6 * back),
                       'blood': 0.25 + 0.75 * smooth01((t - 0.6) / 0.35), 'vein': 0.3})
        extras.append(ex)
    P.rings(rings, S, extras, cap_start=path[0] - Tt[0] * 0.003, cap_end=path[-1] + Tt[-1] * 0.0008)


def rotate_towards(d, target, ang):
    axis = d.cross(target)
    if axis.length < 1e-6:
        return d
    return (Matrix.Rotation(ang, 3, axis.normalized()) @ d).normalized()


def build_fingers_L(res, joints):
    P = Part('fingers.L', 'skin', [])
    T, N, B = hand_frame()
    knuck = WRIST + T * PALM_LEN
    bones = []
    for i, name in enumerate(FINGER_NAMES):
        base = knuck + N * KNUCKLE_OFFS[i] * 0.95 - T * 0.020 - B * 0.001
        d = (T + N * (KNUCKLE_OFFS[i] * 0.8)).normalized()
        L = FINGER_LEN[i]
        seg = []
        for k, frac in enumerate((0.44, 0.31, 0.25)):
            d = rotate_towards(d, B, FINGER_CURL[i][k])
            seg.append((d, L * frac))
        r0 = [0.0086, 0.0090, 0.0085, 0.0074][i]
        finger_tube(P, base, seg, (r0, r0 * 0.74), res, 7, name, joints)
        bones += ['%s%d.L' % (name, k + 1) for k in range(3)]
    # thumb: from the heel of the palm, along the index finger
    base = WRIST + T * 0.030 + N * 0.020 + B * 0.003
    d = (T * 0.90 + N * 0.10 + B * 0.42).normalized()
    seg = []
    for k, (l, c) in enumerate(((0.052, 0.10), (0.038, 0.14), (0.030, 0.18))):
        d = rotate_towards(d, B, c)
        seg.append((d, l))
    finger_tube(P, base, seg, (0.0145, 0.0080), res, 7, 'thumb', joints)
    bones += ['thumb1.L', 'thumb2.L', 'thumb3.L', 'hand.L']
    P.bones = bones
    return P


# ---------------------------------------------------------------- legs and shoes
def build_leg_L(res):
    P = Part('leg.L', 'cloth', ['thigh.L', 'shin.L', 'foot.L'])
    P.const = {'stocking': 1.0}
    P.attr_fn = lambda p: {'blood': 0.35 * smooth01((0.3 - p.z) / 0.2)}
    ctrl = chaikin([KNEE + Vector((0, 0, 0.16)), KNEE, ANKLE + Vector((0, 0, 0.0)), ANKLE + Vector((0, -0.01, -0.05))], 2)
    path, L = resample(ctrl, 14 * res + 1)
    segs = 12 * res

    def off(s, t, th):
        c, sn = math.cos(th), math.sin(th)
        z = KNEE.z + 0.16 - s
        r = 0.045
        r += 0.010 * math.exp(-((z - 0.44) / 0.09) ** 2) * max(0.0, -c) ** 0.7  # calf, at the back
        r = lerp(r, 0.024, smooth01((0.30 - z) / 0.17))
        r += 0.004 * math.exp(-((z - 0.10) / 0.02) ** 2) * abs(sn)   # ankle bones
        r += 0.006 * math.exp(-((z - KNEE.z) / 0.035) ** 2) * max(0.0, c)  # kneecap
        return (r * c, r * 0.92 * sn)
    rings, S, fr = sweep(path, segs, off, Vector((0, -1, 0)))
    P.rings(rings, S, cap_start=path[0] + Vector((0, 0, 0.005)), cap_end=path[-1] - Vector((0, 0, 0.005)))
    return P


def build_shoe_L(res):
    P = Part('shoe.L', 'cloth', ['foot.L', 'toe.L'])
    P.const = {'shoe': 1.0}
    x0 = ANKLE.x + 0.004
    heel_y, toe_y = 0.070, -0.175
    n = 18 * res + 1
    segs = 12 * res

    def prof(y):
        t = (heel_y - y) / (heel_y - toe_y)      # 0 heel .. 1 toe
        w = 0.029 + 0.012 * math.sin(min(1.0, t * 1.25) * math.pi * 0.62)
        w *= lerp(1.0, 0.8, smooth01((t - 0.80) / 0.20))
        top = lerp(0.120, 0.070, smooth01((t - 0.18) / 0.35))
        top = lerp(top, 0.045, smooth01((t - 0.70) / 0.30))
        heel = 0.028 * (1 - smooth01((t - 0.28) / 0.08))
        bot = 0.0 if t < 0.36 else lerp(0.012, 0.004, smooth01((t - 0.36) / 0.1))
        return w, top, bot, t
    rings = []
    ys = []
    for i in range(n):
        tt = i / (n - 1)
        tt = 0.5 - 0.5 * math.cos(tt * math.pi)
        y = lerp(heel_y, toe_y, tt)
        ys.append(y)
        w, top, bot, t = prof(y)
        ring = []
        zc = (top + bot) * 0.5
        hh = (top - bot) * 0.5
        endk = math.sqrt(max(0.0, 1 - max(smooth01((0.03 - t) / 0.03), smooth01((t - 0.965) / 0.035)) * 0.9))
        for j in range(segs):
            th = math.pi * 0.5 + TAU * j / segs
            c, s = math.cos(th), math.sin(th)
            e = 2.0 / 3.2
            xx = w * endk * math.copysign(abs(c) ** e, c)
            zz = zc + hh * endk * math.copysign(abs(s) ** (2.0 / (2.4 if s > 0 else 5.0)), s)
            ring.append(Vector((x0 + xx, y, zz)))
        rings.append(ring)
    extras = [[{'sole': 1.0 if p.z < 0.03 * (1 - smooth01((heel_y - p.y) / 0.1)) + 0.012 else 0.0} for p in r] for r in rings]
    P.rings(rings, [heel_y - y for y in ys], extras,
            cap_start=Vector((x0, heel_y + 0.004, (prof(heel_y)[1] + prof(heel_y)[2]) * 0.5)),
            cap_end=Vector((x0, toe_y - 0.003, (prof(toe_y)[1] + prof(toe_y)[2]) * 0.5)))
    return P


# ---------------------------------------------------------------- head
HEAD_FEATS = [
    # centre (head-local), sigma, amplitude
    ((0.029, -0.088, 0.016), (0.019, 0.035, 0.016), -0.030, 'sock'),
    ((-0.029, -0.088, 0.016), (0.019, 0.035, 0.016), -0.030, 'sock'),
    ((0.033, -0.093, 0.045), (0.022, 0.03, 0.007), 0.005, ''),
    ((-0.033, -0.093, 0.045), (0.022, 0.03, 0.007), 0.005, ''),
    ((0.0, -0.100, 0.028), (0.008, 0.03, 0.010), -0.002, ''),
    ((0.0, -0.098, -0.012), (0.009, 0.04, 0.028), 0.010, ''),
    ((0.0, -0.100, -0.036), (0.012, 0.04, 0.012), 0.004, ''),
    ((0.052, -0.070, 0.000), (0.018, 0.03, 0.012), 0.005, ''),
    ((-0.052, -0.070, 0.000), (0.018, 0.03, 0.012), 0.005, ''),
    ((0.050, -0.066, -0.046), (0.020, 0.03, 0.025), -0.012, ''),
    ((-0.050, -0.066, -0.046), (0.020, 0.03, 0.025), -0.012, ''),
    ((0.068, -0.030, 0.035), (0.015, 0.025, 0.020), -0.008, ''),
    ((-0.068, -0.030, 0.035), (0.015, 0.025, 0.020), -0.008, ''),
    ((0.0, -0.085, -0.108), (0.020, 0.03, 0.020), 0.002, ''),
    ((0.074, 0.004, 0.000), (0.006, 0.016, 0.026), 0.011, ''),
    ((-0.074, 0.004, 0.000), (0.006, 0.016, 0.026), 0.011, ''),
]


def head_point(th, phi, positive_only=False, lift=0.0):
    """th: 0 = front (-Y), +pi/2 = left (+X). phi: -pi/2 bottom .. +pi/2 top. Returns (world point, socket weight)."""
    sphi, cphi = math.sin(phi), math.cos(phi)
    z = (0.135 if sphi > 0 else 0.138) * sphi
    rx = 0.069 * (1 - 0.20 * smooth01(-z / 0.12))
    front = (1 + math.cos(th)) * 0.5
    ry_b = 0.104 * (1 - 0.30 * smooth01((-z - 0.03) / 0.09))
    ry = lerp(ry_b, 0.094, front)
    p = Vector((rx * math.sin(th) * cphi, -ry * math.cos(th) * cphi, z))
    n = p.normalized() if p.length > 1e-6 else Vector((0, 0, 1))
    disp = 0.0
    sock = 0.0
    for c, s, amp, tag in HEAD_FEATS:
        if positive_only and amp < 0:
            continue
        g = gauss3(p, c, s)
        disp += amp * g
        if tag == 'sock':
            sock += g
    p = p + n * (disp + lift)
    return HEAD_C + p, sock


def phi_rows(count):
    """Latitudes with more rows across the face band."""
    out = []
    for k in range(count):
        u = k / (count - 1)
        # warp: dense around phi in [-0.45, 0.45]
        x = (u - 0.5) * 2
        w = x * (0.55 + 0.45 * x * x)
        out.append(w * math.pi * 0.5 * 0.985)
    return out


def build_head(res):
    P = Part('head', 'skin', ['head'], uv_boost=1.35)
    segs = 40 * res
    phis = phi_rows(30 * res + 1)
    rings, extras = [], []
    for phi in phis:
        ring, ex = [], []
        for j in range(segs):
            th = math.pi + TAU * j / segs
            th = th - 0.45 * math.sin(th)          # more columns across the face
            p, sock = head_point(th, phi)
            ring.append(p)
            rel = p - HEAD_C
            ex.append({'sock': min(1.0, sock), 'vein': 0.5 * smooth01((rel.z - 0.03) / 0.05) + 0.3})
        rings.append(ring)
        extras.append(ex)
    P.rings(rings, [phi * 0.12 for phi in phis], extras,
            cap_start=HEAD_C + Vector((0, 0.004, -0.141)), cap_end=HEAD_C + Vector((0, 0.0, 0.137)))
    # deep, wet little eyes at the bottom of the sockets
    for sx in (1, -1):
        c = HEAD_C + Vector((sx * 0.028, -0.055, 0.014))
        er = []
        es = 8 * res
        for k in range(1, 7 * res):
            a = math.pi * k / (7 * res) - math.pi * 0.5
            er.append([c + Vector((0.0065 * math.cos(a) * math.sin(TAU * j / es), -0.0065 * math.cos(a) * math.cos(TAU * j / es), 0.0055 * math.sin(a))) for j in range(es)])
        ex = [[{'eye': 1.0, 'sock': 1.0} for _ in r] for r in er]
        P.rings(er, None, ex, cap_start=c + Vector((0, 0, -0.0055)), cap_end=c + Vector((0, 0, 0.0055)))
    return P


def hairline(th):
    k = (1 + math.cos(th)) * 0.5   # 1 front, 0 back
    return lerp(-0.07, 0.07, k ** 0.6)


def build_hair(res):
    P = Part('hair', 'skin', ['head'], uv_boost=1.2)
    P.const = {'hair': 1.0}
    segs = 40 * res
    rows = 12 * res
    rings = []
    th_of = [math.pi + TAU * j / segs for j in range(segs)]
    # tuck ring under the hairline, then rows up to the crown
    def phi_for(z):
        return math.asin(max(-1.0, min(1.0, z / (0.135 if z > 0 else 0.138))))
    rings.append([head_point(th, phi_for(hairline(th) - 0.004), False, -0.002)[0] for th in th_of])
    for r in range(rows):
        v = r / (rows - 1)
        ring = []
        for th in th_of:
            z0 = hairline(th)
            phi0 = phi_for(z0)
            phi = lerp(phi0, math.pi * 0.5 * 0.94, v ** 0.9)
            lift = 0.0025 + 0.0015 * smooth01(v * 3)
            ring.append(head_point(th, phi, True, lift)[0])
        rings.append(ring)
    P.rings(rings, None, None, cap_end=HEAD_C + Vector((0, 0.0, 0.1415)))
    # bun
    c = HEAD_C + Vector((0.0, 0.104, -0.005))
    er = []
    es = 16 * res
    nr = 10 * res
    for k in range(1, nr):
        a = math.pi * k / nr - math.pi * 0.5
        ring = []
        for j in range(es):
            t = TAU * j / es
            wob = 1 + 0.08 * math.sin(t * 5 + a * 3)
            ring.append(c + Vector((0.034 * math.cos(a) * math.sin(t) * wob, 0.026 * (math.sin(a) + 0.0), 0.030 * math.cos(a) * math.cos(t) * wob)))
        er.append(ring)
    # rings along Y: orient so the pole axis is Y (front pole buried in the skull)
    P.rings(er, None, None, cap_start=c + Vector((0, -0.026, 0)), cap_end=c + Vector((0, 0.026, 0)))
    # loose greasy strands escaping the bun, hanging over one eye and onto the mask
    strands = [(-0.42, 0.95, -0.085, 0.0040), (-0.33, 0.80, -0.070, 0.0032), (-0.52, 1.00, -0.050, 0.0030),
               (-0.24, 0.62, -0.030, 0.0026), (-0.60, 1.05, -0.100, 0.0034), (0.36, 0.70, -0.045, 0.0028),
               (0.46, 0.85, -0.020, 0.0024)]
    for k, (th0, th1, zend, w) in enumerate(strands):
        count = 12 * res + 1
        rows, nrs = [], []
        pts = []
        for i in range(count):
            t = i / (count - 1)
            th = lerp(th0, th0 * th1, t) + 0.05 * math.sin(t * 5.0 + k)
            z = lerp(hairline(th0) - 0.002, zend, t)
            phi = math.asin(max(-1.0, min(1.0, z / (0.135 if z > 0 else 0.138))))
            lift = lerp(0.0028, 0.0105, smooth01((0.01 - z) / 0.03)) + 0.002 * t
            pts.append(head_point(th, phi, True, lift)[0])
        for i, p in enumerate(pts):
            t = i / (count - 1)
            tan = (pts[min(i + 1, count - 1)] - pts[max(i - 1, 0)]).normalized()
            n = (p - HEAD_C).normalized()
            side = tan.cross(n).normalized()
            half = w * lerp(1.0, 0.35, t) * 0.5
            rows.append([p - side * half, p + side * half])
            nrs.append([n, n])
        old = P.const
        P.const = {'hair': 1.0}
        P.slab(rows, nrs, 0.0010)
        P.const = old
    return P


def build_neck(res):
    P = Part('neck', 'skin', ['upperchest', 'neck', 'head'])
    P.const = {'vein': 1.0}
    ctrl = [NECK_BASE + Vector((0, 0, -0.03)), NECK_BASE + Vector((0, -0.004, 0.08)), HEAD_C + Vector((0, 0.03, -0.08))]
    path, L = resample(chaikin(ctrl, 2), 12 * res + 1)
    segs = 18 * res

    def off(s, t, th):
        c, sn = math.cos(th), math.sin(th)
        r = lerp(0.036, 0.030, smooth01(t * 1.5))
        # sternocleidomastoid cords, trachea
        cord = math.exp(-((abs(math.atan2(sn, c)) - 0.75 + 0.35 * t) / 0.22) ** 2)
        r += 0.0035 * cord + 0.0022 * math.exp(-(math.atan2(sn, c) / 0.25) ** 2) * math.exp(-((t - 0.45) / 0.2) ** 2)
        return (r * c, r * sn)
    rings, S, fr = sweep(path, segs, off, Vector((0, -1, 0)))
    P.rings(rings, S)
    return P


def build_mask(res):
    P = Part('mask', 'cloth', ['head'], uv_boost=2.2)
    P.const = {'mask': 1.0}
    rows, cols = 12 * res + 1, 20 * res + 1
    Pts, Nr, ex = [], [], []
    th_max = 1.42
    mouth = HEAD_C + Vector((0.004, -0.108, -0.068))
    for r in range(rows):
        v = r / (rows - 1)
        row, nrow, erow = [], [], []
        for c in range(cols):
            u = c / (cols - 1)
            th = lerp(-th_max, th_max, u)
            centre = math.exp(-(th / 0.5) ** 2)
            ztop = -0.004 + 0.006 * centre
            zbot = -0.128 + 0.010 * (1 - centre)
            z = lerp(ztop, zbot, v)
            phi = math.asin(max(-1.0, min(1.0, z / (0.135 if z > 0 else 0.138))))
            # pleats bulge across the middle
            pleat = 0.0042 * abs(math.sin(v * math.pi * 3.0)) ** 0.6 * smooth01(1 - abs(th) / 1.3)
            lift = 0.0030 + pleat + 0.006 * smooth01((v - 0.75) / 0.25) * centre  # pulled taut under the chin
            p, _ = head_point(th, phi, True, lift)
            # stretch flat across the hollow between cheekbone and nose
            flat = HEAD_C + (p - HEAD_C) * 1.0
            row.append(flat)
            n = (p - HEAD_C)
            n.z *= 0.3
            nrow.append(n.normalized())
            d = (flat - mouth).length
            mo = math.exp(-(d / 0.024) ** 2) + 0.35 * math.exp(-(((flat.x - mouth.x) / 0.02) ** 2 + ((flat.z - (mouth.z - 0.03)) / 0.04) ** 2))
            erow.append({'mouth': min(1.0, mo), 'crease': 0.4 + 0.6 * abs(math.sin(v * math.pi * 3))})
        Pts.append(row)
        Nr.append(nrow)
        ex.append(erow)
    P.slab(Pts, Nr, 0.0018, ex)
    # ties round the back of the head
    for sx in (1, -1):
        for z0, z1 in ((-0.006, 0.03), (-0.118, -0.065)):
            ctrl = []
            for k in range(9):
                t = k / 8
                th = sx * lerp(th_max - 0.02, math.pi * 0.98, t)
                z = lerp(z0, z1, smooth01(t))
                phi = math.asin(max(-1.0, min(1.0, z / (0.135 if z > 0 else 0.138))))
                ctrl.append(head_point(th, phi, True, 0.004 if abs(th) < 2.2 else 0.0075)[0])
            path, _ = resample(chaikin(ctrl, 2), 10 * res + 1)
            rws, nrs = [], []
            for i, p in enumerate(path):
                t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
                n = (p - HEAD_C).normalized()
                side = t.cross(n).normalized()
                rws.append([p - side * 0.003, p + side * 0.003])
                nrs.append([n, n])
            P2 = P
            old = P2.const
            P2.const = {'mask': 1.0, 'tie': 1.0}
            P2.slab(rws, nrs, 0.0015)
            P2.const = old
    return P


def build_cap(res):
    P = Part('cap', 'cloth', ['head'], uv_boost=1.6)
    P.const = {'cap': 1.0}
    tilt = Matrix.Rotation(-0.72, 3, 'X')
    base_c = HEAD_C + Vector((0.0, 0.020, 0.098))
    segs = 36 * res
    rings = []
    # band (a slanted, slightly flaring cylinder), then a folded, peaked top
    prof = [(-0.004, 0.066, 0.084, 0.0), (0.0, 0.070, 0.088, 0.0), (0.018, 0.080, 0.096, 0.0), (0.034, 0.096, 0.106, 0.0),
            (0.040, 0.092, 0.100, 0.0), (0.044, 0.062, 0.070, 0.003), (0.047, 0.030, 0.034, 0.005)]
    hs = [q[0] for q in prof]
    fx = pchip(hs, [q[1] for q in prof])
    fy = pchip(hs, [q[2] for q in prof])
    fp = pchip(hs, [q[3] for q in prof])
    for h in densify(hs, res):
        ring = []
        for j in range(segs):
            th = math.pi + TAU * j / segs
            c, s = math.cos(th), math.sin(th)
            # front cuff folded back: a sharp crease line around the band
            crease = 0.004 * math.exp(-((h - 0.022) / 0.004) ** 2) * max(0.0, c)
            peak = fp(h) * max(0.0, -c) * 2.0
            local = Vector((fx(h) * s + crease * s, -fy(h) * c - crease * c, h + peak + 0.006 * math.sin(th * 2 + 1)))
            ring.append(base_c + tilt @ local)
        rings.append(ring)
    P.rings(rings, None, None, cap_end=base_c + tilt @ Vector((0, 0.01, 0.050)))
    # the fold-over flap at the back
    rows, cols = 5 * res + 1, 10 * res + 1
    Pts, Nr = [], []
    for r in range(rows):
        v = r / (rows - 1)
        row, nrow = [], []
        for c in range(cols):
            u = c / (cols - 1)
            th = lerp(2.25, 4.03, u)
            h = lerp(0.038, 0.010, v)
            out = 0.004 + 0.010 * v
            local = Vector(((fx(h) + out) * math.sin(th), -(fy(h) + out) * math.cos(th), h + 0.003 * math.sin(u * math.pi)))
            row.append(base_c + tilt @ local)
            nrow.append((tilt @ Vector((math.sin(th), -math.cos(th), 0.25))).normalized())
        Pts.append(row)
        Nr.append(nrow)
    P.slab(Pts, Nr, 0.002)
    return P


# ---------------------------------------------------------------- all
def build_all(res=1):
    joints = {}
    parts = [build_dress(res), build_apron(res), build_straps(res), build_belt(res), build_neck(res),
             build_head(res), build_hair(res), build_mask(res), build_cap(res)]
    left = [build_sleeve_L(res), build_forearm_L(res, joints), build_fingers_L(res, joints), build_leg_L(res), build_shoe_L(res)]
    for p in left:
        parts.append(p)
        parts.append(p.mirrored(p.name[:-2] + '.R'))
    return parts, joints
