"""Procedural Cycles materials for the seal patient (the source of the baked maps).

Each procedural material exposes signals that the baker switches onto the output:
color (albedo), rough (roughness), height (0..1, for the infected height map) and the bumped
normal (baked as a tangent-space normal map). The coat material has an `INFECT` value node:
0 bakes the healthy coat, 1 bakes the infected flipper into the UV2 atlas.

Coordinates: the attribute `P` is the vertex position in the patient frame (x nose->tail, y up,
z = seal's left) and `F` a per-part "flow" frame (along the flipper for the flippers), so fur
streaks run the way the hair lies.
"""
import bpy
import seal_geometry as G


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

    def vattr(self, name):
        return self.n('ShaderNodeAttribute', attribute_name=name, attribute_type='GEOMETRY').outputs['Vector']

    def value(self, v, name=None):
        node = self.n('ShaderNodeValue')
        node.outputs[0].default_value = v
        if name:
            node.name = name
            node.label = name
        return node.outputs[0]

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

    def add(self, *vals):
        out = vals[0]
        for v in vals[1:]:
            out = self.math('ADD', out, v)
        return out

    def mul(self, *vals):
        out = vals[0]
        for v in vals[1:]:
            out = self.math('MULTIPLY', out, v)
        return out

    def mr(self, v, fmin, fmax, tmin=0.0, tmax=1.0, smooth=True):
        node = self.n('ShaderNodeMapRange', interpolation_type='SMOOTHSTEP' if smooth else 'LINEAR', clamp=True)
        self.link(v, node.inputs['Value'])
        for key, val in (('From Min', fmin), ('From Max', fmax), ('To Min', tmin), ('To Max', tmax)):
            if isinstance(val, (int, float)):
                node.inputs[key].default_value = val
            else:
                self.link(val, node.inputs[key])
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

    def fmix(self, fac, a, b):
        node = self.n('ShaderNodeMix', data_type='FLOAT', clamp_factor=True)
        for idx, v in ((0, fac), (2, a), (3, b)):
            if isinstance(v, (int, float)):
                node.inputs[idx].default_value = v
            else:
                self.link(v, node.inputs[idx])
        return node.outputs[0]

    def sep(self, vec):
        s = self.n('ShaderNodeSeparateXYZ')
        self.link(vec, s.inputs[0])
        return s.outputs['X'], s.outputs['Y'], s.outputs['Z']

    def combine(self, x, y, z):
        c = self.n('ShaderNodeCombineXYZ')
        for i, v in enumerate((x, y, z)):
            if isinstance(v, (int, float)):
                c.inputs[i].default_value = v
            else:
                self.link(v, c.inputs[i])
        return c.outputs[0]

    def vscale(self, vec, s):
        node = self.n('ShaderNodeMapping')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = s
        return node.outputs['Vector']

    def voff(self, vec, o):
        node = self.n('ShaderNodeMapping')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Location'].default_value = o
        return node.outputs['Vector']

    def noise(self, vec, scale, detail=4.0, rough=0.5, distort=0.0, fac=True):
        node = self.n('ShaderNodeTexNoise')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        node.inputs['Detail'].default_value = detail
        node.inputs['Roughness'].default_value = rough
        node.inputs['Distortion'].default_value = distort
        return node.outputs['Fac'] if fac else node.outputs['Color']

    def voronoi(self, vec, scale, rand=1.0, feature='F1'):
        node = self.n('ShaderNodeTexVoronoi', feature=feature)
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        node.inputs['Randomness'].default_value = rand
        return node

    def warp(self, vec, scale, amount):
        col = self.noise(vec, scale, 3.0, 0.5, fac=False)
        sub = self.n('ShaderNodeVectorMath', operation='SUBTRACT')
        self.link(col, sub.inputs[0])
        sub.inputs[1].default_value = (0.5, 0.5, 0.5)
        sc = self.n('ShaderNodeVectorMath', operation='SCALE')
        self.link(sub.outputs[0], sc.inputs[0])
        sc.inputs['Scale'].default_value = amount
        add = self.n('ShaderNodeVectorMath', operation='ADD')
        self.link(vec, add.inputs[0])
        self.link(sc.outputs[0], add.inputs[1])
        return add.outputs[0]

    def dist_to(self, vec, c, s):
        """Scaled distance from point c with radii s (an ellipsoid metric)."""
        mp = self.n('ShaderNodeMapping', vector_type='POINT')
        self.link(vec, mp.inputs['Vector'])
        mp.inputs['Scale'].default_value = (1 / s[0], 1 / s[1], 1 / s[2])
        mp.inputs['Location'].default_value = (-c[0] / s[0], -c[1] / s[1], -c[2] / s[2])
        ln = self.n('ShaderNodeVectorMath', operation='LENGTH')
        self.link(mp.outputs[0], ln.inputs[0])
        return ln.outputs['Value']

    def lines(self, v, width):
        """Thin lines where a 0..1 noise crosses 0.5."""
        return self.mr(self.math('ABSOLUTE', self.math('SUBTRACT', v, 0.5)), 0.0, width, 1.0, 0.0)

    def finish(self, color, rough, height, strength=1.0, distance=0.001):
        bsdf = self.n('ShaderNodeBsdfPrincipled')
        self.link(color, bsdf.inputs['Base Color'])
        self.link(rough, bsdf.inputs['Roughness'])
        bsdf.inputs['Specular IOR Level'].default_value = 0.45
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
        hn = self.math('ADD', 0.5, self.math('MULTIPLY', height, 0.5))
        for nm, sock in (('SIG_color', color), ('SIG_rough', rough), ('SIG_height', hn)):
            r = self.n('NodeReroute')
            r.name = nm
            self.link(sock, r.inputs[0])
        bsdf.name = 'BSDF'


def set_bake_signal(mat, which):
    nt = mat.node_tree
    out, emit, bsdf = nt.nodes['Out'], nt.nodes['BakeEmit'], nt.nodes['BSDF']
    for l in list(out.inputs['Surface'].links):
        nt.links.remove(l)
    if which in ('color', 'rough', 'height'):
        for l in list(emit.inputs['Color'].links):
            nt.links.remove(l)
        nt.links.new(nt.nodes['SIG_' + which].outputs[0], emit.inputs['Color'])
        nt.links.new(emit.outputs[0], out.inputs['Surface'])
    else:
        nt.links.new(bsdf.outputs[0], out.inputs['Surface'])


def set_infect(mat, v):
    node = mat.node_tree.nodes.get('INFECT')
    if node:
        node.outputs[0].default_value = v


# ------------------------------------------------------------------------------------------------ coat
def coat_material():
    mat = bpy.data.materials.new('Seal_Coat_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    P = b.vattr('pco')
    F = b.vattr('fco')
    px, py, pz = b.sep(P)
    apz = b.math('ABSOLUTE', pz)
    Pm = b.combine(px, py, apz)      # mirrored: left and right share the face features
    (belly, saddle, muzzle, nose, nostril, mouth, eyerim, whpad, ear, fold, flip, hind, palm, knuck, inf,
     lid, shoulder, groove) = (b.attr(n) for n in ('belly', 'saddle', 'muzzle', 'nose', 'nostril', 'mouth', 'eyerim',
                                                   'whpad', 'ear', 'fold', 'flip', 'hind', 'palm', 'knuck', 'inf',
                                                   'lid', 'shoulder', 'groove'))
    limbs = b.math('MAXIMUM', flip, hind)

    # ---- base: dark slate back, grey flanks, a dirty pale belly with a noisy boundary
    Pw = b.warp(P, 5.0, 0.06)
    tone = b.noise(Pw, 7.0, 5, 0.55)
    back = b.mix(tone, (0.085, 0.087, 0.090), (0.140, 0.136, 0.130))
    under = b.mix(b.noise(P, 11.0, 4), (0.30, 0.285, 0.255), (0.40, 0.38, 0.34))
    edge = b.mr(b.add(belly, b.mul(b.math('SUBTRACT', b.noise(Pw, 9.0, 6, 0.6), 0.5), 0.7)), 0.22, 0.70)
    col = b.mix(edge, back, under)
    col = b.mix(b.mul(saddle, 0.6), col, (0.055, 0.056, 0.060))

    # ---- the harbour-seal pattern: dense irregular dark spots of every size, a few faint pale
    # rings on the back, sparser spots on the belly
    Ps = b.warp(P, 6.0, 0.05)
    patt = None
    for scale, lo, hi, gate, jit in ((17.0, 0.12, 0.40, 0.30, 0.22), (38.0, 0.10, 0.34, 0.35, 0.26), (80.0, 0.08, 0.26, 0.55, 0.3)):
        vo = b.voronoi(b.voff(Ps, (scale * 0.013, scale * 0.029, 0.7)), scale, 1.0)
        vr = b.n('ShaderNodeSeparateColor')
        b.link(vo.outputs['Color'], vr.inputs[0])
        rnd = vr.outputs[0]
        rad = b.add(lo, b.mul(rnd, rnd, hi - lo))
        dd = b.add(vo.outputs['Distance'], b.mul(b.math('SUBTRACT', b.noise(P, scale * 3.2, 4, 0.65), 0.5), jit))
        sp = b.math('SUBTRACT', 1.0, b.mr(b.math('SUBTRACT', dd, rad), -0.03, 0.03))
        sp = b.mul(sp, b.mr(rnd, gate - 0.08, gate))
        patt = sp if patt is None else b.math('MAXIMUM', patt, sp)
        if scale == 17.0:
            ringd = b.math('SUBTRACT', dd, b.add(rad, 0.12))
            ring = b.mul(b.mr(b.math('ABSOLUTE', ringd), 0.08, 0.03), b.mr(rnd, 0.72, 0.85))
    belly_sparse = b.fmix(belly, 1.0, 0.35)
    face_fade = b.math('SUBTRACT', 1.0, b.mul(muzzle, 0.7))
    patt = b.mul(patt, belly_sparse, face_fade, b.math('SUBTRACT', 1.0, b.mul(limbs, 0.35)))
    col = b.mix(b.mul(patt, 0.9), col, b.mix(b.noise(P, 40.0, 3), (0.014, 0.014, 0.016), (0.034, 0.031, 0.030)))
    # frosting: silvery guard hairs catching light
    frost = b.mr(b.noise(b.vscale(F, (0.25, 1.0, 1.0)), 220.0, 3, 0.6), 0.62, 0.78)
    col = b.mix(b.mul(frost, 0.14, b.math('SUBTRACT', 1.0, belly)), col, (0.22, 0.22, 0.22))

    # ---- flippers: darker, sparse fur, grooves between the digits, paler grey palms
    col = b.mix(b.mul(limbs, 0.25), col, b.mix(b.noise(P, 30.0, 4), (0.055, 0.053, 0.050), (0.095, 0.090, 0.084)))
    col = b.mix(b.mul(limbs, palm, 0.55), col, (0.17, 0.16, 0.15))
    col = b.mix(b.mul(limbs, b.mr(knuck, 0.35, 0.05), 0.45), col, (0.012, 0.011, 0.011))

    # ---- the face
    col = b.mix(b.mul(muzzle, 0.55), col, b.mix(b.noise(P, 50.0, 3), (0.065, 0.062, 0.060), (0.11, 0.105, 0.095)))
    # pale "spectacles" round the eyes and a pale chin, dark wet rims
    col = b.mix(b.mul(b.mr(eyerim, 0.3, 0.8), 0.85), col, (0.02, 0.018, 0.017))
    col = b.mix(b.mul(lid, 0.25), col, (0.06, 0.045, 0.045))
    # tear stains: seals have no tear ducts, so the eyes run down the cheeks
    ex, ey, ez = G.EYE_C
    rx = b.math('SUBTRACT', px, ex + 0.012)
    ry = b.math('SUBTRACT', py, ey - 0.006)
    run = b.mr(ry, 0.0, -0.075)
    along = b.math('ABSOLUTE', b.add(rx, b.mul(ry, 0.45), b.mul(b.math('SUBTRACT', b.noise(b.vscale(P, (1, 4, 1)), 40.0, 3), 0.5), 0.010)))
    tear = b.mul(b.mr(along, b.add(0.004, b.mul(run, 0.010)), 0.0), b.math('SUBTRACT', 1.0, b.math('POWER', run, 5.0)),
                 b.mr(ry, 0.008, -0.004), b.mr(apz, ez - 0.035, ez - 0.005))
    col = b.mix(b.mul(tear, 0.85), col, (0.012, 0.010, 0.009))
    # whisker follicles: rows of dark pits over the pads
    fol = b.voronoi(b.vscale(Pm, (1.0, 1.0, 1.0)), 260.0, 0.35)
    fol = b.mul(b.math('SUBTRACT', 1.0, b.mr(fol.outputs['Distance'], 0.10, 0.28)), b.mr(whpad, 0.25, 0.6))
    col = b.mix(b.mul(fol, 0.85), col, (0.006, 0.005, 0.005))
    col = b.mix(b.mul(b.mr(whpad, 0.2, 0.8), 0.25), col, (0.20, 0.19, 0.18))
    # rhinarium: black, cobbled, wet; nostril slits, mouth line, ear pits
    cobble = b.voronoi(Pm, 420.0, 1.0, 'DISTANCE_TO_EDGE').outputs['Distance']
    rhin = b.mr(nose, 0.35, 0.75)
    col = b.mix(rhin, col, b.mix(b.mr(cobble, 0.0, 0.08), (0.004, 0.004, 0.004), (0.020, 0.018, 0.017)))
    col = b.mix(b.mr(nostril, 0.15, 0.6), col, (0.002, 0.001, 0.001))
    col = b.mix(b.mr(mouth, 0.2, 0.7), col, (0.006, 0.004, 0.004))
    col = b.mix(b.mr(ear, 0.2, 0.6), col, (0.004, 0.003, 0.003))
    col = b.mix(b.mul(fold, 0.7), col, (0.018, 0.016, 0.015))

    # ---- grim: old scars, raw abrasions, moult patches, grime where it lies on the table
    scar_n = b.noise(b.warp(b.vscale(P, (1.0, 2.2, 2.2)), 4.0, 0.2), 6.0, 3, 0.5)
    scar = b.mul(b.lines(scar_n, 0.004), b.mr(b.noise(P, 5.0, 2), 0.66, 0.72), b.math('SUBTRACT', 1.0, limbs))
    col = b.mix(b.mul(scar, 0.45), col, (0.28, 0.24, 0.22))
    # a crescent bite scar on the right shoulder
    bite_d = b.dist_to(P, (-0.20, 0.22, -0.16), (0.035, 0.05, 0.035))
    bite = b.mul(b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', bite_d, 1.0)), 0.12, 0.0), b.mr(py, 0.20, 0.23))
    col = b.mix(b.mul(bite, 0.75), col, (0.34, 0.28, 0.26))
    moult = b.mul(b.mr(b.noise(b.warp(P, 3.0, 0.15), 4.5, 6, 0.6), 0.60, 0.72), b.math('SUBTRACT', 1.0, belly))
    col = b.mix(b.mul(moult, 0.5), col, (0.20, 0.17, 0.13))
    table = b.mul(b.mr(py, 0.05, 0.005), b.math('SUBTRACT', 1.0, limbs))
    grime_n = b.mr(b.noise(b.warp(P, 8.0, 0.05), 14.0, 8, 0.7), 0.45, 0.65)
    col = b.mix(b.mul(table, grime_n, 0.65), col, (0.14, 0.11, 0.085))
    abr = b.mul(b.mr(b.noise(b.warp(P, 6.0, 0.1), 9.0, 8, 0.75), 0.66, 0.72), b.mr(py, 0.07, 0.03))
    col = b.mix(b.mul(abr, 0.8), col, (0.20, 0.06, 0.05))
    old_blood = b.mul(b.mr(b.noise(b.warp(P, 12.0, 0.04), 18.0, 10, 0.75), 0.66, 0.70), b.mr(py, 0.10, 0.03))
    col = b.mix(b.mul(old_blood, 0.9), col, (0.05, 0.012, 0.01))

    # ---- roughness: dry fur, wet face and belly edge, glossy nose and tears
    rough = b.fmix(b.noise(P, 18.0, 3), 0.50, 0.66)
    rough = b.fmix(b.mul(frost, 0.6), rough, 0.38)
    rough = b.fmix(b.mul(table, 0.8), rough, 0.34)
    rough = b.fmix(b.mul(limbs, 0.5), rough, 0.44)
    rough = b.fmix(b.math('MAXIMUM', rhin, b.mr(eyerim, 0.2, 0.7)), rough, 0.16)
    rough = b.fmix(b.math('MAXIMUM', b.mul(tear, 0.9), b.mr(mouth, 0.2, 0.6)), rough, 0.22)
    rough = b.fmix(b.mul(abr, 0.8), rough, 0.25)
    rough = b.fmix(b.mul(scar, 0.6), rough, 0.62)

    # ---- height: fur lying nose to tail, pores, grooves, scars
    fur = b.noise(b.vscale(F, (0.12, 1.0, 1.0)), 240.0, 4, 0.55)
    fur2 = b.noise(b.warp(b.vscale(F, (0.2, 1.0, 1.0)), 30.0, 0.02), 90.0, 3, 0.5)
    h = b.add(b.mul(b.math('SUBTRACT', fur, 0.5), 0.34), b.mul(b.math('SUBTRACT', fur2, 0.5), 0.22))
    h = b.add(h, b.mul(b.math('SUBTRACT', b.mr(cobble, 0.0, 0.06), 0.5), rhin, 0.5))
    h = b.add(h, b.mul(fol, -0.35))
    h = b.add(h, b.mul(b.mr(knuck, 0.35, 0.05), limbs, -0.30))
    h = b.add(h, b.mul(scar, 0.35), b.mul(bite, 0.4), b.mul(abr, -0.25))
    wrink = b.noise(b.warp(b.vscale(F, (1.0, 3.0, 3.0)), 20.0, 0.02), 70.0, 4, 0.6)
    h = b.add(h, b.mul(b.lines(wrink, 0.05), limbs, palm, -0.4))

    # ---- infection (baked into the UV2 atlas with INFECT = 1): weeks of fishing line cutting in.
    # Swollen bruised skin with the fur sloughing off, wet ulcers rimmed with yellow fibrin, pus,
    # black necrosis spreading from the tip and the edges, raw grooves where the line has cut in,
    # and a bruised halo just ahead of it all.
    INFECT = b.value(0.0, 'INFECT')
    ths, thc = b.attr('ths'), b.attr('thc')
    fs = b.sep(F)[0]
    gro = None
    for s0, tilt, phase, emb in G.LINE_LOOPS:
        import math as _m
        loop_s = b.add(s0, b.mul(b.add(b.mul(ths, _m.cos(phase)), b.mul(thc, _m.sin(phase))), tilt))
        dsl = b.math('ABSOLUTE', b.math('SUBTRACT', fs, loop_s))
        g = b.mr(dsl, 0.0065, 0.0)
        gro = g if gro is None else b.math('MAXIMUM', gro, g)
    Pi = b.warp(P, 12.0, 0.010)
    edge_n = b.mul(b.math('SUBTRACT', b.noise(P, 30.0, 5, 0.65), 0.5), 0.6)
    wi = b.mul(b.mr(b.add(inf, edge_n), 0.0, 0.45), INFECT)
    halo = b.mul(b.mr(b.add(inf, edge_n), -0.45, 0.1), INFECT)
    tipness = b.mr(fs, 0.27, 0.35)
    edgeness = b.mr(b.math('ABSOLUTE', b.sep(F)[2]), 0.04, 0.068)
    ulc_n = b.noise(Pi, 38.0, 6, 0.62)
    ulcer = b.mr(b.add(ulc_n, b.mul(gro, 0.12), b.mul(tipness, 0.05)), 0.505, 0.535)
    ulcer_core = b.mr(ulc_n, 0.555, 0.60)
    fibrin = b.mul(b.mr(ulc_n, 0.475, 0.505), b.math('SUBTRACT', 1.0, ulcer))
    necro_n = b.noise(b.warp(P, 9.0, 0.02), 24.0, 8, 0.7)
    necro = b.mr(b.add(necro_n, b.mul(tipness, 0.22), b.mul(edgeness, 0.10)), 0.60, 0.64)
    pus_v = b.voronoi(b.warp(P, 40.0, 0.004), 180.0, 1.0)
    pus = b.mul(b.math('SUBTRACT', 1.0, b.mr(pus_v.outputs['Distance'], 0.16, 0.30)), b.mr(b.noise(P, 20.0, 3), 0.47, 0.55))
    fur_left = b.mul(b.mr(b.noise(P, 55.0, 4, 0.6), 0.50, 0.56), b.math('SUBTRACT', 1.0, ulcer))
    raw = b.mr(gro, 0.45, 0.9)
    raw_edge = b.mul(b.mr(gro, 0.05, 0.45), b.math('SUBTRACT', 1.0, raw))
    skin = b.mix(b.noise(Pi, 90.0, 4), (0.075, 0.040, 0.050), (0.13, 0.060, 0.070))
    sick = b.mix(b.mul(fur_left, 0.85), skin, (0.035, 0.032, 0.033))
    sick = b.mix(b.mul(b.mr(b.noise(P, 16.0, 3), 0.5, 0.65), 0.55), sick, (0.10, 0.11, 0.05))
    sick = b.mix(fibrin, sick, b.mix(b.noise(P, 140.0, 3), (0.34, 0.27, 0.10), (0.48, 0.40, 0.18)))
    ulc_col = b.mix(ulcer_core, b.mix(b.noise(P, 260.0, 3), (0.22, 0.035, 0.035), (0.33, 0.075, 0.065)), (0.12, 0.010, 0.014))
    sick = b.mix(ulcer, sick, ulc_col)
    sick = b.mix(b.mul(pus, b.math('MAXIMUM', ulcer, fibrin), 0.9), sick, (0.55, 0.50, 0.26))
    sick = b.mix(necro, sick, b.mix(b.noise(P, 120.0, 3), (0.006, 0.005, 0.005), (0.04, 0.026, 0.020)))
    sick = b.mix(b.mul(raw_edge, 0.85), sick, (0.42, 0.30, 0.12))
    sick = b.mix(raw, sick, b.mix(b.noise(P, 300.0, 3), (0.20, 0.008, 0.010), (0.42, 0.05, 0.04)))
    col_h = b.mix(b.mul(halo, b.math('SUBTRACT', 1.0, wi), 0.65), col, (0.09, 0.030, 0.050))
    col = b.mix(wi, col_h, sick)
    rough_i = b.fmix(b.math('MAXIMUM', ulcer, raw), b.fmix(necro, b.fmix(fibrin, 0.34, 0.26), 0.55), 0.10)
    rough_i = b.fmix(b.mul(pus, 0.8), rough_i, 0.18)
    rough = b.fmix(wi, rough, rough_i)
    hi = b.add(b.mul(b.math('SUBTRACT', b.noise(Pi, 20.0, 4), 0.5), 0.6), b.mul(ulcer, -0.45), b.mul(fibrin, 0.15),
               b.mul(raw, -1.0), b.mul(raw_edge, 0.25), b.mul(pus, 0.35), b.mul(necro, -0.2))
    h = b.fmix(wi, h, hi)

    b.finish(col, rough, h, strength=0.55, distance=0.0012)
    return mat


# ------------------------------------------------------------------------------------------------ detail
def detail_material():
    mat = bpy.data.materials.new('Seal_Detail_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    P = b.vattr('pco')
    F = b.vattr('fco')
    eye, eyez, sclera, whisker, claw, cap, cap_d, cap_u, cap_v, line = (
        b.attr(n) for n in ('eye', 'eyez', 'sclera', 'whisker', 'claw', 'cap', 'cap_d', 'cap_u', 'cap_v', 'line'))

    # eyes: almost all pupil, a dark brown iris edge, a bloodshot sliver of white in the back corner
    col = b.mix(b.mr(eyez, 0.55, 0.8), (0.030, 0.016, 0.009), (0.0025, 0.0022, 0.002))
    veins = b.lines(b.noise(b.warp(P, 400.0, 0.001), 700.0, 3), 0.03)
    scl = b.mix(b.mul(veins, 0.7), (0.42, 0.30, 0.27), (0.30, 0.03, 0.03))
    col = b.mix(b.mr(sclera, 0.1, 0.6), col, scl)
    col = b.mix(b.mr(eyez, -0.4, -0.7), col, (0.02, 0.01, 0.01))
    rough = b.fmix(b.mr(sclera, 0.1, 0.6), 0.02, 0.10)
    h = b.mul(b.noise(P, 900.0, 2), 0.02)

    # whiskers: pale beaded keratin, dark at the root
    wcol = b.mix(b.mr(cap_u, 0.02, 0.18), (0.10, 0.085, 0.07), b.mix(b.noise(P, 300.0, 2), (0.46, 0.42, 0.34), (0.60, 0.56, 0.47)))
    col = b.mix(whisker, col, wcol)
    rough = b.fmix(whisker, rough, 0.38)

    # claws: dark horn with striations and worn pale tips
    stri = b.noise(b.vscale(F, (1.0, 1.0, 1.0)), 900.0, 2, 0.5)
    ccol = b.mix(b.mr(cap_u, 0.55, 0.95), b.mix(stri, (0.018, 0.015, 0.012), (0.045, 0.036, 0.028)), (0.20, 0.17, 0.13))
    col = b.mix(claw, col, ccol)
    rough = b.fmix(claw, rough, b.fmix(stri, 0.26, 0.4))
    h = b.add(h, b.mul(claw, b.math('SUBTRACT', stri, 0.5), 0.3))

    # the cut face: skin rim, thin fat, dark wet muscle with fibre ends, radius and ulna with marrow
    d = cap_d
    muscle = b.mix(b.noise(b.vscale(F, (1.0, 1.0, 0.0)), 180.0, 5, 0.6), (0.11, 0.008, 0.010), (0.24, 0.025, 0.022))
    fib = b.voronoi(b.vscale(F, (1.0, 1.0, 0.0)), 520.0, 1.0, 'DISTANCE_TO_EDGE').outputs['Distance']
    muscle = b.mix(b.mul(b.mr(fib, 0.05, 0.0), 0.5), muscle, (0.30, 0.10, 0.08))
    fascia = b.lines(b.noise(b.warp(b.vscale(F, (1, 1, 0)), 60.0, 0.004), 40.0, 3), 0.018)
    muscle = b.mix(b.mul(fascia, 0.6), muscle, (0.45, 0.30, 0.22))
    fat = b.mix(b.noise(F, 300.0, 3), (0.50, 0.40, 0.24), (0.62, 0.52, 0.32))
    ccap = b.mix(b.mr(d, 0.0055, 0.0075), fat, muscle)
    ccap = b.mix(b.mr(d, 0.0028, 0.0018), ccap, (0.035, 0.033, 0.032))
    bone_ring = None
    bone_fill = None
    for bu, bv, rv, ru in G.BONES_UV:
        du = b.math('DIVIDE', b.math('SUBTRACT', cap_u, bu), ru)
        dv = b.math('DIVIDE', b.math('SUBTRACT', cap_v, bv), rv)
        rr = b.math('SQRT', b.add(b.mul(du, du), b.mul(dv, dv)))
        rr = b.add(rr, b.mul(b.math('SUBTRACT', b.noise(F, 400.0, 3), 0.5), 0.12))
        ring_ = b.mul(b.mr(rr, 1.05, 0.95), b.mr(rr, 0.55, 0.68))
        fill = b.mr(rr, 0.70, 0.55)
        bone_ring = ring_ if bone_ring is None else b.math('MAXIMUM', bone_ring, ring_)
        bone_fill = fill if bone_fill is None else b.math('MAXIMUM', bone_fill, fill)
    saw = b.add(0.5, b.mul(b.math('SINE', b.mul(cap_v, 2400.0)), 0.5))
    bone_c = b.mix(b.mul(saw, 0.25), b.mix(b.noise(F, 500.0, 3), (0.55, 0.50, 0.40), (0.70, 0.65, 0.54)), (0.40, 0.34, 0.26))
    marrow = b.mix(b.noise(F, 600.0, 4), (0.20, 0.03, 0.03), (0.34, 0.10, 0.06))
    ccap = b.mix(bone_ring, ccap, bone_c)
    ccap = b.mix(bone_fill, ccap, marrow)
    # blood welling toward the lowest part of the face
    pool = b.mul(b.mr(cap_u, -0.005, -0.03), b.mr(b.noise(F, 60.0, 4), 0.3, 0.55))
    ccap = b.mix(b.mul(pool, 0.7, b.math('SUBTRACT', 1.0, bone_ring)), ccap, (0.08, 0.004, 0.006))
    col = b.mix(cap, col, ccap)
    rough_cap = b.fmix(bone_ring, b.fmix(b.mr(d, 0.0028, 0.0018), 0.14, 0.45), 0.42)
    rough = b.fmix(cap, rough, rough_cap)
    hcap = b.add(b.mul(b.math('SUBTRACT', b.noise(F, 180.0, 5), 0.5), 0.5), b.mul(bone_ring, 0.5), b.mul(saw, bone_ring, 0.15),
                 b.mul(b.mr(fib, 0.05, 0.0), -0.2))
    h = b.fmix(cap, h, hcap)

    # fishing line: scuffed green-grey monofilament with a crust of algae
    lcol = b.mix(b.mr(b.noise(P, 150.0, 3), 0.5, 0.7), (0.30, 0.42, 0.34), (0.22, 0.20, 0.12))
    col = b.mix(line, col, lcol)
    rough = b.fmix(line, rough, 0.22)

    b.finish(col, rough, h, strength=0.5, distance=0.0008)
    return mat


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
    nm.uv_map = 'UVMap'
    nt.links.new(tc.outputs['Color'], bsdf.inputs['Base Color'])
    nt.links.new(tr.outputs['Color'], bsdf.inputs['Roughness'])
    nt.links.new(tn.outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
    bsdf.inputs['Specular IOR Level'].default_value = 0.45
    return mat, (tc, tr, tn)
