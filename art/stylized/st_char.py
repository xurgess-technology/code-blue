"""Stylized humans: the surgeon and the Hive as smooth blended shapes on the human pipeline's skeleton.

Style rules (the start of the style guide):
- People, not dolls: normal-ish proportions, a little heavier in the head and hands.
- Simple, soft forms: no pores, wrinkles or anatomy lines; forms are big and readable.
- Faces are figurine faces: clear brow, simple nose, a mouth line, big clear eyes in real sockets.
- Clothes are stiff, chunky shells with thick hems, seams where they end.
- Every eye is a separate object sitting in a carved socket (a graft site).

Blender axes: Z up, the character faces -Y, its left is +X. Pure numpy + the skeleton numbers.
"""
import math
import numpy as np
import st_sdf as S

SKIN, CLOTH, EYE, SHOE, CAP, THREAD = 'skin', 'cloth', 'eye', 'shoe', 'cap', 'thread'


def srgb(c):
    c = np.asarray(c, float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def smooth01(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def mix(a, b, t):
    t = np.asarray(t, float)[..., None] if np.ndim(t) else t
    return a + (b - a) * t


# ====================================================================== variants
VARIANTS = {
    'surgeon': dict(
        height=1.80, fem=0.0, girth=1.0, head_scale=1.08, shoulders=1.0, v2=True, gash=True,
        skin=(0.80, 0.63, 0.53), flush=(0.80, 0.52, 0.46), lip=(0.68, 0.45, 0.42),
        hair=(0.16, 0.10, 0.07), iris=(0.26, 0.42, 0.52), cloth=(0.24, 0.56, 0.52), glove=(0.50, 0.66, 0.86),
        jaw=0.55, cheek=0.5, nose=1.0, brow=1.0, jowl=0.0, sag=0.0, mouth_open=0.0, eye_open=0.62,
        outfit='scrubs', graft=False, seed=5),
    'surgeon_graft': dict(base='surgeon', graft=True),
    'hive': dict(
        height=1.75, fem=0.0, girth=1.12, head_scale=1.13, shoulders=1.0,
        skin=(0.60, 0.61, 0.53), flush=(0.52, 0.44, 0.44), lip=(0.44, 0.38, 0.40),
        hair=(0.30, 0.28, 0.26), iris=(0.60, 0.60, 0.52), cloth=(0.56, 0.66, 0.74),
        jaw=0.70, cheek=0.25, nose=1.15, brow=1.3, jowl=0.35, sag=0.6, mouth_open=1.0, eye_open=1.0,
        outfit='gown', graft=False, seed=41),
}


def get(name):
    v = dict(VARIANTS[name])
    if 'base' in v:
        b = dict(VARIANTS[v.pop('base')])
        b.update(v)
        v = b
    v['name'] = name
    return v


# ====================================================================== skeleton
class Skel:
    """Joint positions (rest pose, A-pose arms) in world metres, from the human pipeline's Body."""

    def __init__(self, body):
        self.J = {k: np.array(tuple(v)) for k, v in body.J.items()}
        self.bones = {k: (np.array(tuple(h)), np.array(tuple(t))) for k, (h, t) in body.joints.items()}
        for k in list(self.bones):
            if k.endswith('.L'):
                h, t = self.bones[k]
                self.bones[k[:-2] + '.R'] = (h * np.array([-1, 1, 1]), t * np.array([-1, 1, 1]))
        self.HC = np.array(tuple(body.HC))
        self.hs = body.hs
        self.s = body.s

    def mirror(self, p):
        return np.array([-p[0], p[1], p[2]])

    def b(self, name):
        return self.bones[name]


# ====================================================================== torso profile
# z, rx, ry, cy, n  (1.78 m male reference; superellipse slices of the trunk)
TRUNK = np.array([
    (0.760, 0.110, 0.085, 0.012, 2.2),
    (0.830, 0.150, 0.103, 0.014, 2.4),
    (0.900, 0.166, 0.110, 0.016, 2.5),
    (0.960, 0.162, 0.104, 0.012, 2.5),
    (1.020, 0.148, 0.097, 0.006, 2.4),
    (1.080, 0.138, 0.093, 0.002, 2.3),
    (1.150, 0.141, 0.095, 0.000, 2.3),
    (1.220, 0.150, 0.100, 0.000, 2.4),
    (1.290, 0.160, 0.104, 0.002, 2.5),
    (1.360, 0.168, 0.104, 0.006, 2.7),
    (1.410, 0.180, 0.100, 0.010, 2.9),
    (1.450, 0.190, 0.090, 0.014, 3.0),
    (1.480, 0.170, 0.080, 0.018, 2.8),
    (1.500, 0.120, 0.066, 0.020, 2.4),
    (1.515, 0.075, 0.056, 0.022, 2.1),
])


def trunk_sdf(s, girth=1.0, belly=0.0, grow=0.0, extra=None, z_lo=None, z_hi=None, table=None, shoulders=1.0):
    """The trunk as stacked superellipse slices. grow: metres added all round; extra(z) -> more metres
    (garment flare). Capped at z_lo/z_hi by rounded planes."""
    T = TRUNK if table is None else table
    zs = T[:, 0] * s
    shk = 1.0 + (shoulders - 1.0) * smooth01((T[:, 0] - 1.30) / 0.14) * (1 - smooth01((T[:, 0] - 1.49) / 0.03))
    rx = T[:, 1] * s * girth * shk
    ry = T[:, 2] * s * girth
    b = belly * np.exp(-((T[:, 0] - 1.06) / 0.14) ** 2)
    rx = rx + 0.030 * b * s
    ry = ry + 0.034 * b * s
    cy = T[:, 3] * s - 0.012 * b * s
    nn = T[:, 4]
    z0 = zs[0] if z_lo is None else z_lo
    z1 = zs[-1] if z_hi is None else z_hi

    def f(P):
        z = np.clip(P[:, 2], zs[0], zs[-1])
        g = grow + (extra(P[:, 2]) if extra else 0.0)
        a = np.interp(z, zs, rx) + g
        c = np.interp(z, zs, ry) + g
        n = np.interp(z, zs, nn)
        cyv = np.interp(z, zs, cy)
        x = np.abs(P[:, 0]) / a
        y = np.abs(P[:, 1] - cyv) / c
        q = (x ** n + y ** n) ** (1.0 / n)
        d = (q - 1.0) * np.minimum(a, c) * 0.85
        d = np.maximum(d, np.maximum(z0 - P[:, 2], P[:, 2] - z1))
        return d
    return f


# ====================================================================== head
class Head:
    """The head in head-local units (metres at head scale 1): origin between the ear canals,
    -Y forward, +X the character's left, Z up. world = HC + local * hs."""

    def __init__(self, V, sk):
        self.V, self.sk = V, sk
        self.HC, self.hs = sk.HC, sk.hs
        jaw, cheek = V['jaw'], V['cheek']
        self.v2 = V.get('v2', False)
        self.eye_c = np.array([0.0345, -0.0735, 0.012])
        self.eye_r = 0.0145
        self.jw = 0.043 + 0.010 * jaw
        self.mouth_z, self.nose_tip = -0.0535, (-0.112, -0.020)
        if self.v2:
            self.eye_c = np.array([0.032, -0.0700, 0.010])
            self.eye_r = 0.0135
            self.gap = 0.0010          # clearance between the eyeball and its socket/lids
            self.lid_t = 0.0018
            self.mouth_z, self.nose_tip = -0.0450, (-0.100, -0.015)
            # seat the eyes on the real (blended) face: find the skin in front of each eye centre
            base = self.sdf_local_v2(True, eyes=False)
            ys = np.linspace(-0.13, -0.04, 900)
            Q = np.stack([np.full(len(ys), self.eye_c[0]), ys, np.full(len(ys), self.eye_c[2])], 1)
            face_y = ys[int(np.argmax(base(Q) < 0))]
            # the ball's front stands 0.4 r proud of where the skin was
            self.eye_c[1] = face_y + self.eye_r * 0.74

    def local(self, P):
        return (P - self.HC) / self.hs

    def world(self, p):
        return self.HC + np.asarray(p) * self.hs

    def eye_world(self, side):
        c = self.eye_c.copy()
        c[0] *= side
        return self.world(c), self.eye_r * self.hs

    # -------------------------------------------------------------- the skull, face and neck
    def sdf_local(self, with_neck=True):
        if self.v2:
            return self.sdf_local_v2(with_neck)
        V = self.V
        jw = self.jw
        sag = V['sag']
        E = S.ellipsoid
        cr = E((0, 0.008, 0.036), (0.080, 0.097, 0.094))
        fh = E((0, -0.028, 0.046), (0.064, 0.066, 0.060))
        mid = E((0, -0.042, -0.014), (0.054, 0.056, 0.054))
        jaw = E((0, -0.034, -0.068 - 0.008 * sag), (jw, 0.056, 0.032))
        chin = E((0, -0.080, -0.094 - 0.008 * sag), (0.021, 0.016, 0.018))
        ang = S.mirror_x(E((jw - 0.002, -0.002, -0.070 - 0.006 * sag), (0.011, 0.020, 0.015)))
        cheek = S.mirror_x(E((0.040, -0.068, -0.016 - 0.006 * sag), (0.018 + 0.004 * V['cheek'], 0.018, 0.018)))
        jowl = S.mirror_x(E((0.044, -0.056, -0.080), (0.020, 0.022, 0.020)))
        h = S.union(cr, fh, k=0.04)
        h = S.union(h, mid, k=0.03)
        h = S.union(h, jaw, k=0.035)
        h = S.union(h, chin, k=0.03)
        h = S.union(h, ang, k=0.02)
        h = S.union(h, cheek, k=0.03)
        if V['jowl'] > 0:
            h = S.union(h, S.offset(jowl, -0.010 * (1 - V['jowl'])), k=0.03)
        # brow ridge: a soft bar over each eye
        ey = self.eye_c
        br = S.mirror_x(S.round_cone((0.012, ey[1] - 0.014, ey[2] + 0.021), (0.050, ey[1] + 0.000, ey[2] + 0.020), 0.0095 * V['brow'], 0.0075 * V['brow']))
        h = S.union(h, br, k=0.014)
        # nose: a simple wedge with a round tip and small wings
        nz = V['nose']
        bridge = S.round_cone((0, -0.090, 0.022), (0, -0.108 - 0.004 * nz, -0.020), 0.0075, 0.0125 * nz)
        wings = S.mirror_x(S.sphere((0.0115 * nz, -0.098, -0.026), 0.0085 * nz))
        nose = S.union(bridge, wings, k=0.008)
        h = S.union(h, nose, k=0.010)
        # lips: soft upper and lower pads
        mo = V['mouth_open']
        lu = E((0, -0.093, -0.047), (0.021, 0.010, 0.0075))
        ll = E((0, -0.089, -0.059 - 0.006 * mo), (0.019, 0.010, 0.008))
        h = S.union(h, lu, k=0.010)
        h = S.union(h, ll, k=0.010)
        # mouth line (or an open slack mouth)
        if mo > 0:
            mouth = E((0, -0.100, -0.0535 - 0.003 * mo), (0.014, 0.020, 0.0035 + 0.004 * mo))
            h = S.subtract(h, mouth, k=0.003)
        else:
            mouth = S.chain([np.array([-0.0215, -0.095, -0.0505]), np.array([-0.010, -0.1015, -0.0535]),
                             np.array([0.010, -0.1015, -0.0535]), np.array([0.0215, -0.095, -0.0505])], [0.0012, 0.0017, 0.0017, 0.0012])
            h = S.subtract(h, mouth, k=0.002)
        # eye sockets: carve, then lids as shells round the eyeball
        ec = self.eye_c
        er = self.eye_r
        sock = S.mirror_x(E((ec[0], ec[1] - 0.004, ec[2]), (0.019, 0.016, 0.0145)))
        h = S.subtract(h, sock, k=0.005)
        h = S.union(h, self.lids(), k=0.0035)
        # ears
        ear = S.mirror_x(E((0.079, 0.006, -0.004), (0.011, 0.019, 0.029), S.rot((1, 0, 0), -12)))
        concha = S.mirror_x(S.sphere((0.089, 0.004, -0.008), 0.0085))
        ears = S.subtract(ear, concha, k=0.004)
        h = S.union(h, ears, k=0.006)
        if with_neck:
            neck = S.round_cone((0, 0.026, -0.200), (0, 0.020, -0.060), 0.048, 0.044)
            h = S.union(h, neck, k=0.016)
        return h

    # -------------------------------------------------------------- v2: the rebuilt surgeon head
    def sdf_local_v2(self, with_neck=True, eyes=True):
        """A shorter, fuller figurine face; small nose and ears; eyes in sockets cut to the eyeball."""
        E = S.ellipsoid
        cr = E((0, 0.010, 0.030), (0.078, 0.094, 0.092))
        fh = E((0, -0.026, 0.044), (0.064, 0.066, 0.060))
        mid = E((0, -0.036, -0.018), (0.058, 0.060, 0.060))
        jaw = E((0, -0.028, -0.062), (0.050, 0.056, 0.034))
        chin = E((0, -0.072, -0.084), (0.020, 0.015, 0.016))
        cheek = S.mirror_x(E((0.034, -0.060, -0.026), (0.026, 0.024, 0.026)))
        h = S.union(cr, fh, k=0.04)
        h = S.union(h, mid, k=0.03)
        h = S.union(h, jaw, k=0.035)
        h = S.union(h, chin, k=0.03)
        h = S.union(h, cheek, k=0.03)
        ec, er = self.eye_c, self.eye_r
        br = S.chain([np.array([-0.048, ec[1] + 0.001, ec[2] + 0.019]), np.array([-0.014, ec[1] - 0.012, ec[2] + 0.021]),
                      np.array([0.014, ec[1] - 0.012, ec[2] + 0.021]), np.array([0.048, ec[1] + 0.001, ec[2] + 0.019])],
                     [0.0055, 0.0068, 0.0068, 0.0055])
        h = S.union(h, br, k=0.016)
        # a small nose
        bridge = S.round_cone((0, -0.084, 0.016), (0, -0.099, -0.014), 0.0055, 0.0095)
        wings = S.mirror_x(S.sphere((0.0088, -0.090, -0.019), 0.0062))
        h = S.union(h, S.union(bridge, wings, k=0.008), k=0.009)
        # lips and the mouth line between them
        lu = E((0, -0.089, -0.0405), (0.018, 0.008, 0.0060))
        ll = E((0, -0.086, -0.0510), (0.016, 0.008, 0.0065))
        h = S.union(h, lu, k=0.009)
        h = S.union(h, ll, k=0.009)
        mouth = S.chain([np.array([-0.0195, -0.0885, -0.0440]), np.array([-0.009, -0.0955, -0.0458]),
                         np.array([0.009, -0.0955, -0.0458]), np.array([0.0195, -0.0885, -0.0440])], [0.0010, 0.0014, 0.0014, 0.0010])
        h = S.subtract(h, mouth, k=0.0018)
        # eyes: a spherical socket exactly round the ball, then lids as a shell on that same sphere
        if eyes:
            ball = S.mirror_x(S.sphere(ec, er + self.gap))
            sock = lambda P: np.maximum(ball(P), self.eye_opening(P)[0] - 0.0004)
            h = S.subtract(h, sock, k=0.0015)
            h = S.union(h, self.lids_v2(), k=0.0020)
        # ears: a flat plate blended into the side of the head, a rolled rim round the back and top,
        # a lobe, and a shallow bowl in the middle
        h = S.union(h, S.mirror_x(self.ear_v2()), k=0.009)
        if with_neck:
            neck = S.round_cone((0, 0.024, -0.190), (0, 0.016, -0.055), 0.046, 0.043)
            h = S.union(h, neck, k=0.016)
        return h

    def ear_v2(self):
        x0, y0, z0 = 0.0745, 0.012, -0.006
        R = S.rot((1, 0, 0), -10)
        plate = S.ellipsoid((x0, y0, z0), (0.0065, 0.0135, 0.0205), R)
        lobe = S.ellipsoid((x0 - 0.0012, y0 - 0.002, z0 - 0.017), (0.0050, 0.0062, 0.0068))
        root = S.ellipsoid((x0 - 0.004, y0 - 0.003, z0 - 0.010), (0.0055, 0.0085, 0.0150))

        def rim(P):
            # an oval ring (taller than wide) standing off the head, kept only round the back and top
            Q = (P - np.array([x0 + 0.0045, y0 + 0.001, z0 + 0.002])) @ R
            u, v = Q[:, 1], Q[:, 2] / 1.55
            q = np.sqrt(u * u + v * v) - 0.0112
            d = np.sqrt(q * q + Q[:, 0] ** 2) - 0.0026
            keep = -(u + 0.0045)                     # the front of the ring is open
            return S.smax(d, keep, 0.003)
        ear = S.union(plate, lobe, k=0.006)
        ear = S.union(ear, root, k=0.006)
        ear = S.union(ear, rim, k=0.004)
        bowl = S.ellipsoid((x0 + 0.0072, y0 - 0.0005, z0 - 0.002), (0.0040, 0.0062, 0.0098), R)
        return S.subtract(ear, bowl, k=0.0025)

    def eye_opening(self, L):
        """Signed distance-ish (metres) to the almond opening of the eye on the socket sphere: negative
        inside the opening. L head-local; left eye frame (use |x|)."""
        ec, er = self.eye_c, self.eye_r
        Q = L.copy()
        Q[:, 0] = np.abs(Q[:, 0])
        d = Q - ec
        ax = np.arctan2(d[:, 0], -d[:, 1])          # + towards the outer corner
        az = np.arctan2(d[:, 2], -d[:, 1])          # + up
        Ax, Az = 0.70, 0.46 * self.V['eye_open'] / 0.62
        u = (ax - 0.04) / Ax
        zc = 0.03 + 0.10 * ax                       # the outer corner sits a little higher
        az_half = Az * (1.0 - 0.45 * u * u)
        v = (az - zc) / np.maximum(az_half, 0.02)
        val = np.sqrt(u * u + v * v)
        return (val - 1.0) * 0.30 * (er + self.gap), d

    def lids_v2(self):
        ec, er, gap, t = self.eye_c, self.eye_r, self.gap, self.lid_t

        def f(P):
            Q = P.copy()
            Q[:, 0] = np.abs(Q[:, 0])
            o, d = self.eye_opening(P)
            r = np.linalg.norm(Q - ec, axis=1)
            # a whole shell round the ball (its back half is buried in the head), open only at the almond
            shell = np.maximum(r - (er + gap + t), (er + gap) - r)
            return S.smax(shell, -o, 0.0012)
        return f

    def lids(self):
        """Upper and lower lids: thick shells round the eyeball, cut to leave an almond opening."""
        V = self.V
        ec, er = self.eye_c, self.eye_r
        op = V['eye_open']
        t = 0.0032
        ball = S.sphere(ec, er + t)
        inner = S.sphere(ec, er + 0.0004)
        sh = S.subtract(ball, inner)
        # opening: the region between two tilted curved planes in front of the eye
        up_z = ec[2] + 0.0025 + 0.0060 * op
        lo_z = ec[2] - 0.0035 - 0.0035 * op

        def upper(P):
            dx = (P[:, 0] - ec[0]) / 0.018
            z = up_z - 0.0060 * dx * dx + 0.0015 * dx
            return z - P[:, 2]            # inside (negative) above the lid line
        def lower(P):
            dx = (P[:, 0] - ec[0]) / 0.018
            z = lo_z + 0.0030 * dx * dx
            return P[:, 2] - z            # inside below the lid line
        front = lambda P: -(P[:, 1] - (ec[1] + 0.004))     # only the front of the ball
        cut = lambda P: np.minimum(upper(P), lower(P))
        lid = S.intersect(S.intersect(sh, cut), lambda P: np.maximum(-front(P) - 0.02, -1))

        def f(P):
            Q = P.copy()
            Q[:, 0] = np.abs(Q[:, 0])
            return lid(Q)
        return f

    def sdf(self, with_neck=True):
        fl = self.sdf_local(with_neck)
        return lambda P: fl(self.local(P)) * self.hs

    # -------------------------------------------------------------- paint
    def paint_skin(self, P, graft=False):
        """Vertex colours (linear) and roughness for the head skin."""
        V = self.V
        L = self.local(P)
        x, y, z = L[:, 0], L[:, 1], L[:, 2]
        base = srgb(V['skin'])
        col = np.tile(base, (len(P), 1))
        n = S.fbm(P, 18.0, V['seed'], 3)
        col *= (0.96 + 0.08 * n)[:, None]
        if V['outfit'] == 'gown':
            blot = smooth01((S.fbm(P, 9.0, 8, 3) - 0.52) / 0.1)
            col = mix(col, srgb((0.50, 0.46, 0.44)), np.clip(blot * 0.45, 0, 1))
            vein = smooth01(1 - np.abs(S.fbm(P, 20.0, 13, 3) - 0.5) / 0.012) * smooth01((z - 0.02) / 0.03) * smooth01((np.abs(x) - 0.04) / 0.02)
            col = mix(col, srgb((0.46, 0.50, 0.56)), np.clip(vein * 0.22, 0, 1))
        # warmth: cheeks, nose tip, ears
        fl = srgb(V['flush'])
        ec = self.eye_c
        cheek = np.exp(-(((np.abs(x) - 0.043) / 0.020) ** 2 + ((y + 0.074) / 0.03) ** 2 + ((z + 0.022) / 0.018) ** 2))
        nt = self.nose_tip
        nose = np.exp(-((x / 0.012) ** 2 + ((y - nt[0]) / 0.010) ** 2 + ((z - nt[1]) / 0.012) ** 2))
        ear = smooth01((np.abs(x) - 0.072) / 0.010) * (np.abs(z) < 0.04)
        warm = np.clip(0.45 * cheek + 0.35 * nose + 0.40 * ear, 0, 1)
        col = mix(col, fl, warm)
        # lips
        mz = self.mouth_z
        lip = np.exp(-((x / 0.018) ** 4 + ((z - mz) / 0.0070) ** 2)) * (y < mz * 0 - 0.082)
        col = mix(col, srgb(V['lip']), np.clip(lip * 0.6, 0, 1))
        mline = np.exp(-((x / 0.019) ** 6 + ((z - mz + 0.0006) / 0.0014) ** 2)) * (y < -0.084)
        col = mix(col, srgb(V['lip']) * 0.35, np.clip(mline * 0.8, 0, 1))
        # sunken, bruised eyes on the sick
        sick = 1.0 if V['outfit'] == 'gown' else 0.0
        under = np.exp(-(((np.abs(x) - ec[0]) / 0.016) ** 2 + ((z - ec[2] + 0.012) / 0.008) ** 2)) * (y < -0.05)
        col = mix(col, srgb((0.40, 0.33, 0.36)), np.clip(under * (0.55 * sick + 0.12), 0, 1))
        if sick:
            inside = np.exp(-((x / 0.016) ** 2 + ((z + 0.056) / 0.006) ** 2)) * (y > -0.100) * (y < -0.080)
            col = mix(col, srgb((0.16, 0.06, 0.06)), np.clip(inside * 1.2, 0, 1))
            rim = np.exp(-(((np.abs(x) - ec[0]) / 0.014) ** 2 + ((z - ec[2] + 0.0075) / 0.0028) ** 2)) * (y < ec[1] + 0.004)
            col = mix(col, srgb((0.62, 0.30, 0.30)), np.clip(rim * 0.8, 0, 1))
        # brows: painted soft bars
        bx = np.abs(x)
        bz = ec[2] + 0.021 + 0.004 * np.sin((bx - 0.014) / 0.036 * math.pi) - 0.004 * ((bx - 0.012) / 0.04)
        brow = smooth01(1 - np.abs(z - bz) / 0.0045) * smooth01((bx - 0.010) / 0.006) * smooth01((0.058 - bx) / 0.008) * (y < -0.05)
        col = mix(col, srgb(V['hair']), np.clip(brow * 0.92 * min(1.0, V['brow']), 0, 1))
        # hair: painted cap of hair on the scalp (surgeons: the part below the cap; balding: a fringe)
        # bald: a faint cooler, shinier scalp
        scalp = smooth01((z - 0.045) / 0.03)
        col = mix(col, col * np.array([0.97, 0.97, 1.0]), scalp)
        # lash line: dark edge where the lids meet the eye
        er = self.eye_r
        if self.v2:
            o, d = self.eye_opening(L)
            r = np.linalg.norm(d, axis=1)
            near = np.abs(r - (er + self.gap + self.lid_t * 0.5)) < self.lid_t * 1.6
            lash = smooth01(1 - np.abs(o) / 0.0016) * near * (d[:, 2] > -0.002) * (d[:, 1] < -0.004)
            col = mix(col, np.array([0.03, 0.016, 0.012]), np.clip(lash * 0.9, 0, 1))
        else:
            dx, dy, dz = bx - ec[0], y - ec[1], z - ec[2]
            de = np.sqrt(dx * dx + dy * dy + dz * dz)
            lash = smooth01(1 - np.abs(de - (er + 0.0015)) / 0.0022) * (dz > 0.0005) * (dy < -0.004)
            col = mix(col, np.array([0.02, 0.012, 0.01]), np.clip(lash * 0.9, 0, 1))
        rough = np.full(len(P), 0.55) - 0.12 * lip - 0.12 * scalp
        if graft:
            # the grafted (left, +X) eye: angry pink skin round a stitched socket, a faint bruise
            gx, gz = (x - ec[0]) / INC_RX, (z - ec[2]) / INC_RZ
            gd = np.sqrt(gx * gx + gz * gz)          # 1 on the incision
            front = (y < ec[1] + 0.012) & (x > 0)
            swell = np.exp(-((gd - 1.0) / 0.35) ** 2) * front
            cut = np.exp(-((gd - 1.0) / 0.045) ** 2) * front
            bruise = np.exp(-((gd - 1.3) / 0.45) ** 2) * front
            col = mix(col, srgb((0.52, 0.36, 0.44)), np.clip(bruise * 0.40, 0, 1))
            col = mix(col, srgb((0.78, 0.42, 0.40)), np.clip(swell * 0.55, 0, 1))
            col = mix(col, srgb((0.34, 0.06, 0.07)), np.clip(cut * 0.95, 0, 1))
            rough = rough - 0.25 * cut
        return col, rough

    def hair_mask(self, L):
        V = self.V
        x, y, z = L[:, 0], L[:, 1], L[:, 2]
        if V['outfit'] == 'gown':
            # balding: a horseshoe fringe round the back and sides, thinning to nothing on top
            band = smooth01((0.055 - z) / 0.012) * smooth01((z + 0.018) / 0.010)
            back = smooth01((y + 0.010) / 0.025)
            side = smooth01((np.abs(x) - 0.060) / 0.012) * smooth01((y + 0.030) / 0.02)
            return np.clip(band * np.maximum(back, side) * 0.85, 0, 1)
        # under a surgical cap: sideburns and the nape
        side = smooth01((np.abs(x) - 0.066) / 0.008) * smooth01((0.040 - z) / 0.008) * smooth01((z + 0.012) / 0.008) * smooth01((0.012 - y) / 0.010) * smooth01((y + 0.030) / 0.01)
        nape = smooth01((y - 0.050) / 0.012) * smooth01((0.03 - z) / 0.01) * smooth01((z + 0.050) / 0.012)
        return np.clip(np.maximum(side, nape), 0, 1)

    # -------------------------------------------------------------- the cap
    def cap_sdf(self):
        """A tie-back surgical cap: a puffy shell over the cranium, a band, two tails at the back."""
        cr = S.ellipsoid((0, 0.008, 0.036), (0.080, 0.097, 0.094))
        fh = S.ellipsoid((0, -0.028, 0.046), (0.064, 0.066, 0.060))
        dome = S.union(cr, fh, k=0.04)

        def puff(P):
            return 0.0055 + 0.0025 * (S.fbm(P, 30.0, 7, 2) - 0.5)
        solid = S.displace(dome, puff)

        def edge(P):
            # the cap's lower edge: forehead high at the front, down over the ears to the nape
            y, z = P[:, 1], P[:, 2]
            zc = 0.044 + 0.000 * y - 0.30 * np.maximum(y + 0.02, 0) ** 1.0 * 0.0 - 0.52 * np.clip(y + 0.050, 0, 0.15)
            return zc - z
        cap = S.intersect(solid, edge, k=0.003)
        band = S.intersect(S.displace(dome, lambda P: np.full(len(P), 0.0085)), lambda P: np.maximum(edge(P) - 0.001, -(edge(P) + 0.011)), k=0.002)
        tails = S.union(S.round_cone((0.010, 0.100, -0.010), (0.030, 0.118, -0.075), 0.0055, 0.004),
                        S.round_cone((-0.006, 0.100, -0.008), (-0.014, 0.122, -0.070), 0.0055, 0.0042), k=0.004)
        knot = S.ellipsoid((0.002, 0.100, -0.004), (0.012, 0.008, 0.009))
        f = S.union(cap, band, k=0.004)
        f = S.union(f, knot, k=0.006)
        f = S.union(f, tails, k=0.006)
        return lambda P: f(self.local(P)) * self.hs


# ====================================================================== limbs
def arm_points(sk, side=1):
    m = (lambda p: p) if side > 0 else sk.mirror
    J = sk.J
    return m(J['shoulder']), m(J['elbow']), m(J['wrist']), m(J['knuckle'])


def arm_sdf(sk, side=1, girth=1.0, from_t=0.0):
    sh, el, wr, kn = arm_points(sk, side)
    g = girth * sk.s
    d1 = el - sh
    start = sh + d1 * from_t
    upper_mid = sh + d1 * 0.45
    fore_mid = el + (wr - el) * 0.35
    pts = [start, upper_mid, el, fore_mid, wr]
    rad = [0.046 * g, 0.042 * g, 0.034 * g, 0.037 * g, 0.027 * g]
    return S.chain(pts, rad), (sh, el, wr, kn)


def hand_sdf(sk, side=1, scale=1.12, slim_wrist=False):
    """A chunky, simple hand: a rounded palm block and fingers as tapered chains through the finger bones."""
    m = (lambda p: p) if side > 0 else sk.mirror
    B = sk.bones
    sfx = '.L'
    wr, kn = m(sk.J['wrist']), m(sk.J['knuckle'])
    ax = kn - wr
    L = np.linalg.norm(ax)
    ax /= L
    # the palm's side axis: from the pinky base to the index base
    i1, p1 = m(B['index1' + sfx][0]), m(B['pinky1' + sfx][0])
    sa = i1 - p1
    sa -= ax * (sa @ ax)
    sa /= np.linalg.norm(sa)
    na = np.cross(ax, sa)
    R = np.stack([ax, sa, na], axis=1)
    c = wr + ax * L * 0.52
    palm = S.rbox(c, (L * 0.58, 0.040 * scale, 0.0135 * scale), 0.011, R)
    wrist = S.capsule(wr - ax * 0.02, wr + ax * 0.02, (0.0225 if slim_wrist else 0.026) * sk.s)
    parts = [palm]
    for fname, r0 in (('index', 0.0092), ('middle', 0.0096), ('ring', 0.0091), ('pinky', 0.0080), ('thumb', 0.0105)):
        b1 = B[fname + '1' + sfx]
        b2 = B[fname + '2' + sfx]
        b3 = B[fname + '3' + sfx]
        pts = [m(b1[0]), m(b1[1]), m(b2[1]), m(b3[1])]
        # pull the finger ends a hair past the bone tip, taper the tip
        tip = pts[-1] + (pts[-1] - pts[-2]) * 0.15
        pts[-1] = tip
        r = [r0 * scale * 1.08, r0 * scale, r0 * scale * 0.92, r0 * scale * 0.80]
        parts.append(S.chain(pts, r))
    f = S.union(palm, parts[1], k=0.010)
    for p in parts[2:]:
        f = S.union(f, p, k=0.007 if p is not parts[-1] else 0.014)
    f = S.union(f, wrist, k=0.008 if slim_wrist else 0.016)
    return f


def leg_sdf(sk, side=1, girth=1.0, from_t=0.0, to_ankle=True):
    m = (lambda p: p) if side > 0 else sk.mirror
    J = sk.J
    hip, knee, ank = m(J['hip']), m(J['knee']), m(J['ankle'])
    g = girth * sk.s
    start = hip + (knee - hip) * from_t
    pts = [start, hip + (knee - hip) * 0.5, knee, knee + (ank - knee) * 0.32, ank]
    rad = [0.075 * g, 0.062 * g, 0.048 * g, 0.052 * g, 0.034 * g]
    return S.chain(pts, rad)


def foot_sdf(sk, side=1, puff=0.0):
    m = (lambda p: p) if side > 0 else sk.mirror
    J = sk.J
    ank, ball, toe = m(J['ankle']), m(J['ball']), m(J['toe'])
    heel = ank + np.array([0, 0.040, -0.050]) * sk.s
    heel[2] = 0.030
    b = ball.copy(); b[2] = 0.028
    t = toe.copy(); t[2] = 0.026
    f = S.union(S.round_cone(heel, b, 0.030 + puff, 0.036 + puff), S.round_cone(b, t, 0.036 + puff, 0.030 + puff), k=0.02)
    f = S.union(f, S.round_cone(ank, heel + np.array([0, -0.01, 0.01]), 0.036 + puff, 0.032 + puff), k=0.03)
    return S.intersect(f, lambda P: -P[:, 2])   # flat sole at z 0


# ====================================================================== whole characters
class Part:
    def __init__(self, name, mat, f, lo, hi, h, paint=None, rigid=None, project=2, mask=None):
        self.name, self.mat, self.f, self.lo, self.hi, self.h = name, mat, f, lo, hi, h
        self.paint = paint
        self.mask = mask          # f(P) -> (N, 3) shader mask channels, or None
        self.rigid = rigid
        self.project = project


def cloth_paint(V, P, base, grime=0.3, blood=0.0, seed=1, extra=None):
    col = np.tile(srgb(base), (len(P), 1))
    n = S.fbm(P, 9.0, seed, 3)
    col *= (0.90 + 0.18 * n)[:, None]
    lowz = smooth01((0.9 - P[:, 2]) / 0.8)
    g = smooth01((S.fbm(P, 5.0, seed + 3, 3) - 0.55 + 0.25 * lowz * grime) / 0.12) * grime
    col = mix(col, col * np.array([0.62, 0.58, 0.46]), np.clip(g, 0, 1))
    if blood > 0:
        b = smooth01((S.fbm(P, 11.0, seed + 9, 3) - 0.66) / 0.05) * blood
        col = mix(col, srgb((0.30, 0.04, 0.03)), np.clip(b, 0, 1))
    rough = np.full(len(P), 0.9)
    if extra:
        col, rough = extra(P, col, rough)
    return col, rough


def build(name, body):
    """Returns (parts, info): every Part to mesh and the numbers the Blender side needs."""
    V = get(name)
    sk = Skel(body)
    s = sk.s
    head = Head(V, sk)
    parts = []
    H = V['height']
    hl = head.world((-0.14, -0.16, -0.23))
    hh = head.world((0.14, 0.15, 0.15))

    # -------------------------------------------------------------- head and neck (+ upper chest in the V)
    hsdf = head.sdf(True)
    if V['outfit'] == 'scrubs':
        chest = trunk_sdf(s, V['girth'], grow=-0.004, z_lo=1.24 * s, z_hi=1.50 * s, shoulders=V['shoulders'])
        chest = S.intersect(chest, lambda P: np.maximum(np.abs(P[:, 0]) - 0.11 * s, P[:, 1] - 0.03), k=0.02)
        hsdf = S.union(hsdf, chest, k=0.03)
        hl = np.minimum(hl, np.array([-0.2, -0.13, 1.19 * s]))
        hh = np.maximum(hh, np.array([0.2, 0.13, H]))
    else:
        hl = np.minimum(hl, np.array([-0.2, -0.13, 1.30 * s]))
        chest = trunk_sdf(s, V['girth'], grow=-0.004, z_lo=1.36 * s, z_hi=1.50 * s)
        chest = S.intersect(chest, lambda P: np.abs(P[:, 0]) - 0.10 * s, k=0.02)
        hsdf = S.union(hsdf, chest, k=0.03)
    parts.append(Part('Head', SKIN, hsdf, hl, hh, 0.0011, paint=lambda P: head.paint_skin(P, V['graft'])))

    # eyes: separate balls in the sockets
    for side, tag in ((1, 'L'), (-1, 'R')):
        c, r = head.eye_world(side)
        kind = 'hive' if (V['outfit'] == 'gown' or (V['graft'] and side == 1)) else 'human'
        parts.append(Part('Eye_' + tag, EYE, S.sphere(c, r), c - r * 1.3, c + r * 1.3, r / 40.0,
                          paint=(lambda P, c=c, r=r, kind=kind: eye_paint(V, P, c, r, kind)), rigid='head'))

    if V['graft']:
        parts.append(Part('Stitches', THREAD, stitches_sdf(head), head.world((0.0, -0.11, -0.02)), head.world((0.07, -0.05, 0.05)), 0.0005,
                          paint=lambda P: (np.tile(srgb((0.06, 0.04, 0.05)), (len(P), 1)), np.full(len(P), 0.5)), rigid='head'))

    if V['outfit'] == 'scrubs':
        _scrubs(V, sk, parts)
    else:
        _gown(V, sk, parts)
    return parts, {'V': V, 'sk': sk, 'head': head}


def eye_paint(V, P, c, r, kind):
    d = (P - c) / r
    fwd = -d[:, 1]                      # 1 at the front of the ball
    sclera = srgb((0.93, 0.91, 0.87)) if kind == 'human' else srgb((0.82, 0.80, 0.66))
    col = np.tile(sclera, (len(P), 1))
    # a hint of pink at the edges of the white
    col = mix(col, srgb((0.86, 0.66, 0.62)), np.clip((0.55 - fwd) * 0.8, 0, 0.5))
    if kind == 'human':
        iris = smooth01((fwd - 0.80) / 0.03)
        ring = np.exp(-((fwd - 0.83) / 0.02) ** 2)
        ic = srgb(V['iris'])
        col = mix(col, ic * (0.8 + 0.4 * S.fbm(P, 2500.0, 3, 2))[:, None], iris)
        col = mix(col, ic * 0.35, np.clip(ring * 0.6, 0, 1))
        pupil = smooth01((fwd - 0.955) / 0.008)
        col = mix(col, np.array([0.005, 0.005, 0.006]), pupil)
        rough = np.full(len(P), 0.05)
    else:
        # filmed over: a milky, veined ball; a small grey pupil set off-centre, and a second one drifting
        milk = srgb((0.84, 0.82, 0.62))
        col = mix(col, milk, smooth01((fwd - 0.70) / 0.1))
        vein = smooth01(1 - np.abs(S.fbm(P, 900.0, 5, 3) - 0.5) / 0.03) * np.clip(0.8 - fwd, 0, 1)
        col = mix(col, srgb((0.62, 0.30, 0.28)), np.clip(vein * 0.8, 0, 1))
        for (ox, oz, pr) in ((0.05, -0.05, 0.26), (-0.36, 0.26, 0.14)):
            q = np.stack([d[:, 0] - ox, d[:, 2] - oz], 1)
            pd = np.linalg.norm(q, axis=1)
            p = smooth01((pr - pd) / 0.05) * (fwd > 0.3)
            col = mix(col, srgb((0.22, 0.22, 0.20)), np.clip(p * 0.85, 0, 1))
        rough = np.full(len(P), 0.18)
    return col, rough


INC_RX, INC_RZ = 0.0225, 0.0175     # the graft incision: an oval round the eye, just outside the lids


def stitches_sdf(head):
    """Black thread stitches round the grafted left eye socket: short bars across a closed incision ring."""
    ec = head.eye_c
    fs = []
    n = 14
    for i in range(n):
        a = 2 * math.pi * i / n + 0.2
        cx, cz = ec[0] + math.cos(a) * INC_RX, ec[2] + math.sin(a) * INC_RZ
        # each stitch crosses the incision ring (radially), lying on the skin
        dx, dz = math.cos(a), math.sin(a)
        p0 = np.array([cx - dx * 0.0026, 0.0, cz - dz * 0.0026])
        p1 = np.array([cx + dx * 0.0026, 0.0, cz + dz * 0.0026])
        fs.append((p0, p1))
    hl = head.sdf_local(False)

    def f(P):
        L = head.local(P)
        best = np.full(len(P), 1e9)
        for p0, p1 in fs:
            # place each stitch just on the skin: find the skin surface in y along the stitch
            for q in (p0, p1):
                pass
            best = np.minimum(best, _stitch_d(L, p0, p1, hl))
        return best * head.hs
    return f


_stitch_cache = {}


def _stitch_d(L, p0, p1, hl):
    key = (tuple(p0), tuple(p1))
    if key not in _stitch_cache:
        pts = []
        for q in (p0, p0 * 0.5 + p1 * 0.5, p1):
            # march from the front toward the face to find the skin
            ys = np.linspace(-0.14, -0.04, 400)
            Q = np.stack([np.full(400, q[0]), ys, np.full(400, q[2])], 1)
            d = hl(Q)
            i = int(np.argmax(d < 0))
            pts.append(np.array([q[0], ys[max(i - 1, 0)] + 0.0006, q[2]]))
        _stitch_cache[key] = pts
    a, m, b = _stitch_cache[key]
    return np.minimum(S.capsule(a, m, 0.00055)(L), S.capsule(m, b, 0.00055)(L))


def _scrubs(V, sk, parts):
    s = sk.s
    g = V['girth']
    col = V['cloth']
    # a rounder trunk than the reference slices: no square shoulders
    T2 = TRUNK.copy()
    T2[:, 4] = np.minimum(T2[:, 4], 2.25)
    # top: follows the body loosely, short sleeves, a V neck
    trunk = trunk_sdf(s, g, grow=0.013, extra=lambda z: 0.007 * smooth01((1.20 * s - z) / (0.3 * s)),
                      z_lo=0.90 * s, z_hi=1.52 * s, table=T2)
    top = trunk
    sleeve_end = {}
    for side in (1, -1):
        sh, el, wr, kn = arm_points(sk, side)
        ax = (el - sh) / np.linalg.norm(el - sh)
        end = sh + (el - sh) * 0.50
        sleeve_end[side] = (end, ax)
        sleeve = S.intersect(S.round_cone(sh + ax * 0.015, end, 0.049 * s * g, 0.049 * s * g), S.plane(ax, end @ ax), k=0.003)
        top = S.union(top, sleeve, k=0.04)

    def vneck(P):
        x, y, z = P[:, 0], P[:, 1], P[:, 2]
        zv = 1.355 * s + np.abs(x) * 2.2
        return np.maximum(zv - z, y - 0.0)
    top = S.subtract(top, vneck, k=0.006)
    top = S.subtract(top, S.capsule((0, 0.02, 1.47 * s), (0, 0.02, 1.62 * s), 0.058 * s), k=0.008)

    def top_extra(P, c, r):
        band = (np.abs(P[:, 2] - 0.912 * s) < 0.011).astype(float)
        for side in (1, -1):
            e, ax = sleeve_end[side]
            band = np.maximum(band, ((np.abs((P - e) @ ax + 0.010) < 0.010) & (P[:, 0] * side > 0.12)).astype(float))
        c = mix(c, c * 0.82, band)
        pocket = (np.abs(P[:, 0] - 0.085 * s) < 0.045) & (np.abs(P[:, 2] - 1.29 * s) < 0.05) & (P[:, 1] < 0)
        edge = pocket & ((np.abs(np.abs(P[:, 0] - 0.085 * s) - 0.045) < 0.003) | (np.abs(P[:, 2] - 1.335 * s) < 0.003))
        c = mix(c, c * 0.72, edge.astype(float))
        return c, r
    parts.append(Part('Top', CLOTH, top, np.array([-0.45, -0.2, 0.85 * s]), np.array([0.45, 0.2, 1.60 * s]), 0.0024,
                      paint=lambda P: cloth_paint(V, P, col, grime=0.35, blood=0.35, seed=3, extra=top_extra)))

    # bare arms and hands
    skin = srgb(V['skin'])
    flush = srgb(V['flush'])

    def arm_paint(P):
        c = np.tile(skin, (len(P), 1)) * (0.96 + 0.08 * S.fbm(P, 16.0, 4, 3))[:, None]
        # warmer hands (knuckles and fingertips flush a little)
        hand = smooth01((1.10 * s - P[:, 2]) / 0.08)
        c = mix(c, flush, np.clip(hand * 0.30, 0, 1))
        return c, np.full(len(P), 0.52)
    for side, tag in ((1, 'L'), (-1, 'R')):
        arm, (sh, el, wr, kn) = arm_sdf(sk, side, g * 0.98, from_t=0.22)
        # forearm narrows smoothly into the wrist, no step where the hand begins
        arm = S.union(arm, S.round_cone(el + (wr - el) * 0.35, wr + (wr - el) / np.linalg.norm(wr - el) * 0.012, 0.035 * s, 0.024 * s), k=0.01)
        hand = hand_sdf(sk, side, 1.06, slim_wrist=True)
        f = S.union(arm, hand, k=0.008)
        lo = np.minimum(np.minimum(sh, kn), wr) - 0.1
        hi = np.maximum(np.maximum(sh, kn), wr) + 0.1
        parts.append(Part('Arm_' + tag, SKIN, f, lo, hi, 0.0012, paint=arm_paint))

    # trousers: a short pelvis, legs tapering from thigh to ankle, crotch kept high
    pel = trunk_sdf(s, g, grow=0.006, z_lo=0.80 * s, z_hi=0.985 * s, table=T2)
    pants = pel
    for side in (1, -1):
        m = (lambda p: p) if side > 0 else sk.mirror
        hip, knee, ank = m(sk.J['hip']), m(sk.J['knee']), m(sk.J['ankle'])
        pts = [hip + np.array([0, 0, 0.02]), hip + (knee - hip) * 0.45, knee, knee + (ank - knee) * 0.5, ank]
        rad = [0.084 * s, 0.074 * s, 0.062 * s, 0.058 * s, 0.054 * s]
        pants = S.union(pants, S.chain(pts, rad), k=0.035)
    hem_z = 0.105 * s
    pants = S.intersect(pants, lambda P: hem_z - P[:, 2], k=0.004)
    parts.append(Part('Pants', CLOTH, pants, np.array([-0.3, -0.2, 0.08]), np.array([0.3, 0.2, 1.05 * s]), 0.0026,
                      paint=lambda P: cloth_paint(V, P, np.array(col) * 0.92, grime=0.5, seed=4)))
    if V.get('gash'):
        _gash_parts(V, sk, parts, T2, arm_paint)
    # clogs
    for side, tag in ((1, 'L'), (-1, 'R')):
        f = foot_sdf(sk, side, puff=0.012)
        f = S.union(f, S.capsule(sk.J['ankle'] * np.array([side, 1, 1]) + np.array([0, 0, 0.02]), sk.J['ankle'] * np.array([side, 1, 1]) + np.array([0, 0, 0.09]), 0.040), k=0.03)
        c = sk.J['ankle'] * np.array([side, 1, 1])

        def clog_paint(P):
            col_ = np.tile(srgb((0.10, 0.11, 0.13)), (len(P), 1))
            sole = smooth01((0.018 - P[:, 2]) / 0.004)
            col_ = mix(col_, srgb((0.30, 0.30, 0.30)), sole)
            return col_, np.full(len(P), 0.35) + 0.4 * sole
        parts.append(Part('Shoe_' + tag, SHOE, f, c + np.array([-0.1, -0.3, -0.1]), c + np.array([0.1, 0.12, 0.1]), 0.0016, paint=clog_paint))


# the players' belly gash (scripts/downed/player_body.gd, the player table's stitches step)
GASH_TH = -0.34          # azimuth: the character's right of the navel
GASH_Z = 1.110           # centre height (x s)
GASH_HALF = 0.095        # half length (x s)
Z_ROLL = 1.262           # where the scrub top rolls up to (x s)
LAST_GASH = {}           # variant -> (centre, normal) of the gash, for the exporter


def gash_frame(sk, surf_f):
    """Centre, outward normal and the down direction of the gash on the belly skin surface."""
    s = sk.s
    z = GASH_Z * s
    d = np.array([math.sin(GASH_TH), -math.cos(GASH_TH), 0.0])
    ts = np.linspace(0.30, 0.0, 600)
    Q = np.stack([d[0] * ts, 0.012 * s + d[1] * ts, np.full(len(ts), z)], 1)
    i = int(np.argmax(surf_f(Q) < 0))
    c = Q[max(i - 1, 0)]
    g = S.gradient(surf_f, c[None, :], 0.001)[0]
    n = g / np.linalg.norm(g)
    return c, n, np.array([0.0, 0.0, -1.0])


def _gash_parts(V, sk, parts, T2, skin_paint):
    """Belly skin under the top (its own piece, Human_GashSkin, with the GashOpen shape made at export),
    and the rolled-up hem (Human_TopRolled) shown when the lower top is hidden."""
    s = sk.s
    g = V['girth']
    belly = trunk_sdf(s, g, grow=-0.002, z_lo=0.93 * s, z_hi=1.31 * s, table=T2)
    belly = S.intersect(belly, lambda P: P[:, 1] - 0.075, k=0.02)
    c, n, down = gash_frame(sk, belly)
    LAST_GASH[V['name']] = (c, n)

    def gash_mask(P):
        # G = the gash: a slit the length of the wound, widest in the middle
        rel = P - c
        t = rel @ down
        side = rel - np.outer(t, down)
        side -= np.outer(side @ n, n)
        w = np.linalg.norm(side, axis=1)
        along = np.clip(1.0 - (t / (GASH_HALF * s)) ** 2, 0.0, 1.0)
        g_ = smooth01(1.0 - w / (0.020 * s * np.sqrt(along) + 1e-4)) * (along > 0)
        out = np.zeros((len(P), 3))
        out[:, 1] = g_
        return out
    parts.append(Part('Belly', SKIN, belly, np.array([-0.26, -0.2, 0.90 * s]), np.array([0.26, 0.12, 1.34 * s]), 0.0020,
                      paint=skin_paint, mask=gash_mask))
    # the rolled hem: a fat band of scrub round the waist at the roll line
    roll = trunk_sdf(s, g, grow=0.026, table=T2, z_lo=0.8 * s, z_hi=1.5 * s)
    band = S.intersect(roll, lambda P: np.abs(P[:, 2] - Z_ROLL * s) - 0.013, k=0.010)
    band = S.displace(band, lambda P: 0.003 * np.sin(np.arctan2(P[:, 0], -P[:, 1]) * 11 + 0.4))
    col = V['cloth']
    parts.append(Part('TopRolled', CLOTH, band, np.array([-0.26, -0.2, Z_ROLL * s - 0.05]), np.array([0.26, 0.2, Z_ROLL * s + 0.05]), 0.0022,
                      paint=lambda P: cloth_paint(V, P, np.array(col) * 0.95, grime=0.3, seed=7),
                      mask=lambda P: np.tile([1.0, 0.0, 0.0], (len(P), 1))))
    return c, n


def _gown(V, sk, parts):
    s = sk.s
    g = V['girth']
    col = V['cloth']
    # the patient gown: one continuous profile from the knees to the shoulders, loose all round
    GOWN = np.array([
        (0.45, 0.190, 0.150, 0.000, 2.2),
        (0.62, 0.184, 0.142, 0.004, 2.3),
        (0.78, 0.176, 0.132, 0.008, 2.4),
        (0.92, 0.172, 0.122, 0.010, 2.5),
    ] + [tuple(r) for r in TRUNK[4:]])
    lower = trunk_sdf(s, g, belly=0.8, grow=0.018, table=GOWN, z_lo=0.45 * s, z_hi=1.52 * s)
    gown = lower
    for side in (1, -1):
        sh, el, wr, kn = arm_points(sk, side)
        ax = (el - sh) / np.linalg.norm(el - sh)
        end = sh + (el - sh) * 0.52
        sleeve = S.intersect(S.round_cone(sh - ax * 0.02, end, 0.056 * s * g, 0.054 * s * g), S.plane(ax, end @ ax), k=0.004)
        gown = S.union(gown, sleeve, k=0.035)

    def hem(P):
        rag = 0.018 * (S.fbm(P * np.array([1, 1, 0]), 22.0, 9, 2) - 0.5)
        tilt = 0.03 * P[:, 0] / 0.2      # tied wrong: hangs lower on the right
        return (0.52 * s + rag - tilt) - P[:, 2]
    gown = S.intersect(gown, hem, k=0.004)
    # neck opening
    gown = S.subtract(gown, S.capsule((0, 0.015, 1.46 * s), (0, 0.015, 1.62 * s), 0.064 * s), k=0.01)
    # a few soft vertical folds
    gown = S.displace(gown, lambda P: 0.004 * np.sin(np.arctan2(P[:, 0], -P[:, 1]) * 9 + 0.6) * smooth01((1.1 * s - P[:, 2]) / 0.3))

    def gown_extra(P, c, r):
        # the washed-out print: small diamonds on a grid
        u = np.arctan2(P[:, 0], -P[:, 1]) * 0.17 / 0.035
        v = P[:, 2] / 0.035
        du = np.abs(((u + v * 0.5) % 1.0) - 0.5)
        dv = np.abs((v % 1.0) - 0.5)
        dia = (du + dv < 0.16).astype(float)
        c = mix(c, c * np.array([0.62, 0.70, 0.78]), dia * 0.7)
        # a stain down the front
        st = smooth01((S.fbm(P, 4.0, 21, 3) - 0.52) / 0.08) * (P[:, 1] < 0)
        c = mix(c, srgb((0.46, 0.40, 0.26)), np.clip(st * 0.55, 0, 1))
        return c, r
    parts.append(Part('Gown', CLOTH, gown, np.array([-0.45, -0.3, 0.45 * s]), np.array([0.45, 0.3, 1.60 * s]), 0.0028,
                      paint=lambda P: cloth_paint(V, P, col, grime=0.8, blood=0.15, seed=31, extra=gown_extra)))
    head = Head(V, sk)
    skin_col = V['skin']

    def body_skin(P):
        col_ = np.tile(srgb(skin_col), (len(P), 1))
        n = S.fbm(P, 14.0, 5, 3)
        col_ *= (0.94 + 0.12 * n)[:, None]
        blot = smooth01((S.fbm(P, 6.0, 8, 3) - 0.55) / 0.1)
        col_ = mix(col_, srgb((0.52, 0.46, 0.46)), np.clip(blot * 0.5, 0, 1))
        vein = smooth01(1 - np.abs(S.fbm(P, 22.0, 13, 3) - 0.5) / 0.018)
        col_ = mix(col_, srgb((0.42, 0.46, 0.52)), np.clip(vein * 0.35, 0, 1))
        # knuckles and hands a little darker and redder
        return col_, np.full(len(P), 0.5)
    # bare arms and hands, bare lower legs
    for side, tag in ((1, 'L'), (-1, 'R')):
        arm, (sh, el, wr, kn) = arm_sdf(sk, side, g * 1.04, from_t=0.15)
        hand = hand_sdf(sk, side, 1.14)
        f = S.union(arm, hand, k=0.012)
        lo = np.minimum(np.minimum(sh, kn), wr) - 0.1
        hi = np.maximum(np.maximum(sh, kn), wr) + 0.1
        parts.append(Part('Arm_' + tag, SKIN, f, lo, hi, 0.0013, paint=body_skin))
        leg = leg_sdf(sk, side, g * 0.97, from_t=0.35)
        foot = foot_sdf(sk, side, puff=0.004)
        lf = S.union(leg, foot, k=0.04)
        hip = sk.J['hip'] * np.array([side, 1, 1])

        def leg_paint(P):
            col_, r = body_skin(P)
            # grip sock: over the foot and up the ankle, slouched
            sock_top = 0.16 + 0.012 * np.sin(np.arctan2(P[:, 0], P[:, 1]) * 3)
            sock = smooth01((sock_top - P[:, 2]) / 0.004)
            scol = srgb((0.58, 0.60, 0.56)) * (0.9 + 0.2 * S.fbm(P, 60.0, 3, 2))[:, None]
            dirt = smooth01((0.05 - P[:, 2]) / 0.05)
            scol = mix(scol, srgb((0.30, 0.27, 0.20)), np.clip(dirt * 0.7, 0, 1))
            dots = ((np.sin(P[:, 0] * 500) * np.sin(P[:, 1] * 500) > 0.8) & (P[:, 2] < 0.008)).astype(float)
            scol = mix(scol, srgb((0.20, 0.30, 0.24)), dots)
            col_ = mix(col_, scol, sock)
            r = r + 0.45 * sock
            return col_, r
        lsock = S.displace(lf, lambda P: 0.0035 * smooth01((0.16 - P[:, 2]) / 0.004) + 0.002 * smooth01(1 - np.abs(P[:, 2] - 0.155) / 0.01))
        parts.append(Part('Leg_' + tag, SKIN, lsock, np.array([side * 0.09 - 0.14, -0.30, -0.01]), np.array([side * 0.09 + 0.14, 0.14, 0.80 * s]), 0.0018, paint=leg_paint))
    # wristband on the left wrist
    wr = sk.J['wrist']
    el = sk.J['elbow']
    ax = (wr - el) / np.linalg.norm(wr - el)
    c = wr - ax * 0.035
    band = S.intersect(S.round_cone(c - ax * 0.011, c + ax * 0.011, 0.031 * s, 0.030 * s), S.union(S.plane(ax, (c + ax * 0.011) @ ax), S.plane(ax, (c + ax * 0.011) @ ax)))
    band = S.intersect(band, S.plane(-ax, -((c - ax * 0.011) @ ax)))
    parts.append(Part('Wristband', CLOTH, band, c - 0.06, c + 0.06, 0.0008,
                      paint=lambda P: (np.tile(srgb((0.86, 0.84, 0.78)), (len(P), 1)), np.full(len(P), 0.5))))
