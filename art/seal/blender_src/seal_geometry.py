"""Seal patient procedural geometry (pure Python + mathutils, no bpy).

Everything here is in the PATIENT FRAME the game uses (scripts/patient_body.gd):
x runs nose (-X) to tail (+X), y is up with the table top at y = 0, and +Z is the seal's LEFT
(it lies on its belly facing -X). seal_build.py converts to Blender axes (x, -z, y) when it makes
the objects, and the glTF exporter's +Y-up conversion turns that back into this frame exactly.

Every part is generated from analytic shape functions at a resolution multiplier `res`:
res=1 is the game mesh, res=3 (plus one subdivision) is the dense copy the maps are baked from.
"""
import math
from mathutils import Vector, noise

TAU = math.tau
# Everything below is authored at a 1.0 scale; the built model (mesh, bones, sites, sections) is this
# much bigger, so the seal matches the size of the procedural one on the table. Material coordinates
# (the `pco` attribute) stay unscaled so the procedural patterns keep their authored sizes.
SCALE = 1.08

# per-vertex float masks used by the procedural materials (never exported)
ATTRS = ['belly', 'saddle', 'muzzle', 'nose', 'nostril', 'mouth', 'eyerim', 'whpad', 'ear', 'fold',
         'flip', 'hind', 'palm', 'knuck', 'inj', 'gun', 'inf', 'eye', 'whisker', 'claw', 'cap',
         'cap_d', 'cap_u', 'cap_v', 'line', 'eyez', 'sclera', 'lid', 'shoulder', 'groove', 'ths', 'thc']

# ---------------------------------------------------------------- surgery constants (metres along the left fore flipper axis)
LIMB_S = 0.115          # tourniquet site (`limb`)
CUT_S = 0.185           # amputation line (`limb_cut`): a single edge loop, the stub / paddle boundary
INFECT_S = 0.205        # infection mask starts (0) ...
INFECT_FULL_S = 0.245   # ... and is fully on (1)
TIP_S = 0.352           # nominal end of the paddle (UV2.v = 1)
BAND_HALF = 0.0225      # support loops either side of LIMB_S for the tourniquet band

# fore flipper frame (left side; the right one is the mirror z -> -z)
FL_PIVOT = Vector((-0.262, 0.098, 0.236))
FL_DIR = Vector((0.855, -0.110, 0.507)).normalized()

# site centres on the body
INJ_X = -0.43           # back of the neck, dorsal midline
GUN_X = 0.03            # right flank
GUN_THETA = -0.62       # radians from the top toward the right (-Z) side
HEAD_X = -0.60          # head / torso UV split


def smooth01(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def lerp(a, b, t):
    return a + (b - a) * t


def sgnpow(v, e):
    return math.copysign(abs(v) ** e, v)


def gauss(p, c, s):
    return math.exp(-(((p.x - c[0]) / s[0]) ** 2 + ((p.y - c[1]) / s[1]) ** 2 + ((p.z - c[2]) / s[2]) ** 2))


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-12)))
    return (p - (a + ab * t)).length, t


def poly_dist(p, pts):
    best = 1e9
    for i in range(len(pts) - 1):
        d, _ = seg_dist(p, pts[i], pts[i + 1])
        best = min(best, d)
    return best


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
            return ys[0] + m[0] * (x - xs[0]) * 0.0
        if x >= xs[-1]:
            return ys[-1]
        i = 0
        while xs[i + 1] < x:
            i += 1
        t = (x - xs[i]) / h[i]
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h[i] * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h[i] * m[i + 1])
    return f


def densify(vals, res):
    if res <= 1:
        return list(vals)
    out = []
    for i in range(len(vals) - 1):
        for k in range(res):
            out.append(lerp(vals[i], vals[i + 1], k / res))
    out.append(vals[-1])
    return out


def warp_table(weight_fn, count, start, span=TAU, samples=2048):
    """count angles from start over span, spaced so their density follows weight_fn(angle)."""
    acc = [0.0]
    for k in range(samples):
        a = start + span * (k + 0.5) / samples
        acc.append(acc[-1] + weight_fn(a))
    total = acc[-1]
    out = []
    i = 0
    for j in range(count):
        target = total * j / count
        while acc[i + 1] < target:
            i += 1
        f = (target - acc[i]) / max(acc[i + 1] - acc[i], 1e-12)
        out.append(start + span * (i + f) / samples)
    return out


# ---------------------------------------------------------------- mesh container
class VData:
    """What a vertex carries besides its position."""
    __slots__ = ('attr', 'col', 'w', 'F')

    def __init__(self, attr=None, col=(0.0, 0.0, 0.0, 0.0), w=None, F=None):
        self.attr = attr or {}
        self.col = col
        self.w = w or {}
        self.F = F


class Part:
    def __init__(self, name, mat, uv_boost=1.0):
        self.name, self.mat, self.uv_boost = name, mat, uv_boost
        self.v, self.vd = [], []
        self.f, self.fuv, self.fuv2, self.ftag = [], [], [], []
        self.uv_off = 0.0

    def add_v(self, p, vd):
        self.v.append(Vector(p))
        if vd.F is None:
            vd.F = Vector(p)
        self.vd.append(vd)
        return len(self.v) - 1

    def face(self, idx, uvs, uv2=None, tag=0):
        self.f.append(tuple(idx))
        self.fuv.append([tuple(u) for u in uvs])
        self.fuv2.append([tuple(u) for u in uv2] if uv2 else [(0.0, 0.0)] * len(idx))
        self.ftag.append(tag)

    def next_uv_block(self, width):
        o = self.uv_off
        self.uv_off += width + 0.04
        return o

    def rings(self, rings, vdata, vcoords=None, cap_start=None, cap_end=None, closed_path=False,
              v2=None, tags=None, outward=None):
        """rings: list of equal-length closed point loops. vdata: matching VData.
        cap_start / cap_end: (point, VData) poles. v2: per-ring UV2.v or None. tags: per-quad-row tag.
        outward: callable(ring_index) -> reference centre used to fix the winding."""
        n = len(rings[0])
        nr = len(rings)
        if vcoords is None:
            vcoords = [0.0]
            for i in range(1, nr):
                c0 = sum(rings[i - 1], Vector()) / n
                c1 = sum(rings[i], Vector()) / n
                vcoords.append(vcoords[-1] + max((c1 - c0).length, 0.0015))
            if closed_path:
                c0 = sum(rings[-1], Vector()) / n
                c1 = sum(rings[0], Vector()) / n
                vcoords.append(vcoords[-1] + (c1 - c0).length)
        circ = sum(sum((r[(j + 1) % n] - r[j]).length for j in range(n)) for r in rings) / nr
        u0 = self.next_uv_block(circ)
        first_face = len(self.f)
        ids = [[self.add_v(p, vdata[i][j]) for j, p in enumerate(r)] for i, r in enumerate(rings)]
        rows = nr if closed_path else nr - 1
        for i in range(rows):
            i2 = (i + 1) % nr
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                uv2 = None
                if v2 is not None and v2[i] is not None and v2[i2] is not None:
                    uv2 = [(j / n, v2[i]), ((j + 1) / n, v2[i]), ((j + 1) / n, v2[i2]), (j / n, v2[i2])]
                self.face((ids[i][j], ids[i][j2], ids[i2][j2], ids[i2][j]),
                          [(ua, vcoords[i]), (ub, vcoords[i]), (ub, vcoords[i + 1]), (ua, vcoords[i + 1])],
                          uv2, tags[i] if tags else 0)
        if cap_start is not None:
            pole = self.add_v(cap_start[0], cap_start[1])
            vp = vcoords[0] - (cap_start[0] - sum(rings[0], Vector()) / n).length
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                self.face((pole, ids[0][j2], ids[0][j]), [((ua + ub) / 2, vp), (ub, vcoords[0]), (ua, vcoords[0])],
                          None, tags[0] if tags else 0)
        if cap_end is not None:
            pole = self.add_v(cap_end[0], cap_end[1])
            vp = vcoords[-1] + (cap_end[0] - sum(rings[-1], Vector()) / n).length
            uv2 = None
            for j in range(n):
                j2 = (j + 1) % n
                ua, ub = u0 + circ * j / n, u0 + circ * (j + 1) / n
                if v2 is not None and v2[-1] is not None:
                    uv2 = [(j / n, v2[-1]), ((j + 1) / n, v2[-1]), ((j + 0.5) / n, 1.0)]
                self.face((ids[-1][j], ids[-1][j2], pole), [(ua, vcoords[-1]), (ub, vcoords[-1]), ((ua + ub) / 2, vp)],
                          uv2, tags[-1] if tags else 0)
        # winding: make the first quad face away from its ring centre
        fa = self.f[first_face]
        pa, pb, pc = self.v[fa[0]], self.v[fa[1]], self.v[fa[2]]
        nrm = (pb - pa).cross(pc - pa)
        ctr = outward(0) if outward else sum(rings[0], Vector()) / n * 0.5 + sum(rings[1 % nr], Vector()) / n * 0.5
        if nrm.dot(pa - ctr) < 0:
            self.flip_faces(first_face)
        return ids

    def flip_faces(self, start=0):
        for k in range(start, len(self.f)):
            self.f[k] = tuple(reversed(self.f[k]))
            self.fuv[k] = list(reversed(self.fuv[k]))
            self.fuv2[k] = list(reversed(self.fuv2[k]))

    def tris(self):
        return sum(len(f) - 2 for f in self.f)

    def mirrored_z(self, name):
        m = Part(name, self.mat, self.uv_boost)
        m.v = [Vector((p.x, p.y, -p.z)) for p in self.v]
        for vd in self.vd:
            attr = dict(vd.attr)
            attr['inf'] = 0.0
            col = (0.0, vd.col[1], vd.col[2], vd.col[3])
            w = {mirror_bone(k): x for k, x in vd.w.items()}
            F = Vector((vd.F.x, vd.F.y, -vd.F.z))
            m.vd.append(VData(attr, col, w, F))
        m.f = [tuple(reversed(f)) for f in self.f]
        m.fuv = [list(reversed(u)) for u in self.fuv]
        m.fuv2 = [[(0.0, 0.0)] * len(f) for f in self.f]
        m.ftag = [0] * len(self.f)
        return m


def mirror_bone(b):
    if b.endswith('.L'):
        return b[:-2] + '.R'
    if b.endswith('.R'):
        return b[:-2] + '.L'
    return b


# ---------------------------------------------------------------- body sections
BODY_KEYS = [  # x, half-width (z), half-height above centre, below centre, centre height, n top, n bottom
    (-0.905, 0.018, 0.017, 0.017, 0.112, 2.0, 2.0),
    (-0.893, 0.035, 0.032, 0.033, 0.110, 2.0, 2.0),
    (-0.872, 0.050, 0.044, 0.046, 0.108, 2.0, 2.05),
    (-0.842, 0.066, 0.051, 0.056, 0.108, 2.0, 2.2),
    (-0.805, 0.074, 0.060, 0.064, 0.111, 2.0, 2.2),
    (-0.772, 0.079, 0.076, 0.071, 0.117, 2.0, 2.1),
    (-0.735, 0.097, 0.096, 0.081, 0.123, 2.0, 2.15),
    (-0.690, 0.109, 0.110, 0.093, 0.129, 2.0, 2.2),
    (-0.640, 0.117, 0.114, 0.107, 0.134, 2.05, 2.3),
    (-0.580, 0.128, 0.118, 0.125, 0.140, 2.1, 2.4),
    (-0.500, 0.154, 0.130, 0.140, 0.146, 2.1, 2.6),
    (-0.410, 0.189, 0.148, 0.150, 0.152, 2.1, 2.8),
    (-0.310, 0.226, 0.163, 0.157, 0.158, 2.1, 3.0),
    (-0.190, 0.253, 0.174, 0.162, 0.162, 2.1, 3.1),
    (-0.050, 0.265, 0.177, 0.165, 0.162, 2.1, 3.1),
    (0.090, 0.259, 0.170, 0.160, 0.157, 2.1, 3.1),
    (0.210, 0.236, 0.151, 0.145, 0.144, 2.1, 3.0),
    (0.310, 0.196, 0.125, 0.121, 0.125, 2.1, 2.8),
    (0.395, 0.142, 0.094, 0.090, 0.101, 2.1, 2.5),
    (0.465, 0.094, 0.064, 0.060, 0.082, 2.05, 2.3),
    (0.515, 0.060, 0.044, 0.040, 0.070, 2.0, 2.2),
    (0.555, 0.034, 0.026, 0.022, 0.064, 2.0, 2.0),
    (0.582, 0.013, 0.011, 0.009, 0.062, 2.0, 2.0),
]
_bx = [k[0] for k in BODY_KEYS]
B_W, B_HU, B_HL, B_C, B_NT, B_NB = (pchip(_bx, [k[i] for k in BODY_KEYS]) for i in range(1, 7))
NOSE_TIP = Vector((-0.909, 0.112, 0.0))
TAIL_TIP = Vector((0.590, 0.062, 0.0))


def base_point(x, th):
    """Undisplaced body surface. th: 0 = top (+Y), +pi/2 = seal's left (+Z)."""
    c, s = math.cos(th), math.sin(th)
    w = B_W(x)
    if c >= 0:
        e = 2.0 / B_NT(x)
        y = B_C(x) + B_HU(x) * sgnpow(c, e)
        z = w * sgnpow(s, e)
    else:
        e = 2.0 / B_NB(x)
        y = B_C(x) + B_HL(x) * sgnpow(c, e)
        z = w * sgnpow(s, e)
        # blubber sags: the widest line sits low on the flanks, only on the torso
        ta = abs(math.atan2(s, c))
        sag = 0.055 * smooth01((x + 0.52) / 0.2) * smooth01((0.45 - x) / 0.15)
        z *= 1.0 + sag * math.exp(-((ta - 2.05) / 0.42) ** 2) * smooth01((ta - 1.5708) / 0.35)
    # the belly flattens where it presses on the table
    if y < 0.014:
        y = 0.014 - (0.014 - y) * 0.35
    return Vector((x, y, z))


def base_normal(x, th):
    dx, dt = 0.002, 0.004
    tx = base_point(min(x + dx, 0.58), th) - base_point(max(x - dx, -0.9), th)
    tt = base_point(x, th + dt) - base_point(x, th - dt)
    n = tt.cross(tx)
    p = base_point(x, th)
    ctr = Vector((x, B_C(x), 0.0))
    if n.dot(p - ctr) < 0:
        n = -n
    return n.normalized()


def theta_from_top(th):
    a = math.fmod(th, TAU)
    if a < 0:
        a += TAU
    return min(a, TAU - a)


# ---------------------------------------------------------------- head landmarks (left side, mirrored by |z|)
EYE_R = 0.0262
EK = EYE_R / 0.0232        # socket and lid sizes follow the globe


def _eye_frame():
    x, th = -0.772, 0.93
    p = base_point(x, th)
    n = base_normal(x, th)
    centre = p - n * 0.0135
    gaze = (n + Vector((-0.85, 0.05, 0.0))).normalized()
    return centre, gaze


EYE_C, EYE_GAZE = _eye_frame()
NOSTRIL_A = Vector((-0.9055, 0.121, 0.0040))
NOSTRIL_B = Vector((-0.8925, 0.137, 0.0190))
MOUTH = [Vector((-0.893, 0.086, 0.0)), Vector((-0.884, 0.083, 0.017)), Vector((-0.866, 0.082, 0.032)),
         Vector((-0.842, 0.085, 0.045)), Vector((-0.818, 0.090, 0.053)), Vector((-0.800, 0.095, 0.056))]
EAR = base_point(-0.662, 0.98)
WHISKER_PAD = Vector((-0.856, 0.094, 0.036))


def head_features(p):
    """Displacement (m, along the normal) and masks for a point on the undisplaced head/torso."""
    q = Vector((p.x, p.y, abs(p.z)))
    a = {}
    d = 0.0
    # eye: the globe sits in a recess ringed by heavy, drooping lids
    de = (q - EYE_C).length
    rel = q - EYE_C
    upper = smooth01((rel.y + 0.004) / 0.012)
    d -= 0.016 * EK * smooth01(1.0 - de / (0.0235 * EK))
    lid_r = (0.0245 + 0.002 * upper) * EK
    lid = math.exp(-((de - lid_r) / 0.0055) ** 2)
    d += lid * (0.0032 + 0.0038 * upper)
    a['lid'] = lid
    a['eyerim'] = math.exp(-((de - 0.0235 * EK) / 0.0042) ** 2)
    # soft brow pad, inner end raised (a worried look), and the cheek under the eye
    brow_c = EYE_C + Vector((-0.004, 0.024, -0.010))
    d += 0.0045 * gauss(q, brow_c, (0.020, 0.010, 0.016))
    d += 0.005 * gauss(q, EYE_C + Vector((0.006, -0.036, 0.012)), (0.03, 0.02, 0.02))
    # forehead melon and the stop down to the muzzle
    d += 0.005 * gauss(q, (-0.735, 0.225, 0.0), (0.05, 0.03, 0.05))
    d -= 0.004 * gauss(q, (-0.800, 0.170, 0.0), (0.02, 0.03, 0.035))
    # whisker pads: fat, puffy, left and right of a philtrum groove
    wp = gauss(q, WHISKER_PAD, (0.030, 0.028, 0.024))
    d += 0.022 * wp
    a['whpad'] = min(1.0, wp * 1.4)
    d -= 0.0045 * gauss(q, (-0.878, 0.098, 0.0), (0.03, 0.016, 0.006))
    # rhinarium and the V of the nostrils
    a['nose'] = gauss(q, (-0.900, 0.128, 0.0), (0.016, 0.018, 0.026))
    d += 0.0025 * a['nose']
    nd, nt = seg_dist(q, NOSTRIL_A, NOSTRIL_B)
    nos = math.exp(-(nd / 0.0036) ** 2) * (0.35 + 0.65 * math.sin(min(1.0, nt * 1.15) * math.pi * 0.5 + 0.35))
    d -= 0.0075 * nos
    a['nostril'] = min(1.0, nos * 1.3)
    # mouth line, chin
    md = poly_dist(q, MOUTH)
    mo = math.exp(-(md / 0.0035) ** 2) * smooth01((q.x + 0.785) / -0.02)
    d -= 0.0045 * mo
    a['mouth'] = mo
    d += 0.004 * gauss(q, (-0.868, 0.062, 0.0), (0.028, 0.012, 0.032))
    a['muzzle'] = smooth01((-0.785 - q.x) / 0.07)
    # ear opening: a little pit behind the eye
    er = gauss(q, EAR, (0.0055, 0.0055, 0.0055))
    d -= 0.0045 * er
    a['ear'] = er
    # neck folds: fat creases on the sides and throat where the head meets the shoulders
    if -0.64 < q.x < -0.40:
        env = smooth01((q.x + 0.64) / 0.06) * smooth01((-0.40 - q.x) / 0.08)
        side = smooth01((0.19 - q.y + 0.1 * q.z) / 0.12)
        wob = noise.noise(Vector((q.x * 7.0, q.z * 9.0, 3.3))) * 2.2
        fold = math.sin((q.x + 0.64) * TAU / 0.06 + wob) * env * side * (0.5 + 0.5 * noise.noise(Vector((q.x * 11.0, q.y * 11.0, q.z * 11.0))))
        d += 0.0016 * fold
        a['fold'] = max(0.0, -fold) * env
    # shoulders over the fore flippers, hips, a shallow spine furrow
    d += 0.011 * gauss(q, (-0.255, 0.105, 0.215), (0.06, 0.045, 0.05))
    a['shoulder'] = gauss(q, (-0.24, 0.09, 0.235), (0.05, 0.035, 0.035))
    d += 0.005 * gauss(q, (0.33, 0.15, 0.13), (0.045, 0.04, 0.04))
    if -0.35 < q.x < 0.35:
        d -= 0.0022 * math.exp(-(q.z / 0.028) ** 2) * smooth01((q.y - 0.25) / 0.05) * smooth01(1 - abs(q.x) / 0.35)
    return d, a


def body_point(x, th):
    p = base_point(x, th)
    n = base_normal(x, th)
    d, a = head_features(p)
    return p + n * d, n, a


# ---------------------------------------------------------------- weights
CHAIN_BONES = ['head', 'neck', 'chest', 'spine', 'lumbar', 'pelvis']
CHAIN_JOINTS = [-0.585, -0.36, -0.10, 0.12, 0.34]
CHAIN_HALF = [0.04, 0.06, 0.08, 0.08, 0.06]


def chain_weights(x):
    w = {}
    for i, b in enumerate(CHAIN_BONES):
        lo = 1.0 if i == 0 else smooth01((x - CHAIN_JOINTS[i - 1] + CHAIN_HALF[i - 1]) / (2 * CHAIN_HALF[i - 1]))
        hi = 1.0 if i == len(CHAIN_BONES) - 1 else 1.0 - smooth01((x - CHAIN_JOINTS[i] + CHAIN_HALF[i]) / (2 * CHAIN_HALF[i]))
        if lo * hi > 1e-4:
            w[b] = lo * hi
    return w


def breath_weight(p, ta):
    return 0.85 * math.exp(-((p.x + 0.17) / 0.17) ** 2) * (0.3 + 0.7 * smooth01((2.7 - ta) / 0.9)) * smooth01((p.x + 0.52) / 0.1)


def body_weights(p, ta):
    w = chain_weights(p.x)
    wr = breath_weight(p, ta)
    for side, sz in (('L', 1.0), ('R', -1.0)):
        ins = FL_PIVOT + FL_DIR * 0.01
        ins = Vector((ins.x, ins.y, ins.z * sz))
        g = 0.55 * math.exp(-((p - ins).length / 0.07) ** 2)
        if g > 1e-3:
            for k in w:
                w[k] *= (1 - g)
            w['flipper_upper.' + side] = g
        if p.x > 0.44:
            h = 0.45 * smooth01((p.x - 0.44) / 0.1) * smooth01(p.z * sz / 0.03 + 0.5)
            if h > 1e-3:
                for k in w:
                    w[k] *= (1 - h)
                w['hind.' + side] = w.get('hind.' + side, 0.0) + h
    if wr > 1e-3:
        for k in w:
            w[k] *= (1 - wr)
        w['ribs'] = wr
    return w


def mask_colour(p, ta, inf=0.0):
    """COLOR_0: r = infection weight, g = breathing weight, b = injection site, a = gunshot site."""
    inj = inj_mask(p)
    gun = gun_mask(p)
    return (inf, min(1.0, breath_weight(p, ta) / 0.85), inj, gun)


def inj_mask(p):
    # a stripe along the dorsal midline of the neck, where the minigame's vein runs along X
    return math.exp(-((p.x - INJ_X) / 0.085) ** 4) * math.exp(-(p.z / 0.030) ** 2) * smooth01((p.y - 0.22) / 0.04)


GUN_P = None


def gun_mask(p):
    return math.exp(-((p - GUN_P).length / 0.085) ** 2)


# ---------------------------------------------------------------- body (head + torso)
BODY_XS = [0.574, 0.560, 0.545, 0.528, 0.510, 0.490, 0.468, 0.445, 0.420, 0.393, 0.365, 0.335, 0.305,
           0.275, 0.245, 0.215, 0.185, 0.155, 0.125, 0.100, 0.075, 0.052, 0.030, 0.008, -0.015, -0.040,
           -0.068, -0.098, -0.128, -0.158, -0.188, -0.216, -0.242, -0.268, -0.294, -0.320, -0.347, -0.375,
           -0.403, -0.430, -0.455, -0.478, -0.500, -0.521, -0.542, -0.562, -0.581, -0.600]
HEAD_XS = [-0.600, -0.618, -0.636, -0.652, -0.667, -0.681, -0.694, -0.706, -0.717, -0.728, -0.738, -0.747,
           -0.756, -0.765, -0.774, -0.783, -0.792, -0.802, -0.813, -0.825, -0.837, -0.849, -0.860, -0.870,
           -0.879, -0.887, -0.894, -0.900, -0.9045]


def body_theta_weight(th):
    ta = theta_from_top(th)
    return (1.0 + 0.55 * math.exp(-((ta - 1.0) / 0.38) ** 2) + 0.25 * math.exp(-(ta / 0.45) ** 2)
            - 0.5 * smooth01((ta - 2.1) / 0.6))


def head_theta_weight(th):
    ta = theta_from_top(th)
    return (1.0 + 1.1 * math.exp(-((ta - 1.0) / 0.32) ** 2) + 0.3 * math.exp(-(ta / 0.5) ** 2)
            + 0.35 * math.exp(-((ta - 2.0) / 0.4) ** 2) - 0.35 * smooth01((ta - 2.5) / 0.4))


def surface_vdata(p, n, ta, a, x):
    attr = dict(a)
    head = smooth01((-0.56 - p.x) / 0.08)
    attr['belly'] = lerp(smooth01((ta - 1.5) / 0.95), smooth01((ta - 1.95) / 0.7), head)
    attr['saddle'] = lerp(smooth01((1.25 - ta) / 0.85), 0.5 * smooth01((1.0 - ta) / 0.8), head)
    attr['inj'] = inj_mask(p)
    attr['gun'] = gun_mask(p)
    return VData(attr, mask_colour(p, ta), body_weights(p, ta))


def _body_rings(xs, segs, head_blend):
    """head_blend(x) -> 0 uses the torso column spacing, 1 the head's; the shared seam ring is 0."""
    tb = warp_table(body_theta_weight, segs, math.pi)
    th_ = warp_table(head_theta_weight, segs, math.pi)
    rings, vd = [], []
    for x in xs:
        k = head_blend(x)
        ring, row = [], []
        for j in range(segs):
            th = lerp(tb[j], th_[j], k)
            p, n, a = body_point(x, th)
            ta = theta_from_top(th)
            ring.append(p)
            row.append(surface_vdata(p, n, ta, a, x))
        rings.append(ring)
        vd.append(row)
    return rings, vd


def build_torso(res):
    P = Part('torso', 'coat')
    xs = densify(BODY_XS, res)
    rings, vd = _body_rings(xs, 56 * res, lambda x: 0.0)
    tail = TAIL_TIP
    tvd = VData({'belly': 0.3}, mask_colour(tail, 1.5), body_weights(tail, 1.5))
    P.rings(rings, vd, cap_start=(tail, tvd),
            outward=lambda i: Vector((xs[0], B_C(xs[0]), 0.0)))
    return P


def build_head(res):
    P = Part('head', 'coat', uv_boost=1.9)
    xs = densify(HEAD_XS, res)
    rings, vd = _body_rings(xs, 56 * res, lambda x: smooth01((HEAD_X - x) / 0.07))
    tip = NOSE_TIP
    nvd = VData({'nose': 1.0, 'muzzle': 1.0}, mask_colour(tip, 1.5), {'head': 1.0})
    P.rings(rings, vd, cap_end=(tip, nvd), outward=lambda i: Vector((xs[0], B_C(xs[0]), 0.0)))
    return P


# ---------------------------------------------------------------- eyes and whiskers
def build_eyes(res):
    P = Part('eyes', 'detail', uv_boost=3.0)
    for sz in (1.0, -1.0):
        c = Vector((EYE_C.x, EYE_C.y, EYE_C.z * sz))
        g = Vector((EYE_GAZE.x, EYE_GAZE.y, EYE_GAZE.z * sz)).normalized()
        a = g.orthogonal().normalized()
        b = g.cross(a).normalized()
        segs, nring = 16 * res, 10 * res
        rings, vd = [], []
        for k in range(1, nring):
            phi = math.pi * k / nring
            ring, row = [], []
            for j in range(segs):
                ang = TAU * j / segs
                dirv = g * math.cos(phi) + (a * math.cos(ang) + b * math.sin(ang)) * math.sin(phi)
                ring.append(c + dirv * EYE_R)
                back = max(0.0, dirv.dot(Vector((1.0, 0.25, 0.0)).normalized()))
                row.append(VData({'eye': 1.0, 'eyez': math.cos(phi), 'sclera': smooth01((back - 0.45) / 0.3)},
                                 (0, 0, 1, 1), {'head': 1.0}))
            rings.append(ring)
            vd.append(row)
        front = VData({'eye': 1.0, 'eyez': 1.0}, (0, 0, 1, 1), {'head': 1.0})
        backv = VData({'eye': 1.0, 'eyez': -1.0}, (0, 0, 1, 1), {'head': 1.0})
        P.rings(rings, vd, cap_start=(c + g * EYE_R, front), cap_end=(c - g * EYE_R, backv),
                outward=lambda i, c=c: c)
    return P


def tube(P, path, radii, segs, vd_fn, tip_pole=True, base_pole=False, uv_boost_block=None):
    """Open tube along a polyline; radii per path point; vd_fn(t) -> VData."""
    from_up = Vector((0.0, 1.0, 0.0))
    T = []
    for i in range(len(path)):
        a = path[max(0, i - 1)]
        b = path[min(len(path) - 1, i + 1)]
        T.append((b - a).normalized())
    N0 = from_up - T[0] * from_up.dot(T[0])
    if N0.length < 1e-4:
        N0 = Vector((1.0, 0.0, 0.0)) - T[0] * T[0].x
    Ns = [N0.normalized()]
    for i in range(1, len(path)):
        rot = T[i - 1].rotation_difference(T[i])
        nv = rot @ Ns[-1]
        Ns.append((nv - T[i] * nv.dot(T[i])).normalized())
    rings, vd = [], []
    L = len(path)
    for i, p in enumerate(path):
        B = T[i].cross(Ns[i])
        t = i / (L - 1)
        rings.append([p + (Ns[i] * math.cos(TAU * j / segs) + B * math.sin(TAU * j / segs)) * radii[i] for j in range(segs)])
        vd.append([vd_fn(t) for _ in range(segs)])
    if tip_pole:
        end = path[-1] + T[-1] * radii[-1] * 0.8
        rings_ids = P.rings(rings, vd, cap_end=(end, vd_fn(1.0)), cap_start=(path[0] - T[0] * radii[0], vd_fn(0.0)) if base_pole else None,
                            outward=lambda i: path[0] * 0.5 + path[1] * 0.5)
    else:
        rings_ids = P.rings(rings, vd, outward=lambda i: path[0] * 0.5 + path[1] * 0.5)
    return rings_ids


def build_whiskers(res):
    P = Part('whiskers', 'detail', uv_boost=2.0)
    segs = 3 if res == 1 else 6
    npts = 6 if res == 1 else 18
    rng = 0
    for sz in (1.0, -1.0):
        roots = []
        # muzzle whiskers: rows over the pad, longest at the back and bottom
        for row in range(4):
            for col in range(5 - (row == 3)):
                x = -0.874 + 0.0135 * col + 0.004 * row
                th = 1.02 + 0.20 * row + 0.03 * col
                roots.append((x, th, 0.045 + 0.018 * col + 0.012 * row, row, col))
        for x, th, length, row, col in roots:
            rng += 1
            p, n, _ = body_point(x, th)
            p = Vector((p.x, p.y, p.z * sz))
            n = Vector((n.x, n.y, n.z * sz))
            h = math.sin(rng * 12.9898) * 43758.5453
            h = h - math.floor(h)
            dirv = (n * 0.55 + Vector((-0.55 + 0.1 * col, -0.30 - 0.08 * row, 0.62 * sz))).normalized()
            L = length * (0.85 + 0.3 * h)
            pts = []
            for k in range(npts):
                t = k / (npts - 1)
                q = p - n * 0.002 + dirv * L * t + Vector((0.12 * L * t * t, -0.32 * L * t * t, 0.0))
                pts.append(q)
            radii = []
            for k in range(npts):
                t = k / (npts - 1)
                r = lerp(0.00105, 0.00022, t ** 0.8)
                if res > 1:
                    r *= 1.0 + 0.28 * math.sin(t * L / 0.0045 * TAU)
                radii.append(r)
            tube(P, pts, radii, segs, lambda t: VData({'whisker': 1.0, 'cap_u': t}, (0, 0, 0, 0), {'head': 1.0}))
        # two brow whiskers over each eye and one on the nose
        for k in range(3):
            if k < 2:
                x = EYE_C.x + 0.004 - 0.010 * k
                p, n, _ = body_point(x, 0.62 + 0.10 * k)
                dirv = (n + Vector((0.15, 0.45, 0.3))).normalized()
                L = 0.055 + 0.012 * k
            else:
                p, n, _ = body_point(-0.868, 0.35)
                dirv = (n + Vector((-0.4, 0.2, 0.25))).normalized()
                L = 0.035
            p = Vector((p.x, p.y, p.z * sz))
            n = Vector((n.x, n.y, n.z * sz))
            dirv = Vector((dirv.x, dirv.y, dirv.z * sz))
            pts = [p - n * 0.002 + dirv * L * (i / (npts - 1)) + Vector((0.2 * L, -0.25 * L, 0.0)) * (i / (npts - 1)) ** 2 for i in range(npts)]
            radii = [lerp(0.0009, 0.0002, i / (npts - 1)) for i in range(npts)]
            tube(P, pts, radii, segs, lambda t: VData({'whisker': 1.0, 'cap_u': t}, (0, 0, 0, 0), {'head': 1.0}))
    return P


# ---------------------------------------------------------------- fore flippers (left side; mirrored for the right)
FS_KEYS = [  # s, half up, half side, n vertical, n horizontal
    (-0.075, 0.060, 0.086, 2.0, 2.2),
    (-0.020, 0.051, 0.080, 2.0, 2.3),
    (0.030, 0.041, 0.071, 1.95, 2.5),
    (0.070, 0.035, 0.065, 1.9, 2.6),
    (LIMB_S, 0.031, 0.061, 1.85, 2.7),
    (0.150, 0.028, 0.059, 1.8, 2.7),
    (CUT_S, 0.025, 0.058, 1.75, 2.7),
    (0.215, 0.021, 0.061, 1.7, 2.7),
    (0.245, 0.018, 0.066, 1.6, 2.7),
    (0.280, 0.015, 0.068, 1.55, 2.7),
    (0.310, 0.012, 0.065, 1.5, 2.6),
    (0.333, 0.009, 0.057, 1.5, 2.5),
    (0.352, 0.005, 0.038, 1.5, 2.3),
]
_fs = [k[0] for k in FS_KEYS]
F_HU, F_HS, F_NV, F_NH = (pchip(_fs, [k[i] for k in FS_KEYS]) for i in range(1, 5))
FLIP_SS = [-0.075, -0.045, -0.015, 0.015, 0.045, 0.070, LIMB_S - BAND_HALF, LIMB_S, LIMB_S + BAND_HALF, 0.160,
           0.175, CUT_S, 0.195, INFECT_S, 0.222, INFECT_FULL_S, 0.262, 0.278, 0.293, 0.306, 0.318, 0.328, 0.337,
           0.3435, 0.348]
DIGITS = [-0.74, -0.37, 0.0, 0.37, 0.74]     # across the paddle, normalised side coordinate
LINE_LOOPS = [(0.226, 0.009, 0.4, 0.985), (0.254, -0.011, 1.9, 0.975), (0.284, 0.008, 3.1, 0.98)]   # s, tilt, phase, embed


def fl_centre(s):
    """Centreline of the left fore flipper: straight to the cut, then easing down onto the table
    and curling back toward the tail."""
    up = Vector((0.0, 1.0, 0.0))
    U = (up - FL_DIR * up.dot(FL_DIR)).normalized()
    V = FL_DIR.cross(U).normalized()
    drop = -0.040 * smooth01((s - 0.19) / 0.17)
    curl = -0.030 * smooth01((s - 0.20) / 0.2) ** 1.5
    return FL_PIVOT + FL_DIR * s + U * drop + V * curl


def fl_frame(s):
    ds = 0.004
    T = (fl_centre(s + ds) - fl_centre(s - ds)).normalized()
    up = Vector((0.0, 1.0, 0.0))
    U = (up - T * up.dot(T)).normalized()
    V = T.cross(U).normalized()
    return fl_centre(s), T, U, V


def digit_ridge(vn):
    return max(math.exp(-((vn - k) / 0.13) ** 2) for k in DIGITS)


def fl_tip_ext(vn):
    # digit I (leading edge, +V) is the longest; the web dips between the digit tips
    return 0.010 * vn + 0.008 * digit_ridge(vn) - 0.008 - 0.012 * vn * vn


def fl_point(s, th):
    """th: 0 = top (+U), +pi/2 = +V. Returns point, side coordinate, top flag."""
    c, sn = math.cos(th), math.sin(th)
    vn = sgnpow(sn, 2.0 / F_NH(s))
    ext = fl_tip_ext(vn) * smooth01((s - 0.295) / 0.045)
    se = s + ext
    ctr, T, U, V = fl_frame(se)
    hu = F_HU(se)
    fade = smooth01((s - 0.215) / 0.05)
    if c >= 0:
        ridge = 1.0 + (0.55 * digit_ridge(vn) - 0.28) * fade
        up = hu * ridge * sgnpow(c, 2.0 / F_NV(se))
    else:
        up = -hu * 0.78 * sgnpow(-c, 2.0 / F_NV(se)) * (1.0 + (0.25 * digit_ridge(vn) - 0.12) * fade)
    side = F_HS(se) * vn
    # the flipper flares into the body at the shoulder
    flare = smooth01((0.03 - s) / 0.1)
    return ctr + U * up * (1.0 + 0.15 * flare) + V * side * (1.0 + 0.45 * flare) - U * 0.012 * flare, vn, c >= 0


def flipper_weights(s, side='L'):
    up, fo, ha, di = ('flipper_upper.' + side, 'flipper_fore.' + side, 'flipper_hand.' + side, 'flipper_digits.' + side)
    a = smooth01((s - 0.015) / 0.05)
    b = smooth01((s - CUT_S) / 0.035)
    c = smooth01((s - 0.245) / 0.05)
    wch = smooth01((-0.02 - s) / 0.05)
    w = {'chest': (1 - a) * wch, up: (1 - a) * (1 - wch), fo: a * (1 - b), ha: b * (1 - c), di: c}
    return {k: v for k, v in w.items() if v > 1e-4}


def infection_weight(s):
    return smooth01((s - INFECT_S) / (INFECT_FULL_S - INFECT_S))


def build_fore_flipper(res):
    """Left fore flipper, stub and paddle as one continuous surface; faces past the cut carry tag 1."""
    P = Part('flipper.L', 'coat', uv_boost=1.35)
    segs = 34 * res
    ss = densify(FLIP_SS, res)
    ths = flipper_thetas(segs)
    rings, vd, v2, tags = [], [], [], []
    for s in ss:
        ring, row = [], []
        for th in ths:
            p, vn, top = fl_point(s, th)
            ta = theta_from_top(th)
            inf = infection_weight(s)
            fade = smooth01((s - 0.225) / 0.06)
            groove = 0.0
            for s0, tilt, phase, emb in LINE_LOOPS:
                groove = max(groove, math.exp(-((s - (s0 + tilt * math.sin(th + phase))) / 0.0026) ** 2))
            attr = {'flip': smooth01((s + 0.03) / 0.06), 'palm': 0.0 if top else 1.0, 'groove': groove,
                    'ths': math.sin(th), 'thc': math.cos(th),
                    'knuck': digit_ridge(vn) * fade * (1.0 if top else 0.5), 'inf': inf,
                    'belly': 0.0 if top else 0.5}
            col = (inf, 0.0, 0.0, 0.0)
            F = Vector((s, (p - fl_centre(s)).dot(Vector((0, 1, 0))), vn * 0.07))
            row.append(VData(attr, col, flipper_weights(s), F))
            ring.append(p)
        rings.append(ring)
        vd.append(row)
        v2.append(max(0.0, (s - CUT_S) / (TIP_S - CUT_S)) if s >= CUT_S - 1e-6 else None)
    for i in range(len(ss) - 1):
        tags.append(1 if ss[i] >= CUT_S - 1e-6 else 0)
    tags.append(1)
    tip_s = TIP_S
    ctr, T, U, V = fl_frame(tip_s)
    tip = ctr + T * 0.002 + U * 0.001
    tvd = VData({'flip': 1.0, 'inf': 1.0, 'knuck': 0.3}, (1.0, 0, 0, 0), flipper_weights(tip_s),
                Vector((tip_s, 0.0, 0.0)))
    v2 = [None if x is None else min(0.985, 0.01 + 0.975 * x) for x in v2]
    root = fl_centre(ss[0]) - fl_frame(ss[0])[1] * 0.01
    rvd = VData({'flip': 0.0}, (0.0, 0.0, 0.0, 0.0), flipper_weights(ss[0]), Vector((ss[0], 0.0, 0.0)))
    P.rings(rings, vd, cap_start=(root, rvd), cap_end=(tip, tvd), v2=v2, tags=tags,
            outward=lambda i: fl_centre(ss[0]) * 0.5 + fl_centre(ss[1]) * 0.5)
    return P


def build_fore_claws(res, side='L'):
    P = Part('claws_f.' + side, 'detail', uv_boost=2.5)
    segs = 6 if res == 1 else 12
    npts = 6 if res == 1 else 14
    for k, vn in enumerate(DIGITS):
        s_tip = 0.326 + fl_tip_ext(vn) * 0.85
        th = math.asin(max(-0.98, min(0.98, sgnpow(vn, F_NH(s_tip) / 2.0))))
        base, _, _ = fl_point(s_tip, th * 0.92)
        ctr, T, U, V = fl_frame(s_tip)
        base = base - U * 0.002
        L = 0.030 + 0.004 * (vn > 0) - 0.004 * abs(vn)
        pts, radii = [], []
        for i in range(npts):
            t = i / (npts - 1)
            pts.append(base + T * L * t + U * (0.006 * t - 0.016 * t * t) + V * (vn * 0.004 * t))
            radii.append(lerp(0.0058, 0.0007, t ** 1.1))
        tube(P, pts, radii, segs, lambda t: VData({'claw': 1.0, 'cap_u': t}, (0, 0, 0, 0), flipper_weights(0.33)),
             base_pole=False)
    if side == 'R':
        return mirror_part_z(P, P.name)
    return P


def mirror_part_z(P, name):
    return P.mirrored_z(name)


# ---------------------------------------------------------------- stump cap (the cut face on the stub) and the severed face
BONES_UV = [(0.002, -0.019, 0.0125, 0.0078), (0.005, 0.021, 0.0078, 0.0062)]   # (u, v, radius v, radius u): radius, ulna


def flipper_thetas(segs):
    return warp_table(lambda th: 1.0 + 0.55 * math.exp(-((theta_from_top(th) - 1.5708) / 0.3) ** 2)
                      + 0.6 * math.exp(-((theta_from_top(th) - 0.7) / 0.5) ** 2), segs, math.pi)


def cap_ring_points(res):
    segs = 34 * res
    ths = flipper_thetas(segs)
    return [fl_point(CUT_S, th)[0] for th in ths]


def build_cap(res, severed=False):
    """Concentric rings from the cut edge loop to the centre. The stump side dishes in (muscle
    retracts, bone stands proud); the severed side is the mirror."""
    P = Part('cap.L' if not severed else 'cap_severed.L', 'detail', uv_boost=2.2)
    ring0 = cap_ring_points(res)
    ctr, T, U, V = fl_frame(CUT_S)
    K = 4 * res
    sgn = -1.0 if severed else 1.0
    rings, vd = [], []
    radius = [(p - ctr).length for p in ring0]
    for k in range(K):
        sc = 1.0 - k / K
        ring, row = [], []
        for j, p0 in enumerate(ring0):
            rel = p0 - ctr
            q = ctr + rel * sc
            u = (q - ctr).dot(U)
            v = (q - ctr).dot(V)
            bone = 0.0
            for bu, bv, rv, ru in BONES_UV:
                e = ((u - bu) / ru) ** 2 + ((v - bv) / rv) ** 2
                bone = max(bone, math.exp(-e ** 2 * 0.8))
            dist = radius[j] * (1.0 - sc)
            recess = -0.0045 * smooth01(dist / 0.012) * (1 - bone) + 0.0025 * bone
            wob = 0.0012 * noise.noise(Vector((u * 90.0, v * 90.0, 1.7))) * smooth01(dist / 0.006)
            q = q + T * sgn * (recess + wob) * (1.0 if k > 0 else 0.0)
            ring.append(q)
            row.append(VData({'cap': 1.0, 'cap_d': dist, 'cap_u': u, 'cap_v': v}, (0, 0, 0, 0),
                             {'flipper_fore.L': 1.0}, Vector((u, v, dist))))
        rings.append(ring)
        vd.append(row)
    # planar UVs across the cap (u along V, v along U)
    centre = ctr + T * sgn * 0.0005
    cvd = VData({'cap': 1.0, 'cap_d': 0.03, 'cap_u': 0.0, 'cap_v': 0.0}, (0, 0, 0, 0), {'flipper_fore.L': 1.0}, Vector((0, 0, 0.03)))
    n = len(ring0)
    u0 = P.next_uv_block(0.2)
    ids = [[P.add_v(p, vd[i][j]) for j, p in enumerate(r)] for i, r in enumerate(rings)]
    pole = P.add_v(centre, cvd)

    def uvp(q):
        return (u0 + 0.1 + (q - ctr).dot(V), 0.1 + (q - ctr).dot(U))
    for i in range(K - 1):
        for j in range(n):
            j2 = (j + 1) % n
            quad = (ids[i][j], ids[i][j2], ids[i + 1][j2], ids[i + 1][j])
            P.face(quad, [uvp(P.v[x]) for x in quad])
    for j in range(n):
        j2 = (j + 1) % n
        tri = (ids[K - 1][j], ids[K - 1][j2], pole)
        P.face(tri, [uvp(P.v[x]) for x in tri])
    # facing: the stump cap looks down the flipper (+T), the severed face back up it (-T)
    fa = P.f[0]
    nrm = (P.v[fa[1]] - P.v[fa[0]]).cross(P.v[fa[2]] - P.v[fa[0]])
    if nrm.dot(T) * sgn < 0:
        P.flip_faces(0)
    return P


# ---------------------------------------------------------------- fishing line (amputation case only)
def build_line(res):
    P = Part('line.L', 'detail', uv_boost=1.0)
    segs = 4 if res == 1 else 8
    for s0, tilt, phase, emb in LINE_LOOPS:
        n = 26 * res
        path = []
        for k in range(n):
            th = TAU * k / n
            s = s0 + tilt * math.sin(th + phase)
            p, vn, top = fl_point(s, th)
            ctr = fl_centre(s)
            path.append(ctr + (p - ctr) * emb)
        r = 0.0016
        # closed tube
        T = [(path[(i + 1) % n] - path[i - 1]).normalized() for i in range(n)]
        rings, vd = [], []
        for i, p in enumerate(path):
            Nn = (p - fl_centre(s0)).normalized()
            Nn = (Nn - T[i] * Nn.dot(T[i])).normalized()
            B = T[i].cross(Nn)
            rings.append([p + (Nn * math.cos(TAU * j / segs) + B * math.sin(TAU * j / segs)) * r for j in range(segs)])
            vd.append([VData({'line': 1.0}, (1.0, 0, 0, 0), flipper_weights(s0)) for _ in range(segs)])
        P.rings(rings, vd, closed_path=True, outward=lambda i, path=path: path[0] - (path[0] - fl_centre(s0)).normalized() * 0.001)
    # a frayed loose end trailing onto the table
    p0, _, _ = fl_point(0.254, 1.35)
    ctr, T, U, V = fl_frame(0.254)
    pts = []
    npts = 8 * res
    for k in range(npts):
        t = k / (npts - 1)
        q = p0 + V * (0.03 * t) + T * (0.05 * t) - U * 0.0
        q.y = max(0.0012, p0.y - (p0.y - 0.0012) * smooth01(t * 2.2))
        q = q + Vector((0.0, 0.0, 0.0))
        pts.append(q + V * 0.03 * t * t)
    tube(P, pts, [0.0016] * npts, segs, lambda t: VData({'line': 1.0}, (1.0, 0, 0, 0), flipper_weights(0.254 + 0.06 * t)))
    return P


# ---------------------------------------------------------------- hind flippers
HS_KEYS = [  # s, half up, half side
    (0.000, 0.032, 0.036),
    (0.040, 0.027, 0.040),
    (0.085, 0.020, 0.050),
    (0.130, 0.015, 0.064),
    (0.180, 0.012, 0.082),
    (0.225, 0.010, 0.097),
    (0.260, 0.009, 0.106),
    (0.290, 0.007, 0.108),
    (0.312, 0.005, 0.104),
]
_hs = [k[0] for k in HS_KEYS]
H_HU, H_HS = (pchip(_hs, [k[i] for k in HS_KEYS]) for i in (1, 2))
HIND_SS = [0.0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.18, 0.205, 0.23, 0.25, 0.268, 0.283, 0.296, 0.306]
HIND_ROOT = Vector((0.455, 0.070, 0.034))
HIND_DIR = Vector((1.0, 0.02, 0.17)).normalized()
HIND_ROLL = 0.30       # radians: the outer edge lifts, the two soles tip toward each other


def hind_frame(s):
    up = Vector((0.0, 1.0, 0.0))
    T = HIND_DIR
    U = (up - T * up.dot(T)).normalized()
    V = T.cross(U).normalized()
    cr, sr = math.cos(HIND_ROLL), math.sin(HIND_ROLL)
    U2 = U * cr - V * sr
    V2 = V * cr + U * sr
    ctr = HIND_ROOT + T * s + Vector((0.0, -0.030 * smooth01(s / 0.16) + 0.012 * smooth01((s - 0.2) / 0.11), 0.0))
    return ctr, T, U2, V2


def hind_ext(vn):
    # the outer digits (I and V) are longest; the trailing edge dips between them, scalloped at the webs
    ridge = max(math.exp(-((vn - k) / 0.12) ** 2) for k in DIGITS)
    return 0.030 * vn * vn - 0.010 + 0.010 * ridge


def hind_point(s, th):
    c, sn = math.cos(th), math.sin(th)
    vn = sgnpow(sn, 2.0 / 2.5)
    se = s + hind_ext(vn) * smooth01((s - 0.24) / 0.05)
    ctr, T, U, V = hind_frame(se)
    ridge = max(math.exp(-((vn - k) / 0.14) ** 2) for k in DIGITS)
    fade = smooth01((s - 0.10) / 0.08)
    up = H_HU(se) * (1.0 + (0.6 * ridge - 0.3) * fade) * sgnpow(c, 2.0 / 1.7)
    side = H_HS(se) * vn
    return ctr + U * up + V * side, vn, c >= 0


def hind_weights(s, side):
    a = smooth01((s - 0.02) / 0.07)
    b = smooth01((s - 0.14) / 0.08)
    w = {'pelvis': 1 - a, 'hind.' + side: a * (1 - b), 'hind_toes.' + side: a * b}
    return {k: v for k, v in w.items() if v > 1e-4}


def build_hind(res):
    P = Part('hind.L', 'coat', uv_boost=1.2)
    segs = 24 * res
    ss = densify(HIND_SS, res)
    ths = warp_table(lambda th: 1.0 + 0.6 * math.exp(-((theta_from_top(th) - 1.5708) / 0.3) ** 2), segs, math.pi)
    rings, vd = [], []
    for s in ss:
        ring, row = [], []
        for th in ths:
            p, vn, top = hind_point(s, th)
            ridge = max(math.exp(-((vn - k) / 0.14) ** 2) for k in DIGITS)
            row.append(VData({'hind': 1.0, 'palm': 0.0 if top else 1.0, 'knuck': ridge * smooth01((s - 0.1) / 0.08)},
                             (0, 0, 0, 0), hind_weights(s, 'L'), Vector((s, 0.0, vn * 0.1))))
            ring.append(p)
        rings.append(ring)
        vd.append(row)
    ctr, T, U, V = hind_frame(0.316)
    P.rings(rings, vd, cap_end=(ctr + T * 0.002, VData({'hind': 1.0}, (0, 0, 0, 0), hind_weights(0.31, 'L'))),
            outward=lambda i: hind_frame(ss[0])[0] * 0.5 + hind_frame(ss[1])[0] * 0.5)
    return P


def build_hind_claws(res):
    P = Part('claws_h.L', 'detail', uv_boost=2.0)
    segs = 5 if res == 1 else 10
    npts = 4 if res == 1 else 10
    for vn in DIGITS:
        s_c = 0.215 + hind_ext(vn) * 0.8
        th = math.asin(max(-0.98, min(0.98, sgnpow(vn, 2.5 / 2.0))))
        base, _, _ = hind_point(s_c, th * 0.92)
        ctr, T, U, V = hind_frame(s_c)
        base = base + U * 0.001
        L = 0.016
        pts = [base + T * L * (i / (npts - 1)) + U * (0.002 * (i / (npts - 1)) - 0.005 * (i / (npts - 1)) ** 2) for i in range(npts)]
        radii = [lerp(0.0032, 0.0005, (i / (npts - 1)) ** 1.2) for i in range(npts)]
        tube(P, pts, radii, segs, lambda t: VData({'claw': 1.0, 'cap_u': t}, (0, 0, 0, 0), hind_weights(0.25, 'L')))
    return P


# ---------------------------------------------------------------- sites (patient frame, rest pose)
def _frame_on(p, x_dir, normal):
    p = p * SCALE
    y = normal.normalized()
    x = (x_dir - y * x_dir.dot(y)).normalized()
    z = x.cross(y).normalized()
    return p, x, y, z


def sites():
    """name -> (origin, X, Y, Z, bone, extra). Y = out of the skin, X along the limb / body."""
    out = {}
    # injection: back of the neck on the dorsal midline (the displaced surface)
    p, n, _ = body_point(INJ_X, 0.0)
    out['injection'] = _frame_on(p, Vector((1, 0, 0)), n) + ('neck', {})
    p, n, _ = body_point(GUN_X, GUN_THETA)
    out['gunshot'] = _frame_on(p, Vector((1, 0, 0)), n) + ('spine', {})
    for nm, s in (('limb', LIMB_S), ('limb_cut', CUT_S)):
        ctr, T, U, V = fl_frame(s)
        # section at s: measured from the ring itself
        segs = 96
        ths = [math.pi + TAU * j / segs for j in range(segs)]
        pts = [fl_point(s, th)[0] for th in ths]
        top = max((q - ctr).dot(U) for q in pts)
        bottom = -min((q - ctr).dot(U) for q in pts)
        half_side = max(abs((q - ctr).dot(V)) for q in pts)
        origin = (ctr + U * top) * SCALE
        sec = {'half_up': top * SCALE, 'half_down': bottom * SCALE, 'half_side': half_side * SCALE, 'axis_depth': top * SCALE,
               'shape': 2.3, 'infection_start': (INFECT_S - s) * SCALE, 'infection_full': (INFECT_FULL_S - s) * SCALE}
        out[nm] = (origin, T, U, V.normalized(), 'flipper_fore.L', sec)
    return out


def _init_gun():
    global GUN_P
    GUN_P = base_point(GUN_X, GUN_THETA)


_init_gun()


# ---------------------------------------------------------------- all
def build_all(res=1):
    fl = build_fore_flipper(res)
    parts = {
        'torso': build_torso(res),
        'head': build_head(res),
        'eyes': build_eyes(res),
        'whiskers': build_whiskers(res),
        'flipper.L': fl,
        'flipper.R': fl.mirrored_z('flipper.R'),
        'claws_f.L': build_fore_claws(res, 'L'),
        'claws_f.R': build_fore_claws(res, 'R'),
        'hind.L': build_hind(res),
        'claws_h.L': build_hind_claws(res),
        'cap.L': build_cap(res),
        'line.L': build_line(res),
    }
    parts['hind.R'] = parts['hind.L'].mirrored_z('hind.R')
    parts['claws_h.R'] = parts['claws_h.L'].mirrored_z('claws_h.R')
    return parts
