"""Procedural Cycles materials for the humans (the source of the baked maps).

Each material exposes four signals the baker switches onto the output: color (albedo), rough
(roughness), mask (the game's mask texture) and the bumped normal.

Mask textures (<variant>_<Material>_mask.png, 1024, linear):
  Cloth: R = player tint (scrubs, trousers, cap; blood and dirt excluded), G = reflective strips, B = 0
  Skin:  R = anesthetic vein (inner left elbow), G = players' belly gash, B = Bob's gunshot wound site
"""
import math
import bpy
from mathutils import Vector
import hu_body


def lin(c):
    def f(x):
        return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4
    return tuple(f(x) for x in c)


def scale_col(c, k):
    return tuple(max(0.0, min(1.0, x * k)) for x in c)


class NB:
    def __init__(self, mat):
        self.mat = mat
        self.nt = mat.node_tree
        self.nt.nodes.clear()
        self.x = 0

    def n(self, kind, **props):
        node = self.nt.nodes.new(kind)
        node.location = (self.x, 0)
        self.x += 30
        for k, v in props.items():
            setattr(node, k, v)
        return node

    def link(self, a, b):
        self.nt.links.new(a, b)

    def attr(self, name):
        return self.n('ShaderNodeAttribute', attribute_name=name, attribute_type='GEOMETRY').outputs['Fac']

    def math(self, op, a, b=None, clamp=False):
        node = self.n('ShaderNodeMath', operation=op, use_clamp=clamp)
        for i, v in enumerate((a, b)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                node.inputs[i].default_value = v
            else:
                self.link(v, node.inputs[i])
        return node.outputs[0]

    def mul(self, *vals):
        out = vals[0]
        for v in vals[1:]:
            out = self.math('MULTIPLY', out, v)
        return out

    def add(self, a, b):
        return self.math('ADD', a, b)

    def maxi(self, *vals):
        out = vals[0]
        for v in vals[1:]:
            out = self.math('MAXIMUM', out, v)
        return out

    def inv(self, a):
        return self.math('SUBTRACT', 1.0, a, clamp=True)

    def mr(self, v, fmin, fmax, tmin=0.0, tmax=1.0, smooth=True):
        node = self.n('ShaderNodeMapRange', interpolation_type='SMOOTHSTEP' if smooth else 'LINEAR', clamp=True)
        self.link(v, node.inputs['Value'])
        node.inputs['From Min'].default_value = fmin
        node.inputs['From Max'].default_value = fmax
        node.inputs['To Min'].default_value = tmin
        node.inputs['To Max'].default_value = tmax
        return node.outputs['Result']

    def mix(self, fac, a, b):
        node = self.n('ShaderNodeMix', data_type='RGBA', clamp_factor=True)
        for idx, v in ((0, fac), (6, a), (7, b)):
            if isinstance(v, (int, float)):
                node.inputs[idx].default_value = v
            elif isinstance(v, tuple):
                node.inputs[idx].default_value = (*v, 1.0) if len(v) == 3 else v
            else:
                self.link(v, node.inputs[idx])
        return node.outputs[2]

    def coords(self):
        return self.n('ShaderNodeTexCoord').outputs['Object']

    def sep(self, vec):
        s = self.n('ShaderNodeSeparateXYZ')
        self.link(vec, s.inputs[0])
        return s.outputs['X'], s.outputs['Y'], s.outputs['Z']

    def vscale(self, vec, s):
        node = self.n('ShaderNodeMapping')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = s
        return node.outputs['Vector']

    def noise(self, vec, scale, detail=4.0, rough=0.5, distort=0.0, fac=True):
        node = self.n('ShaderNodeTexNoise')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        node.inputs['Detail'].default_value = detail
        node.inputs['Roughness'].default_value = rough
        node.inputs['Distortion'].default_value = distort
        return node.outputs['Fac'] if fac else node.outputs['Color']

    def voronoi(self, vec, scale, feature='F1', rand=1.0):
        node = self.n('ShaderNodeTexVoronoi', feature=feature)
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        node.inputs['Randomness'].default_value = rand
        return node.outputs['Distance']

    def warp(self, vec, scale, amount):
        col = self.noise(vec, scale, 3.0, 0.5, fac=False)
        sub = self.n('ShaderNodeVectorMath', operation='SUBTRACT')
        self.link(col, sub.inputs[0])
        sub.inputs[1].default_value = (0.5, 0.5, 0.5)
        sc = self.n('ShaderNodeVectorMath', operation='SCALE')
        self.link(sub.outputs[0], sc.inputs[0])
        sc.inputs['Scale'].default_value = amount
        ad = self.n('ShaderNodeVectorMath', operation='ADD')
        self.link(vec, ad.inputs[0])
        self.link(sc.outputs[0], ad.inputs[1])
        return ad.outputs[0]

    def ellip(self, co, c, s):
        mp = self.n('ShaderNodeMapping', vector_type='POINT')
        self.link(co, mp.inputs['Vector'])
        mp.inputs['Scale'].default_value = (1 / s[0], 1 / s[1], 1 / s[2])
        mp.inputs['Location'].default_value = (-c[0] / s[0], -c[1] / s[1], -c[2] / s[2])
        ln = self.n('ShaderNodeVectorMath', operation='LENGTH')
        self.link(mp.outputs[0], ln.inputs[0])
        return ln.outputs['Value']

    def rgb(self, r, g, b):
        node = self.n('ShaderNodeCombineColor')
        for i, v in enumerate((r, g, b)):
            if isinstance(v, (int, float)):
                node.inputs[i].default_value = v
            else:
                self.link(v, node.inputs[i])
        return node.outputs[0]

    def finish(self, color, rough, height, mask, strength=1.0, distance=0.001):
        bsdf = self.n('ShaderNodeBsdfPrincipled')
        self.link(color, bsdf.inputs['Base Color'])
        self.link(rough, bsdf.inputs['Roughness'])
        bump = self.n('ShaderNodeBump')
        bump.inputs['Strength'].default_value = strength
        bump.inputs['Distance'].default_value = distance
        self.link(height, bump.inputs['Height'])
        self.link(bump.outputs['Normal'], bsdf.inputs['Normal'])
        emit = self.n('ShaderNodeEmission')
        emit.name = 'BakeEmit'
        out = self.n('ShaderNodeOutputMaterial')
        out.name = 'Out'
        self.link(bsdf.outputs[0], out.inputs['Surface'])
        for nm, sock in (('SIG_color', color), ('SIG_rough', rough), ('SIG_mask', mask)):
            r = self.n('NodeReroute')
            r.name = nm
            self.link(sock, r.inputs[0])
        bsdf.name = 'BSDF'


def set_bake_signal(mat, which):
    nt = mat.node_tree
    out, emit, bsdf = nt.nodes['Out'], nt.nodes['BakeEmit'], nt.nodes['BSDF']
    for l in list(out.inputs['Surface'].links):
        nt.links.remove(l)
    if which in ('color', 'rough', 'mask'):
        for l in list(emit.inputs['Color'].links):
            nt.links.remove(l)
        nt.links.new(nt.nodes['SIG_' + which].outputs[0], emit.inputs['Color'])
        nt.links.new(emit.outputs[0], out.inputs['Surface'])
    else:
        nt.links.new(bsdf.outputs[0], out.inputs['Surface'])


# ====================================================================== cloth
def cloth_material(P):
    mat = bpy.data.materials.new('HU_Cloth_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    X, Y, Z = b.sep(co)
    A = {k: b.attr(k) for k in ('scrubs', 'pants', 'tint', 'cap', 'mask', 'tie', 'gown', 'sock', 'grip', 'uniform', 'reflect',
                                'boot', 'belt', 'metal', 'shoe', 'sole', 'lace', 'band', 'pocket', 'seam', 'patch', 'zip',
                                'blood', 'grime', 'crease')}
    s = P['height'] / 1.78
    grime_k = P['grime']
    blood_k = P['blood']
    seed = P['seed']
    co_s = b.vscale(co, (1.0, 1.0, 1.0))
    # --- base colours
    scrub = lin(P['cloth_col']) if P['outfit'] == 'scrubs' else lin((0.24, 0.56, 0.50))
    col = b.mix(b.noise(co, 7.0, 3), scale_col(scrub, 0.92), scale_col(scrub, 1.06))
    # gown: faded blue-grey with a small diamond print
    if P['outfit'] == 'gown':
        gcol = lin(P['cloth_col'])
        dots = b.voronoi(b.vscale(co, (1, 1, 1)), 55.0, rand=0.0)
        dots = b.mr(dots, 0.18, 0.10)
        gown = b.mix(b.noise(co, 5.0, 3), scale_col(gcol, 0.95), scale_col(gcol, 1.08))
        gown = b.mix(b.mul(dots, 0.8), gown, lin((0.20, 0.30, 0.42)))
        col = b.mix(A['gown'], col, gown)
    ucol = lin(P['cloth_col']) if P['outfit'] == 'paramedic' else lin((0.10, 0.16, 0.11))
    uni = b.mix(b.noise(co, 9.0, 4), scale_col(ucol, 0.85), scale_col(ucol, 1.15))
    col = b.mix(A['uniform'], col, uni)
    # reflective strips: silver with a lattice of glass beads, a yellow trim either side
    beads = b.mr(b.noise(co, 900.0, 1), 0.3, 0.7)
    refl = b.mix(beads, lin((0.62, 0.64, 0.62)), lin((0.78, 0.80, 0.78)))
    col = b.mix(A['reflect'], col, refl)
    col = b.mix(b.mul(A['zip'], 0.9), col, lin((0.04, 0.04, 0.045)))
    col = b.mix(b.mul(A['patch'], A['uniform']), col, b.mix(b.mr(b.ellip(co, (0.085 * s, -0.12 * s, 1.365 * s), (0.02 * s, 0.2, 0.02 * s)), 1.0, 0.8), lin((0.75, 0.73, 0.68)), lin((0.10, 0.22, 0.55))))
    col = b.mix(A['mask'], col, b.mix(b.noise(co, 80.0, 3), lin((0.55, 0.70, 0.78)), lin((0.64, 0.78, 0.84))))
    col = b.mix(A['tie'], col, lin((0.82, 0.84, 0.84)))
    col = b.mix(A['belt'], col, b.mix(b.noise(co, 60.0, 5), lin((0.03, 0.03, 0.03)), lin((0.07, 0.065, 0.06))))
    col = b.mix(A['metal'], col, lin((0.42, 0.42, 0.40)))
    shoe_c = {'clog': (0.10, 0.12, 0.16), 'sneaker': (0.62, 0.62, 0.60), 'boot': (0.04, 0.035, 0.03), 'sock': (0.60, 0.52, 0.34)}[P['shoes']]
    col = b.mix(A['shoe'], col, b.mix(b.noise(co, 40.0, 4), scale_col(lin(shoe_c), 0.85), scale_col(lin(shoe_c), 1.1)))
    col = b.mix(A['sock'], col, b.mix(b.noise(b.vscale(co, (1, 1, 6)), 50.0, 3), scale_col(lin(shoe_c), 0.9), scale_col(lin(shoe_c), 1.05)))
    grip = b.mul(A['grip'], b.mr(b.voronoi(co, 140.0, rand=0.2), 0.25, 0.18))
    col = b.mix(grip, col, lin((0.08, 0.08, 0.08)))
    sole_c = lin((0.93, 0.93, 0.9)) if P['shoes'] == 'sneaker' else lin((0.03, 0.03, 0.03))
    col = b.mix(b.mul(A['sole'], b.inv(A['sock'])), col, sole_c)
    col = b.mix(b.mul(A['lace'], 0.9), col, lin((0.08, 0.08, 0.09)))
    # hems and seams: a little darker, stitched
    stitch = b.mr(b.noise(b.vscale(co, (1, 1, 1)), 300.0, 1), 0.5, 0.62)
    col = b.mix(b.mul(A['band'], 0.18), col, lin((0.0, 0.0, 0.0)))
    col = b.mix(b.mul(A['seam'], 0.25), col, lin((0.0, 0.0, 0.0)))
    col = b.mix(b.mul(A['pocket'], 0.10), col, lin((0.0, 0.0, 0.0)))
    base_noblood = col

    # --- wear: crease dirt, hem and knee grime, sweat, smudges
    crease_n = b.noise(b.warp(b.vscale(co, (7, 7, 1.4)), 3.0, 0.25), 3.0, 5, 0.55)
    creases = b.mul(b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', crease_n, 0.5)), 0.0, 0.06, 1.0, 0.0), b.add(A['crease'], 0.2))
    col = b.mix(b.mul(creases, 0.35 * grime_k), col, lin((0.12, 0.11, 0.09)))
    dirt = b.mul(b.maxi(A['grime'], b.mr(Z, 0.45 * s, 0.10 * s)), b.mr(b.noise(b.vscale(co, (1, 1, 0.4)), 6.0, 8, 0.65), 0.35, 0.75))
    col = b.mix(b.mul(dirt, 0.6 * grime_k), col, lin((0.16, 0.14, 0.10)))
    smudge = b.mr(b.noise(b.warp(co, 6.0, 0.1), 22.0, 10, 0.7), 0.58, 0.76)
    col = b.mix(b.mul(smudge, 0.35 * grime_k), col, lin((0.12, 0.11, 0.09)))
    sweat = b.maxi(b.mr(b.ellip(co, (0.15 * s, 0.0, 1.36 * s), (0.05 * s, 0.09 * s, 0.07 * s)), 1.2, 0.2),
                   b.mr(b.ellip(co, (-0.15 * s, 0.0, 1.36 * s), (0.05 * s, 0.09 * s, 0.07 * s)), 1.2, 0.2),
                   b.mul(b.mr(b.ellip(co, (0.0, 0.03 * s, 1.46 * s), (0.06 * s, 0.12 * s, 0.06 * s)), 1.3, 0.4), 0.7))
    sweat = b.mul(sweat, b.mr(b.noise(co, 12.0, 6, 0.6), 0.35, 0.6), b.maxi(A['scrubs'], A['uniform'], A['gown']))
    col = b.mix(b.mul(sweat, 0.55 * grime_k), col, lin((0.10, 0.10, 0.06)))
    # --- blood: spatter and drips on the front, smears on the thighs where hands are wiped, soaked cuffs
    splat_n = b.noise(b.warp(co, 9.0, 0.05), 11.0 + seed * 0.37, 12, 0.75)
    front = b.mr(Y, 0.02 * s, -0.10 * s)
    zone = b.maxi(b.mul(front, b.mr(Z, 0.75 * s, 1.15 * s), b.mr(Z, 1.45 * s, 1.20 * s)), A['blood'])
    spots = b.mul(b.mr(splat_n, 0.625, 0.66), zone)
    halo = b.mul(b.mr(splat_n, 0.57, 0.645), zone)
    drip_n = b.noise(b.vscale(co, (38, 38, 2.2)), 1.0 + seed * 0.01, 6, 0.6)
    drips = b.mul(b.mr(drip_n, 0.68, 0.73), zone, b.mr(b.noise(co, 3.0, 2), 0.42, 0.62))
    wipe_streak = b.noise(b.warp(b.vscale(co, (30, 30, 3)), 4.0, 0.3), 1.0, 5, 0.6)
    for sx in (1, -1):
        d = b.ellip(co, (sx * 0.11 * s, -0.10 * s, 0.80 * s), (0.05 * s, 0.14 * s, 0.10 * s))
        drips = b.maxi(drips, b.mul(b.mr(d, 1.0, 0.3), b.mr(wipe_streak, 0.42, 0.58)))
    blood = b.mul(b.maxi(spots, drips), blood_k * 1.6)
    col = b.mix(b.mul(halo, 0.45 * blood_k), col, lin((0.25, 0.14, 0.09)))
    col = b.mix(blood, col, b.mix(b.noise(co, 80.0, 3), lin((0.10, 0.012, 0.010)), lin((0.20, 0.03, 0.02))))
    # --- roughness
    rough = b.mix(b.noise(co, 25.0, 3), (0.78, 0.78, 0.78), (0.92, 0.92, 0.92))
    rough = b.mix(A['reflect'], rough, (0.35, 0.35, 0.35))
    rough = b.mix(b.maxi(A['shoe'], A['belt']), rough, b.mix(b.noise(co, 70.0, 4), (0.30, 0.30, 0.30), (0.55, 0.55, 0.55)))
    rough = b.mix(A['sock'], rough, (0.95, 0.95, 0.95))
    rough = b.mix(A['metal'], rough, (0.30, 0.30, 0.30))
    rough = b.mix(b.mul(blood, 0.8), rough, (0.45, 0.45, 0.45))
    rs = b.n('ShaderNodeSeparateColor')
    b.link(rough, rs.inputs[0])
    # --- height
    weave = b.add(b.noise(b.vscale(co, (1, 1, 5)), 650.0, 2, 0.5), b.noise(b.vscale(co, (5, 5, 1)), 650.0, 2, 0.5))
    wrink = b.noise(b.warp(co, 12.0, 0.08), 40.0, 6, 0.6)
    h = b.add(b.mul(weave, 0.05), b.mul(creases, -0.9))
    h = b.add(h, b.mul(wrink, 0.18))
    h = b.add(h, b.mul(b.mul(A['band'], stitch), 0.25))
    h = b.add(h, b.mul(beads, b.mul(A['reflect'], 0.2)))
    h = b.add(h, b.mul(grip, 0.8))
    h = b.add(h, b.mul(b.mr(b.noise(b.vscale(co, (1, 1, 12)), 30.0, 2), 0.4, 0.6), b.mul(A['mask'], 0.6)))
    # --- mask: player tint (not over blood or heavy dirt), reflective
    tint = b.mul(A['tint'], b.inv(b.mul(blood, 1.5)), b.inv(b.mul(A['band'], 0.2)))
    mask = b.rgb(tint, A['reflect'], 0.0)
    b.finish(col, rs.outputs[0], h, mask, strength=0.6, distance=0.002)
    return mat


# ====================================================================== skin
def skin_material(P):
    mat = bpy.data.materials.new('HU_Skin_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    X, Y, Z = b.sep(co)
    body = hu_body.Body(P, 1)
    s, hs, HC = body.s, body.hs, body.HC
    A = {k: b.attr(k) for k in ('lip', 'brow', 'hair', 'scalp', 'beard', 'eye', 'iris', 'lid', 'nail', 'knuckle', 'vein', 'cheek',
                                'socket', 'flesh', 'bone', 'ear', 'nostril', 'gashz', 'veinz', 'stumpz', 'palm', 'nipple', 'navel',
                                'moust', 'band')}
    base = lin(P['skin'])
    age = P['age']
    red_k = P['skin_red']
    bob = P['name'] == 'bob'
    mott = b.noise(co, 14.0, 6, 0.6)
    col = b.mix(mott, scale_col(base, 0.90), scale_col(base, 1.06))
    col = b.mix(b.mul(b.mr(b.noise(co, 4.0, 3), 0.4, 0.8), 0.35), col, scale_col(tuple(c * w for c, w in zip(base, (1.05, 0.92, 0.85))), 1.0))
    # freckles / sun spots, stronger on light skin
    spots = b.mr(b.noise(co, 180.0, 2, 0.5), 0.66, 0.74)
    col = b.mix(b.mul(spots, 0.25 * max(0.0, sum(P['skin']) / 3 - 0.45) * 2.0), col, scale_col(base, 0.72))
    # flush: cheeks, nose, ears, knuckles, lids
    flush_col = tuple(min(1.0, c * k) for c, k in zip(base, (1.12, 0.78, 0.76)))
    flush = b.maxi(A['cheek'], b.mul(A['ear'], 0.7), b.mul(A['knuckle'], 0.8), b.mul(A['lid'], 0.35))
    col = b.mix(b.mul(flush, 0.55 * red_k), col, flush_col)
    # tired: dark hollows round the eyes
    under = b.maxi(b.mul(A['socket'], 0.6), b.mr(b.maxi(b.ellip(co, (HC.x + body.eye_c.x * hs, HC.y + (body.eye_c.y - 0.008) * hs, HC.z + (body.eye_c.z - 0.012) * hs), (0.018 * hs, 0.02 * hs, 0.008 * hs)),
                                                         b.ellip(co, (HC.x - body.eye_c.x * hs, HC.y + (body.eye_c.y - 0.008) * hs, HC.z + (body.eye_c.z - 0.012) * hs), (0.018 * hs, 0.02 * hs, 0.008 * hs))), 1.3, 0.5))
    col = b.mix(b.mul(under, 0.45 + 0.3 * age), col, tuple(c * w for c, w in zip(base, (0.62, 0.52, 0.55))))
    # palms and soles lighter
    col = b.mix(b.mul(A['palm'], 0.5), col, tuple(min(1.0, c * w) for c, w in zip(base, (1.25, 1.12, 1.05))))
    # veins on forearms, hands, temples
    wv = b.warp(co, 9.0, 0.08)
    veins = b.mr(b.voronoi(wv, 30.0, 'DISTANCE_TO_EDGE'), 0.0, 0.03, 1.0, 0.0)
    veins = b.mul(veins, b.mr(b.noise(co, 6.0, 3), 0.45, 0.65), A['vein'])
    col = b.mix(b.mul(veins, 0.22), col, tuple(c * w for c, w in zip(base, (0.60, 0.68, 0.95))))
    # the anesthetic vein: a clear blue line down the inner elbow, a little bruise from old needles
    veinline = b.mul(A['veinz'], b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', b.noise(b.vscale(co, (6, 6, 0.8)), 12.0, 2), 0.5)), 0.03, 0.0))
    col = b.mix(b.mul(veinline, 0.75), col, tuple(c * w for c, w in zip(base, (0.45, 0.55, 0.95))))
    if bob:
        col = b.mix(b.mul(A['veinz'], 0.35), col, lin((0.45, 0.38, 0.30)))
    # stubble and beard
    stub = b.mul(A['beard'], b.mr(b.noise(co, 900.0, 1), 0.35, 0.65), P['beard'])
    col = b.mix(b.mul(stub, 0.85), col, lin(P['hair_col']))
    col = b.mix(b.mul(A['beard'], P['beard'] * 0.25), col, tuple(c * 0.75 for c in base))
    # scalp showing through short hair
    col = b.mix(b.mul(A['scalp'], 0.35 if P['hair'] != 'balding' else 0.10), col, tuple(c * 0.7 for c in base))
    if P['hair'] == 'buzz':
        buzz = b.mul(A['scalp'], b.mr(b.noise(co, 1400.0, 1), 0.30, 0.60))
        col = b.mix(b.mul(A['scalp'], 0.75), col, lin(P['hair_col']))
        col = b.mix(buzz, col, scale_col(lin(P['hair_col']), 0.5))
    # brows
    brow_n = b.mr(b.noise(b.vscale(co, (40, 4, 40)), 60.0, 2), 0.35, 0.65)
    col = b.mix(b.mul(A['brow'], brow_n, 0.95), col, lin(P['brows_col']))
    # lips
    lipc = tuple(min(1.0, c * k) for c, k in zip(base, (0.80, 0.42, 0.44)))
    col = b.mix(b.mul(b.mr(A['lip'], 0.30, 0.85), 0.8), col, lipc)
    col = b.mix(b.mul(A['nostril'], 0.9), col, tuple(c * 0.25 for c in base))
    col = b.mix(b.mul(A['nipple'], 0.6), col, tuple(c * w for c, w in zip(base, (0.75, 0.55, 0.55))))
    col = b.mix(b.mul(A['navel'], 0.7), col, tuple(c * 0.45 for c in base))
    # lashes: a dark line along the lid edges
    lash = b.mr(A['lid'], 0.80, 1.0)
    col = b.mix(b.mul(lash, 0.85), col, lin((0.02, 0.018, 0.016)))
    col = b.mix(b.mul(b.mr(A['lid'], 0.3, 0.8), 0.25 * red_k), col, flush_col)
    # nails
    col = b.mix(A['nail'], col, b.mix(b.noise(b.vscale(co, (1, 1, 10)), 50.0, 3), tuple(min(1.0, c * k) for c, k in zip(base, (1.15, 0.95, 0.95))), tuple(min(1.0, c * 1.35) for c in base)))
    # hair
    strands = b.noise(b.vscale(co, (70, 70, 5)), 14.0, 4, 0.5)
    hairc = b.mix(b.mr(strands, 0.3, 0.7), scale_col(lin(P['hair_col']), 0.55), scale_col(lin(P['hair_col']), 1.35))
    col = b.mix(b.mul(A['hair'], 0.96), col, hairc)
    col = b.mix(A['band'], col, lin((0.02, 0.02, 0.025)))
    # eyes: sclera with veins, iris with radial fibres, pupil
    ex = b.math('SUBTRACT', b.math('ABSOLUTE', X), HC.x + body.eye_c.x * hs)
    ez = b.math('SUBTRACT', Z, HC.z + body.eye_c.z * hs)
    rr = b.math('SQRT', b.add(b.math('POWER', ex, 2.0), b.math('POWER', ez, 2.0)))
    ang = b.math('ARCTAN2', ez, ex)
    fib = b.mr(b.noise(b.vscale(b.rgb(b.mul(ang, 3.0), b.mul(rr, 400.0), 0.0), (1, 1, 1)), 6.0, 3), 0.3, 0.7)
    iris_c = b.mix(fib, scale_col(lin(P['iris']), 0.6), scale_col(lin(P['iris']), 1.6))
    iris_c = b.mix(b.mr(rr, 0.0048 * hs, 0.0056 * hs), iris_c, scale_col(lin(P['iris']), 0.35))
    sclera = b.mix(b.mr(b.voronoi(b.warp(co, 800.0, 0.0005), 1400.0, 'DISTANCE_TO_EDGE'), 0.0, 0.05, 0.6, 0.0), lin((0.80, 0.76, 0.70)), lin((0.62, 0.30, 0.26)))
    if bob:
        sclera = b.mix(0.35, sclera, lin((0.78, 0.66, 0.42)))
    eyec = b.mix(A['iris'], sclera, iris_c)
    eyec = b.mix(b.mul(A['iris'], b.mr(rr, 0.0024 * hs, 0.0018 * hs)), eyec, lin((0.005, 0.005, 0.005)))
    col = b.mix(A['eye'], col, eyec)
    # a stump cap: raw muscle, a ring of fat under the skin, the ends of the bones
    flesh_c = b.mix(b.noise(co, 120.0, 5, 0.7), lin((0.30, 0.03, 0.03)), lin((0.52, 0.09, 0.07)))
    flesh_c = b.mix(b.mr(A['flesh'], 0.75, 0.6), flesh_c, lin((0.78, 0.66, 0.40)))
    flesh_c = b.mix(b.mr(A['bone'], 0.55, 0.72), flesh_c, lin((0.85, 0.80, 0.66)))
    col = b.mix(b.mr(A['stumpz'], 0.0, 0.5), col, flesh_c)
    # sick Bob: sallow grey-yellow
    if bob:
        col = b.mix(0.30, col, lin((0.62, 0.60, 0.46)))
        bruise = b.mul(b.mr(b.noise(co, 8.0, 4), 0.62, 0.72), b.mr(Z, 1.45 * s, 1.20 * s))
        col = b.mix(b.mul(bruise, 0.3), col, lin((0.35, 0.30, 0.38)))
    # dried blood under the nails and on the knuckles (surgeons)
    if P['outfit'] == 'scrubs':
        bl = b.mul(b.maxi(A['nail'], b.mul(A['knuckle'], 0.5)), b.mr(b.noise(co, 60.0, 8, 0.7), 0.55, 0.66), P['blood'])
        col = b.mix(bl, col, lin((0.18, 0.03, 0.02)))
    # --- roughness
    rough = b.mix(mott, (0.48, 0.48, 0.48), (0.62, 0.62, 0.62))
    rough = b.mix(A['lip'], rough, (0.38, 0.38, 0.38))
    rough = b.mix(b.maxi(A['cheek'], b.mr(Z, HC.z - 0.02, HC.z + 0.08)), rough, (0.42, 0.42, 0.42))
    rough = b.mix(A['nail'], rough, (0.25, 0.25, 0.25))
    rough = b.mix(A['hair'], rough, (0.50, 0.50, 0.50))
    rough = b.mix(A['eye'], rough, (0.04, 0.04, 0.04))
    rough = b.mix(b.mr(A['stumpz'], 0.0, 0.5), rough, (0.22, 0.22, 0.22))
    rough = b.mix(b.mr(A['lid'], 0.85, 1.0), rough, (0.25, 0.25, 0.25))
    rs = b.n('ShaderNodeSeparateColor')
    b.link(rough, rs.inputs[0])
    # --- height: pores, fine wrinkles, forehead lines, knuckle creases, lip lines, hair strands
    pores = b.noise(co, 1100.0, 2, 0.5)
    wr = b.noise(b.warp(b.vscale(co, (2, 2, 30)), 25.0, 0.05), 20.0, 4, 0.6)
    wrinkles = b.mul(b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', wr, 0.5)), 0.0, 0.05, 1.0, 0.0), b.add(A['knuckle'], 0.10 + 0.25 * age))
    fz = b.noise(b.warp(b.vscale(co, (3, 3, 70)), 20.0, 0.02), 8.0, 3, 0.5)
    furrow = b.mul(b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', fz, 0.5)), 0.0, 0.05, 1.0, 0.0),
                   b.mr(b.ellip(co, (HC.x, HC.y - 0.09 * hs, HC.z + 0.075 * hs), (0.05 * hs, 0.05 * hs, 0.03 * hs)), 1.3, 0.5), 0.3 + age)
    liplines = b.mul(b.mr(b.noise(b.vscale(co, (40, 1, 1)), 40.0, 2), 0.45, 0.55), A['lip'])
    h = b.add(b.mul(pores, 0.04), b.mul(veins, 0.35))
    h = b.add(h, b.mul(veinline, 0.6))
    h = b.add(h, b.mul(wrinkles, -0.5))
    h = b.add(h, b.mul(furrow, -0.6))
    h = b.add(h, b.mul(liplines, -0.15))
    h = b.add(h, b.mul(b.mul(strands, A['hair']), 0.35))
    h = b.add(h, b.mul(stub, 0.12))
    h = b.add(h, b.mul(b.mul(A['stumpz'], b.noise(co, 200.0, 4)), 0.4))
    # --- mask: vein, gash, gunshot site
    gun = body_gunshot_mask(b, co, body)
    mask = b.rgb(b.mr(b.maxi(A['veinz'], b.mul(veinline, 1.0)), 0.05, 0.6), A['gashz'], gun)
    b.finish(col, rs.outputs[0], h, mask, strength=0.45, distance=0.0012)
    return mat


def body_gunshot_mask(b, co, body):
    import math as _m
    s = body.s
    th, z = -0.62, 1.035 * s
    p, _ = body.surf_slice(z, th)
    return b.mr(b.ellip(co, (p.x, p.y, p.z), (0.030 * s, 0.03 * s, 0.030 * s)), 1.0, 0.2)


def baked_material(name, img_color, img_rough, img_normal):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    nt.links.new(bsdf.outputs[0], out.inputs['Surface'])
    tc = nt.nodes.new('ShaderNodeTexImage')
    tc.image = img_color
    tr = nt.nodes.new('ShaderNodeTexImage')
    tr.image = img_rough
    tn = nt.nodes.new('ShaderNodeTexImage')
    tn.image = img_normal
    nm = nt.nodes.new('ShaderNodeNormalMap')
    nt.links.new(tc.outputs['Color'], bsdf.inputs['Base Color'])
    nt.links.new(tr.outputs['Color'], bsdf.inputs['Roughness'])
    nt.links.new(tn.outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
    bsdf.inputs['Specular IOR Level'].default_value = 0.35
    return mat, (tc, tr, tn)
