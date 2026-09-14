"""Procedural Cycles materials for the Night Nurse (the source of the baked PBR maps).

Each procedural material exposes three signals, switched onto the output for baking:
color (albedo), rough (roughness) and the bumped surface normal.
"""
import bpy


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

    def val(self, v):
        if isinstance(v, (int, float)):
            node = self.n('ShaderNodeValue')
            node.outputs[0].default_value = float(v)
            return node.outputs[0]
        return v

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

    def vscale(self, vec, s):
        node = self.n('ShaderNodeMapping')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = s
        return node.outputs['Vector']

    def noise(self, vec, scale, detail=4.0, rough=0.5, distort=0.0, fac=True, w=None):
        node = self.n('ShaderNodeTexNoise')
        if w is not None:
            node.noise_dimensions = '4D'
            node.inputs['W'].default_value = w
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        node.inputs['Detail'].default_value = detail
        node.inputs['Roughness'].default_value = rough
        node.inputs['Distortion'].default_value = distort
        return node.outputs['Fac'] if fac else node.outputs['Color']

    def voronoi_edge(self, vec, scale):
        node = self.n('ShaderNodeTexVoronoi', feature='DISTANCE_TO_EDGE')
        self.link(vec, node.inputs['Vector'])
        node.inputs['Scale'].default_value = scale
        return node.outputs['Distance']

    def voronoi(self, vec, scale, rand=1.0):
        node = self.n('ShaderNodeTexVoronoi', feature='F1')
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
        add = self.n('ShaderNodeVectorMath', operation='ADD')
        self.link(vec, add.inputs[0])
        self.link(sc.outputs[0], add.inputs[1])
        return add.outputs[0]

    def finish(self, color, rough, height, strength=1.0, distance=0.001):
        bsdf = self.n('ShaderNodeBsdfPrincipled')
        self.link(color, bsdf.inputs['Base Color'])
        self.link(rough, bsdf.inputs['Roughness'])
        bump = self.n('ShaderNodeBump')
        bump.inputs['Strength'].default_value = strength
        bump.inputs['Distance'].default_value = distance
        self.link(height, bump.inputs['Height'])
        self.link(bump.outputs['Normal'], bsdf.inputs['Normal'])
        emit = self.n('ShaderNodeEmission', name='BakeEmit')
        emit.name = 'BakeEmit'
        out = self.n('ShaderNodeOutputMaterial')
        out.name = 'Out'
        self.link(bsdf.outputs[0], out.inputs['Surface'])
        # stash the signals on named reroutes so the baker can switch them
        for nm, sock in (('SIG_color', color), ('SIG_rough', rough)):
            r = self.n('NodeReroute')
            r.name = nm
            self.link(sock, r.inputs[0])
        bsdf.name = 'BSDF'


def set_bake_signal(mat, which):
    nt = mat.node_tree
    out, emit, bsdf = nt.nodes['Out'], nt.nodes['BakeEmit'], nt.nodes['BSDF']
    for l in list(out.inputs['Surface'].links):
        nt.links.remove(l)
    if which in ('color', 'rough'):
        for l in list(emit.inputs['Color'].links):
            nt.links.remove(l)
        nt.links.new(nt.nodes['SIG_' + which].outputs[0], emit.inputs['Color'])
        nt.links.new(emit.outputs[0], out.inputs['Surface'])
    else:
        nt.links.new(bsdf.outputs[0], out.inputs['Surface'])


def cloth_material():
    mat = bpy.data.materials.new('NN_Cloth_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    z = b.n('ShaderNodeSeparateXYZ')
    b.link(co, z.inputs[0])
    zc = z.outputs['Z']
    apron, stock, shoe, sole, belt = b.attr('apron'), b.attr('stocking'), b.attr('shoe'), b.attr('sole'), b.attr('belt')
    maskA, cap, bloodz, crease, mouth, tie = b.attr('mask'), b.attr('cap'), b.attr('blood'), b.attr('crease'), b.attr('mouth'), b.attr('tie')

    # base whites, slightly different per garment
    col = b.mix(b.noise(co, 9.0, 2, 0.5), (0.50, 0.49, 0.45), (0.60, 0.585, 0.53))
    col = b.mix(apron, col, b.mix(b.noise(co, 20.0, 3), (0.64, 0.63, 0.585), (0.72, 0.71, 0.66)))
    col = b.mix(cap, col, (0.76, 0.75, 0.70))
    col = b.mix(maskA, col, b.mix(b.noise(co, 60.0, 4), (0.43, 0.52, 0.50), (0.50, 0.59, 0.56)))
    col = b.mix(tie, col, (0.60, 0.64, 0.60))
    col = b.mix(stock, col, b.mix(b.noise(co, 30.0, 5), (0.42, 0.41, 0.385), (0.52, 0.51, 0.48)))
    col = b.mix(shoe, col, b.mix(b.noise(co, 45.0, 6), (0.44, 0.42, 0.37), (0.58, 0.56, 0.50)))
    col = b.mix(b.math('MULTIPLY', shoe, sole), col, (0.12, 0.11, 0.10))
    col = b.mix(belt, col, b.mix(b.noise(co, 50.0, 4), (0.035, 0.04, 0.06), (0.07, 0.075, 0.10)))

    whites = b.math('MAXIMUM', b.math('SUBTRACT', 1.0, b.math('ADD', b.math('ADD', belt, shoe), stock), clamp=True), 0.0)
    # yellowed age: broad blotches, stronger on the skirt and at the armpits/collar
    age = b.mr(b.noise(b.warp(co, 2.0, 0.3), 3.2, 8, 0.62), 0.38, 0.70)
    col = b.mix(b.math('MULTIPLY', age, 0.72), col, (0.50, 0.42, 0.27))
    # hem grime rising from the floor
    hem = b.mr(zc, 0.75, 0.34)
    grime = b.math('MULTIPLY', hem, b.mr(b.noise(b.vscale(co, (1, 1, 0.35)), 6.0, 8, 0.65), 0.35, 0.75))
    col = b.mix(b.math('MULTIPLY', grime, 0.55), col, (0.36, 0.31, 0.23))
    # water-mark tide lines
    tide = b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', b.noise(co, 4.5, 3), 0.55)), 0.012, 0.0)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', tide, 0.12), whites), col, (0.45, 0.38, 0.25))

    # old blood: splatter spots, drips running down, brown halos
    splat_n = b.noise(b.warp(co, 9.0, 0.05), 11.0, 12, 0.75)
    spots = b.math('MULTIPLY', b.mr(splat_n, 0.615, 0.655), bloodz)
    halo = b.math('MULTIPLY', b.mr(splat_n, 0.55, 0.64), bloodz)
    drip_n = b.noise(b.vscale(co, (38, 38, 2.2)), 1.0, 6, 0.6)
    drips = b.math('MULTIPLY', b.mr(drip_n, 0.66, 0.72), b.math('MULTIPLY', bloodz, b.mr(b.noise(co, 3.0, 2), 0.40, 0.60)))
    # smears on the apron where the hands were wiped, at hanging-hand height
    def ellip(c, s):
        mp = b.n('ShaderNodeMapping', vector_type='POINT')
        b.link(co, mp.inputs['Vector'])
        mp.inputs['Scale'].default_value = (1 / s[0], 1 / s[1], 1 / s[2])
        mp.inputs['Location'].default_value = (-c[0] / s[0], -c[1] / s[1], -c[2] / s[2])
        ln = b.n('ShaderNodeVectorMath', operation='LENGTH')
        b.link(mp.outputs[0], ln.inputs[0])
        return ln.outputs['Value']
    streak = b.noise(b.warp(b.vscale(co, (30, 30, 3)), 4.0, 0.3), 1.0, 5, 0.6)
    for sx in (1, -1):
        d = ellip((sx * 0.12, -0.17, 0.92), (0.05, 0.12, 0.13))
        sm = b.math('MULTIPLY', b.mr(d, 1.0, 0.3), b.mr(streak, 0.42, 0.58))
        drips = b.math('MAXIMUM', drips, b.math('MULTIPLY', sm, apron))
    # grit: dirt settled in the creases, smudges, sweat-yellowed armpits and collar, slubby linen
    crease_n = b.noise(b.warp(b.vscale(co, (7, 7, 1.4)), 3.0, 0.25), 3.0, 5, 0.55)
    creases = b.math('MULTIPLY', b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', crease_n, 0.5)), 0.0, 0.06, 1.0, 0.0), crease)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', creases, 0.55), whites), col, (0.30, 0.26, 0.20))
    smudge = b.mr(b.noise(b.warp(co, 6.0, 0.1), 28.0, 10, 0.72), 0.58, 0.74)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', smudge, 0.45), whites), col, (0.33, 0.29, 0.23))
    specks = b.mr(b.noise(co, 160.0, 4, 0.6), 0.70, 0.78)
    col = b.mix(b.math('MULTIPLY', specks, 0.5), col, (0.22, 0.19, 0.15))
    sweat = b.math('MAXIMUM', b.mr(ellip((0.13, 0.0, 1.60), (0.05, 0.08, 0.09)), 1.2, 0.3),
                   b.mr(ellip((-0.13, 0.0, 1.60), (0.05, 0.08, 0.09)), 1.2, 0.3))
    sweat = b.math('MAXIMUM', sweat, b.math('MULTIPLY', b.mr(zc, 1.76, 1.84), 0.8))
    sweat = b.math('MULTIPLY', sweat, b.mr(b.noise(co, 12.0, 6, 0.6), 0.35, 0.6))
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', sweat, 0.75), whites), col, (0.48, 0.38, 0.20))
    slub = b.noise(b.vscale(co, (1.0, 1.0, 35.0)), 70.0, 2, 0.5)
    slub2 = b.noise(b.vscale(co, (35.0, 35.0, 1.0)), 70.0, 2, 0.5)
    col = b.mix(b.math('MULTIPLY', b.mr(b.math('MAXIMUM', slub, slub2), 0.55, 0.75), 0.18), col, (0.35, 0.33, 0.29))

    col = b.mix(b.math('MULTIPLY', halo, 0.55), col, (0.40, 0.28, 0.17))
    col = b.mix(b.math('MAXIMUM', spots, drips), col, b.mix(b.noise(co, 80.0, 3), (0.14, 0.035, 0.025), (0.24, 0.06, 0.04)))
    import nn_geometry as G
    hc = G.HEAD_C
    sep = b.n('ShaderNodeSeparateXYZ')
    b.link(co, sep.inputs[0])
    xc = sep.outputs['X']
    # the mouth: a too-wide grin of old blood soaked through the mask, with the imprint of teeth
    mx, mz = hc.x + 0.003, hc.z - 0.066
    dx = b.math('SUBTRACT', xc, mx)
    curve = b.math('MULTIPLY', b.math('MULTIPLY', dx, dx), 22.0)          # corners pulled up
    dz = b.math('SUBTRACT', b.math('SUBTRACT', zc, mz), curve)
    wobble = b.math('MULTIPLY', b.math('SUBTRACT', b.noise(co, 70.0, 5, 0.7), 0.5), 0.35)
    gd = b.math('ADD', b.math('SQRT', b.math('ADD', b.math('POWER', b.math('DIVIDE', dx, 0.036), 2.0),
                                              b.math('POWER', b.math('DIVIDE', dz, 0.0085), 2.0))), wobble)
    front = b.mr(sep.outputs['Y'], hc.y - 0.07, hc.y - 0.10)
    grin = b.math('MULTIPLY', b.mr(gd, 1.05, 0.75), front)
    teeth = b.math('ADD', 0.5, b.math('MULTIPLY', b.math('SINE', b.math('MULTIPLY', dx, 6.2832 / 0.0068)), 0.5))
    teeth = b.mr(teeth, 0.25, 0.75)
    lip = b.mr(b.math('ABSOLUTE', dz), 0.0022, 0.0006)
    grin_dark = b.math('MULTIPLY', grin, b.math('MAXIMUM', b.math('MULTIPLY', teeth, 0.75), lip))
    seep = b.math('MULTIPLY', b.mr(gd, 2.2, 0.9), front)
    mouth_h = b.mr(b.math('ADD', mouth, b.math('MULTIPLY', b.math('SUBTRACT', b.noise(co, 60.0, 5, 0.7), 0.5), 0.7)), 0.12, 0.40)
    mouth_h = b.math('MAXIMUM', b.math('MULTIPLY', mouth_h, 0.6), b.math('MULTIPLY', seep, maskA))
    col = b.mix(b.math('MULTIPLY', mouth_h, 0.75), col, (0.34, 0.24, 0.14))
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', grin, maskA), 0.7), col, (0.22, 0.07, 0.05))
    mouth_e = b.math('MULTIPLY', grin_dark, maskA)
    col = b.mix(mouth_e, col, (0.07, 0.018, 0.014))
    # black tears running from the sockets down over the mask
    tears = None
    for sx, length in ((1, 0.13), (-1, 0.09)):
        tx = b.math('ABSOLUTE', b.math('ADD', b.math('SUBTRACT', xc, hc.x + sx * 0.030),
                                         b.math('MULTIPLY', b.math('SUBTRACT', b.noise(b.vscale(co, (4, 4, 1)), 30.0, 3), 0.5), 0.012)))
        run = b.mr(zc, hc.z + 0.012, hc.z + 0.012 - length)
        width = b.math('ADD', 0.0020, b.math('MULTIPLY', run, 0.0050))
        t = b.math('MULTIPLY', b.mr(b.math('DIVIDE', tx, width), 1.0, 0.2), b.math('SUBTRACT', 1.0, b.math('POWER', run, 6.0)))
        t = b.math('MULTIPLY', t, b.mr(zc, hc.z + 0.02, hc.z + 0.005))
        tears = t if tears is None else b.math('MAXIMUM', tears, t)
    tears = b.math('MULTIPLY', tears, front)
    col = b.mix(b.math('MULTIPLY', tears, maskA), col, (0.05, 0.035, 0.03))

    # roughness
    rough = b.mix(b.noise(co, 25.0, 3), (0.80, 0.80, 0.80), (0.92, 0.92, 0.92))
    rough = b.mix(shoe, rough, b.mix(b.noise(co, 70.0, 4), (0.32, 0.32, 0.32), (0.55, 0.55, 0.55)))
    rough = b.mix(belt, rough, (0.55, 0.55, 0.55))
    rough = b.mix(b.math('MAXIMUM', spots, mouth_e), rough, (0.5, 0.5, 0.5))
    rough_s = b.n('ShaderNodeSeparateColor')
    b.link(rough, rough_s.inputs[0])

    # height: linen tooth, creases, scuffs, crusted blood
    weave = b.math('ADD', b.noise(b.vscale(co, (1, 1, 5)), 700.0, 2, 0.5), b.noise(b.vscale(co, (5, 5, 1)), 700.0, 2, 0.5))
    wrink = b.noise(b.warp(co, 12.0, 0.08), 40.0, 6, 0.6)
    # rumpled fabric: a second, finer set of crease lines in a different direction
    crease2 = b.noise(b.warp(b.vscale(co, (3, 3, 9)), 5.0, 0.2), 6.0, 4, 0.55)
    creases2 = b.math('MULTIPLY', b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', crease2, 0.5)), 0.0, 0.04, 1.0, 0.0), crease)
    h = b.math('ADD', b.math('MULTIPLY', b.math('ADD', weave, b.math('ADD', slub, slub2)), 0.05), b.math('MULTIPLY', creases, -1.0))
    h = b.math('ADD', h, b.math('MULTIPLY', creases2, -0.45))
    h = b.math('ADD', h, b.math('MULTIPLY', wrink, 0.22))
    h = b.math('ADD', h, b.math('MULTIPLY', b.math('MAXIMUM', spots, mouth_e), 0.3))
    b.finish(col, rough_s.outputs[0], h, strength=0.7, distance=0.0025)
    return mat


def skin_material():
    mat = bpy.data.materials.new('NN_Skin_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    sock, knuck, nail, hair, eye, vein_a, bloodz = (b.attr(n) for n in ('sock', 'knuckle', 'nail', 'hair', 'eye', 'vein', 'blood'))

    mott = b.noise(co, 16.0, 6, 0.6)
    col = b.mix(mott, (0.24, 0.245, 0.255), (0.37, 0.365, 0.35))
    necro = b.mr(b.noise(b.warp(co, 4.0, 0.2), 9.0, 8, 0.7), 0.60, 0.72)
    col = b.mix(b.math('MULTIPLY', necro, 0.55), col, (0.20, 0.18, 0.21))
    col = b.mix(b.math('MULTIPLY', b.mr(b.noise(co, 5.0, 4), 0.45, 0.75), 0.6), col, (0.33, 0.29, 0.34))    # bruised purple patches
    col = b.mix(b.math('MULTIPLY', b.mr(b.noise(co, 55.0, 5), 0.55, 0.8), 0.45), col, (0.44, 0.42, 0.33))   # sallow yellow blotches
    # veins: warped voronoi cell edges, patchy
    wv = b.warp(co, 9.0, 0.10)
    v1 = b.mr(b.voronoi_edge(wv, 26.0), 0.0, 0.035, 1.0, 0.0)
    v2 = b.mr(b.voronoi_edge(b.warp(co, 30.0, 0.04), 70.0), 0.0, 0.03, 1.0, 0.0)
    patch = b.mr(b.noise(co, 6.0, 3), 0.40, 0.62)
    veins = b.math('MULTIPLY', b.math('MAXIMUM', v1, b.math('MULTIPLY', v2, 0.55)), b.math('MULTIPLY', patch, vein_a))
    col = b.mix(b.math('MULTIPLY', veins, 0.9), col, (0.09, 0.11, 0.17))
    # knuckles darker and wrinkled
    col = b.mix(b.math('MULTIPLY', knuck, 0.45), col, (0.25, 0.20, 0.23))
    # nails: yellow-grey horn with dark grime at the tips
    nail_c = b.mix(b.mr(b.noise(b.vscale(co, (1, 1, 12)), 60.0, 3), 0.3, 0.7), (0.30, 0.28, 0.20), (0.46, 0.43, 0.32))
    col = b.mix(nail, col, nail_c)
    # dried blood on fingertips and palms
    bspots = b.math('MULTIPLY', b.mr(b.noise(co, 30.0, 10, 0.7), 0.58, 0.64), bloodz)
    col = b.mix(bspots, col, (0.16, 0.045, 0.03))
    # sunken sockets: bruised rims, black depths (object-space ellipsoids, sharper than the mesh)
    def ellip(c, s):
        mp = b.n('ShaderNodeMapping', vector_type='POINT')
        b.link(co, mp.inputs['Vector'])
        mp.inputs['Scale'].default_value = (1 / s[0], 1 / s[1], 1 / s[2])
        mp.inputs['Location'].default_value = (-c[0] / s[0], -c[1] / s[1], -c[2] / s[2])
        ln = b.n('ShaderNodeVectorMath', operation='LENGTH')
        b.link(mp.outputs[0], ln.inputs[0])
        return ln.outputs['Value']
    import nn_geometry as G
    hc = G.HEAD_C
    dL = ellip((hc.x + 0.029, hc.y - 0.076, hc.z + 0.015), (0.019, 0.03, 0.015))
    dR = ellip((hc.x - 0.029, hc.y - 0.076, hc.z + 0.015), (0.019, 0.03, 0.015))
    dmin = b.math('MINIMUM', dL, dR)
    dmin = b.math('ADD', dmin, b.math('MULTIPLY', b.math('SUBTRACT', b.noise(b.warp(co, 60.0, 0.004), 45.0, 4), 0.5), 0.7))
    rim = b.mr(dmin, 2.0, 1.0)
    deep = b.mr(dmin, 1.2, 0.6)
    # crow's-feet: concentric creases radiating round the sockets
    rings_ = b.math('MULTIPLY', b.math('ADD', 0.5, b.math('MULTIPLY', b.math('SINE', b.math('MULTIPLY', dmin, 26.0)), 0.5)),
                    b.math('MULTIPLY', b.mr(dmin, 2.8, 1.6), b.mr(dmin, 1.0, 1.5)))
    col = b.mix(b.math('MULTIPLY', rings_, 0.2), col, (0.16, 0.13, 0.14))
    col = b.mix(b.math('MULTIPLY', rim, 0.8), col, (0.22, 0.08, 0.09))
    col = b.mix(b.math('MAXIMUM', deep, b.mr(sock, 0.6, 0.95)), col, (0.006, 0.004, 0.004))
    # forehead furrows
    fz = b.noise(b.warp(b.vscale(co, (3, 3, 70)), 20.0, 0.02), 8.0, 3, 0.5)
    furrow = b.math('MULTIPLY', b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', fz, 0.5)), 0.0, 0.05, 1.0, 0.0),
                    b.mr(ellip((hc.x, hc.y - 0.085, hc.z + 0.075), (0.055, 0.05, 0.03)), 1.3, 0.5))
    col = b.mix(b.math('MULTIPLY', furrow, 0.4), col, (0.15, 0.13, 0.13))
    # black tears from the sockets, down to the mask
    sep = b.n('ShaderNodeSeparateXYZ')
    b.link(co, sep.inputs[0])
    xc, zc = sep.outputs['X'], sep.outputs['Z']
    tears = None
    for sx, length in ((1, 0.13), (-1, 0.09)):
        tx = b.math('ABSOLUTE', b.math('ADD', b.math('SUBTRACT', xc, hc.x + sx * 0.030),
                                         b.math('MULTIPLY', b.math('SUBTRACT', b.noise(b.vscale(co, (4, 4, 1)), 30.0, 3), 0.5), 0.012)))
        run = b.mr(zc, hc.z + 0.012, hc.z + 0.012 - length)
        width = b.math('ADD', 0.0020, b.math('MULTIPLY', run, 0.0050))
        t = b.math('MULTIPLY', b.mr(b.math('DIVIDE', tx, width), 1.0, 0.2), b.math('SUBTRACT', 1.0, b.math('POWER', run, 6.0)))
        t = b.math('MULTIPLY', t, b.mr(zc, hc.z + 0.02, hc.z + 0.005))
        tears = t if tears is None else b.math('MAXIMUM', tears, t)
    tears = b.math('MULTIPLY', tears, b.mr(sep.outputs['Y'], hc.y - 0.05, hc.y - 0.09))
    col = b.mix(tears, col, (0.03, 0.02, 0.018))
    # hair: scraped-back, greasy dark grey strands
    strands = b.noise(b.vscale(co, (60, 60, 4)), 12.0, 4, 0.5)
    hairc = b.mix(b.mr(strands, 0.3, 0.7), (0.035, 0.032, 0.030), (0.085, 0.078, 0.072))
    col = b.mix(b.math('MULTIPLY', hair, 0.92), col, hairc)
    col = b.mix(eye, col, (0.004, 0.004, 0.004))

    rough = b.mix(mott, (0.52, 0.52, 0.52), (0.68, 0.68, 0.68))
    rough = b.mix(b.math('MULTIPLY', veins, 0.5), rough, (0.42, 0.42, 0.42))
    rough = b.mix(nail, rough, (0.28, 0.28, 0.28))
    rough = b.mix(b.mr(sock, 0.4, 0.9), rough, (0.30, 0.30, 0.30))
    rough = b.mix(b.math('MAXIMUM', b.mr(dmin, 2.2, 0.8), tears), rough, (0.22, 0.22, 0.22))   # wet round the eyes
    rough = b.mix(hair, rough, (0.55, 0.55, 0.55))
    rough = b.mix(eye, rough, (0.04, 0.04, 0.04))
    rs = b.n('ShaderNodeSeparateColor')
    b.link(rough, rs.inputs[0])

    pores = b.noise(co, 900.0, 2, 0.5)
    wr = b.noise(b.warp(b.vscale(co, (2, 2, 30)), 25.0, 0.05), 20.0, 4, 0.6)
    wrinkles = b.math('MULTIPLY', b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', wr, 0.5)), 0.0, 0.05, 1.0, 0.0), b.math('ADD', knuck, 0.15))
    h = b.math('ADD', b.math('MULTIPLY', pores, 0.03), b.math('MULTIPLY', veins, 0.55))
    h = b.math('ADD', h, b.math('MULTIPLY', wrinkles, -0.6))
    h = b.math('ADD', h, b.math('MULTIPLY', rings_, -0.3))
    h = b.math('ADD', h, b.math('MULTIPLY', furrow, -0.7))
    h = b.math('ADD', h, b.math('MULTIPLY', necro, 0.25))
    h = b.math('ADD', h, b.math('MULTIPLY', mott, 0.2))
    h = b.math('ADD', h, b.math('MULTIPLY', b.math('MULTIPLY', strands, hair), 0.25))
    b.finish(col, rs.outputs[0], h, strength=0.5, distance=0.0015)
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
    nt.links.new(tc.outputs['Color'], bsdf.inputs['Base Color'])
    nt.links.new(tr.outputs['Color'], bsdf.inputs['Roughness'])
    nt.links.new(tn.outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
    bsdf.inputs['Specular IOR Level'].default_value = 0.35
    return mat, (tc, tr, tn)
