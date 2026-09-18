"""Game-ready export of a stylized character built by st_build: decimated pieces, one texture atlas per
material baked from the dense sculpt (albedo with AO folded in, roughness, tangent normals, the cloth
tint mask), the shared human skeleton and its 11 clips, site markers, and a GLB with external PNGs.

The layout follows the human models' contract (scripts/human/human_model.gd): materials whose names
contain "Skin" / "Cloth", a main piece called Human, Site_<name> empties under bones, the cloth mask
R channel = the player tint zone. Eyes stay separate pieces (Human_Eye_L / _R) so a graft can swap one.
The players' belly gash: Human_GashSkin (belly skin, blend shape GashOpen; skin mask G paints the wound),
Human_TopLower (the top below the roll line: hide it to bare the belly), Human_TopRolled (the rolled hem,
hidden by default) and Site_gash on the spine.
"""
import os
import time
import math
import bpy
import numpy as np
from mathutils import Vector, Matrix
import hu_rig
import st_char
import st_clips

# triangle budget per dense part (the whole character lands near the old surgeons' ~20k)
BUDGET = {'Head': 7200, 'Eye_L': 480, 'Eye_R': 480, 'Arm_L': 2400, 'Arm_R': 2400,
          'Top': 3000, 'Pants': 2300, 'Shoe_L': 650, 'Shoe_R': 650, 'Belly': 1400, 'TopRolled': 800,
          # the Hive: gown, bare legs in grip socks, the wristband and the fungus in its open skull
          'Gown': 3000, 'Leg_L': 1300, 'Leg_R': 1300, 'Wristband': 120, 'Fungus': 3600,
          # the Sonographer: the ears swivel and the windpipe glows, so each is its own piece
          'Ear_L': 900, 'Ear_R': 900, 'Throat': 1200, 'ThroatSkin': 420,
          # its doctor's whites, the probe grown into its right hand, the cable up the arm, the gel
          'Coat': 3000, 'Shirt': 1500, 'Tie': 200, 'Probe': 700,
          'Cable_A': 240, 'Cable_B': 200, 'Cable_C': 200,
          'Gel_L': 180, 'Gel_R': 180, 'Gel_Chin': 100}
# parts baked into the Skin atlas; everything else shares the Cloth atlas (for the Hive that is the gown,
# its legs and the fungus, so the head, hands and eyes keep the Skin atlas's resolution to themselves)
SKIN_PARTS = ('Head', 'Eye_L', 'Eye_R', 'Arm_L', 'Arm_R', 'Belly', 'Ear_L', 'Ear_R', 'Throat',
              'ThroatSkin', 'Gel_L', 'Gel_R', 'Gel_Chin')
# parts the game shows only on the player table: they must not occlude the rest in the bake
HIDDEN_PIECES = ('TopRolled', 'Belly', 'ThroatSkin')
# parts that stay their own object in the GLB instead of being joined into Human, because the game
# moves them or lights them on their own: the eyes, the Sonographer's ears and its windpipe
LOOSE_PARTS = ('Eye_L', 'Eye_R', 'Ear_L', 'Ear_R', 'Throat', 'ThroatSkin',
               'Probe', 'Cable_A', 'Cable_B', 'Cable_C', 'Gel_L', 'Gel_R', 'Gel_Chin')


def _log(*a):
    print('[st_export]', *a, flush=True)


def _select(objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


def rest(arm):
    if arm.animation_data:
        arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    bpy.context.view_layer.update()


def make_low(high, part_name, coll):
    """A decimated copy of a dense part, keeping its vertex groups and colour attributes."""
    me = high.data.copy()
    low = bpy.data.objects.new(high.name + '_low', me)
    coll.objects.link(low)
    low.matrix_world = high.matrix_world.copy()
    for vg in high.vertex_groups:
        low.vertex_groups.new(name=vg.name)
    # vertex group weights live in the mesh data, so the copied mesh already carries them
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    target = BUDGET.get(part_name, 1500)
    mod = low.modifiers.new('dec', 'DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = min(1.0, target / max(tris, 1))
    if part_name == 'Belly' and 'maskc' in me.color_attributes:
        # keep detail where the gash opens: a vertex group the decimator protects
        vg = low.vertex_groups.new(name='_keep')
        mc = np.empty(len(me.vertices) * 4, np.float32)
        me.color_attributes['maskc'].data.foreach_get('color', mc)
        g = mc.reshape(-1, 4)[:, 1]
        near = np.nonzero(g > 0.0)[0]
        co = np.empty(len(me.vertices) * 3)
        me.vertices.foreach_get('co', co)
        co = co.reshape(-1, 3)
        if len(near):
            ctr = co[near].mean(axis=0)
            d = np.linalg.norm(co - ctr, axis=1)
            w = np.clip(1.0 - (d - 0.07) / 0.05, 0.0, 1.0)
            for i in np.nonzero(w > 0)[0]:
                vg.add([int(i)], float(w[i]), 'REPLACE')
            mod.vertex_group = '_keep'
            mod.invert_vertex_group = True
            mod.vertex_group_factor = 3.0
    mod.use_symmetry = part_name in ('Head', 'Top', 'Pants')
    mod.symmetry_axis = 'X'
    _select([low])
    bpy.ops.object.modifier_apply(modifier='dec')
    if '_keep' in low.vertex_groups:
        low.vertex_groups.remove(low.vertex_groups['_keep'])
    me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    _log('  low %-8s %7d -> %5d tris' % (part_name, tris, sum(len(p.vertices) - 2 for p in me.polygons)))
    return low


def uv_unwrap(objs, margin):
    _select(objs)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(62), island_margin=margin, scale_to_bounds=False)
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.pack_islands(rotate=True, scale=True, margin_method='FRACTION', margin=margin)
    bpy.ops.object.mode_set(mode='OBJECT')


# ---------------------------------------------------------------- bake materials on the dense parts
def signal_material(name):
    """An emission-only material whose colour is a named signal from the dense mesh's attributes."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    em = nt.nodes.new('ShaderNodeEmission')
    em.name = 'EM'
    col = nt.nodes.new('ShaderNodeAttribute')
    col.attribute_name = 'Col'
    col.name = 'COL'
    rough = nt.nodes.new('ShaderNodeAttribute')
    rough.attribute_name = 'rough'
    rough.name = 'ROUGH'
    mask = nt.nodes.new('ShaderNodeAttribute')
    mask.attribute_name = 'maskc'
    mask.name = 'MASK'
    nt.links.new(em.outputs['Emission'], out.inputs['Surface'])
    nt.links.new(col.outputs['Color'], em.inputs['Color'])
    return m


def set_signal(m, which):
    nt = m.node_tree
    em = nt.nodes['EM']
    for l in list(em.inputs['Color'].links):
        nt.links.remove(l)
    src = {'color': nt.nodes['COL'].outputs['Color'], 'rough': nt.nodes['ROUGH'].outputs['Fac'],
           'mask': nt.nodes['MASK'].outputs['Color']}[which]
    nt.links.new(src, em.inputs['Color'])


def target_material(name, imgs):
    """The final material on the low mesh: image textures in a Principled BSDF (what glTF exports)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    nodes = {}
    for key in ('albedo', 'rough', 'normal', 'ao', 'mask'):
        n = nt.nodes.new('ShaderNodeTexImage')
        n.image = imgs[key]
        n.name = key
        nodes[key] = n
    nt.links.new(nodes['albedo'].outputs['Color'], b.inputs['Base Color'])
    nt.links.new(nodes['rough'].outputs['Color'], b.inputs['Roughness'])
    nm = nt.nodes.new('ShaderNodeNormalMap')
    nt.links.new(nodes['normal'].outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], b.inputs['Normal'])
    b.inputs['Specular IOR Level'].default_value = 0.45 if 'Skin' in name else 0.3
    return m, nodes


def new_image(name, size, colorspace):
    img = bpy.data.images.new(name, size, size, alpha=True, float_buffer=False)
    img.colorspace_settings.name = colorspace
    px = np.zeros(size * size * 4, np.float32)
    img.pixels.foreach_set(px)
    return img


def dilate(img, steps):
    """Grow baked texels (alpha > 0) into the empty space round their islands, then make it opaque."""
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    a = px.reshape(h, w, 4)
    filled = a[:, :, 3] > 0.5
    for _ in range(steps):
        if filled.all():
            break
        acc = np.zeros_like(a[:, :, :3])
        cnt = np.zeros((h, w))
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sf = np.roll(filled, (dy, dx), (0, 1))
            sa = np.roll(a[:, :, :3], (dy, dx), (0, 1))
            acc += sa * sf[:, :, None]
            cnt += sf
        grow = (~filled) & (cnt > 0)
        a[grow, :3] = acc[grow] / cnt[grow][:, None]
        filled = filled | grow
    a[:, :, 3] = 1.0
    img.pixels.foreach_set(a.ravel())
    img.update()


def bake_into(low, high, kind, target_node, samples):
    nt = low.data.materials[0].node_tree
    for n in nt.nodes:
        n.select = False
    target_node.select = True
    nt.nodes.active = target_node
    bpy.context.scene.cycles.samples = samples
    _select([high, low], active=low)
    kw = dict(use_selected_to_active=True, cage_extrusion=0.008, max_ray_distance=0.03, margin=0, use_clear=False,
              target='IMAGE_TEXTURES')
    if kind == 'NORMAL':
        bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', **kw)
    else:
        bpy.ops.object.bake(type=kind, **kw)


# ---------------------------------------------------------------- gash pieces
def split_below(ob, z_cut, name):
    """Move the faces lying wholly below z_cut into a new object (same data layers, UVs and groups)."""
    import bmesh
    _select([ob])
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(ob.data)
    for f in bm.faces:
        f.select = all(v.co.z < z_cut + 0.0005 for v in f.verts)
    bmesh.update_edit_mesh(ob.data)
    bpy.ops.mesh.separate(type='SELECTED')
    bpy.ops.object.mode_set(mode='OBJECT')
    new = [o for o in bpy.context.selected_objects if o != ob][0]
    new.name = new.data.name = name
    _log('  split %s: %d faces below %.3f' % (name, len(new.data.polygons), z_cut))
    return new


def add_gash_shape(ob, variant, s):
    """GashOpen: the wound opens along the gash line: the lips part and the middle sinks."""
    me = ob.data
    n = len(me.vertices)
    co = np.empty(n * 3)
    me.vertices.foreach_get('co', co)
    co = co.reshape(-1, 3)
    nr = np.empty(n * 3)
    me.vertices.foreach_get('normal', nr)
    nr = nr.reshape(-1, 3)
    c, nrm = st_char.LAST_GASH[variant]
    down = np.array([0.0, 0.0, -1.0])
    rel = co - c
    t = rel @ down
    side = rel - np.outer(t, down)
    side -= np.outer(side @ nrm, nrm)
    w = np.linalg.norm(side, axis=1)
    along = np.clip(1.0 - (t / (st_char.GASH_HALF * s)) ** 2, 0.0, 1.0)
    half = 0.016 * s * np.sqrt(along) + 1e-4
    inside = np.clip(1.0 - w / (half * 1.6), 0.0, 1.0)
    sink = 0.012 * s * inside ** 1.5 * along
    spread_dir = side / np.maximum(w, 1e-6)[:, None]
    spread = 0.006 * s * np.sin(np.clip(w / (half * 1.6), 0, 1) * math.pi) * along
    off = -nr * sink[:, None] + spread_dir * spread[:, None]
    ob.shape_key_add(name='Basis', from_mix=False)
    sk = ob.shape_key_add(name='GashOpen', from_mix=False)
    sk.data.foreach_set('co', (co + off).astype(np.float32).ravel())
    _log('  GashOpen: %d verts move' % int((np.linalg.norm(off, axis=1) > 1e-5).sum()))


# ---------------------------------------------------------------- sites
def site_empty(arm, name, bone, matrix):
    e = bpy.data.objects.new('Site_' + name, None)
    e.empty_display_type = 'ARROWS'
    e.empty_display_size = 0.05
    bpy.context.scene.collection.objects.link(e)
    e.parent = arm
    e.parent_type = 'BONE'
    e.parent_bone = bone
    bpy.context.view_layer.update()
    e.matrix_world = matrix
    return e


def godot_frame(x_dir, y_dir, origin):
    """World matrix whose glTF/Godot local axes are X = x_dir, Y = y_dir (see hu_outfit.godot_frame)."""
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


def make_sites(c, arm):
    head = c['head']
    sk = st_char.Skel(c['body'])
    ec = head.eye_c
    eyes_mid = Vector(tuple(head.world(np.array([0.0, ec[1], ec[2]]))))
    sites = [site_empty(arm, 'eyes', 'head', godot_frame(Vector((1, 0, 0)), Vector((0, 0, 1)), eyes_mid))]
    # injection: the inner left elbow, on the skin, +Y out of it, X down the forearm
    el, wr = Vector(tuple(sk.J['elbow'])), Vector(tuple(sk.J['wrist']))
    fa = (wr - el).normalized()
    out = Vector((-0.45, -1.0, 0.0))
    out = (out - fa * out.dot(fa)).normalized()
    p = el + fa * 0.03 + out * 0.036 * sk.s
    sites.append(site_empty(arm, 'injection', 'forearm.L', godot_frame(fa, out, p)))
    if c['V'].get('sono'):
        # where each ear turns, the middle of the throat's window, where the cable enters the neck,
        # and the probe's tip: the echo fires from there, pointing out of the wand
        for tag, sg in (('L', 1.0), ('R', -1.0)):
            r = head.EAR_ROOT * np.array([sg, 1.0, 1.0])
            ep = Vector(tuple(head.world(r)))
            sites.append(site_empty(arm, 'ear_' + tag, 'head', godot_frame(Vector((sg, 0, 0)), Vector((0, 0, 1)), ep)))
        ext = head.neck_ext()
        thr = Vector(tuple(head.world(np.array([0.0, -0.028, -0.140 - 0.5 * ext]))))
        sites.append(site_empty(arm, 'throat', 'neck2', godot_frame(Vector((0, -1, 0)), Vector((0, 0, 1)), thr)))
        cab = Vector(tuple(head.world(st_char.CABLE_NECK)))
        sites.append(site_empty(arm, 'cable', 'neck', godot_frame(Vector((-1, 0, 0)), Vector((0, 0, 1)), cab)))
        mth = Vector(tuple(head.world(np.array([0.0, -0.100, head.mouth_z]))))
        sites.append(site_empty(arm, 'mouth', 'head', godot_frame(Vector((1, 0, 0)), Vector((0, -1, 0)), mth)))
        tip = st_char.probe_tip(sk)
        _wr, pd = st_char.probe_axis(sk)
        up = np.array([0.0, 0.0, 1.0])
        if abs(float(pd @ up)) > 0.9:
            up = np.array([0.0, 1.0, 0.0])
        side = np.cross(up, pd)
        side = side / np.linalg.norm(side)
        sites.append(site_empty(arm, 'probe', 'hand.R',
                                godot_frame(Vector(tuple(side)), Vector(tuple(np.cross(pd, side))), Vector(tuple(tip)))))
    g = st_char.LAST_GASH.get(c['V']['name'])
    if g is not None:
        gc, gn = Vector(tuple(g[0])), Vector(tuple(g[1]))
        sites.append(site_empty(arm, 'gash', 'spine', godot_frame(Vector((0, 0, -1)), gn, gc)))
    return sites


# ---------------------------------------------------------------- main entry
def export(c, out_dir, variant, tex=2048, ao_samples=24, clips=None):
    """clips: modules with build_actions(arm, body) (default: the shared human clips and st_clips)."""
    t0 = time.time()
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.device = 'CPU'
    arm = c['arm']
    arm.location = (0, 0, 0)
    rest(arm)
    highs = {o.name.split('_', 1)[1]: o for o in c['obs']}
    for ho in highs.values():
        ho.hide_set(False)
        ho.hide_render = False
    coll = bpy.data.collections.new(variant + '_low')
    scn.collection.children.link(coll)
    lows = {}
    for pname, ho in highs.items():
        lows[pname] = make_low(ho, pname, coll)
    skin_lows = [lows[p] for p in lows if p in SKIN_PARTS]
    cloth_lows = [lows[p] for p in lows if p not in SKIN_PARTS]
    uv_unwrap(skin_lows, 0.004)
    uv_unwrap(cloth_lows, 0.004)
    _log('uv done %.1fs' % (time.time() - t0))

    tex_dir = os.path.join(out_dir, 'textures')
    os.makedirs(tex_dir, exist_ok=True)
    sig = signal_material('ST_Signal')
    for ho in highs.values():
        ho.data.materials.clear()
        ho.data.materials.append(sig)
    mats = {}
    for key, group in (('Skin', skin_lows), ('Cloth', cloth_lows)):
        imgs = {'albedo': new_image('%s_%s_albedo' % (variant, key), tex, 'sRGB'),
                'rough': new_image('%s_%s_roughness' % (variant, key), tex, 'Non-Color'),
                'normal': new_image('%s_%s_normal' % (variant, key), tex, 'Non-Color'),
                'ao': new_image('%s_%s_ao' % (variant, key), tex, 'Non-Color'),
                'mask': new_image('%s_%s_mask' % (variant, key), tex // 2, 'Non-Color')}
        m, nodes = target_material('Human_' + key, imgs)
        for lo in group:
            lo.data.materials.clear()
            lo.data.materials.append(m)
        mats[key] = (m, nodes, imgs)
    if scn.world is None:
        scn.world = bpy.data.worlds.new('BakeWorld')
    scn.world.light_settings.distance = 0.15
    for lo in lows.values():
        for attr in ('visible_camera', 'visible_diffuse', 'visible_glossy', 'visible_transmission', 'visible_volume_scatter', 'visible_shadow'):
            setattr(lo, attr, False)
    for which, kind, key_img, samples in (('color', 'EMIT', 'albedo', 2), ('rough', 'EMIT', 'rough', 2), ('mask', 'EMIT', 'mask', 2),
                                          (None, 'NORMAL', 'normal', 2), (None, 'AO', 'ao', ao_samples)):
        if which:
            set_signal(sig, which)
        for pname, lo in lows.items():
            key = 'Skin' if pname in SKIN_PARTS else 'Cloth'
            hidden = [highs[q] for q in HIDDEN_PIECES if q in highs and q != pname]
            for h in hidden:
                h.hide_render = True
            bake_into(lo, highs[pname], kind, mats[key][1][key_img], samples)
            for h in hidden:
                h.hide_render = False
        _log('baked %s %.1fs' % (key_img, time.time() - t0))
    for lo in lows.values():
        for attr in ('visible_camera', 'visible_diffuse', 'visible_glossy', 'visible_transmission', 'visible_volume_scatter', 'visible_shadow'):
            setattr(lo, attr, True)
    for key in ('Skin', 'Cloth'):
        imgs = mats[key][2]
        for img in imgs.values():
            dilate(img, 16)
        # fold the AO into the albedo (as the human pipeline does)
        w = imgs['albedo'].size[0]
        c_ = np.empty(w * w * 4, np.float32)
        a_ = np.empty(w * w * 4, np.float32)
        imgs['albedo'].pixels.foreach_get(c_)
        imgs['ao'].pixels.foreach_get(a_)
        c_ = c_.reshape(-1, 4)
        # a small box blur takes the sampling noise out of the AO before it darkens the albedo
        ao = np.clip(a_.reshape(w, w, 4)[:, :, 0], 0, 1)
        rad = max(1, w // 512)
        k = 2 * rad + 1
        pad = np.pad(ao, rad, mode='edge')
        cs = np.pad(np.cumsum(np.cumsum(pad, 0), 1), ((1, 0), (1, 0)))
        ao = ((cs[k:, k:] - cs[:-k, k:] - cs[k:, :-k] + cs[:-k, :-k]) / (k * k)).reshape(-1, 1)
        c_[:, :3] *= (1.0 - 0.45 * (1.0 - np.power(ao, 1.2)))
        imgs['albedo'].pixels.foreach_set(c_.ravel())
        imgs['albedo'].update()
        for k, img in imgs.items():
            img.filepath_raw = os.path.join(tex_dir, img.name + '.png')
            img.file_format = 'PNG'
            img.save()
        # the AO and mask are not part of the glTF material
        m, nodes, _ = mats[key]
        m.node_tree.nodes.remove(nodes['ao'])
        m.node_tree.nodes.remove(nodes['mask'])
    _log('textures saved %.1fs' % (time.time() - t0))

    # pieces: the lower top splits off (TopLower); belly skin (GashSkin), the roll and each eye stay apart
    extra = []
    if 'Belly' in lows:
        top_lower = split_below(lows['Top'], st_char.Z_ROLL * c['body'].s, 'Human_TopLower')
        gs = lows['Belly']
        gs.name = gs.data.name = 'Human_GashSkin'
        add_gash_shape(gs, c['V']['name'], c['body'].s)
        tr = lows['TopRolled']
        tr.name = tr.data.name = 'Human_TopRolled'
        extra = [top_lower, gs, tr]
    body_parts = [lows[p] for p in lows if p not in LOOSE_PARTS and p not in ('Belly', 'TopRolled')]
    _select(body_parts, active=lows['Head'])
    bpy.ops.object.join()
    human = bpy.context.view_layer.objects.active
    human.name = human.data.name = 'Human'
    pieces = [human] + extra
    for pname in LOOSE_PARTS:
        lo = lows.get(pname)
        if lo is None:
            continue
        lo.name = lo.data.name = 'Human_' + pname
        pieces.append(lo)
    for ob in pieces:
        ob.parent = arm
        ob.matrix_parent_inverse = Matrix.Identity(4)
        mod = ob.modifiers.new('Armature', 'ARMATURE')
        mod.object = arm
        _select([ob])
        bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
        bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    # the dense sculpt is not exported
    for ho in highs.values():
        ho.hide_set(True)
        ho.hide_render = True
    sites = make_sites(c, arm)
    for mod in (clips if clips is not None else (hu_rig, st_clips)):
        mod.build_actions(arm, c['body'])
    rest(arm)
    arm.name = 'Human_Rig'
    _select(pieces + sites + [arm], active=arm)
    glb = os.path.join(out_dir, '%s_embedded.glb' % variant)
    bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='ACTIONS', export_force_sampling=True, export_skins=True,
                              export_influence_nb=4, export_yup=True, export_apply=False, export_materials='EXPORT',
                              export_image_format='AUTO', export_def_bones=False, export_anim_slide_to_zero=True,
                              export_morph=True, export_morph_normal=False, export_texcoords=True, export_normals=True)
    _log('exported', glb, os.path.getsize(glb) // 1024, 'KB  %.1fs' % (time.time() - t0))
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in pieces)
    _log('pieces', [o.name for o in pieces], 'tris', tris)
    return {'pieces': pieces, 'highs': highs, 'glb': glb, 'tris': tris}
