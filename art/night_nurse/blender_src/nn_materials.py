"""Procedural Cycles materials for the Night Nurse (the source of the baked PBR maps).

Stylized: all the grime, blood and wear is in the colour (as detailed as the original's paint); the relief
stays nearly flat, so there are no pores, veins, wrinkles or weave in the normal map.

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


def ellipsoid(b, co, c, s):
    """Distance in units of the ellipsoid's radii from its centre c (object space)."""
    mp = b.n('ShaderNodeMapping', vector_type='POINT')
    b.link(co, mp.inputs['Vector'])
    mp.inputs['Scale'].default_value = (1 / s[0], 1 / s[1], 1 / s[2])
    mp.inputs['Location'].default_value = (-c[0] / s[0], -c[1] / s[1], -c[2] / s[2])
    ln = b.n('ShaderNodeVectorMath', operation='LENGTH')
    b.link(mp.outputs[0], ln.inputs[0])
    return ln.outputs['Value']


def tears_mask(b, co, hc, front):
    """Two thick black tears running from the sockets down over the face and mask."""
    sep = b.n('ShaderNodeSeparateXYZ')
    b.link(co, sep.inputs[0])
    xc, zc = sep.outputs['X'], sep.outputs['Z']
    tears = None
    for sx, length in ((1, 0.13), (-1, 0.09)):
        tx = b.math('ABSOLUTE', b.math('ADD', b.math('SUBTRACT', xc, hc.x + sx * 0.030),
                                         b.math('MULTIPLY', b.math('SUBTRACT', b.noise(b.vscale(co, (4, 4, 1)), 12.0, 1), 0.5), 0.010)))
        run = b.mr(zc, hc.z + 0.010, hc.z + 0.010 - length)
        width = b.math('ADD', 0.0055, b.math('MULTIPLY', run, 0.0050))
        # a hard painted edge, a rounded drop at the end
        t = b.math('MULTIPLY', b.mr(b.math('DIVIDE', tx, width), 1.0, 0.8), b.mr(run, 1.0, 0.94))
        t = b.math('MULTIPLY', t, b.mr(zc, hc.z + 0.02, hc.z + 0.008))
        tears = t if tears is None else b.math('MAXIMUM', tears, t)
    return b.math('MULTIPLY', tears, front)


def cloth_material():
    """Stylized cloth with the original's detailed paint: yellowed age, hem grime, tide lines, crease dirt,
    smudges, specks, sweat stains, old blood splatter with brown halos, drips and wiped-hand smears.
    All of it is colour; the relief stays nearly flat (no weave, slubs or wrinkles), so the forms read simple."""
    mat = bpy.data.materials.new('NN_Cloth_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    z = b.n('ShaderNodeSeparateXYZ')
    b.link(co, z.inputs[0])
    zc = z.outputs['Z']
    apron, stock, shoe, sole, belt = b.attr('apron'), b.attr('stocking'), b.attr('shoe'), b.attr('sole'), b.attr('belt')
    maskA, bloodz, crease, tie = b.attr('mask'), b.attr('blood'), b.attr('crease'), b.attr('tie')

    # flat base colours per garment
    soft = b.noise(co, 2.5, 1, 0.3)
    col = b.mix(soft, (0.53, 0.52, 0.48), (0.58, 0.57, 0.52))                        # dress
    col = b.mix(apron, col, b.mix(soft, (0.68, 0.67, 0.62), (0.72, 0.71, 0.66)))      # apron
    col = b.mix(maskA, col, b.mix(soft, (0.46, 0.55, 0.52), (0.50, 0.59, 0.56)))      # surgical-green mask
    col = b.mix(tie, col, (0.58, 0.62, 0.58))
    col = b.mix(stock, col, (0.30, 0.29, 0.28))                                        # dark stockings
    col = b.mix(shoe, col, (0.60, 0.58, 0.52))
    col = b.mix(b.math('MULTIPLY', shoe, sole), col, (0.14, 0.13, 0.12))
    col = b.mix(belt, col, (0.06, 0.065, 0.085))

    whites = b.math('MAXIMUM', b.math('SUBTRACT', 1.0, b.math('ADD', b.math('ADD', belt, shoe), stock), clamp=True), 0.0)
    fabric = b.math('MAXIMUM', b.math('SUBTRACT', whites, maskA, clamp=True), 0.0)    # the whites, not the mask
    # yellowed age: broad blotches
    age = b.mr(b.noise(b.warp(co, 2.0, 0.3), 3.2, 8, 0.62), 0.38, 0.70)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', age, 0.62), fabric), col, (0.52, 0.44, 0.29))
    # hem grime rising from the floor
    hem = b.mr(zc, 0.78, 0.34)
    grime = b.math('MULTIPLY', hem, b.mr(b.noise(b.vscale(co, (1, 1, 0.35)), 6.0, 8, 0.65), 0.35, 0.75))
    col = b.mix(b.math('MULTIPLY', grime, 0.6), col, (0.34, 0.30, 0.22))
    # water-mark tide lines
    tide = b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', b.noise(co, 4.5, 3), 0.55)), 0.012, 0.0)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', tide, 0.14), fabric), col, (0.45, 0.38, 0.25))
    # dirt settled in the creases, smudges, specks
    crease_n = b.noise(b.warp(b.vscale(co, (7, 7, 1.4)), 3.0, 0.25), 3.0, 5, 0.55)
    creases = b.math('MULTIPLY', b.mr(b.math('ABSOLUTE', b.math('SUBTRACT', crease_n, 0.5)), 0.0, 0.06, 1.0, 0.0), crease)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', creases, 0.5), whites), col, (0.30, 0.26, 0.20))
    smudge = b.mr(b.noise(b.warp(co, 6.0, 0.1), 28.0, 10, 0.72), 0.58, 0.74)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', smudge, 0.45), whites), col, (0.33, 0.29, 0.23))
    specks = b.mr(b.noise(co, 160.0, 4, 0.6), 0.70, 0.78)
    col = b.mix(b.math('MULTIPLY', specks, 0.5), col, (0.22, 0.19, 0.15))
    # sweat-yellowed armpits and collar
    sweat = b.math('MAXIMUM', b.mr(ellipsoid(b, co, (0.13, 0.0, 1.60), (0.05, 0.08, 0.09)), 1.2, 0.3),
                   b.mr(ellipsoid(b, co, (-0.13, 0.0, 1.60), (0.05, 0.08, 0.09)), 1.2, 0.3))
    sweat = b.math('MAXIMUM', sweat, b.math('MULTIPLY', b.mr(zc, 1.76, 1.84), 0.8))
    sweat = b.math('MULTIPLY', sweat, b.mr(b.noise(co, 12.0, 6, 0.6), 0.35, 0.6))
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', sweat, 0.75), fabric), col, (0.48, 0.38, 0.20))

    # old blood: splatter spots with brown halos, drips running down, smears where the hands were wiped;
    # a light spray reaches the mask too
    bz = b.math('MAXIMUM', bloodz, b.math('MULTIPLY', maskA, 0.45))
    splat_n = b.noise(b.warp(co, 9.0, 0.05), 11.0, 12, 0.75)
    spots = b.math('MULTIPLY', b.mr(splat_n, 0.615, 0.655), bz)
    halo = b.math('MULTIPLY', b.mr(splat_n, 0.55, 0.64), bz)
    drip_n = b.noise(b.vscale(co, (38, 38, 2.2)), 1.0, 6, 0.6)
    drips = b.math('MULTIPLY', b.mr(drip_n, 0.66, 0.72), b.math('MULTIPLY', bloodz, b.mr(b.noise(co, 3.0, 2), 0.40, 0.60)))
    streak = b.noise(b.warp(b.vscale(co, (30, 30, 3)), 4.0, 0.3), 1.0, 5, 0.6)
    for sx in (1, -1):
        d = ellipsoid(b, co, (sx * 0.12, -0.17, 0.92), (0.05, 0.12, 0.13))
        sm = b.math('MULTIPLY', b.mr(d, 1.0, 0.3), b.mr(streak, 0.42, 0.58))
        drips = b.math('MAXIMUM', drips, b.math('MULTIPLY', sm, apron))
    blood = b.math('MAXIMUM', spots, drips)
    col = b.mix(b.math('MULTIPLY', halo, 0.55), col, (0.40, 0.28, 0.17))
    col = b.mix(blood, col, b.mix(b.noise(co, 80.0, 3), (0.14, 0.035, 0.025), (0.24, 0.06, 0.04)))

    import nn_geometry as G
    hc = G.HEAD_C
    sep = b.n('ShaderNodeSeparateXYZ')
    b.link(co, sep.inputs[0])
    xc = sep.outputs['X']
    front = b.mr(sep.outputs['Y'], hc.y - 0.07, hc.y - 0.10)
    # the mouth: a too-wide painted grin soaked through the mask, with a row of teeth
    mx, mz = hc.x + 0.003, hc.z - 0.066
    dx = b.math('SUBTRACT', xc, mx)
    curve = b.math('MULTIPLY', b.math('MULTIPLY', dx, dx), 22.0)          # corners pulled up
    dz = b.math('SUBTRACT', b.math('SUBTRACT', zc, mz), curve)
    wob = b.math('MULTIPLY', b.math('SUBTRACT', b.noise(co, 70.0, 5, 0.7), 0.5), 0.18)
    gd = b.math('ADD', b.math('SQRT', b.math('ADD', b.math('POWER', b.math('DIVIDE', dx, 0.040), 2.0),
                                              b.math('POWER', b.math('DIVIDE', dz, 0.011), 2.0))), wob)
    grin = b.math('MULTIPLY', b.mr(gd, 1.0, 0.9), front)
    teeth = b.math('ADD', 0.5, b.math('MULTIPLY', b.math('SINE', b.math('MULTIPLY', dx, 6.2832 / 0.0085)), 0.5))
    teeth = b.math('MULTIPLY', b.mr(teeth, 0.35, 0.55), b.mr(b.math('ABSOLUTE', dz), 0.0065, 0.0045))
    lip = b.mr(b.math('ABSOLUTE', dz), 0.0016, 0.0008)
    seep = b.math('MULTIPLY', b.mr(gd, 1.8, 1.2), front)
    col = b.mix(b.math('MULTIPLY', b.math('MULTIPLY', seep, maskA), 0.7), col, (0.33, 0.17, 0.12))
    col = b.mix(b.math('MULTIPLY', grin, maskA), col, (0.19, 0.025, 0.02))
    mouth_e = b.math('MULTIPLY', b.math('MULTIPLY', grin, b.math('SUBTRACT', 1.0, teeth)), b.math('MAXIMUM', lip, b.mr(b.math('ABSOLUTE', dz), 0.0048, 0.0030)))
    col = b.mix(b.math('MULTIPLY', mouth_e, maskA), col, (0.06, 0.012, 0.010))
    tears = tears_mask(b, co, hc, front)
    col = b.mix(b.math('MULTIPLY', tears, maskA), col, (0.035, 0.028, 0.026))

    rough = b.mix(soft, (0.84, 0.84, 0.84), (0.88, 0.88, 0.88))
    rough = b.mix(shoe, rough, (0.42, 0.42, 0.42))
    rough = b.mix(belt, rough, (0.50, 0.50, 0.50))
    rough = b.mix(b.math('MAXIMUM', spots, b.math('MULTIPLY', grin, maskA)), rough, (0.5, 0.5, 0.5))
    rough = b.mix(b.math('MULTIPLY', tears, maskA), rough, (0.30, 0.30, 0.30))
    rough_s = b.n('ShaderNodeSeparateColor')
    b.link(rough, rough_s.inputs[0])

    # height: only a soft cloth tooth and the slightest raise of dried blood
    h = b.math('ADD', b.math('MULTIPLY', b.noise(co, 30.0, 1, 0.3), 0.04), b.math('MULTIPLY', spots, 0.10))
    b.finish(col, rough_s.outputs[0], h, strength=0.25, distance=0.002)
    return mat


def skin_material():
    """Stylized skin with painted wear: grey mottling, bruised and necrotic patches, sallow blotches, grime
    on the knuckles and nails, dried blood on the fingers; bruised wet sockets and black tears; solid dark
    hair with a sheen. Colour only: no pores, veins, crow's feet or furrows (those read as anatomy lines)."""
    mat = bpy.data.materials.new('NN_Skin_Procedural')
    mat.use_nodes = True
    b = NB(mat)
    co = b.coords()
    sock, knuck, nail, hair, eye, bloodz = (b.attr(n) for n in ('sock', 'knuckle', 'nail', 'hair', 'eye', 'blood'))

    mott = b.noise(co, 16.0, 6, 0.6)
    col = b.mix(mott, (0.31, 0.315, 0.33), (0.39, 0.39, 0.395))
    necro = b.mr(b.noise(b.warp(co, 4.0, 0.2), 9.0, 8, 0.7), 0.60, 0.72)
    col = b.mix(b.math('MULTIPLY', necro, 0.5), col, (0.22, 0.20, 0.23))
    col = b.mix(b.math('MULTIPLY', b.mr(b.noise(co, 5.0, 4), 0.45, 0.75), 0.55), col, (0.33, 0.28, 0.34))   # bruised patches
    col = b.mix(b.math('MULTIPLY', b.mr(b.noise(co, 55.0, 5), 0.55, 0.8), 0.4), col, (0.44, 0.42, 0.33))    # sallow blotches
    col = b.mix(b.math('MULTIPLY', knuck, 0.45), col, (0.25, 0.20, 0.23))                                    # grimy knuckles
    nail_c = b.mix(b.mr(b.noise(b.vscale(co, (1, 1, 12)), 60.0, 3), 0.3, 0.7), (0.26, 0.24, 0.18), (0.40, 0.37, 0.28))
    col = b.mix(nail, col, nail_c)
    # dried blood on the fingertips and palms
    bspots = b.math('MULTIPLY', b.mr(b.noise(co, 30.0, 10, 0.7), 0.56, 0.62), bloodz)
    soaked = b.math('MULTIPLY', b.mr(bloodz, 0.80, 0.95), b.mr(b.noise(co, 40.0, 4, 0.6), 0.30, 0.45))   # fingertips dipped in it
    col = b.mix(b.math('MAXIMUM', bspots, soaked), col, b.mix(b.noise(co, 60.0, 3), (0.15, 0.03, 0.025), (0.25, 0.05, 0.035)))

    import nn_geometry as G
    hc = G.HEAD_C
    dL = ellipsoid(b, co, (hc.x + 0.030, hc.y - 0.076, hc.z + 0.016), (0.024, 0.03, 0.020))
    dR = ellipsoid(b, co, (hc.x - 0.030, hc.y - 0.076, hc.z + 0.016), (0.024, 0.03, 0.020))
    dmin = b.math('MINIMUM', dL, dR)
    dmin = b.math('ADD', dmin, b.math('MULTIPLY', b.math('SUBTRACT', b.noise(b.warp(co, 60.0, 0.004), 45.0, 4), 0.5), 0.35))
    rim = b.mr(dmin, 1.9, 1.2)
    deep = b.mr(dmin, 1.1, 0.8)
    col = b.mix(b.math('MULTIPLY', rim, 0.85), col, (0.30, 0.12, 0.13))    # red-raw rims
    col = b.mix(b.math('MAXIMUM', deep, b.mr(sock, 0.7, 0.95)), col, (0.010, 0.008, 0.008))
    sep = b.n('ShaderNodeSeparateXYZ')
    b.link(co, sep.inputs[0])
    tears = tears_mask(b, co, hc, b.mr(sep.outputs['Y'], hc.y - 0.05, hc.y - 0.09))
    col = b.mix(tears, col, (0.03, 0.022, 0.020))
    # hair: flat near-black with a broad sheen band
    sheen = b.mr(b.noise(b.vscale(co, (8, 8, 1)), 6.0, 1, 0.3), 0.45, 0.65)
    hairc = b.mix(sheen, (0.045, 0.042, 0.040), (0.10, 0.095, 0.090))
    col = b.mix(hair, col, hairc)
    col = b.mix(eye, col, (0.004, 0.004, 0.004))

    rough = b.mix(mott, (0.52, 0.52, 0.52), (0.62, 0.62, 0.62))
    rough = b.mix(nail, rough, (0.30, 0.30, 0.30))
    rough = b.mix(b.math('MAXIMUM', b.mr(dmin, 1.8, 1.0), tears), rough, (0.25, 0.25, 0.25))   # wet round the eyes
    rough = b.mix(hair, rough, (0.62, 0.62, 0.62))
    rough = b.mix(eye, rough, (0.03, 0.03, 0.03))
    rs = b.n('ShaderNodeSeparateColor')
    b.link(rough, rs.inputs[0])

    h = b.math('MULTIPLY', b.math('MULTIPLY', sheen, hair), 0.05)
    b.finish(col, rs.outputs[0], h, strength=0.2, distance=0.001)
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
