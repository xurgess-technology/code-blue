"""Hair, headwear, garments and footwear over the Body, skin culling, the surgery pieces and site frames.

build_character(P, res) -> (parts, info)
  parts: every Part; part.meta['piece'] names the game object it joins ('Human' when absent)
  info: body, sites {name: {bone, matrix (Godot convention columns X, Y out of skin, Z), section...}}, stations
"""
import math
from mathutils import Vector, Matrix, noise
from hu_mesh import (Part, TAU, smooth01, lerp, clamp, chaikin, resample, arclen, sweep, sell, frames)
import hu_body


def fold_noise(p, scale, seed, amp):
    return amp * noise.noise(Vector((p.x * scale + seed * 1.7, p.y * scale, p.z * scale * 0.55)))


# ====================================================================== trunk garments
class TrunkGarment:
    """A garment tube around the trunk: rows by v (0 hem .. 1 top), columns by azimuth."""

    def __init__(self, body, name, z_bot, z_top, offset, segs, rows, piece=None, attrs=None, feat_k=0.6,
                 folds=0.004, fold_scale=18.0, below_hip_flare=0.0):
        self.b = body
        self.name = name
        self.z_bot = z_bot          # f(th) -> z of the lowest row
        self.z_top = z_top          # f(th) -> z of the top row
        self.offset = offset        # f(z, th) -> metres out from the skin
        self.segs, self.rows = segs, rows
        self.attrs = attrs or (lambda p, z, th, v: {})
        self.feat_k, self.folds, self.fold_scale = max(feat_k, 0.85), folds, fold_scale
        self.flare = below_hip_flare

    def point(self, z, th, extra_off=0.0):
        b = self.b
        s = b.s
        zr = max(z, 0.88 * s)
        O = Vector((0.0, b.axis_y(zr), zr))
        d = Vector((math.sin(th), -math.cos(th), 0.0))
        off = self.offset(z, th) + extra_off
        t = b.hit(O, d, 0.6, True, lambda q: off)
        p = O + d * t
        p = p + d * (b.trunk_disp(p) * self.feat_k)
        if z < zr:
            # hanging below the hips: straight down and flaring
            p = Vector((p.x, p.y, z)) + d * (self.flare * (zr - z))
        n = fold_noise(p, self.fold_scale, hash(self.name) % 97, self.folds)
        return p + d * n

    def build(self, part, weight_fn=None, uv2=(0.0, 0.0)):
        rings, extras = [], []
        for r in range(self.rows + 1):
            v = r / self.rows
            ring, ex = [], []
            for j in range(self.segs):
                th = TAU * j / self.segs
                if th > math.pi:
                    th -= TAU
                z = lerp(self.z_bot(th), self.z_top(th), v)
                p = self.point(z, th)
                ring.append(p)
                e = self.attrs(p, z, th, v)
                e['_z'] = z
                e['_th'] = th
                e['_v'] = v
                ex.append(e)
            rings.append(ring)
            extras.append(ex)
        old = part.weight_fn
        if weight_fn:
            part.weight_fn = weight_fn
        ids, _ = part.grid(rings, extras, wrap=True)
        part.weight_fn = old
        return ids, rings


def hem_ring(part, ring_ids, inward, down, extra=None):
    """Turn an open edge inward: a second ring offset towards the body, faces between."""
    pts = [part.v[i] for i in ring_ids]
    c = sum(pts, Vector()) / len(pts)
    new = []
    for i, p in zip(ring_ids, pts):
        dvec = Vector((p.x - c.x, p.y - c.y, 0.0))
        if dvec.length > 1e-6:
            dvec.normalize()
        q = p - dvec * inward + Vector((0, 0, -down))
        e = {k: part.attr[k][i] for k in part.attr if part.attr[k][i] > 0}
        if extra:
            e.update(extra)
        new.append(part.add_v(q, e, w=dict(part.w[i]), uv2=part.uv2[i]))
    u0 = part.next_uv_block(0.2)
    n = len(ring_ids)
    for j in range(n):
        j2 = (j + 1) % n
        part.face((ring_ids[j], ring_ids[j2], new[j2], new[j]), [(u0 + j * 0.01, 0), (u0 + (j + 1) * 0.01, 0), (u0 + (j + 1) * 0.01, 0.012), (u0 + j * 0.01, 0.012)])
    return new


def fix_winding_outward(part, first_face, centre):
    """Make faces [first_face:] face away from `centre` (a point or f(p) -> point)."""
    flips = 0
    for fi in range(first_face, len(part.f)):
        f = part.f[fi]
        pts = [part.v[i] for i in f]
        n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
        mid = sum(pts, Vector()) / len(pts)
        c = centre(mid) if callable(centre) else centre
        if n.dot(mid - c) < 0:
            flips += 1
    return flips


# ====================================================================== limb garments
def limb_tube(part, body, kind, s_from, s_to, off_fn, segs, attrs_fn, step, dense_at=()):
    """A sleeve (kind 'arm') or trouser leg ('leg') around the left limb; returns ids and rings."""
    s = body.s
    if kind == 'arm':
        st = body.arm_stations()
        rad = lambda sv, th: body.arm_radius(sv, th, st)
        path_fn = lambda sl: body.arm_path(sl)[0]
        wf = lambda p, ex: body.arm_weights_at(ex['_s'], st)
    else:
        st = body.leg_stations()
        rad = lambda sv, th: body.leg_radius(sv, th, st)
        path_fn = body.leg_path
        wf = lambda p, ex: body.leg_weights_at(ex['_s'], st)
    svals = []
    x = s_from
    while x < s_to:
        svals.append(x)
        x += step
    svals.append(s_to)
    for d in dense_at:
        svals = [v for v in svals if abs(v - d) > step * 0.3] + [d]
    svals = sorted(v for v in svals if s_from <= v <= s_to)
    path = path_fn(svals)
    up = Vector((0, -1, 0))

    def off(i, sv, th):
        a, b = rad(svals[i], th)
        r = math.hypot(a, b)
        o = off_fn(svals[i], th)
        k = (r + o) / max(r, 1e-6)
        return a * k, b * k
    rings, _, fr = sweep(path, segs, off, up, 0.0, S=svals)
    for i, ring in enumerate(rings):
        T, N, B = fr[0][i], fr[1][i], fr[2][i]
        for j, p in enumerate(ring):
            ring[j] = p + (N * math.cos(TAU * j / segs) + B * math.sin(TAU * j / segs)) * fold_noise(p, 22.0, 5, 0.0025)
    extras = [[dict(attrs_fn(svals[i], TAU * j / segs), _s=svals[i]) for j in range(segs)] for i in range(len(svals))]
    old = part.weight_fn
    part.weight_fn = wf
    ids, _ = part.grid(rings, extras, wrap=True, vcoords=svals)
    part.weight_fn = old
    return ids, rings, svals, fr


def tuck_end(part, ids_ring, frame_T, depth, shrink, extra=None):
    pts = [part.v[i] for i in ids_ring]
    c = sum(pts, Vector()) / len(pts)
    new = []
    for i, p in zip(ids_ring, pts):
        q = c + (p - c) * shrink - frame_T * depth
        e = {k: part.attr[k][i] for k in part.attr if part.attr[k][i] > 0}
        if extra:
            e.update(extra)
        new.append(part.add_v(q, e, w=dict(part.w[i]), uv2=part.uv2[i]))
    u0 = part.next_uv_block(0.2)
    n = len(ids_ring)
    for j in range(n):
        j2 = (j + 1) % n
        part.face((ids_ring[j], ids_ring[j2], new[j2], new[j]), [(u0 + j * 0.01, 0), (u0 + (j + 1) * 0.01, 0), (u0 + (j + 1) * 0.01, 0.01), (u0 + j * 0.01, 0.01)])
    return new


# ====================================================================== hair
def build_hair(body, P, res):
    style = P['hair']
    s, hs = body.s, body.hs
    HC = body.HC
    part = Part('hair', 'skin', rigid='head', uv_boost=1.4)
    part.const = {'hair': 1.0}
    if style in ('none', 'buzz'):
        return []          # a buzz cut is texture on the scalp only (a shell z-fights)
    segs = 40 * res
    rows = 9 * res
    ln = P['hair_len']
    top_lift = {'crop': 0.0095, 'buzz': 0.0022, 'balding': 0.0045, 'bun': 0.0040, 'ponytail': 0.0045}[style] * ln

    def lift_at(v, th):
        k = (1 + math.cos(th)) * 0.5
        if style == 'crop':
            return lerp(0.0028, top_lift, smooth01(v * 1.6)) * lerp(0.75, 1.0, k)
        if style == 'buzz':
            return lerp(0.0012, top_lift, smooth01(v * 2))
        return lerp(0.0025, top_lift, smooth01(v * 1.5))

    def elev_of_local_z(z):
        return math.asin(clamp(z / 0.128, -0.95, 0.99))

    rings, extras = [], []
    th_list = [TAU * j / segs for j in range(segs)]
    for r in range(-1, rows + 1):
        v = max(0.0, r / rows)
        ring, ex = [], []
        for th in th_list:
            thw = th if th <= math.pi else th - TAU
            z0 = body.hairline(thw)
            e0 = elev_of_local_z(z0)
            e = lerp(e0, math.radians(88.5), v ** 0.85)
            lift = -0.0012 * hs if r < 0 else lift_at(v, thw) * hs * smooth01(r / 2.5)
            if style == 'balding':
                # a horseshoe round the back and over the ears; the lift fades to nothing at its top edge
                qz = math.sin(e) * 0.125
                ztop = lerp(0.065, 0.090, smooth01((-math.cos(thw) + 0.2) / 1.0))
                lift *= smooth01((ztop - qz) / 0.018)
            p, _ = body.surf_dome(e, thw, True, lift)
            # hair over the ears is swept back: keep the shell off the ear tops
            ring.append(p)
            ex.append({'hair': 1.0 if r >= 0 else 0.6, 'scalp': 1.0})
        rings.append(ring)
        extras.append(ex)
    ids, _ = part.grid(rings, extras, wrap=True)
    top = body.surf_dome(math.radians(90), 0.0, True, (lift_at(1.0, 0.0) if style != 'balding' else -0.001) * hs)[0]
    part.fan(ids[-1], top, extra={'hair': 1.0})
    parts = [part]
    if style == 'balding':
        # remove the shell over the bald crown: faces whose lift collapsed
        def bald(fi, pts):
            c = sum(pts, Vector()) / len(pts)
            q = (c - HC) / hs
            th = math.atan2(q.x, -q.y)
            e = math.degrees(math.asin(clamp(q.z / max(q.length, 1e-6), -1, 1)))
            ztop = lerp(0.065, 0.090, smooth01((-math.cos(th) + 0.2) / 1.0))
            return q.z > ztop + 0.004 or (math.cos(th) > 0.55 and q.z > -0.01)
        part.extract(bald, 'bald_discard')
    if style == 'bun':
        bun = Part('hair_bun', 'skin', rigid='head', uv_boost=1.4)
        bun.const = {'hair': 1.0}
        c = HC + Vector((0.0, 0.088, 0.055)) * hs
        nr, na = 9 * res, 16 * res
        rr = []
        for i in range(1, nr):
            a = math.pi * i / nr - math.pi * 0.5
            ring = []
            for j in range(na):
                t = TAU * j / na
                wob = 1 + 0.07 * math.sin(t * 6 + a * 4)
                ring.append(c + Vector((0.036 * math.cos(a) * math.sin(t) * wob, 0.030 * math.sin(a), 0.033 * math.cos(a) * math.cos(t) * wob)) * hs)
            rr.append(ring)
        bun.tube(rr, None, cap_start=c + Vector((0, -0.030, 0)) * hs, cap_end=c + Vector((0, 0.030, 0)) * hs)
        parts.append(bun)
    if style == 'ponytail':
        pt = Part('hair_tail', 'skin', rigid='head', uv_boost=1.4)
        pt.const = {'hair': 1.0}
        base = HC + Vector((0.0, 0.095, 0.020)) * hs
        ctrl = [base - Vector((0, 0.02, 0)) * hs, base + Vector((0, 0.02, -0.01)) * hs, base + Vector((0, 0.045, -0.08)) * hs,
                base + Vector((0, 0.045, -0.16)) * hs, base + Vector((0, 0.030, -0.22)) * hs]
        path, L = resample(chaikin(ctrl, 2), 14 * res + 1)
        S = arclen(path)
        segs2 = 10 * res

        def off(i, sv, th):
            t = S[i] / S[-1]
            r = lerp(0.014, 0.022, smooth01(t * 3)) * lerp(1.0, 0.25, smooth01((t - 0.5) / 0.5))
            if 0.10 < t < 0.17:
                r *= 0.72       # the hair tie
            return r * math.cos(th) * hs, r * 0.85 * math.sin(th) * hs
        rings2, _, fr = sweep(path, segs2, off, Vector((0, 0, 1)), 0.0, S=S)
        ex2 = [[{'hair': 1.0, 'band': 1.0 if 0.10 < S[i] / S[-1] < 0.17 else 0.0} for _ in range(segs2)] for i in range(len(rings2))]
        pt.tube(rings2, ex2, cap_start=path[0] - fr[0][0] * 0.005, cap_end=path[-1] + fr[0][-1] * 0.004)
        parts.append(pt)
    if False and P['moustache']:
        mo = Part('moustache', 'skin', rigid='head', uv_boost=2.0)
        mo.const = {'hair': 1.0, 'moust': 1.0}
        rows_m, cols_m = 3 * res + 1, 12 * res + 1
        Pts, Nr = [], []
        for r in range(rows_m):
            v = r / (rows_m - 1)
            row, nrow = [], []
            for c2 in range(cols_m):
                u = lerp(-1.0, 1.0, c2 / (cols_m - 1))
                x = u * 0.028
                zl = lerp(-0.061, -0.049, v) - 0.010 * u * u
                p, _ = body.surf_slice(HC.z + zl * hs, math.atan2(x, 0.10))
                d = Vector((p.x, p.y - body.axis_y(p.z), 0)).normalized()
                row.append(p + d * (0.0022 + 0.0025 * (1 - abs(u)) * math.sin(v * math.pi)) * hs)
                nrow.append(d)
            Pts.append(row)
            Nr.append(nrow)
        mo.slab(Pts, Nr, 0.0018 * hs)
        parts.append(mo)
    return parts


# ====================================================================== headwear
def build_cap(body, P, res):
    style = P['cap']
    if style == 'none':
        return []
    hs, HC = body.hs, body.HC
    part = Part('cap', 'cloth', rigid='head', uv_boost=1.6)
    part.const = {'cap': 1.0, 'tint': 1.0, 'scrubs': 1.0}
    part.meta['piece'] = 'Cap'
    segs = 32 * res
    rows = 8 * res
    bouff = style == 'bouffant'

    def edge_e(th):
        k = (1 + math.cos(th)) * 0.5
        side = math.exp(-((abs(th) - 1.6) / 0.6) ** 2)
        e = lerp(-22.0 if bouff else -14.0, 24.0, smooth01(k * 1.3))
        e += (6.0 if not bouff else 2.0) * side
        return math.radians(e)
    rings, extras = [], []
    for r in range(-1, rows + 1):
        v = max(0.0, r / rows)
        ring, ex = [], []
        for j in range(segs):
            th = TAU * j / segs
            if th > math.pi:
                th -= TAU
            e = lerp(edge_e(th), math.radians(89), v ** 0.9)
            if bouff:
                puff = 0.012 + 0.030 * smooth01(v * 2.2) * (1 - 0.3 * smooth01((v - 0.7) / 0.3))
                puff += 0.010 * smooth01(-math.cos(th)) * smooth01(v * 3) * (1 - v)       # room for the bun
                puff += 0.003 * math.sin(th * 13 + v * 5) * smooth01(v * 4) * (1 - v * 0.6)  # gathers
                lift = puff if r >= 0 else 0.004
            else:
                lift = 0.0125 + 0.002 * math.sin(th * 7 + v * 3) * smooth01(v * 3) if r >= 0 else 0.0085
            p, _ = body.surf_dome(e, th, False, lift * hs)
            ring.append(p)
            band = 1.0 if (r <= 0 or (bouff and v < 0.12)) else 0.0
            ex.append({'cap': 1.0, 'band': band, 'crease': 0.5 + 0.5 * abs(math.sin(th * 7))})
        rings.append(ring)
        extras.append(ex)
    ids, _ = part.grid(rings, extras, wrap=True)
    top = body.surf_dome(math.radians(90), 0.0, False, (0.012 if not bouff else 0.030) * hs)[0]
    part.fan(ids[-1], top)
    # turn the edge under
    hem_ring(part, ids[0], 0.004 * hs, -0.002 * hs, {'band': 1.0})
    if not bouff:
        # tie tails at the back of the head
        for sx in (1, -1):
            base = HC + Vector((sx * 0.012, 0.098, -0.012)) * hs
            pts = [base + Vector((sx * 0.004 * k, 0.012 * k * (1 - 0.1 * k), -0.030 * k)) * hs for k in range(6)]
            rws, nrs = [], []
            for i, p in enumerate(pts):
                n = Vector((0, 1, 0.2)).normalized()
                side = Vector((1, 0, 0))
                w = 0.009 * hs
                rws.append([p - side * w, p + side * w])
                nrs.append([n, n])
            part.slab(rws, nrs, 0.0015 * hs)
    return [part]


def build_mask(body, P, res):
    if not P['mask']:
        return []
    hs, HC, s = body.hs, body.HC, body.s
    part = Part('mask', 'cloth', rigid='head', uv_boost=2.0)
    part.const = {'mask': 1.0}
    part.meta['piece'] = 'Mask'
    # radius table of the face from the head axis
    zs = [HC.z + lerp(-0.16, 0.03, i / 38) * hs for i in range(39)]
    ths = [lerp(-1.9, 1.9, i / 38) for i in range(39)]
    R = []
    for z in zs:
        row = []
        for th in ths:
            p, _ = body.surf_slice(z, th)
            row.append(math.hypot(p.x, p.y - body.axis_y(z)))
        R.append(row)

    def r_at(z, th):
        fz = clamp((z - zs[0]) / (zs[-1] - zs[0]) * 38, 0, 37.999)
        ft = clamp((th - ths[0]) / (ths[-1] - ths[0]) * 38, 0, 37.999)
        i, j = int(fz), int(ft)
        a, b = fz - i, ft - j
        return (R[i][j] * (1 - a) * (1 - b) + R[i + 1][j] * a * (1 - b) + R[i][j + 1] * (1 - a) * b + R[i + 1][j + 1] * a * b)

    def drape(z, th):
        best = 0.0
        for dt in (-0.55, -0.4, -0.28, -0.18, -0.09, 0.0, 0.09, 0.18, 0.28, 0.4, 0.55):
            for dz in (0.0, 0.01, 0.02, 0.03, 0.045):
                best = max(best, r_at(z + dz * hs, th + dt) * math.cos(dt) - dz * 0.25)
        return best
    rows, cols = 9 * res + 1, 15 * res + 1
    Pts, Nr, ex = [], [], []
    thm = 1.42
    for r in range(rows):
        v = r / (rows - 1)
        row, nrow, erow = [], [], []
        for c in range(cols):
            u = c / (cols - 1)
            th = lerp(-thm, thm, u)
            centre = math.exp(-(th / 0.45) ** 2)
            ztop = lerp(-0.004, 0.012, centre)
            zbot = lerp(-0.100, -0.150, centre)
            zl = lerp(ztop, zbot, v)
            z = HC.z + zl * hs
            pleat = 0.0035 * abs(math.sin(v * math.pi * 3.0)) ** 0.6 * smooth01(1 - abs(th) / 1.3)
            rr = drape(z, th) + (0.0035 + pleat) * hs
            ay = body.axis_y(z)
            p = Vector((math.sin(th) * rr, ay - math.cos(th) * rr, z))
            row.append(p)
            nrow.append(Vector((math.sin(th), -math.cos(th), 0.0)))
            erow.append({'crease': 0.4 + 0.6 * abs(math.sin(v * math.pi * 3)), 'band': 1.0 if (v < 0.06 or v > 0.94) else 0.0})
        Pts.append(row)
        Nr.append(nrow)
        ex.append(erow)
    part.slab(Pts, Nr, 0.0018 * hs, ex)
    # ties round the back of the head
    for sx in (1, -1):
        for z0, z1 in ((0.004, 0.045), (-0.100, -0.060)):
            ctrl = []
            for k in range(9):
                t = k / 8
                th = sx * lerp(thm - 0.03, math.pi * 0.97, t)
                zl = lerp(z0, z1, smooth01(t))
                e = math.asin(clamp(zl / 0.125, -0.9, 0.9))
                ctrl.append(body.surf_dome(e, th, False, (0.004 if abs(th) < 2.0 else 0.0115) * hs)[0])
            path, _ = resample(chaikin(ctrl, 2), 7 * res + 1)
            rws, nrs = [], []
            for i, p in enumerate(path):
                t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
                n = (p - HC).normalized()
                side = t.cross(n).normalized()
                rws.append([p - side * 0.0035 * hs, p + side * 0.0035 * hs])
                nrs.append([n, n])
            old = part.const
            part.const = {'mask': 1.0, 'tie': 1.0}
            part.slab(rws, nrs, 0.0014 * hs)
            part.const = old
    return [part]


# ====================================================================== footwear
def build_footwear(body, P, res):
    style = P['shoes']
    s = body.s
    J = body.J
    part = Part('shoe.L', 'cloth')
    x0 = J['ankle'].x + 0.004 * s
    heel_y, toe_y = 0.070 * s, (J['toe'].y - 0.018 * s)
    ball_y = J['ball'].y
    n = 14 * res + 1
    segs = 12 * res
    kind = {'clog': 'shoe', 'sneaker': 'shoe', 'boot': 'boot', 'sock': 'sock'}[style]
    part.const = {'shoe': 1.0} if kind != 'sock' else {'sock': 1.0}
    if style == 'boot':
        part.const = {'boot': 1.0, 'shoe': 1.0}

    def wf(p, ex):
        toe = smooth01((ball_y + 0.01 * s - p.y) / (0.03 * s))
        if p.z > J['ankle'].z + 0.03 * s:
            k = smooth01((p.z - J['ankle'].z - 0.03 * s) / (0.05 * s))
            return {'foot.L': 1 - k, 'shin.L': k}
        return {'foot.L': 1 - toe, 'toe.L': toe} if toe > 1e-3 else {'foot.L': 1.0}
    part.weight_fn = wf
    sole_t = {'clog': 0.030, 'sneaker': 0.026, 'boot': 0.034, 'sock': 0.006}[style] * s
    top_h = {'clog': 0.080, 'sneaker': 0.090, 'boot': 0.120, 'sock': 0.110}[style] * s
    width = {'clog': 1.10, 'sneaker': 1.02, 'boot': 1.10, 'sock': 0.92}[style]

    def prof(y):
        t = (heel_y - y) / (heel_y - toe_y)
        w = (0.031 + 0.012 * math.sin(min(1.0, t * 1.2) * math.pi * 0.62)) * s * width
        w *= lerp(1.0, 0.72 if style != 'clog' else 0.85, smooth01((t - 0.78) / 0.22))
        top = lerp(top_h, 0.064 * s, smooth01((t - 0.22) / 0.33))
        top = lerp(top, (0.036 if style != 'clog' else 0.050) * s, smooth01((t - 0.72) / 0.28))
        bot = 0.0
        return w, top, bot, t
    rings, ys, extras = [], [], []
    for i in range(n):
        tt = 0.5 - 0.5 * math.cos(i / (n - 1) * math.pi)
        y = lerp(heel_y, toe_y, tt)
        ys.append(y)
        w, top, bot, t = prof(y)
        zc = (top + bot) * 0.5
        hh = (top - bot) * 0.5
        endk = math.sqrt(max(0.0, 1 - max(smooth01((0.035 - t) / 0.035), smooth01((t - 0.955) / 0.045)) * 0.92))
        ring, er = [], []
        for j in range(segs):
            th = math.pi * 0.5 + TAU * j / segs
            c, sn = math.cos(th), math.sin(th)
            xx = w * endk * math.copysign(abs(c) ** (2.0 / 3.0), c)
            zz = zc + hh * endk * math.copysign(abs(sn) ** (2.0 / (2.2 if sn > 0 else 6.0)), sn)
            p = Vector((x0 + xx, y, zz))
            ring.append(p)
            e = {'sole': 1.0 if zz < sole_t else 0.0}
            if style == 'sock':
                e['grip'] = 1.0 if zz < 0.012 * s else 0.0
            if style == 'sneaker':
                e['lace'] = smooth01((zz - top + 0.02 * s) / (0.01 * s)) * smooth01((0.55 - t) / 0.1) * smooth01((t - 0.2) / 0.05) * smooth01((0.012 * s - abs(xx)) / (0.004 * s))
            er.append(e)
        rings.append(ring)
        extras.append(er)
    ids = part.tube(rings, extras,
                    cap_start=Vector((x0, heel_y + 0.003 * s, prof(heel_y)[1] * 0.5)),
                    cap_end=Vector((x0, toe_y - 0.003 * s, prof(toe_y)[1] * 0.5)))
    # shaft round the ankle (boot to mid-calf, sock cuff, low collar for shoes)
    st = body.leg_stations()
    shaft_top = {'clog': J['ankle'].z - 0.005 * s, 'sneaker': J['ankle'].z + 0.012 * s, 'boot': 0.285 * s, 'sock': 0.175 * s}[style]
    if shaft_top > 0.07 * s:
        zs_ = []
        z = 0.045 * s
        while z < shaft_top:
            zs_.append(z)
            z += 0.018 * s / res
        zs_.append(shaft_top)
        rr, ee = [], []
        loose = {'boot': 0.010, 'sock': 0.0025, 'sneaker': 0.006, 'clog': 0.004}[style] * s
        for z in zs_:
            sv = st['A'] - (z - J['ankle'].z)
            ring, er = [], []
            for j in range(segs):
                th = TAU * j / segs
                a, b = body.leg_radius(sv, th, st)
                r = math.hypot(a, b)
                k = (r + loose) / max(r, 1e-6)
                cy = J['ankle'].y + 0.010 * s * smooth01((0.10 * s - z) / 0.05)
                p = Vector((J['ankle'].x + b * k, cy - a * k, z))
                ring.append(p)
                er.append({'band': 1.0 if z > shaft_top - 0.012 * s else 0.0})
            rr.append(ring)
            ee.append(er)
        ids2 = part.tube(rr, ee)
        hem_ring(part, ids2[-1], 0.003 * s, 0.006 * s, {'band': 1.0})
    return [part, part.mirrored('shoe.R')]


# ====================================================================== caps for the cut
def cut_cap(part, ring_ids, towards, extra_edge, name_attrs=True, flip=False):
    """A flat flesh-and-bone face over a ring of existing vertices (copied so it shades flat)."""
    pts = [part.v[i] for i in ring_ids]
    c = sum(pts, Vector()) / len(pts)
    R = sum((p - c).length for p in pts) / len(pts)
    ids_outer = []
    ids_mid = []
    for i, p in zip(ring_ids, pts):
        e = {'flesh': 1.0, 'stumpz': 1.0}
        ids_outer.append(part.add_v(p, dict(e, flesh=0.6), w=dict(part.w[i]), uv2=part.uv2[i]))
        q = c + (p - c) * 0.86 - towards * 0.0015
        ids_mid.append(part.add_v(q, e, w=dict(part.w[i]), uv2=part.uv2[i]))
    # two forearm bones: raised ivory discs (texture), the centre slightly proud
    cid = part.add_v(c + towards * 0.001, {'flesh': 1.0, 'bone': 1.0, 'stumpz': 1.0}, w=dict(part.w[ring_ids[0]]), uv2=part.uv2[ring_ids[0]])
    u0 = part.next_uv_block(R * 2.4)
    ax = (pts[0] - c).normalized()
    ay = towards.cross(ax).normalized()

    def uv(p):
        d = p - c
        return (u0 + R * 1.2 + d.dot(ax), R * 1.2 + d.dot(ay))
    n = len(ring_ids)
    for k in range(n):
        k2 = (k + 1) % n
        q = (ids_outer[k], ids_outer[k2], ids_mid[k2], ids_mid[k])
        tri = (ids_mid[k], ids_mid[k2], cid)
        uvq = [uv(part.v[i]) for i in q]
        uvt = [uv(part.v[i]) for i in tri]
        fq, ft = q, tri
        # outward normal must point along `towards`
        a, b_, c_ = [part.v[i] for i in fq[:3]]
        if (b_ - a).cross(c_ - a).dot(towards) < 0:
            fq, uvq = fq[::-1], uvq[::-1]
        a, b_, c_ = [part.v[i] for i in ft]
        if (b_ - a).cross(c_ - a).dot(towards) < 0:
            ft, uvt = ft[::-1], uvt[::-1]
        part.face(fq, uvq)
        part.face(ft, uvt)
    return c, R


# ====================================================================== the character
def build_character(P, res=1):
    body = hu_body.Body(P, res)
    s, hs = body.s, body.hs
    J = body.J
    body.spine_joints()
    parts = []
    info = {'body': body, 'sites': {}, 'P': P}
    skin = body.build_skin()
    eyes, lids = body.build_eyes()
    ear = body.build_ear()
    arm = body.build_arm()
    fingers = body.build_fingers()
    leg = body.build_leg()
    armR, fingersR, legR = arm.mirrored('arm.R'), fingers.mirrored('fingers.R'), leg.mirrored('leg.R')
    for p in (armR, fingersR):
        p.uv2 = [(u, 1.0) for u, _ in p.uv2]
    for p in (arm, fingers):
        p.uv2 = [(u, -1.0) for u, _ in p.uv2]
    st_arm = arm.meta['st']
    st_leg = leg.meta['st']
    info['arm_stations'] = st_arm
    info['leg_stations'] = st_leg
    outfit = P['outfit']

    garments = []
    cover = {'trunk': [], 'arm': [], 'leg': []}     # predicates (p, s) -> covered

    # ------------------------------------------------------------------ scrubs
    if outfit == 'scrubs':
        top = Part('scrub_top', 'cloth')
        top.const = {'scrubs': 1.0, 'tint': 1.0}
        z_hem = lambda th: 0.905 * s + 0.006 * s * math.cos(th * 2)

        def z_neck(th):
            a = abs(th)
            back = 1.520 * s
            if a < 1.05:
                return lerp(1.345 * s, 1.515 * s, smooth01(a / 1.05) ** 0.85)
            return lerp(1.525 * s, back, smooth01((a - 1.05) / 2.0))

        def off_top(z, th):
            o = 0.010 + 0.010 * smooth01((1.30 * s - z) / (0.35 * s))
            o += 0.004 * math.exp(-((z - 1.20 * s) / (0.08 * s)) ** 2) * max(0.0, math.cos(th))
            return o * s

        def top_attrs(p, z, th, v):
            pocket = 1.0 if (0.045 * s < p.x < 0.135 * s and 1.215 * s < z < 1.335 * s and math.cos(th) > 0.3) else 0.0
            return {'pocket': pocket, 'crease': 0.3 + 0.7 * smooth01((1.15 * s - z) / (0.2 * s)),
                    'band': 1.0 if v > 0.965 or v < 0.03 else 0.0, 'blood': 0.6 * smooth01((1.25 * s - z) / (0.2 * s))}
        g = TrunkGarment(body, 'scrub_top', z_hem, z_neck, off_top, 40 * res, 18 * res, attrs=top_attrs, feat_k=0.35, folds=0.0035)
        ids, rings = g.build(top, lambda p, ex: body.trunk_weights(p))
        hem_ring(top, ids[0], 0.008 * s, -0.004 * s, {'band': 1.0})
        hem_ring(top, ids[-1], 0.006 * s, 0.004 * s, {'band': 1.0})
        # short sleeves
        sl_end = 0.150 * s
        sl = Part('scrub_sleeve.L', 'cloth')
        sl.const = {'scrubs': 1.0, 'tint': 1.0}
        ids_s, rings_s, sv_s, fr_s = limb_tube(sl, body, 'arm', -0.035 * s, sl_end,
                                                lambda sv, th: (0.011 + 0.010 * smooth01(sv / sl_end)) * s,
                                                16 * res, lambda sv, th: {'band': 1.0 if sv > sl_end - 0.012 * s else 0.0, 'crease': 0.6}, 0.02 * s / res)
        tuck_end(sl, ids_s[-1], fr_s[0][-1], 0.012 * s, 0.93, {'band': 1.0})
        # pants
        pants = Part('scrub_pants', 'cloth')
        pants.const = {'pants': 1.0, 'tint': 1.0}
        gp = TrunkGarment(body, 'scrub_pants', lambda th: 0.860 * s, lambda th: 1.000 * s,
                          lambda z, th: (0.013 + 0.004 * smooth01((0.95 * s - z) / (0.1 * s))) * s, 44 * res, 7 * res,
                          attrs=lambda p, z, th, v: {'band': 1.0 if v > 0.72 else 0.0, 'crease': 0.5}, feat_k=0.5, folds=0.003)
        ids_p, rings_p = gp.build(pants, lambda p, ex: body.trunk_weights(p))
        hem_ring(pants, ids_p[-1], 0.006 * s, 0.006 * s, {'band': 1.0})
        c0 = sum(rings_p[0], Vector()) / len(rings_p[0])
        pants.fan(ids_p[0], c0 - Vector((0, 0, 0.02 * s)), flip=True)
        pl = Part('scrub_leg.L', 'cloth')
        pl.const = {'pants': 1.0, 'tint': 1.0}
        cuff = st_leg['end'] - 0.004 * s
        ids_l, rings_l, sv_l, fr_l = limb_tube(pl, body, 'leg', -0.10 * s, cuff,
                                                lambda sv, th: (0.016 + 0.010 * smooth01((sv - 0.2 * s) / (0.4 * s)) + 0.006 * math.exp(-((sv - st_leg['K']) / (0.08 * s)) ** 2) + 0.010 * smooth01((sv - cuff + 0.10 * s) / (0.10 * s))) * s,
                                                14 * res, lambda sv, th: {'band': 1.0 if sv > cuff - 0.015 * s else 0.0, 'crease': 0.4 + 0.6 * math.exp(-((sv - st_leg['K']) / (0.1 * s)) ** 2),
                                                                          'grime': smooth01((sv - st_leg['K']) / (0.3 * s))}, 0.045 * s / res, dense_at=(st_leg['K'],))
        tuck_end(pl, ids_l[-1], fr_l[0][-1], 0.015 * s, 0.94, {'band': 1.0})
        garments += [top, sl, sl.mirrored('scrub_sleeve.R'), pants, pl, pl.mirrored('scrub_leg.R')]

        gash_band = (0.955 * s, 1.262 * s) if P['gash'] else None

        def cov_trunk(p, sv=None):
            th = math.atan2(p.x, -(p.y - body.axis_y(p.z)))
            if gash_band and gash_band[0] < p.z < gash_band[1]:
                return False
            return 0.80 * s < p.z < z_neck(th) - 0.018 * s or p.z <= 0.80 * s
        cover['trunk'].append(cov_trunk)
        cover['arm'].append(lambda p, sv: sv < sl_end - 0.025 * s)
        cover['leg'].append(lambda p, sv: sv < cuff - 0.03 * s)
        if P['gash']:
            # split the top at a ring above the belly: TopLower hides to bare it, TopRolled shows the roll
            z_roll = 1.262 * s
            top.smooth_normals()
            lower = top.extract(lambda fi, pts: sum(q.z for q in pts) / len(pts) < z_roll and all(q.z < z_roll + 0.004 * s for q in pts), 'scrub_top_lower')
            lower.meta['piece'] = 'TopLower'
            garments.append(lower)
            roll = Part('scrub_roll', 'cloth')
            roll.const = {'scrubs': 1.0, 'tint': 1.0, 'crease': 1.0}
            roll.meta['piece'] = 'TopRolled'
            segs_r = 44 * res
            rings_r = []
            for k in range(8 * res):
                a = TAU * k / (8 * res)
                ring = []
                for j in range(segs_r):
                    th = TAU * j / segs_r
                    base = g.point(z_roll, th, 0.004 * s)
                    d = Vector((math.sin(th), -math.cos(th), 0))
                    tube_r = (0.016 + 0.003 * math.sin(th * 9 + 1.3) + 0.002 * math.sin(th * 23)) * s
                    ring.append(base + d * (tube_r * (1 + math.cos(a)) * 0.9) + Vector((0, 0, tube_r * math.sin(a) * 0.9 - 0.004 * s)))
                rings_r.append(ring)
            # rings go round the torso; wrap both ways: build as a torus grid
            ids_r = []
            for ring in rings_r:
                ids_r.append([roll.add_v(p, None, w=body.trunk_weights(p)) for p in ring])
            u0 = roll.next_uv_block(1.0)
            nk = len(ids_r)
            for k in range(nk):
                k2 = (k + 1) % nk
                for j in range(segs_r):
                    j2 = (j + 1) % segs_r
                    q = (ids_r[k][j], ids_r[k][j2], ids_r[k2][j2], ids_r[k2][j])
                    roll.face(q, [(u0 + j * 0.02, k * 0.02), (u0 + (j + 1) * 0.02, k * 0.02), (u0 + (j + 1) * 0.02, (k + 1) * 0.02), (u0 + j * 0.02, (k + 1) * 0.02)])
            # outward winding
            c = Vector((0, body.axis_y(z_roll), z_roll))
            a0, b0, c0_ = [roll.v[i] for i in roll.f[0][:3]]
            if (b0 - a0).cross(c0_ - a0).dot(a0 - (c + (Vector((a0.x, a0.y - c.y, 0)).normalized() * 0.12 * s))) < 0:
                roll.f = [tuple(reversed(f)) for f in roll.f]
                roll.fuv = [list(reversed(u)) for u in roll.fuv]
            garments.append(roll)

    # ------------------------------------------------------------------ gown
    if outfit == 'gown':
        gown = Part('gown', 'cloth')
        gown.const = {'gown': 1.0}
        hem = lambda th: 0.500 * s + 0.012 * s * math.sin(th * 3 + 0.5)

        def neck(th):
            a = abs(th)
            return lerp(1.480 * s, 1.520 * s, smooth01((a - 0.3) / 1.4))

        def off_g(z, th):
            o = 0.016 + 0.010 * smooth01((1.30 * s - z) / (0.4 * s))
            front = max(0.0, math.cos(th))
            # hug the belly over the wound so the gown never stands proud of it
            o -= 0.012 * front * math.exp(-((z - 1.03 * s) / (0.12 * s)) ** 2)
            return o * s

        def skirt_w(p, ex):
            z = p.z
            w = body.trunk_weights(p)
            blend = smooth01((1.00 * s - z) / (0.12 * s))
            if blend <= 0:
                return w
            leg = 0.65 * smooth01((0.95 * s - z) / (0.45 * s))
            side = smooth01(p.x / (0.20 * s) + 0.5)
            target = {'hips': 1 - leg, 'thigh.L': leg * side, 'thigh.R': leg * (1 - side)}
            out = {}
            for k in set(w) | set(target):
                v = w.get(k, 0.0) * (1 - blend) + target.get(k, 0.0) * blend
                if v > 1e-4:
                    out[k] = v
            return out

        def gown_attrs(p, z, th, v):
            return {'crease': 0.3 + 0.7 * smooth01((1.0 * s - z) / (0.4 * s)), 'band': 1.0 if v > 0.97 else 0.0,
                    'seam': math.exp(-((abs(th) - math.pi) / 0.05) ** 2), 'grime': smooth01((0.8 * s - z) / (0.3 * s))}
        gg = TrunkGarment(body, 'gown', hem, neck, off_g, 44 * res, 26 * res, attrs=gown_attrs, feat_k=0.45, folds=0.005,
                          fold_scale=12.0, below_hip_flare=0.10)
        ids_g, rings_g = gg.build(gown, skirt_w)
        hem_ring(gown, ids_g[0], 0.008 * s, -0.006 * s, {'band': 1.0})
        hem_ring(gown, ids_g[-1], 0.006 * s, 0.004 * s, {'band': 1.0})
        slg = Part('gown_sleeve.L', 'cloth')
        slg.const = {'gown': 1.0}
        gs_end = 0.125 * s
        ids_s, rings_s, sv_s, fr_s = limb_tube(slg, body, 'arm', -0.012 * s, gs_end, lambda sv, th: (0.006 + 0.020 * smooth01((sv + 0.012 * s) / (gs_end + 0.012 * s))) * s,
                                                16 * res, lambda sv, th: {'band': 1.0 if sv > gs_end - 0.012 * s else 0.0}, 0.02 * s / res)
        tuck_end(slg, ids_s[-1], fr_s[0][-1], 0.012 * s, 0.93, {'band': 1.0})
        garments += [gown, slg, slg.mirrored('gown_sleeve.R')]
        # the gunshot window: a panel over the right lower belly the game can hide
        W_TH = (-1.30, 0.02)
        W_Z = (0.915 * s, 1.165 * s)
        gown.smooth_normals()

        def in_window(fi, pts):
            c = sum(pts, Vector()) / len(pts)
            th = math.atan2(c.x, -(c.y - body.axis_y(c.z)))
            return W_TH[0] < th < W_TH[1] and W_Z[0] < c.z < W_Z[1]
        panel = gown.extract(in_window, 'gown_panel')
        panel.meta['piece'] = 'GownPanel'
        garments.append(panel)
        # piping round the window on the gown
        pip = Part('gown_piping', 'cloth')
        pip.const = {'gown': 1.0, 'band': 1.0}
        corners = []
        for k in range(4 * 12 * res):
            t = k / (4 * 12 * res) * 4
            side = int(t)
            f = t - side
            if side == 0:
                th, z = lerp(W_TH[0], W_TH[1], f), W_Z[0]
            elif side == 1:
                th, z = W_TH[1], lerp(W_Z[0], W_Z[1], f)
            elif side == 2:
                th, z = lerp(W_TH[1], W_TH[0], f), W_Z[1]
            else:
                th, z = W_TH[0], lerp(W_Z[1], W_Z[0], f)
            corners.append(gg.point(z, th, 0.0015 * s))
        path = corners + [corners[0]]
        rings_p, _, fr = sweep(path, 4, lambda i, sv, th: (0.0035 * s * math.cos(th), 0.0035 * s * math.sin(th)), Vector((0, 0, 1)), 0.0)
        pip.weight_fn = lambda p, ex: skirt_w(p, ex)
        pip.tube(rings_p)
        garments.append(pip)
        info['gown_window'] = {'theta': W_TH, 'z': W_Z}
        win_margin = 0.02 * s

        def cov_trunk_g(p, sv=None):
            th = math.atan2(p.x, -(p.y - body.axis_y(p.z)))
            if W_TH[0] - 0.12 < th < W_TH[1] + 0.12 and W_Z[0] - win_margin < p.z < W_Z[1] + win_margin:
                return False
            return p.z < neck(th) - 0.02 * s
        cover['trunk'].append(cov_trunk_g)
        cover['arm'].append(lambda p, sv: sv < gs_end - 0.03 * s)
        cover['leg'].append(lambda p, sv: sv < st_leg['K'] - 0.15 * s)

    # ------------------------------------------------------------------ paramedic uniform
    if outfit == 'paramedic':
        jk = Part('uniform_top', 'cloth')
        jk.const = {'uniform': 1.0}
        z_hem = lambda th: 0.960 * s
        z_col = lambda th: 1.546 * s if abs(th) > 0.3 else 1.530 * s
        refl_z = (1.265 * s, 1.300 * s)

        def off_u(z, th):
            o = 0.013 + 0.008 * smooth01((1.25 * s - z) / (0.3 * s))
            if refl_z[0] < z < refl_z[1]:
                o += 0.0015
            if z > 1.515 * s:   # a low collar round the neck
                o += 0.004
            o -= 0.010 * smooth01((1.05 * s - z) / (0.07 * s))    # tucked into the trousers
            return o * s

        def u_attrs(p, z, th, v):
            return {'reflect': 1.0 if refl_z[0] + 0.002 * s < z < refl_z[1] - 0.002 * s else 0.0,
                    'zip': math.exp(-(th / 0.035) ** 2) if z < 1.56 * s else 0.0,
                    'patch': 1.0 if (0.05 * s < p.x < 0.12 * s and 1.33 * s < z < 1.40 * s and math.cos(th) > 0.3) else 0.0,
                    'band': 1.0 if v > 0.95 or v < 0.03 else 0.0, 'crease': 0.5, 'blood': 0.3}
        gu = TrunkGarment(body, 'uniform_top', z_hem, z_col, off_u, 40 * res, 22 * res, attrs=u_attrs, feat_k=0.3, folds=0.004)
        ids_u, _ = gu.build(jk, lambda p, ex: body.trunk_weights(p))
        hem_ring(jk, ids_u[0], 0.008 * s, -0.004 * s, {'band': 1.0})
        hem_ring(jk, ids_u[-1], 0.006 * s, 0.006 * s, {'band': 1.0})
        slu = Part('uniform_sleeve.L', 'cloth')
        slu.const = {'uniform': 1.0}
        cuff_a = st_arm['W'] - 0.012 * s
        bands = [(0.20 * s, 0.232 * s), (st_arm['E'] + 0.09 * s, st_arm['E'] + 0.122 * s)]

        def sl_off(sv, th):
            o = 0.011 + 0.006 * math.exp(-((sv - st_arm['E']) / (0.08 * s)) ** 2) - 0.004 * smooth01((sv - cuff_a + 0.03 * s) / (0.03 * s))
            for a, b2 in bands:
                if a < sv < b2:
                    o += 0.0015
            return o * s

        def sl_attr(sv, th):
            r = 1.0 if any(a + 0.002 * s < sv < b2 - 0.002 * s for a, b2 in bands) else 0.0
            return {'reflect': r, 'band': 1.0 if sv > cuff_a - 0.02 * s else 0.0, 'crease': 0.4 + 0.6 * math.exp(-((sv - st_arm['E']) / (0.05 * s)) ** 2),
                    'grime': smooth01((sv - st_arm['E']) / (0.2 * s)), 'blood': smooth01((sv - cuff_a + 0.08 * s) / (0.06 * s))}
        ids_su, _, _, fr_su = limb_tube(slu, body, 'arm', -0.035 * s, cuff_a, sl_off, 16 * res, sl_attr, 0.022 * s / res,
                                         dense_at=[x for bnd in bands for x in bnd] + [st_arm['E']])
        tuck_end(slu, ids_su[-1], fr_su[0][-1], 0.010 * s, 0.9, {'band': 1.0})
        pants = Part('uniform_pants', 'cloth')
        pants.const = {'uniform': 1.0}
        gp = TrunkGarment(body, 'uniform_pants', lambda th: 0.860 * s, lambda th: 1.040 * s,
                          lambda z, th: 0.022 * s, 44 * res, 7 * res, attrs=lambda p, z, th, v: {'crease': 0.5}, feat_k=0.5, folds=0.003)
        ids_p, rings_p = gp.build(pants, lambda p, ex: body.trunk_weights(p))
        c0 = sum(rings_p[0], Vector()) / len(rings_p[0])
        pants.fan(ids_p[0], c0 - Vector((0, 0, 0.02 * s)), flip=True)
        # belt
        belt = Part('belt', 'cloth')
        belt.const = {'belt': 1.0}
        brings = []
        for z, e in ((0.992 * s, 0.002), (0.994 * s, 0.009), (1.032 * s, 0.009), (1.034 * s, 0.002)):
            brings.append([gp.point(z, TAU * j / (44 * res), e * s) for j in range(44 * res)])
        belt.weight_fn = lambda p, ex: body.trunk_weights(p)
        belt.tube(brings)
        # buckle and a radio pouch
        for (cx, cz, wx, hz, dep, key) in ((0.0, 1.013, 0.030, 0.034, 0.012, 'metal'), (0.13, 0.985, 0.050, 0.075, 0.035, 'belt')):
            th = math.atan2(cx, 0.12)
            base = gp.point(cz * s, th, 0.012 * s)
            n = Vector((math.sin(th), -math.cos(th), 0))
            side = Vector((0, 0, 1)).cross(n).normalized()
            rws, nrs = [], []
            for r in range(3):
                zz = lerp(-hz / 2, hz / 2, r / 2) * s
                rws.append([base + side * lerp(-wx / 2, wx / 2, c) * s + Vector((0, 0, zz)) + n * dep * s * 0.5 for c in (0, 0.5, 1)])
                nrs.append([n, n, n])
            old = belt.const
            belt.const = {key: 1.0, 'belt': 1.0}
            belt.slab(rws, nrs, dep * s)
            belt.const = old
        pl = Part('uniform_leg.L', 'cloth')
        pl.const = {'uniform': 1.0}
        boot_top_s = st_leg['A'] - (0.285 * s - J['ankle'].z)
        cuff = boot_top_s + 0.05 * s
        lband = (st_leg['K'] + 0.13 * s, st_leg['K'] + 0.165 * s)

        def pl_off(sv, th):
            o = 0.014 + 0.008 * smooth01((sv - 0.2 * s) / (0.3 * s)) + 0.005 * math.exp(-((sv - st_leg['K']) / (0.08 * s)) ** 2)
            o -= 0.006 * smooth01((sv - boot_top_s + 0.02 * s) / (0.05 * s))
            if lband[0] < sv < lband[1]:
                o += 0.0015
            return o * s

        def pl_attr(sv, th):
            return {'reflect': 1.0 if lband[0] + 0.002 * s < sv < lband[1] - 0.002 * s else 0.0,
                    'crease': 0.4 + 0.6 * math.exp(-((sv - st_leg['K']) / (0.1 * s)) ** 2), 'grime': smooth01((sv - st_leg['K'] + 0.1 * s) / (0.4 * s)),
                    'seam': math.exp(-((math.sin(th)) / 0.06) ** 2)}
        ids_l, _, _, fr_l = limb_tube(pl, body, 'leg', -0.10 * s, cuff, pl_off, 16 * res, pl_attr, 0.03 * s / res,
                                       dense_at=list(lband) + [st_leg['K']])
        tuck_end(pl, ids_l[-1], fr_l[0][-1], 0.02 * s, 0.9)
        # cargo pockets on the outer thighs
        pk = Part('pocket.L', 'cloth')
        pk.const = {'uniform': 1.0, 'pocket': 1.0}
        st_ = st_leg
        rws, nrs = [], []
        for r in range(4 * res + 1):
            sv = lerp(0.24 * s, 0.40 * s, r / (4 * res))
            row, nrow = [], []
            for c in range(5 * res + 1):
                th = lerp(1.25, 2.05, c / (5 * res))       # outer side (+B for the left leg)
                a, b2 = body.leg_radius(sv, th, st_)
                r0 = math.hypot(a, b2)
                k = (r0 + pl_off(sv, th) + 0.012 * s) / max(r0, 1e-6)
                p0 = body.leg_path([sv])[0]
                q = p0 + Vector((0, -1, 0)) * a * k + Vector((1, 0, 0)) * b2 * k
                row.append(q)
                nrow.append(Vector((math.sin(th) * 1.0, -math.cos(th), 0)).normalized())
            rws.append(row)
            nrs.append(nrow)
        pk.weight_fn = lambda p, ex: body.leg_weights_at(0.3 * s, st_)
        pk.slab(rws, nrs, 0.014 * s)
        garments += [jk, slu, slu.mirrored('uniform_sleeve.R'), pants, belt, pl, pl.mirrored('uniform_leg.R'), pk, pk.mirrored('pocket.R')]
        cover['trunk'].append(lambda p, sv=None: p.z < 1.540 * s - 0.03 * s)
        cover['arm'].append(lambda p, sv: sv < cuff_a - 0.025 * s)
        cover['leg'].append(lambda p, sv: sv < cuff - 0.04 * s)

    # ------------------------------------------------------------------ footwear, hair, headwear
    feet = build_footwear(body, P, res)
    garments += feet
    if P['shoes'] == 'boot':
        top_s = st_leg['A'] - (0.285 * s - J['ankle'].z)
        cover['leg'].append(lambda p, sv: sv > top_s + 0.03 * s)
    elif P['shoes'] == 'sock':
        top_s = st_leg['A'] - (0.175 * s - J['ankle'].z)
        cover['leg'].append(lambda p, sv: sv > top_s + 0.02 * s)
    else:
        cover['leg'].append(lambda p, sv: sv > st_leg['A'] + 0.005 * s)
    hair = build_hair(body, P, res)
    headwear = build_cap(body, P, res) + build_mask(body, P, res)

    # ------------------------------------------------------------------ cull hidden skin
    def cull(part, kind):
        preds = cover[kind]
        if not preds:
            return
        if kind == 'trunk':
            fn = lambda i: any(pr(part.v[i]) for pr in preds)
        else:
            fn = lambda i: any(pr(part.v[i], part.uv2[i][0]) for pr in preds)
        flags = [fn(i) for i in range(len(part.v))]
        part.extract(lambda fi, pts: all(flags[i] for i in part.f[fi]), part.name + '_culled')
    for p in (arm, armR):
        cull(p, 'arm')
    for p in (leg, legR):
        cull(p, 'leg')
    if hair and P['hair'] in ('crop', 'bun', 'ponytail'):
        HC = body.HC

        def under_hair(pt):
            q = (pt - HC) / hs
            th = math.atan2(q.x, -q.y)
            return q.z > body.hairline(th) + 0.016 and q.length > 0.05
        cover['trunk'].append(lambda p, sv=None: under_hair(p))
    cull(skin, 'trunk')

    # ------------------------------------------------------------------ Bob's removable right forearm
    if P['amputee_arm']:
        cut = st_arm['cut']
        for p in (armR, fingersR):
            p.smooth_normals()
        ring_upper = None
        # vertices of the ring at the cut (uv2.x == cut) in the upper arm
        fore = armR.extract(lambda fi, pts: min(armR.uv2[i][0] for i in armR.f[fi]) >= cut - 1e-6, 'forearm.R')
        fore.meta['piece'] = 'Forearm_R'
        ring_u = [i for i, (u, _) in enumerate(armR.uv2) if abs(u - cut) < 1e-6]
        ring_f = [i for i, (u, _) in enumerate(fore.uv2) if abs(u - cut) < 1e-6]
        # order ring vertices around the arm axis
        path = arm.meta['path']
        svals = arm.meta['svals']
        ci = svals.index(cut)
        axis_p = Vector((-path[ci].x, path[ci].y, path[ci].z))
        fr = arm.meta['frames']
        T = Vector((-fr[0][ci].x, fr[0][ci].y, fr[0][ci].z))
        N = Vector((-fr[1][ci].x, fr[1][ci].y, fr[1][ci].z))
        B = T.cross(N)

        def order(part, ids):
            return sorted(ids, key=lambda i: math.atan2((part.v[i] - axis_p).dot(B), (part.v[i] - axis_p).dot(N)))
        ring_u = order(armR, ring_u)
        ring_f = order(fore, ring_f)
        cut_cap(armR, ring_u, T, None)
        cut_cap(fore, ring_f, -T, None)
        # the right fingers ride with the forearm piece
        fore.merge(fingersR)
        fingersR = None
        a_cut, b_cut = body.arm_radius(cut, 0.0, st_arm)[0], body.arm_radius(cut, math.pi / 2, st_arm)[1]
        info['forearm_cut'] = {'s': cut, 'centre': axis_p, 'T': T, 'N': N, 'half_up': abs(a_cut), 'half_side': abs(b_cut)}
        garments.append(fore)

    # ------------------------------------------------------------------ players' gash piece
    if P['gash']:
        skin.smooth_normals()
        th_g = body.GASH_TH
        zg, half = body.GASH_Z, body.GASH_HALF
        gp_pt, _ = body.surf_slice(zg, th_g)

        def near_gash(fi, pts):
            c = sum(pts, Vector()) / len(pts)
            th = math.atan2(c.x, -(c.y - body.axis_y(c.z)))
            return abs(th - th_g) < 0.42 and abs(c.z - zg) < half + 0.045 * s
        gpiece = skin.extract(near_gash, 'gash_skin')
        gpiece.meta['piece'] = 'GashSkin'
        offs = []
        half_gap = 0.016 * s
        for i, p in enumerate(gpiece.v):
            th = math.atan2(p.x, -(p.y - body.axis_y(p.z)))
            r = math.hypot(p.x, p.y - body.axis_y(p.z))
            perp = (th - th_g) * r            # metres across the gash (+ = towards the character's left)
            along = (p.z - zg) / half
            env = math.sqrt(max(0.0, 1 - along * along)) if abs(along) < 1 else 0.0
            d_out = Vector((math.sin(th), -math.cos(th), 0.0))
            d_side = Vector((math.cos(th), math.sin(th), 0.0))
            pull = half_gap * env * math.copysign(1.0, perp) * math.exp(-(perp / (0.022 * s)) ** 2) * smooth01(abs(perp) / (0.004 * s))
            sink = -0.010 * s * env * math.exp(-(perp / (0.010 * s)) ** 2)
            offs.append(d_side * pull + d_out * sink)
            gpiece.attr['gashz'][i] = env * math.exp(-(perp / (0.020 * s)) ** 2)
        gpiece.shape_keys['GashOpen'] = offs
        garments.append(gpiece)

    # ------------------------------------------------------------------ assemble
    for p in [skin, eyes, lids, ear, ear.mirrored('ear.R'), arm, armR, fingers, leg, legR] + ([fingersR] if fingersR else []):
        parts.append(p)
    parts += hair + garments + headwear
    for p in parts:
        p.fill_weights()
        if p.nrm is None:
            p.smooth_normals()
    info['sites'] = sites(body, P, info)
    return parts, info


# ====================================================================== sites
def godot_frame(x_dir, y_dir, origin):
    """A 4x4 Blender world matrix whose glTF/Godot local axes are X = x_dir, Y = y_dir, Z = X cross Y.
    The exporter maps Blender local (x, y, z) to glTF (x, z, -y): so Blender columns are (X, -Zg, Y)."""
    X = x_dir.normalized()
    Y = (y_dir - X * y_dir.dot(X)).normalized()
    Zg = X.cross(Y)
    M = Matrix.Identity(4)
    for r in range(3):
        M[r][0] = X[r]
        M[r][1] = -Zg[r]
        M[r][2] = Y[r]
        M[r][3] = origin[r]
    return M


def sites(body, P, info):
    s = body.s
    out = {}
    st = info['arm_stations']
    arm_path = lambda sv: body.arm_path([sv])[0][0]
    T, N, B = body.arm_frame()
    # right arm = mirror of the left: the thumb-side front (N) becomes the site's up
    def mirror(v):
        return Vector((-v.x, v.y, v.z))

    def arm_site(sv, side, ang, bone):
        c = arm_path(sv)
        path = body.arm_path([sv - 0.005 * s, sv + 0.005 * s])[0]
        t = (path[1] - path[0]).normalized()
        frames_ = frames([path[0], c, path[1]], Vector((0, -1, 0)))
        n, bb = frames_[1][1], frames_[2][1]
        a, b2 = body.arm_radius(sv, ang, st)
        up = (n * math.cos(ang) + bb * math.sin(ang)).normalized()
        surf = c + n * a + bb * b2
        half_up = math.hypot(a, b2)
        a90, b90 = body.arm_radius(sv, ang + math.pi / 2, st)
        half_side = math.hypot(a90, b90)
        if side == 'R':
            c, surf, t, up = mirror(c), mirror(surf), mirror(t), mirror(up)
        return {'bone': bone, 'matrix': godot_frame(t, up, surf), 'origin': surf, 'x': t, 'y': up,
                'half_up': half_up, 'half_side': half_side, 'axis_depth': half_up, 'shape': 2.2}
    out['limb'] = arm_site(st['tq'], 'R', 0.0, 'upperarm.R')
    out['limb_cut'] = arm_site(st['cut'], 'R', 0.0, 'forearm.R')
    out['limb']['infection_start'] = st['inf0'] - st['tq']
    out['limb_cut']['infection_start'] = st['inf0'] - st['cut']
    out['injection'] = arm_site(st['vein'], 'L', 0.55, 'forearm.L')
    for k in ('limb', 'limb_cut', 'injection'):
        out[k]['s'] = {'limb': st['tq'], 'limb_cut': st['cut'], 'injection': st['vein']}[k]
    # gunshot: right lower belly, X towards the feet
    th = -0.62
    z = 1.035 * s
    p, _ = body.surf_slice(z, th)
    p2, _ = body.surf_slice(z + 0.01, th)
    p3, _ = body.surf_slice(z, th + 0.02)
    nrm = (p3 - p).cross(p2 - p).normalized()
    if nrm.dot(Vector((math.sin(th), -math.cos(th), 0))) < 0:
        nrm = -nrm
    out['gunshot'] = {'bone': 'hips', 'matrix': godot_frame(Vector((0, 0, -1)), nrm, p), 'origin': p, 'x': Vector((0, 0, -1)), 'y': nrm}
    if P['gash']:
        th = body.GASH_TH
        z = body.GASH_Z
        p, _ = body.surf_slice(z, th)
        p2, _ = body.surf_slice(z + 0.01, th)
        p3, _ = body.surf_slice(z, th + 0.02)
        nrm = (p3 - p).cross(p2 - p).normalized()
        if nrm.dot(Vector((math.sin(th), -math.cos(th), 0))) < 0:
            nrm = -nrm
        out['gash'] = {'bone': 'spine', 'matrix': godot_frame(Vector((0, 0, -1)), nrm, p), 'origin': p, 'x': Vector((0, 0, -1)), 'y': nrm,
                       'half_len': body.GASH_HALF, 'half_gap': 0.016 * s}
    # eyes and the head top, handy for cameras and the dissection head
    out['eyes'] = {'bone': 'head', 'matrix': godot_frame(Vector((1, 0, 0)), Vector((0, 0, 1)), body.HC + Vector((0, body.eye_c.y - 0.012, body.eye_c.z)) * body.hs),
                   'origin': body.HC + Vector((0, body.eye_c.y, body.eye_c.z)) * body.hs, 'x': Vector((1, 0, 0)), 'y': Vector((0, 0, 1))}
    return out
