"""The human body: skeleton, skin surface (trunk, neck and head as one continuous grid), eyes, lids,
ears, arms with hands and fingers, legs. Pure Python + mathutils.

Blender axes: Z up, the character faces -Y, its left side is +X. 1 unit = 1 m, feet at z 0.

The trunk-neck-head skin is a stack of rows. Up to the head centre every row is a horizontal slice:
rays from the body axis outward, hitting a smooth-union signed distance field (trunk slices, neck
capsule, cranium, face mass, jaw, chin). Above the head centre rows are rays from the head centre at
rising elevation up to the crown. Row heights are placed by arc length along several meridians, so
the under-jaw, the shoulder slope and the crown get rows where the surface is nearly horizontal.
Small forms (nose, lips, sockets, brows, clavicles, pecs, navel, scapulae, buttocks) are Gaussian
displacements along the ray after the hit.
"""
import math
from mathutils import Vector, Matrix, noise
from hu_mesh import (Part, TAU, smooth01, lerp, clamp, gauss3, pchip, resample, chaikin, frames, arclen,
                     sweep, sell, rotate_towards)

A_POSE_DEG = 47.0       # upper arm angle from vertical in the rest pose
FINGERS = ['index', 'middle', 'ring', 'pinky']


def smin(a, b, k):
    h = max(k - abs(a - b), 0.0) / k
    return min(a, b) - h * h * k * 0.25


def sd_ellipsoid(px, py, pz, c, r):
    qx, qy, qz = (px - c[0]) / r[0], (py - c[1]) / r[1], (pz - c[2]) / r[2]
    k0 = math.sqrt(qx * qx + qy * qy + qz * qz)
    k1 = math.sqrt((qx / r[0]) ** 2 + (qy / r[1]) ** 2 + (qz / r[2]) ** 2)
    if k1 < 1e-9:
        return -min(r)
    return k0 * (k0 - 1.0) / k1


def sd_capsule(p, a, b, r):
    ab = b - a
    t = clamp((p - a).dot(ab) / ab.length_squared, 0.0, 1.0)
    return (p - (a + ab * t)).length - r


class Body:
    def __init__(self, P, res=1):
        self.P, self.res = P, res
        s = self.s = P['height'] / 1.78
        f = self.fem = P['fem']
        g = self.girth = P['girth']
        self.hs = s * P['head_scale'] * lerp(1.0, 0.955, f)
        H = P['height']
        self.HC = Vector((0.0, 0.0, H - 0.130 * self.hs))
        sh = P['shoulders']
        # ------------------------------------------------ joints (left side; right is mirrored)
        J = {}
        J['ankle'] = Vector((lerp(0.090, 0.084, f) * s, 0.022 * s, 0.080 * s))
        J['knee'] = Vector((lerp(0.093, 0.086, f) * s, -0.004 * s, 0.490 * s))
        J['hip'] = Vector((lerp(0.086, 0.094, f) * s, 0.004 * s, 0.915 * s))
        J['ball'] = Vector((J['ankle'].x + 0.004 * s, -0.105 * s, 0.022 * s))
        J['toe'] = Vector((J['ankle'].x + 0.006 * s, -0.185 * s, 0.018 * s))
        J['shoulder'] = Vector((lerp(0.180, 0.160, f) * sh * s, 0.020 * s, 1.446 * s))
        J['clav'] = Vector((0.020 * s, 0.000, 1.438 * s))
        J['neck'] = Vector((0.0, 0.030 * s, 1.470 * s))
        J['headj'] = Vector((0.0, 0.020 * s, self.HC.z - 0.058 * self.hs))
        J['crown'] = Vector((0.0, 0.010 * s, H))
        J['hips'] = Vector((0.0, 0.010 * s, 0.930 * s))
        J['spine'] = Vector((0.0, 0.018 * s, 1.070 * s))
        J['chest'] = Vector((0.0, 0.020 * s, 1.200 * s))
        J['upperchest'] = Vector((0.0, 0.024 * s, 1.335 * s))
        a = math.radians(A_POSE_DEG)
        dirA = Vector((math.sin(a), 0.03, -math.cos(a))).normalized()
        self.ua_len = lerp(0.292, 0.272, f) * s
        self.fa_len = lerp(0.255, 0.236, f) * s
        self.palm_len = lerp(0.098, 0.090, f) * s
        J['elbow'] = J['shoulder'] + dirA * self.ua_len
        dirF = (Matrix.Rotation(math.radians(-14.0), 3, Vector((0, 0, 1)).cross(dirA).normalized()) @ dirA)
        # bend the forearm forward (towards -Y) a little: rotate about the arm's side axis
        side = dirA.cross(Vector((0, -1, 0))).normalized()
        dirF = (Matrix.Rotation(math.radians(12.0), 3, side) @ dirA).normalized()
        J['wrist'] = J['elbow'] + dirF * self.fa_len
        J['knuckle'] = J['wrist'] + dirF * self.palm_len
        self.dirA, self.dirF = dirA, dirF
        self.J = J
        self.joints = {}        # bone name -> (head, tail) filled by the generators

        # ------------------------------------------------ trunk slice profile
        k = [  # z, rx, ry, cy, n    (male reference, girth 1)
            (0.760, 0.110, 0.085, 0.012, 2.2),
            (0.830, 0.150, 0.103, 0.014, 2.4),
            (0.900, 0.166, 0.110, 0.016, 2.5),
            (0.960, 0.162, 0.104, 0.012, 2.5),
            (1.020, 0.148, 0.097, 0.006, 2.4),
            (1.080, 0.136, 0.091, 0.002, 2.3),
            (1.150, 0.139, 0.093, 0.000, 2.3),
            (1.220, 0.149, 0.099, 0.000, 2.4),
            (1.290, 0.158, 0.104, 0.002, 2.5),
            (1.360, 0.166, 0.104, 0.006, 2.7),
            (1.410, 0.180, 0.100, 0.010, 2.9),
            (1.450, 0.196, 0.092, 0.014, 3.0),
            (1.480, 0.192, 0.082, 0.018, 2.9),
            (1.500, 0.150, 0.070, 0.020, 2.5),
            (1.515, 0.092, 0.060, 0.022, 2.2),
            (1.535, 0.056, 0.052, 0.022, 2.0),
            (1.560, 0.046, 0.046, 0.020, 2.0),
            (1.640, 0.042, 0.044, 0.018, 2.0),
        ]
        belly = P['belly']
        zs, rx, ry, cy, nn = [], [], [], [], []
        for z, x, y, c, n in k:
            fz = 1.0
            # female: narrower shoulders and waist, wider hips
            if f > 0:
                hip_k = math.exp(-((z - 0.90) / 0.09) ** 2)
                waist_k = math.exp(-((z - 1.10) / 0.07) ** 2)
                sho_k = smooth01((z - 1.30) / 0.12) * (1 - smooth01((z - 1.51) / 0.02))
                neck_k = smooth01((z - 1.515) / 0.02)
                fz = 1 + f * (0.08 * hip_k - 0.10 * waist_k - 0.09 * sho_k - 0.12 * neck_k)
            gz = g if z < 1.50 else math.sqrt(g)
            shz = lerp(1.0, P['shoulders'], smooth01((z - 1.30) / 0.14) * (1 - smooth01((z - 1.50) / 0.02)))
            bz = belly * math.exp(-((z - 1.08) / 0.13) ** 2)
            zs.append(z * s)
            rx.append((x * fz * gz * shz + 0.028 * bz) * s)
            ry.append((y * lerp(1.0, fz, 0.6) * gz + 0.020 * bz) * s)
            cy.append(c * s)
            nn.append(n)
        self.T_Z0, self.T_Z1 = zs[0], zs[-1]
        self.T_RX, self.T_RY, self.T_CY, self.T_N = pchip(zs, rx), pchip(zs, ry), pchip(zs, cy), pchip(zs, nn)
        # neck capsule
        self.neck_a = Vector((0.0, 0.026 * s, 1.44 * s))
        self.neck_b = self.HC + Vector((0.0, 0.006, -0.050)) * self.hs
        self.neck_r = lerp(0.052, 0.045, f) * math.sqrt(g) * s
        self._head_feats()
        self._trunk_feats()
        self.GASH_TH = -0.34          # azimuth of the players' belly gash (character's right of the navel)
        self.GASH_Z = 1.110 * s
        self.GASH_HALF = 0.095 * s

    # ================================================================ distance field
    def sd_trunk(self, p):
        z = clamp(p.z, self.T_Z0, self.T_Z1)
        rx, ry, cy, n = self.T_RX(z), self.T_RY(z), self.T_CY(z), self.T_N(z)
        x = abs(p.x) / rx
        y = abs(p.y - cy) / ry
        q = (x ** n + y ** n) ** (1.0 / n)
        d = (q - 1.0) * min(rx, ry)
        dz = max(self.T_Z0 - p.z, p.z - self.T_Z1, 0.0)
        return max(d, dz) if dz > 0 else d

    def sd_head(self, p):
        """Head-local frame: origin at the ear canals, y forward negative, 1.78 m male reference sizes."""
        hs, HC = self.hs, self.HC
        x, y, z = (p.x - HC.x) / hs, (p.y - HC.y) / hs, (p.z - HC.z) / hs
        P = self.P
        f = self.fem
        cr = sd_ellipsoid(x, y, z, (0.0, 0.006, 0.036), (lerp(0.079, 0.076, f), 0.097, 0.094))
        fh = sd_ellipsoid(x, y, z, (0.0, -0.030, 0.045), (0.061, 0.066, 0.062))
        mid = sd_ellipsoid(x, y, z, (0.0, -0.040, -0.024), (lerp(0.051, 0.048, f), 0.058, 0.050))
        mouth = sd_ellipsoid(x, y, z, (0.0, -0.063, -0.061), (0.025, 0.036, 0.026))
        jw = lerp(0.043, 0.055, P['jaw']) - 0.004 * f
        jaw = sd_ellipsoid(x, y, z, (0.0, -0.024, -0.082), (jw, 0.062, 0.026))
        cz = lerp(0.0, 0.009, P['chin'])
        chin = sd_ellipsoid(x, y, z, (0.0, -0.084 - cz, -0.098), (0.018 + 0.007 * P['jaw'] - 0.003 * f, 0.017, 0.016))
        ang = sd_ellipsoid(abs(x), y, z, (jw + 0.002, -0.006, -0.080), (0.011, 0.020, 0.013))
        zyg = sd_ellipsoid(abs(x), y, z, (0.056, -0.040, -0.002), (0.016, 0.034, 0.013))
        h = smin(cr, fh, 0.030)
        h = smin(h, mid, 0.030)
        h = smin(h, mouth, 0.020)
        h = smin(h, jaw, 0.026)
        h = smin(h, chin, 0.030)
        h = smin(h, ang, 0.012)
        h = smin(h, zyg, 0.018)
        return h * hs

    def sd_neck(self, p):
        q = Vector((p.x, (p.y - self.neck_a.y) * 1.04 + self.neck_a.y, p.z))
        return sd_capsule(q, self.neck_a, self.neck_b, self.neck_r)

    def sdf(self, p):
        return smin(smin(self.sd_head(p), self.sd_neck(p), 0.024 * self.s), self.sd_trunk(p), 0.024 * self.s)

    def hit(self, O, d, tmax=0.6, outer=True, off=None):
        """Distance along unit d from O (inside) to the surface. outer: the outermost crossing, marched
        in from tmax, so rays passing under the jaw or the shoulders never stop on a hidden inner surface.
        off(p): inflate the field (garments)."""
        sdf = self.sdf if off is None else (lambda q: self.sdf(q) - off(q))
        if outer:
            t = tmax
            F = sdf(O + d * t)
            prev = tmax
            while t > 0.0:
                if F <= 0.0:
                    lo, hi = t, prev
                    # hi is outside: bisect between inside (lo) and outside (hi)
                    for _ in range(16):
                        mid = (lo + hi) * 0.5
                        if sdf(O + d * mid) >= 0.0:
                            hi = mid
                        else:
                            lo = mid
                    return (lo + hi) * 0.5
                step = min(max(F * 0.7, 0.0010), 0.02)
                prev = t
                t -= step
                F = sdf(O + d * t)
            return 0.0
        t = 0.0
        F = sdf(O)
        if F > 0:
            return 0.0
        while t < tmax:
            step = min(max(abs(F) * 0.6, 0.0012), 0.006)
            t2 = t + step
            F2 = sdf(O + d * t2)
            if F2 >= 0.0:
                lo, hi = t, t2
                for _ in range(14):
                    mid = (lo + hi) * 0.5
                    if sdf(O + d * mid) >= 0.0:
                        hi = mid
                    else:
                        lo = mid
                return (lo + hi) * 0.5
            t, F = t2, F2
        return tmax

    # ================================================================ features
    def _head_feats(self):
        P = self.P
        f = self.fem
        age = P['age']
        rnd = lambda k: noise.noise(Vector((P['face_seed'] * 1.37, k * 3.1, 0.5))) * 0.5
        ey = 0.012
        F = []   # (centre, sigma, amplitude, symmetric, tag) in head-local metres (1.78 reference head)

        def add(c, s, amp, sym=True, tag=''):
            F.append((c, s, amp, sym, tag))
        ew = lerp(0.0305, 0.0335, P['eye_w'])
        self.eye_c = Vector((ew, -0.0800, 0.016))
        self.eye_r = 0.0120
        add((ew - 0.004, -0.090, 0.004), (0.014, 0.03, 0.006), -0.0025, tag='socket')      # tear trough
        add((ew + 0.004, -0.094, 0.034), (0.022, 0.03, 0.0065), lerp(0.001, 0.0055, P['brow']) * lerp(1.0, 0.45, f), tag='brow')
        add((0.0, -0.100, 0.034), (0.011, 0.03, 0.010), 0.002 * (1 - f))                  # glabella
        add((0.012, -0.090, 0.008), (0.006, 0.03, 0.010), -0.003)                          # inner corner hollow
        add((0.052, -0.066, -0.006), (0.016, 0.03, 0.011), lerp(0.003, 0.009, P['cheek']), tag='cheekbone')
        add((0.036, -0.085, -0.020), (0.014, 0.03, 0.014), 0.0035, tag='cheekbone')                          # malar fat pad
        add((0.047, -0.070, -0.045), (0.016, 0.03, 0.018), -(0.005 * max(0.0, 1.10 - P['girth']) * 2.2) * (1 - 0.5 * f))   # hollow cheek
        add((0.064, -0.040, 0.045), (0.012, 0.02, 0.020), -0.004)                          # temple
        add((0.0, -0.098, -0.078), (0.014, 0.03, 0.0045), -0.0022)                         # mentolabial fold
        add((0.0, -0.098, -0.098), (0.013, 0.03, 0.010), 0.002 + 0.002 * P['chin'])       # chin pad
        add((0.026, -0.094, -0.048), (0.006, 0.03, 0.016), -0.0010 * (0.4 + age), tag='nasolabial')
        add((0.027, -0.093, -0.064), (0.005, 0.03, 0.007), -0.0012 * (0.3 + age))          # mouth corner
        add((0.046, -0.050, -0.092), (0.016, 0.03, 0.013), 0.004 * age * P['girth'])       # jowl
        add((0.030, -0.086, 0.001), (0.012, 0.03, 0.004), 0.0015 * (0.5 + age))            # under-eye bag
        self.head_feats = F

    def _trunk_feats(self):
        P = self.P
        s = self.s
        f = self.fem
        T = []

        def add(c, sg, amp, sym=True):
            T.append((Vector(c) * s, Vector(sg) * s, amp * s, sym))
        m = 1 - f
        add((0.080, -0.115, 1.310), (0.050, 0.06, 0.040), 0.010 * m)          # pecs
        add((0.088, -0.110, 1.270), (0.047, 0.06, 0.047), 0.038 * f)          # breasts
        add((0.084, -0.140, 1.250), (0.036, 0.06, 0.030), 0.012 * f)
        add((0.000, -0.105, 1.465), (0.018, 0.05, 0.014), -0.010, False)      # suprasternal notch
        add((0.055, -0.080, 1.458), (0.040, 0.05, 0.007), 0.0045)             # clavicle, medial
        add((0.120, -0.060, 1.462), (0.040, 0.05, 0.007), 0.0040)             # clavicle, lateral
        add((0.075, 0.110, 1.360), (0.040, 0.06, 0.060), 0.010)               # scapulae
        add((0.000, 0.110, 1.200), (0.010, 0.06, 0.230), -0.006, False)       # spine groove
        add((0.070, 0.120, 0.870), (0.055, 0.07, 0.065), 0.022 + 0.02 * f)    # buttocks
        add((0.000, -0.100, 1.030), (0.070, 0.06, 0.130), 0.030 * P['belly'], False)   # paunch
        add((0.000, -0.095, 1.060), (0.090, 0.06, 0.080), 0.018 * P['belly'], False)
        add((0.130, 0.000, 1.000), (0.030, 0.12, 0.060), 0.012 * P['belly'])  # love handles
        add((0.050, -0.105, 1.180), (0.030, 0.04, 0.080), 0.004 * m * (1 - P['belly']))   # abdominals
        add((0.000, -0.090, 1.075), (0.007, 0.05, 0.007), -0.007, False)      # navel
        add((0.040, 0.055, 1.530), (0.012, 0.012, 0.040), 0.0035 * m)         # trapezius into the neck
        add((0.000, -0.052, 1.545), (0.009, 0.02, 0.012), 0.0065 * m, False)  # adam's apple
        self.trunk_feats = T

    def head_disp(self, p, carve=True):
        """Head-local displacement (metres) and masks at world point p."""
        hs = self.hs
        q = (p - self.HC) / hs
        disp = 0.0
        tags = {}
        for c, sg, amp, sym, tag in self.head_feats:
            qx = abs(q.x) if sym else q.x
            g = math.exp(-(((qx - c[0]) / sg[0]) ** 2 + ((q.y - c[1]) / sg[1]) ** 2 + ((q.z - c[2]) / sg[2]) ** 2))
            disp += amp * g
            if tag:
                tags[tag] = max(tags.get(tag, 0.0), g)
        front = smooth01((-q.y - 0.070) / 0.02)
        if front > 0:
            P = self.P
            nl = lerp(0.88, 1.12, P['nose_len'])
            nw = lerp(0.85, 1.20, P['nose_w'])
            ztip = -0.034 * nl
            zroot = 0.020
            # dorsum: a ridge growing from the nasion to the tip
            if ztip - 0.012 < q.z < zroot + 0.012:
                t = clamp((zroot - q.z) / (zroot - ztip), 0.0, 1.0)
                amp = lerp(0.0015, 0.020, t ** 1.25) * lerp(0.8, 1.15, P['nose_bridge'] * 0.6 + 0.4 * nl)
                sx = lerp(0.0062, 0.0095, t) * nw
                fall = 1.0 - smooth01((q.z - zroot) / 0.012)
                under = 1.0 - smooth01((ztip - q.z) / 0.011)
                g = math.exp(-(q.x / sx) ** 2) * fall * under
                disp += amp * g
                tags['nose'] = max(tags.get('nose', 0.0), g * t)
            # tip ball and alae (nostril wings), falling off sharply underneath
            gt = math.exp(-((q.x / (0.0085 * nw)) ** 2) - ((q.z - ztip) / (0.0085 if q.z > ztip else 0.0055)) ** 2)
            disp += 0.006 * gt
            for sx in (1, -1):
                ga = math.exp(-(((q.x - sx * 0.0155 * nw) / 0.0068) ** 2) - ((q.z - ztip + 0.004) / (0.0072 if q.z > ztip - 0.004 else 0.0042)) ** 2)
                disp += 0.0095 * ga
                tags['ala'] = max(tags.get('ala', 0.0), ga)
                gn = math.exp(-(((q.x - sx * 0.0072) / 0.0034) ** 2) - ((q.z - ztip + 0.0085) / 0.0024) ** 2)
                disp -= 0.0045 * gn
                tags['nostril'] = max(tags.get('nostril', 0.0), gn)
            # philtrum and the lips
            lp = lerp(0.6, 1.25, P['lips'])
            mw = 0.0245 * lerp(0.92, 1.08, P['lips'])
            zm = -0.0625
            cx = clamp(abs(q.x) / mw, 0.0, 1.4)
            zc = zm - 0.0025 * cx * cx
            if abs(q.x) < mw * 1.5 and zm - 0.03 < q.z < zm + 0.03:
                corner = smooth01((1.05 - cx) / 0.45) * (1.0 - 0.35 * cx * cx)
                gu = math.exp(-((q.z - zc - 0.0042) / 0.0050) ** 2) * corner
                gl = math.exp(-((q.z - zc + 0.0062) / (0.0056 if q.z > zc - 0.006 else 0.0046)) ** 2) * corner
                disp += 0.0042 * lp * gu + 0.0052 * lp * gl
                gm = math.exp(-((q.z - zc) / 0.0010) ** 2) * smooth01((1.08 - cx) / 0.12)
                disp -= 0.0016 * gm
                tags['lipu'] = gu
                tags['lipl'] = gl
                tags['mouth'] = gm
                ph = math.exp(-(q.x / 0.0042) ** 2 - ((q.z - (zm + 0.013)) / 0.0065) ** 2)
                disp -= 0.0012 * ph
                for sx in (1, -1):
                    disp += 0.0007 * math.exp(-((q.x - sx * 0.0048) / 0.0022) ** 2 - ((q.z - (zm + 0.013)) / 0.0065) ** 2)
            disp *= front
        if carve:
            # eye sockets: a compact carve under the lid shells, zero where the lids end
            for sx in (1, -1):
                ec = self.eye_c
                dx = (q.x - sx * ec.x) / 0.0112
                dz = (q.z - ec.z) / (0.0092 if q.z > ec.z else 0.0075)
                r = math.sqrt(dx * dx + dz * dz)
                if r < 1.0 and q.y < -0.05:
                    k = smooth01((1.0 - r) / 0.55)
                    disp -= 0.0135 * k
                    tags['socket'] = max(tags.get('socket', 0.0), k)
        return disp * hs, tags

    def trunk_disp(self, p):
        d = 0.0
        for c, sg, amp, sym in self.trunk_feats:
            px = abs(p.x) if sym else p.x
            d += amp * math.exp(-(((px - c.x) / sg.x) ** 2 + ((p.y - c.y) / sg.y) ** 2 + ((p.z - c.z) / sg.z) ** 2))
        # sternocleidomastoid cords on the neck
        if self.J['neck'].z - 0.02 < p.z < self.HC.z:
            t = (p.z - self.J['neck'].z) / (self.HC.z - self.J['neck'].z)
            ang = math.atan2(abs(p.x), -(p.y - 0.02 * self.s))
            target = lerp(0.35, 1.45, t)
            d += 0.0045 * self.s * (1 - 0.5 * self.fem) * math.exp(-((ang - target) / 0.28) ** 2) * math.sin(math.pi * clamp(t, 0, 1))
        return d

    def head_weight(self, p):
        """0 = trunk/neck, 1 = rigid head."""
        return smooth01((self.sd_neck(p) - self.sd_head(p) + 0.008 * self.s) / (0.022 * self.s))

    # ================================================================ weights
    def trunk_weights(self, p, extra=None):
        s = self.s
        J = self.J
        wh = self.head_weight(p) if p.z > J['neck'].z else 0.0
        z = p.z
        # spine chain by height
        bounds = [('hips', J['spine'].z), ('spine', J['chest'].z), ('chest', J['upperchest'].z),
                  ('upperchest', J['neck'].z + 0.012 * s), ('neck', 99.0)]
        w = {}
        prev = 0.0
        acc = []
        widths = [0.05, 0.05, 0.05, 0.03, 0.0]
        for i, (name, top) in enumerate(bounds):
            below = 1.0 if i == len(bounds) - 1 else 1.0 - smooth01((z - top + widths[i] * s) / (2 * widths[i] * s))
            acc.append((name, below))
        rem = 1.0
        for name, below in acc:
            take = rem * below
            if take > 1e-4:
                w[name] = take
            rem -= take
        # the shoulders pull the trunk skin near the armpits and the top of the shoulder
        ax = abs(p.x)
        side = 'L' if p.x >= 0 else 'R'
        S = J['shoulder']
        d = (Vector((ax, p.y, p.z)) - S).length
        w_arm = smooth01((0.12 * s - d) / (0.08 * s)) * smooth01((ax - 0.07 * s) / (0.07 * s))
        if w_arm > 0:
            w_up = w_arm * smooth01((ax - S.x + 0.06 * s) / (0.08 * s)) * 0.85
            w_cl = (w_arm - w_up) * 0.9
            for k in list(w):
                w[k] *= (1 - w_up - w_cl)
            w['upperarm.' + side] = w.get('upperarm.' + side, 0.0) + w_up
            w['shoulder.' + side] = w.get('shoulder.' + side, 0.0) + w_cl
        # thighs pull the skin below the hips
        Hp = J['hip']
        d = (Vector((ax, p.y, p.z)) - Hp).length
        w_th = smooth01((0.15 * s - d) / (0.09 * s)) * smooth01((Hp.z + 0.03 * s - z) / (0.10 * s)) * 0.9
        if w_th > 0:
            for k in list(w):
                w[k] *= (1 - w_th)
            w['thigh.' + side] = w.get('thigh.' + side, 0.0) + w_th
        if wh > 0:
            for k in list(w):
                w[k] *= (1 - wh)
            w['head'] = wh
        return w

    # ================================================================ trunk-neck-head skin
    def axis_y(self, z):
        s = self.s
        if z < 1.49 * s:
            return self.T_CY(z)
        t = smooth01((z - 1.49 * s) / (self.HC.z - 0.03 * self.hs - 1.49 * s))
        return lerp(self.T_CY(1.49 * s), self.HC.y + 0.002, t)

    def surf_slice(self, z, th, feats=True):
        O = Vector((0.0, self.axis_y(z), z))
        d = Vector((math.sin(th), -math.cos(th), 0.0))
        return self._surf(O, d, feats)

    def surf_dome(self, e, th, feats=True, lift=0.0):
        ce = math.cos(e)
        d = Vector((ce * math.sin(th), -ce * math.cos(th), math.sin(e)))
        return self._surf(self.HC, d, feats, lift)

    def _surf(self, O, d, feats, lift=0.0):
        t = self.hit(O, d)
        p = O + d * t
        tags = {}
        if feats:
            wh = self.head_weight(p)
            dh, tags = self.head_disp(p) if wh > 0.01 else (0.0, {})
            dt = self.trunk_disp(p) if wh < 0.99 else 0.0
            p = p + d * (dh * wh + dt * (1 - wh))
        if lift:
            p = p + d * lift
        return p, tags

    def row_params(self):
        """Adaptive row placement: list of ('z', z) and ('e', elevation)."""
        s, hs = self.s, self.hs
        P = self.P
        z0 = self.T_Z0 + 0.02 * s
        zc = self.HC.z
        mer = [0.0, 0.7, -0.7, math.pi / 2, -math.pi / 2, 2.4, -2.4, math.pi]
        mw = [3.0, 1.5, 1.5, 1.0, 1.0, 0.7, 0.7, 0.7]
        samples = []
        n1 = 260
        for i in range(n1):
            samples.append(('z', lerp(z0, zc, i / (n1 - 1))))
        n2 = 70
        for i in range(1, n2):
            samples.append(('e', math.radians(89.0) * i / (n2 - 1)))
        pts = []
        for kind, val in samples:
            if kind == 'z':
                pts.append([self.surf_slice(val, th, False)[0] for th in mer])
            else:
                pts.append([self.surf_dome(val, th, False)[0] for th in mer])
        L = [0.0]
        chin = self.HC.z - 0.13 * hs
        brow = self.HC.z + 0.05 * hs
        for i in range(1, len(samples)):
            dl = sum(w * (pts[i][k] - pts[i - 1][k]).length for k, w in enumerate(mw)) / sum(mw)
            kind, val = samples[i]
            zref = pts[i][0].z
            if P['gash'] and 0.96 * s < zref < 1.26 * s:
                dens = 1.05
            elif zref < 1.40 * s:
                dens = 0.42
            elif zref < chin:
                dens = 0.9
            elif zref < brow:
                dens = 1.9
            else:
                dens = 0.95
            L.append(L[-1] + dl * dens)
        spacing = 0.0115 * s / self.res
        count = max(8, int(L[-1] / spacing))
        out = []
        j = 0
        for k in range(count + 1):
            target = L[-1] * k / count
            while j < len(L) - 2 and L[j + 1] < target:
                j += 1
            a, b = samples[j], samples[j + 1]
            f = 0.0 if L[j + 1] == L[j] else (target - L[j]) / (L[j + 1] - L[j])
            if a[0] == b[0]:
                out.append((a[0], lerp(a[1], b[1], f)))
            else:           # the step from the last slice to the first dome ray
                out.append(('z', lerp(a[1], zc, f)) if f < 0.5 else ('e', lerp(0.0, b[1], (f - 0.5) * 2)))
        return out

    def build_skin(self):
        P = self.P
        res = self.res
        segs = 44 * res
        part = Part('skin', 'skin')
        part.weight_fn = lambda p, ex: self.trunk_weights(p, ex)
        rows = self.row_params()
        rings, extras = [], []
        HC = self.HC
        for kind, val in rows:
            if kind == 'z':
                zt = smooth01((val - (HC.z - 0.20 * self.hs)) / (0.10 * self.hs))
            else:
                zt = 1.0 - 0.7 * smooth01(val / math.radians(80))
            warp = 0.52 * zt
            gw = 0.0
            if P['gash'] and kind == 'z':
                gw = 0.55 * smooth01((val - 0.95 * self.s) / (0.05 * self.s)) * (1 - smooth01((val - 1.23 * self.s) / (0.05 * self.s)))
            ring, ex = [], []
            for j in range(segs):
                th0 = TAU * j / segs
                th = th0 - warp * math.sin(th0)
                if gw > 0:
                    thg = self.GASH_TH
                    th = th - gw * math.sin(th - thg) * 0.9
                if kind == 'z':
                    p, tags = self.surf_slice(val, th)
                else:
                    p, tags = self.surf_dome(val, th)
                ring.append(p)
                ex.append(self.skin_attrs(p, tags))
            rings.append(ring)
            extras.append(ex)
        ids, _ = part.grid(rings, extras, wrap=True)
        # close bottom (hidden) and crown
        c0 = sum(rings[0], Vector()) / segs
        part.fan(ids[0], c0 + Vector((0, 0, -0.01)), flip=True)
        top = self.surf_dome(math.radians(90.0), 0.0)[0]
        part.fan(ids[-1], top, extra=self.skin_attrs(top, {}))
        part.meta['rows'] = rows
        part.meta['segs'] = segs
        part.meta['ids'] = ids
        return part

    def skin_attrs(self, p, tags):
        q = (p - self.HC) / self.hs
        a = {}
        for k in ('lipu', 'lipl'):
            if k in tags:
                a['lip'] = max(a.get('lip', 0.0), smooth01((tags[k] - 0.35) / 0.4))
        if 'mouth' in tags:
            a['lip'] = max(a.get('lip', 0.0), tags['mouth'])
        if 'socket' in tags:
            a['socket'] = tags['socket']
        if 'nostril' in tags:
            a['nostril'] = tags['nostril']
        if 'nose' in tags:
            a['cheek'] = max(a.get('cheek', 0.0), tags['nose'] * 0.6)
        if 'cheekbone' in tags:
            a['cheek'] = max(a.get('cheek', 0.0), tags['cheekbone'] * 0.8)
        # eyebrows
        for sx in (1, -1):
            u = (q.x * sx - 0.012) / 0.040
            if 0 <= u <= 1 and q.y < -0.05:
                zc = 0.031 + 0.010 * math.sin(u * 2.6) - 0.006 * u
                g = math.exp(-((q.z - zc) / lerp(0.0055, 0.0035, u)) ** 2) * smooth01(u / 0.1) * smooth01((1 - u) / 0.25)
                a['brow'] = max(a.get('brow', 0.0), g)
        # beard zone
        bz = smooth01((-q.z - 0.030) / 0.02) * smooth01((q.y + 0.02) / -0.03 + 1.0) * smooth01((0.078 - abs(q.x)) / 0.01)
        bz *= 1.0 - smooth01(a.get('lip', 0.0) * 2)
        bz *= 1 - math.exp(-((abs(q.x) - 0.0) / 0.012) ** 2 - ((q.z + 0.045) / 0.01) ** 2) * 0.6   # thinner under the nose
        neckb = smooth01((q.z + 0.20) / 0.04) * smooth01((-q.y - 0.0) / 0.03) if q.z < -0.09 else 1.0
        a['beard'] = bz * neckb * (1.0 if q.z < 0.0 else 0.0)
        if self.P['moustache']:
            mo = math.exp(-((q.x / 0.026) ** 2) - ((q.z + 0.052) / 0.008) ** 2) * smooth01((-q.y - 0.08) / 0.01)
            a['beard'] = max(a['beard'], mo)
        # scalp hair region (texture under the hair shell)
        a['scalp'] = self.scalp_mask(p)
        # ears region darker / redder
        a['ear'] = math.exp(-(((abs(q.x) - 0.072) / 0.012) ** 2 + ((q.y - 0.01) / 0.02) ** 2 + (q.z / 0.035) ** 2))
        # nipples and navel (under clothes except Bob's window and the players' belly)
        s = self.s
        for sx in (1, -1):
            g = math.exp(-(((p.x - sx * 0.090 * s) / 0.010) ** 2 + ((p.z - lerp(1.305, 1.255, self.fem) * s) / 0.010) ** 2)) * smooth01((-p.y) / 0.05)
            a['nipple'] = max(a.get('nipple', 0.0), g)
        a['navel'] = math.exp(-((p.x / 0.009) ** 2 + ((p.z - 1.075 * s) / 0.009) ** 2)) * smooth01(-p.y / 0.05)
        a['vein'] = 0.25 + 0.4 * smooth01((p.z - 1.48 * s) / 0.05) * (1 - self.head_weight(p))
        return a

    def hairline(self, th):
        """Head-local z of the hairline at azimuth th (0 front)."""
        k = (1 + math.cos(th)) * 0.5
        base = lerp(-0.075, 0.066, k ** 0.7)
        # temples recede at the sides of the forehead
        side = math.exp(-((abs(th) - 0.55) / 0.22) ** 2)
        base += 0.012 * side * (0.4 + self.P['age'])
        # above the ears the hair line wraps round them
        ear = math.exp(-((abs(th) - 1.62) / 0.28) ** 2)
        base += 0.030 * ear
        return base

    def scalp_mask(self, p):
        q = (p - self.HC) / self.hs
        th = math.atan2(q.x, -q.y)
        hl = self.hairline(th)
        m = smooth01((q.z - hl) / 0.008)
        if self.P['hair'] == 'balding':
            ztop = lerp(0.065, 0.090, smooth01((-math.cos(th) + 0.2) / 1.0))
            m *= 1 - smooth01((q.z - ztop) / 0.015) * 0.92
        return m

    # ================================================================ eyes and lids
    def build_eyes(self):
        res = self.res
        hs = self.hs
        part = Part('eyes', 'skin', rigid='head', uv_boost=3.0)
        lids = Part('lids', 'skin', rigid='head', uv_boost=2.4)
        R = self.eye_r * hs
        P = self.P
        for sx in (1, -1):
            c = self.HC + Vector((sx * self.eye_c.x, self.eye_c.y, self.eye_c.z)) * hs
            # eyeball: rings around the forward axis (-Y), a little divergent
            fwd = Vector((sx * 0.06, -1.0, 0.0)).normalized()
            up = Vector((0, 0, 1))
            side = fwd.cross(up).normalized()
            up = side.cross(fwd).normalized()
            nr = 8 * res
            na = 12 * res
            rings, ex = [], []
            for i in range(1, nr):
                a = math.pi * i / nr          # 0 at the front pole
                ring, er = [], []
                for j in range(na):
                    b = TAU * j / na
                    dirv = fwd * math.cos(a) + (side * math.cos(b) + up * math.sin(b)) * math.sin(a)
                    bulge = 1.0 + 0.06 * math.exp(-(a / 0.45) ** 2)       # cornea
                    ring.append(c + dirv * R * bulge)
                    ang = math.degrees(a)
                    er.append({'eye': 1.0, 'iris': smooth01((36.0 - ang) / 3.0), 'socket': smooth01((ang - 80) / 20) * 0.5})
                rings.append(ring)
                ex.append(er)
            part.tube(rings, ex, cap_start=c + fwd * R * 1.06, cap_end=c - fwd * R)
            # lids: two shells over the eyeball, the opening an almond
            U = math.radians(lerp(62, 70, P['eye_w']))
            hu = math.radians(lerp(22, 32, P['eye_open']))
            hl = math.radians(lerp(17, 22, P['eye_open']))
            tilt = math.radians(4.0 + 3 * self.fem)
            cols = 14 * res + 1
            for upper in (True, False):
                P_rows = []
                exs = []
                nrow = 5 * res
                for r in range(nrow + 1):
                    v = r / nrow
                    row, er = [], []
                    for ci in range(cols):
                        u = lerp(-math.radians(80), math.radians(80), ci / (cols - 1))
                        lat = u * sx          # + = lateral (towards the ear)
                        k = clamp(abs(u) / U, 0.0, 1.0)
                        shape = math.sqrt(max(0.0, 1 - k ** 2.4))
                        wc = tilt * (lat / U) * 0.8 - math.radians(2.0)
                        w_edge = wc + (hu * shape if upper else -hl * shape)
                        w_far = math.radians(70) if upper else -math.radians(66)
                        w = lerp(w_edge, w_far, v ** 1.2)
                        dirv = fwd * (math.cos(u) * math.cos(w)) + side * (math.sin(u) * math.cos(w)) + up * math.sin(w)
                        # the skin surface along this direction: the lid blends into it
                        t_sdf = self.hit(c, dirv, 0.05)
                        sp = c + dirv * t_sdf
                        dh, _ = self.head_disp(sp, carve=False)
                        t_skin = t_sdf + dh * 0.9
                        # radius: touching the ball at the edge, a rounded margin, then down into the skin
                        margin = R * 1.03 + R * (0.10 if upper else 0.065) * smooth01(v * 6.0)
                        if upper:
                            margin += R * 0.06 * math.exp(-((v - 0.40) / 0.14) ** 2)
                        blend = smooth01((v - 0.30) / 0.70)
                        rad = lerp(margin, t_skin - 0.0006 * hs, blend)
                        rad = max(rad, R * 1.03)
                        row.append(c + dirv * rad)
                        er.append({'lid': 1.0 - smooth01(v / 0.30), 'socket': 0.25 * smooth01((0.5 - v) / 0.4)})
                    P_rows.append(row)
                    exs.append(er)
                flip = upper          # the shells are not mirrored per eye (side points the same way for both)
                lids.grid(P_rows, exs, flip=flip)
        return part, lids

    # ================================================================ ears
    def build_ear(self):
        res = self.res
        hs = self.hs
        P = self.P
        part = Part('ear.L', 'skin', rigid='head', uv_boost=2.0)
        es = lerp(0.9, 1.12, P['ears'])
        h = 0.056 * es
        wdt = 0.029 * es
        C = self.HC + Vector((0.074, 0.010, 0.004)) * hs
        # ear plane: facing out (+X), swung back 22 degrees and leaning back
        n = Vector((1, 0, 0))
        n = Matrix.Rotation(math.radians(-24), 3, 'Z') @ n
        up = Matrix.Rotation(math.radians(-14), 3, 'X') @ Vector((0, 0, 1))
        up = (up - n * up.dot(n)).normalized()
        fwd = n.cross(up).normalized()       # towards the face (-Y)
        if fwd.y > 0:
            fwd = -fwd
        na = 20 * res
        nr = 5 * res

        def outline(phi):
            # phi 0 = towards the face, pi/2 up, pi back
            rx = wdt * (0.55 + 0.45 * smooth01((math.cos(phi) * -1 + 0.2)))
            ry = h * 0.5 * (1.0 if math.sin(phi) > 0 else 0.92)
            r = 1.0 / math.sqrt((math.cos(phi) / rx) ** 2 + (math.sin(phi) / ry) ** 2)
            return r

        front_rows, back_rows, fex, bex = [], [], [], []
        for i in range(1, nr + 1):
            t = i / nr
            fr, br, fe, be = [], [], [], []
            for j in range(na):
                phi = TAU * j / na
                r = outline(phi) * t
                off = up * (math.sin(phi) * r) + fwd * (math.cos(phi) * r) - fwd * wdt * 0.15
                face_side = smooth01((math.cos(phi) - 0.35) / 0.5)       # attached edge towards the face
                # front relief: helix rim, antihelix ridge, concha bowl
                helix = math.exp(-((t - 0.88) / 0.09) ** 2) * (1 - face_side)
                anti = math.exp(-((t - 0.60) / 0.10) ** 2) * (1 - face_side) * smooth01(math.sin(phi) + 0.6)
                concha = math.exp(-((t - 0.25) / 0.28) ** 2) * smooth01((math.cos(phi) + 0.7) / 0.9)
                lobe = smooth01((-math.sin(phi) - 0.55) / 0.3)
                out = 0.0042 * helix + 0.0022 * anti - 0.0048 * concha
                thick = 0.0022 + 0.0022 * helix + 0.0035 * lobe
                # the ear stands off the head: further out towards the back rim
                stand = 0.001 + 0.0075 * smooth01((t - 0.2) / 0.8) * (1 - face_side)
                sink = -0.010 * face_side * smooth01((t - 0.55) / 0.3) - 0.004 * (1 - t)
                base = C + off * hs + n * (stand + sink) * hs
                fr.append(base + n * (out + thick * 0.5) * hs)
                br.append(base + n * (-thick * 0.5 - 0.003 * (1 - t)) * hs)
                e = {'ear': 1.0, 'cheek': 0.4 * helix + 0.5 * lobe}
                fe.append(e)
                be.append(e)
            front_rows.append(fr)
            back_rows.append(br)
            fex.append(fe)
            bex.append(be)
        fid, _ = part.grid(front_rows, fex, wrap=True, flip=False)
        part.fan(fid[0], C + n * 0.001 * hs - fwd * wdt * 0.15 * hs, flip=True)
        bid, _ = part.grid(back_rows, bex, wrap=True, flip=True)
        part.fan(bid[0], C - n * 0.004 * hs - fwd * wdt * 0.15 * hs)
        # rim between the two outer rings
        u0 = part.next_uv_block(0.2)
        for j in range(na):
            j2 = (j + 1) % na
            q = (fid[-1][j], bid[-1][j], bid[-1][j2], fid[-1][j2])
            part.face(q, [(u0 + j * 0.004, 0), (u0 + j * 0.004, 0.004), (u0 + (j + 1) * 0.004, 0.004), (u0 + (j + 1) * 0.004, 0)])
        # check winding of the front against the plane normal
        a, b, c = [part.v[i] for i in part.f[0][:3]]
        if (b - a).cross(c - a).dot(n) < 0:
            part.f = [tuple(reversed(f)) for f in part.f]
            part.fuv = [list(reversed(u)) for u in part.fuv]
        return part

    # ================================================================ arms and hands
    def arm_frame(self):
        T = self.dirF
        N = Vector((0, -1, 0))
        N = (N - T * N.dot(T)).normalized()
        B = T.cross(N)           # palm side for the left hand
        return T, N, B

    def arm_path(self, s_list):
        """Points along the left arm at arclengths s from the shoulder joint (negative = inside the trunk)."""
        J = self.J
        start = J['shoulder'] - self.dirA * 0.045 * self.s + Vector((-0.035, 0.0, -0.022)) * self.s
        ctrl = [start, J['shoulder'], J['elbow'], J['wrist'], J['knuckle'] + self.dirF * 0.006 * self.s]
        dense = chaikin(ctrl, 3)
        # re-anchor: arclength 0 at the shoulder joint
        L = arclen(dense)
        # find arclength of the point closest to the shoulder
        best = min(range(len(dense)), key=lambda i: (dense[i] - J['shoulder']).length)
        s0 = L[best]
        pts = []
        for sv in s_list:
            target = s0 + sv
            i = 0
            while i < len(L) - 2 and L[i + 1] < target:
                i += 1
            seg = L[i + 1] - L[i]
            f = clamp(0.0 if seg <= 0 else (target - L[i]) / seg, 0.0, 1.0)
            pts.append(dense[i].lerp(dense[i + 1], f))
        return pts, s0, L[-1] - s0

    def arm_stations(self):
        s = self.s
        path_probe, s0, send = self.arm_path([0.0])
        # arclength of elbow and wrist along the smoothed path
        pts, _, _ = self.arm_path([x * 0.002 for x in range(int(send / 0.002))])
        sE = min(range(len(pts)), key=lambda i: (pts[i] - self.J['elbow']).length) * 0.002
        sW = min(range(len(pts)), key=lambda i: (pts[i] - self.J['wrist']).length) * 0.002
        sK = min(range(len(pts)), key=lambda i: (pts[i] - self.J['knuckle']).length) * 0.002
        return {'s0': -0.050 * s, 'E': sE, 'W': sW, 'K': sK, 'end': send,
                'cut': sE + 0.070 * s, 'tq': sE - 0.075 * s, 'inf0': sE + 0.100 * s, 'inf1': sE + 0.150 * s,
                'vein': sE + 0.005 * s}

    def arm_radius(self, sv, th, st):
        """Offsets (a along N = thumb side/front, b along B = palm side) for the left arm at s."""
        s = self.s
        f = self.fem
        g = self.girth
        c, sn = math.cos(th), math.sin(th)
        sE, sW, sK = st['E'], st['W'], st['K']
        gm = lerp(1.0, 0.90, f) * s
        u = sv
        # upper arm
        ra = lerp(0.050, 0.041, smooth01((u + 0.02 * s) / (0.16 * s))) * g
        rb = lerp(0.052, 0.043, smooth01((u + 0.02 * s) / (0.16 * s))) * g
        # biceps (towards the front) and triceps (back) swell mid arm
        mid = math.exp(-((u - 0.45 * sE) / (0.10 * s)) ** 2)
        ra += 0.004 * g * mid * max(0.0, c) + 0.003 * g * mid * max(0.0, -c)
        # elbow
        eb = smooth01((u - (sE - 0.08 * s)) / (0.08 * s))
        ra = lerp(ra, 0.036 * g, eb)
        rb = lerp(rb, 0.039 * g, eb)
        # forearm: muscular near the elbow, tapering to a flat wrist
        fu = (u - sE) / max(sW - sE, 1e-4)
        if u > sE:
            ra = lerp(0.041, 0.028, smooth01(fu * 1.1)) * lerp(g, 1.0, 0.5)
            rb = lerp(0.039, 0.019, smooth01((fu - 0.05) * 1.05)) * lerp(g, 1.0, 0.5)
            ra += 0.003 * math.exp(-((fu - 0.18) / 0.15) ** 2) * max(0.0, sn * -1 + 0.3)
        # olecranon bump behind the elbow
        bump = 0.006 * s * math.exp(-((u - sE - 0.005 * s) / (0.022 * s)) ** 2) * max(0.0, -sn) ** 1.5
        # wrist bones, palm widening, closing at the knuckles
        if u > sW - 0.03 * s:
            w = smooth01((u - sW + 0.006 * s) / (0.040 * s))
            pw = lerp(0.032, 0.039, smooth01((u - sW) / (0.05 * s)))
            ra = lerp(ra, pw * lerp(1.0, 0.9, f), w)
            rb = lerp(rb, lerp(0.0175, 0.0150, smooth01((u - sW) / (0.07 * s))) * lerp(1.0, 0.9, f), w)
            # hypothenar and thenar pads on the palm side
            bump += 0.0035 * s * math.exp(-((u - sW - 0.030 * s) / (0.03 * s)) ** 2) * max(0.0, sn) * max(0.0, -c) ** 0.8
            bump += 0.0022 * s * math.exp(-((u - sW) / (0.010 * s)) ** 2) * abs(c)
            # thenar pad: the palm side of the thumb base
            bump += 0.010 * s * math.exp(-((u - sW - 0.038 * s) / (0.026 * s)) ** 2) * max(0.0, sn * 0.7 + c * 0.7) ** 1.2
            # knuckles on the back of the hand
            for k in (0.026, 0.009, -0.008, -0.024):
                bump += 0.0028 * s * math.exp(-((u - sK + 0.004 * s) / (0.009 * s)) ** 2) * math.exp(-((ra * c - k * s) / (0.008 * s)) ** 2) * max(0.0, -sn)
        end = (u - (st['end'] - 0.030 * s)) / (0.030 * s)
        if end > 0:
            k = math.sqrt(max(0.0, 1.0 - min(1.0, end) ** 2 * 0.80))
            ra *= lerp(1.0, 0.80, min(1.0, end)) * k ** 0.4
            rb *= k
        if u < 0:
            k = 1.0 - 0.15 * smooth01(-u / (0.07 * s))
            ra *= k
            rb *= k
        a, b = sell(th, ra * gm, rb * gm, lerp(2.0, 2.12, smooth01((u - sW) / (0.03 * s))))
        return a + c * bump, b + sn * bump

    def arm_weights_at(self, sv, st, side='L'):
        s = self.s
        sE, sW = st['E'], st['W']
        w = {}
        sh = smooth01((0.03 * s - sv) / (0.09 * s)) * 0.55
        ua = 1.0 - smooth01((sv - sE + 0.035 * s) / (0.07 * s))
        fa = 1.0 - ua
        hand = smooth01((sv - sW + 0.015 * s) / (0.03 * s))
        fa *= (1 - hand)
        ua *= (1 - sh)
        w['shoulder.' + side] = sh * (1 - smooth01((sv - sE + 0.035 * s) / (0.07 * s)))
        w['upperarm.' + side] = ua
        w['forearm.' + side] = fa
        w['hand.' + side] = hand
        return {k: v for k, v in w.items() if v > 1e-4}

    def build_arm(self, split_cut=False):
        """Left arm from inside the shoulder to the knuckles. With split_cut, returns (upper, lower) split
        on the ring at the amputation line (used mirrored for Bob's right arm)."""
        s, res = self.s, self.res
        st = self.arm_stations()
        # stations: denser at the elbow, wrist and palm
        svals = []
        x = st['s0']
        while x < st['end']:
            svals.append(x)
            near = min(abs(x - st['E']), abs(x - st['W']))
            dx = (0.030 if x < st['E'] - 0.05 * s else 0.022) * s
            if near < 0.04 * s:
                dx = 0.011 * s
            if x > st['W']:
                dx = 0.010 * s
            x += dx / res
        svals.append(st['end'])
        for key in ('cut', 'tq', 'E', 'W'):
            sv = st[key]
            svals = [v for v in svals if abs(v - sv) > 0.004 * s / res]
            svals.append(sv)
        svals.sort()
        path, _, _ = self.arm_path(svals)
        T, N, B = self.arm_frame()
        segs = 16 * res

        def off(i, sv, th):
            return self.arm_radius(svals[i], th, st)
        rings, _, fr = sweep(path, segs, off, Vector((0, -1, 0)), 0.0, S=svals)
        part = Part('arm.L', 'skin')
        extras = []
        for i, sv in enumerate(svals):
            er = []
            for j in range(segs):
                th = TAU * j / segs
                c, sn = math.cos(th), math.sin(th)
                e = {'_s': sv}
                e['vein'] = 0.35 + 0.5 * smooth01((sv - st['E']) / (0.1 * s))
                e['knuckle'] = math.exp(-((sv - st['K']) / (0.012 * s)) ** 2) * max(0.0, -sn)
                e['palm'] = smooth01((sv - st['W']) / (0.02 * s)) * max(0.0, sn) ** 0.5
                # antecubital vein (texture mask): inner elbow, between the front and the palm side
                ang = math.atan2(sn, c)
                e['veinz'] = math.exp(-((sv - st['vein']) / (0.035 * s)) ** 2) * math.exp(-((ang - 0.55) / 0.45) ** 2)
                e['knuckle'] = max(e['knuckle'], 0.5 * math.exp(-((sv - st['E']) / (0.02 * s)) ** 2) * max(0.0, -sn))
                er.append(e)
            extras.append(er)
        part.weight_fn = lambda p, ex: self.arm_weights_at(ex['_s'], st)
        part.uv2_fn = lambda p, ex: (ex['_s'], -1.0)
        ids, _ = part.grid(rings, extras, wrap=True, vcoords=svals)
        start_c = path[0] - fr[0][0] * 0.01 * s
        part.fan(ids[0], start_c, extra={'_s': svals[0]}, flip=True)
        part.fan(ids[-1], path[-1] + fr[0][-1] * 0.003 * s, extra={'_s': svals[-1]})
        part.meta['st'] = st
        part.meta['svals'] = svals
        part.meta['ids'] = ids
        part.meta['rings'] = rings
        part.meta['frames'] = fr
        part.meta['path'] = path
        self.joints['shoulder.L'] = (self.J['clav'], self.J['shoulder'])
        self.joints['upperarm.L'] = (self.J['shoulder'], self.J['elbow'])
        self.joints['forearm.L'] = (self.J['elbow'], self.J['wrist'])
        self.joints['hand.L'] = (self.J['wrist'], self.J['knuckle'])
        return part

    def build_fingers(self):
        s, res = self.s, self.res
        f = self.fem
        T, N, B = self.arm_frame()
        K = self.J['knuckle']
        st = self.arm_stations()
        part = Part('fingers.L', 'skin')
        lens = [0.074, 0.082, 0.077, 0.061]
        offs = [0.0270, 0.0095, -0.0085, -0.0255]
        curls = [(0.10, 0.16, 0.10), (0.14, 0.20, 0.12), (0.18, 0.24, 0.14), (0.24, 0.28, 0.16)]
        splay = [0.20, 0.06, -0.08, -0.22]
        radii = [0.0108, 0.0112, 0.0106, 0.0093]
        fk = lerp(1.0, 0.9, f) * s
        for i, name in enumerate(FINGERS):
            base = K + N * offs[i] * fk - T * 0.016 * s - B * 0.001 * s
            d = (T + N * splay[i] * 0.5).normalized()
            L = lens[i] * fk
            seg = []
            for k2, frac in enumerate((0.45, 0.30, 0.25)):
                d = rotate_towards(d, B, curls[i][k2])
                seg.append((d, L * frac + (0.016 * s if k2 == 0 else 0.0)))
            self._finger(part, base, seg, radii[i] * fk / s * s, name, st)
        # thumb from the heel of the palm
        base = self.J['wrist'] + T * 0.036 * s + N * 0.020 * fk + B * 0.009 * s
        d = (T * 0.86 + N * 0.34 + B * 0.38).normalized()
        seg = []
        for k2, (l, c) in enumerate(((0.044, 0.10), (0.032, 0.16), (0.027, 0.14))):
            d = rotate_towards(d, B, c)
            seg.append((d, l * fk))
        self._finger(part, base, seg, 0.0140 * fk, 'thumb', st, thumb=True)
        return part

    def _finger(self, part, base, seg, r0, name, st, thumb=False):
        s, res = self.s, self.res
        pts = [base]
        for d, l in seg:
            pts.append(pts[-1] + d * l)
        for i in range(len(seg)):
            self.joints['%s%d.L' % (name, i + 1)] = (pts[i], pts[i + 1])
        jl = [0.0]
        for d, l in seg:
            jl.append(jl[-1] + l)
        Ltot = jl[-1]
        dense = chaikin(pts, 3)
        count = 11 * res + 1
        svals_t = [1 - (1 - k / (count - 1)) ** 1.5 for k in range(count)]
        path, L = resample(dense, count, lambda t: 1 - (1 - t) ** 1.5)
        S = arclen(path)
        segs = 7 * res
        T0 = seg[0][0]
        Bh = self.arm_frame()[2]
        up = (Bh - T0 * Bh.dot(T0)).normalized()
        r1 = r0 * (0.74 if not thumb else 0.70)
        bury = (0.020 if not thumb else 0.012) * s

        def off(i, sv, th):
            c, sn = math.cos(th), math.sin(th)
            sl = S[i] * Ltot / max(S[-1], 1e-6)
            t = sl / Ltot
            r = lerp(r0, r1, t) * lerp(0.55, 1.0, smooth01(sl / bury))
            back = max(0.0, -c)
            for j in jl[1:-1]:
                r += 0.0018 * s * math.exp(-((sl - j) / (0.007 * s)) ** 2) * (0.4 + 0.8 * back)
            for kk in range(len(jl) - 1):
                midp = (jl[kk] + jl[kk + 1]) * 0.5
                r -= 0.0005 * s * math.exp(-((sl - midp) / ((jl[kk + 1] - jl[kk]) * 0.3)) ** 2) * back
            rem = max(0.0, Ltot - sl)
            tip = r1 * 1.25
            if rem < tip:
                r *= math.sqrt(max(0.06, 1 - (1 - rem / tip) ** 2))
            pad = 1.0 + 0.10 * max(0.0, c)
            return (r * c * pad, r * sn * 0.90)
        rings, _, fr = sweep(path, segs, off, up, 0.0, S=S)
        extras = []
        side = 'L'
        for i in range(len(rings)):
            sl = S[i] * Ltot / max(S[-1], 1e-6)
            t = sl / Ltot
            er = []
            for j in range(segs):
                th = TAU * j / segs
                back = max(0.0, -math.cos(th))
                e = {'_fs': sl, 'nail': smooth01((t - 0.80) / 0.04) * smooth01((back - 0.55) / 0.25),
                     'knuckle': max(math.exp(-((sl - j2) / (0.010 * s)) ** 2) for j2 in jl[1:-1]) * (0.3 + 0.7 * back),
                     'palm': max(0.0, math.cos(th)) * 0.6, 'vein': 0.2}
                er.append(e)
            extras.append(er)
        names = ['%s%d.%s' % (name, k + 1, side) for k in range(3)]

        def wf(p, ex):
            sl = ex.get('_fs', 0.0)
            w = {}
            h = 1.0 - smooth01((sl - bury * 0.7) / (0.012 * s))
            if thumb:
                h = 1.0 - smooth01((sl - 0.010 * s) / (0.02 * s))
            b1 = (1 - h) * (1 - smooth01((sl - jl[1] + 0.004 * s) / (0.008 * s)))
            rest = 1 - h - b1
            b2 = rest * (1 - smooth01((sl - jl[2] + 0.003 * s) / (0.006 * s)))
            b3 = rest - b2
            for nm, x in (('hand.' + side, h), (names[0], b1), (names[1], b2), (names[2], b3)):
                if x > 1e-4:
                    w[nm] = x
            return w
        old = part.weight_fn
        part.weight_fn = wf
        part.uv2_fn = lambda p, ex: (st['K'] + ex.get('_fs', 0.0), -1.0)
        ids, _ = part.grid(rings, extras, wrap=True, vcoords=[x for x in S])
        part.fan(ids[0], path[0] - fr[0][0] * 0.002 * s, extra={'_fs': 0.0}, flip=True)
        part.fan(ids[-1], path[-1] + fr[0][-1] * 0.0006 * s, extra={'_fs': Ltot, 'nail': 0.0})
        part.weight_fn = old

    # ================================================================ legs
    def leg_stations(self):
        s = self.s
        J = self.J
        return {'s0': -0.10 * s, 'K': (J['knee'] - J['hip']).length, 'A': (J['knee'] - J['hip']).length + (J['ankle'] - J['knee']).length,
                'end': (J['knee'] - J['hip']).length + (J['ankle'] - J['knee']).length + 0.03 * s}

    def leg_path(self, svals):
        J = self.J
        s = self.s
        start = J['hip'] + Vector((-0.015, 0.0, 0.10)) * s
        ctrl = [start, J['hip'], J['knee'], J['ankle'], J['ankle'] + Vector((0, 0.0, -0.035)) * s]
        dense = chaikin(ctrl, 3)
        L = arclen(dense)
        best = min(range(len(dense)), key=lambda i: (dense[i] - J['hip']).length)
        s0 = L[best]
        out = []
        for sv in svals:
            target = s0 + sv
            i = 0
            while i < len(L) - 2 and L[i + 1] < target:
                i += 1
            seg = L[i + 1] - L[i]
            fr = clamp(0.0 if seg <= 0 else (target - L[i]) / seg, 0.0, 1.0)
            out.append(dense[i].lerp(dense[i + 1], fr))
        return out

    def leg_radius(self, sv, th, st):
        s, f, g = self.s, self.fem, self.girth
        c, sn = math.cos(th), math.sin(th)     # c: front (+N = -Y)
        sK, sA = st['K'], st['A']
        u = sv
        r = lerp(0.094, 0.076, smooth01(u / (0.22 * s)))
        r = lerp(r, 0.054, smooth01((u - 0.22 * s) / (sK - 0.22 * s)))
        r += 0.010 * f * math.exp(-((u - 0.05 * s) / (0.12 * s)) ** 2)
        r *= g
        # knee and patella
        r = lerp(r, 0.051 * g, math.exp(-((u - sK) / (0.05 * s)) ** 2))
        pat = 0.006 * math.exp(-((u - sK + 0.005 * s) / (0.03 * s)) ** 2) * max(0.0, c) ** 2
        # calf at the back, shin at the front
        cu = u - sK
        if cu > 0:
            r = lerp(0.052, 0.036, smooth01((cu - 0.08 * s) / (sA - sK - 0.10 * s))) * lerp(g, 1.0, 0.4)
            r += 0.013 * math.exp(-((cu - 0.12 * s) / (0.08 * s)) ** 2) * max(0.0, -c) ** 0.8 * lerp(g, 1.0, 0.3)
            r += 0.004 * math.exp(-((cu - 0.14 * s) / (0.08 * s)) ** 2) * abs(sn)
        ank = 0.005 * math.exp(-((u - sA) / (0.018 * s)) ** 2) * abs(sn)
        # buttock and groin volume at the top of the thigh, so trousers do not step in under the hips
        top = smooth01((0.16 * s - u) / (0.16 * s))
        pat += (0.030 * max(0.0, -c) ** 1.2 + 0.006 * max(0.0, c)) * top * (1 + 0.5 * f) * g / s
        r *= s * lerp(1.0, 0.94, f)
        return (r * c + c * pat * s, r * 0.93 * sn + sn * ank * s)

    def leg_weights_at(self, sv, st, side='L'):
        s = self.s
        w = {}
        hips = smooth01((0.02 * s - sv) / (0.10 * s)) * 0.5
        th = 1 - smooth01((sv - st['K'] + 0.05 * s) / (0.10 * s))
        foot = smooth01((sv - st['A'] + 0.02 * s) / (0.035 * s))
        sh = (1 - th) * (1 - foot)
        th *= (1 - hips)
        for nm, x in (('hips', hips), ('thigh.' + side, th), ('shin.' + side, sh), ('foot.' + side, foot)):
            if x > 1e-4:
                w[nm] = x
        return w

    def build_leg(self):
        s, res = self.s, self.res
        st = self.leg_stations()
        svals = []
        x = st['s0']
        while x < st['end']:
            svals.append(x)
            dx = 0.035 * s if x < st['K'] - 0.08 * s else 0.022 * s
            if abs(x - st['K']) < 0.06 * s:
                dx = 0.016 * s
            x += dx / res
        svals.append(st['end'])
        path = self.leg_path(svals)
        segs = 16 * res
        rings, _, fr = sweep(path, segs, lambda i, sv, th: self.leg_radius(svals[i], th, st), Vector((0, -1, 0)), 0.0, S=svals)
        part = Part('leg.L', 'skin')
        part.weight_fn = lambda p, ex: self.leg_weights_at(ex['_s'], st)
        part.uv2_fn = lambda p, ex: (ex['_s'], 2.0)
        extras = [[{'_s': sv, 'vein': 0.3, 'knuckle': 0.4 * math.exp(-((sv - st['K']) / (0.03 * s)) ** 2) * max(0.0, math.cos(TAU * j / segs))}
                   for j in range(segs)] for sv in svals]
        ids, _ = part.grid(rings, extras, wrap=True, vcoords=svals)
        part.fan(ids[0], path[0] + Vector((0, 0, 0.01)), extra={'_s': svals[0]}, flip=True)
        part.fan(ids[-1], path[-1] - Vector((0, 0, 0.006)), extra={'_s': svals[-1]})
        part.meta.update(st=st, svals=svals, rings=rings, frames=fr, path=path, ids=ids)
        J = self.J
        self.joints['thigh.L'] = (J['hip'], J['knee'])
        self.joints['shin.L'] = (J['knee'], J['ankle'])
        self.joints['foot.L'] = (J['ankle'], J['ball'])
        self.joints['toe.L'] = (J['ball'], J['toe'])
        return part

    def spine_joints(self):
        J = self.J
        self.joints['hips'] = (J['hips'], J['spine'])
        self.joints['spine'] = (J['spine'], J['chest'])
        self.joints['chest'] = (J['chest'], J['upperchest'])
        self.joints['upperchest'] = (J['upperchest'], J['neck'])
        self.joints['neck'] = (J['neck'], J['headj'])
        self.joints['head'] = (J['headj'], J['crown'])
