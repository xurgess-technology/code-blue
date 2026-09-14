"""Build the seal patient: geometry, UVs, rig, weights, animations, baked maps, .blend and .glb.

blender --background --factory-startup --python seal_build.py -- [--tex=2048] [--detail-tex=1024]
        [--infect-tex=1024] [--ao-samples=24] [--nobake] [--noexport]
"""
import sys
import os
import time
import json
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
import seal_geometry as G
import seal_materials as M
import seal_rig as R
for m in (G, M, R):
    importlib.reload(m)

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


TEX = arg('tex', 2048)
DTEX = arg('detail-tex', 1024)
ITEX = arg('infect-tex', 1024)
AO_SAMPLES = arg('ao-samples', 24)
NOBAKE = '--nobake' in ARGS
NOEXPORT = '--noexport' in ARGS
T0 = time.time()
GAME_DIR = os.path.normpath(os.path.join(HERE, '..', '..', '..', 'assets', 'models', 'patients', 'seal'))
BAKE_OFFSET = Vector((0.0, 0.0, 1.2))          # parts that would self-shadow inside others are baked up here
OFFSET_PARTS = ('cap.L', 'line.L')
COAT_PARTS = ('torso', 'head', 'flipper.L', 'flipper.R', 'hind.L', 'hind.R')
DETAIL_PARTS = ('eyes', 'whiskers', 'claws_f.L', 'claws_f.R', 'claws_h.L', 'claws_h.R', 'cap.L', 'line.L')


def log(*a):
    print('[seal_build %6.1fs]' % (time.time() - T0), *a, flush=True)


def to_b(v):
    """Patient-frame direction to Blender axes."""
    return Vector((v[0], -v[2], v[1]))


def to_bp(v):
    """Patient-frame position (authored at scale 1) to Blender, scaled by G.SCALE."""
    return to_b(v) * G.SCALE


def frame_matrix(origin, X, Y, Z):
    """Blender world matrix for a node whose glTF/Godot local axes are X, Y, Z (patient frame)."""
    cx, cy, cz = to_b(X), -to_b(Z), to_b(Y)
    m = Matrix((
        (cx.x, cy.x, cz.x, 0.0),
        (cx.y, cy.y, cz.y, 0.0),
        (cx.z, cy.z, cz.z, 0.0),
        (0.0, 0.0, 0.0, 1.0)))
    m.translation = to_b(origin)          # site origins arrive already scaled
    return m


# ------------------------------------------------------------------------------------------ objects
def part_object(part, mats, name=None):
    me = bpy.data.meshes.new(name or part.name)
    me.from_pydata([tuple(to_bp(v)) for v in part.v], [], part.f)
    uv = me.uv_layers.new(name='UVMap')
    flat = []
    for fu in part.fuv:
        for u, v in fu:
            flat += [u * part.uv_boost, v * part.uv_boost]
    uv.data.foreach_set('uv', flat)
    uv2 = me.uv_layers.new(name='UV2')
    flat = []
    for fu in part.fuv2:
        for u, v in fu:
            flat += [u, v]
    uv2.data.foreach_set('uv', flat)
    me.uv_layers.active = me.uv_layers['UVMap']
    for k in G.ATTRS:
        vals = [vd.attr.get(k, 0.0) for vd in part.vd]
        if max(abs(x) for x in vals) <= 0:
            continue
        a = me.attributes.new(k, 'FLOAT', 'POINT')
        a.data.foreach_set('value', vals)
    for nm, getter in (('pco', lambda i, vd: part.v[i]), ('fco', lambda i, vd: vd.F)):
        a = me.attributes.new(nm, 'FLOAT_VECTOR', 'POINT')
        flat = []
        for i, vd in enumerate(part.vd):
            q = getter(i, vd)
            flat += [q.x, q.y, q.z]
        a.data.foreach_set('vector', flat)
    ca = me.color_attributes.new('SealMask', 'FLOAT_COLOR', 'POINT')
    flat = []
    for vd in part.vd:
        flat += list(vd.col)
    ca.data.foreach_set('color', flat)
    ta = me.attributes.new('tag', 'INT', 'FACE')
    ta.data.foreach_set('value', part.ftag)
    for mt in mats:
        me.materials.append(mt)
    idx = 0 if part.mat == 'coat' else 1
    me.polygons.foreach_set('material_index', [idx] * len(me.polygons))
    me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    me.validate(clean_customdata=False)
    ob = bpy.data.objects.new(name or part.name, me)
    bpy.context.scene.collection.objects.link(ob)
    groups = {}
    for i, vd in enumerate(part.vd):
        for bone, w in vd.w.items():
            if w <= 1e-4:
                continue
            if bone not in groups:
                groups[bone] = ob.vertex_groups.new(name=bone)
            groups[bone].add([i], w, 'REPLACE')
    return ob


def select_only(objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


def pack_uvs(objs, margin):
    select_only(objs)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, scale=True, margin_method='FRACTION', margin=margin, shape_method='CONCAVE')
    bpy.ops.object.mode_set(mode='OBJECT')


def join(objs, name):
    select_only(objs)
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def duplicate(ob, name):
    c = ob.copy()
    c.data = ob.data.copy()
    c.name = name
    c.data.name = name
    bpy.context.scene.collection.objects.link(c)
    return c


def weld(ob, dist=1e-6):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(ob.data)
    bm.free()


def smooth_custom_normals(ob):
    me = ob.data
    normals = [v.normal.copy() for v in me.vertices]
    try:
        me.normals_split_custom_set_from_vertices(normals)
    except Exception as e:
        log('custom normals unavailable:', e)


def split_by_tag(ob, tag, name):
    """Move faces whose 'tag' attribute equals tag into a new object."""
    me = ob.data
    tags = [0] * len(me.polygons)
    me.attributes['tag'].data.foreach_get('value', tags)
    select_only([ob])
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.object.mode_set(mode='OBJECT')
    for p, t in zip(me.polygons, tags):
        p.select = (t == tag)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.separate(type='SELECTED')
    bpy.ops.object.mode_set(mode='OBJECT')
    new = [o for o in bpy.context.selected_objects if o is not ob][0]
    new.name = name
    new.data.name = name
    return new


def translate_mesh(ob, off):
    ob.data.transform(Matrix.Translation(off))


def hide_from_rays(ob):
    """The low bake copy must not shadow the AO rays cast from the dense surface just under it."""
    for attr in ('visible_camera', 'visible_diffuse', 'visible_glossy', 'visible_transmission', 'visible_volume_scatter', 'visible_shadow'):
        setattr(ob, attr, False)


def show_to_rays(ob):
    for attr in ('visible_camera', 'visible_diffuse', 'visible_glossy', 'visible_transmission', 'visible_volume_scatter', 'visible_shadow'):
        setattr(ob, attr, True)


def new_image(name, size, colorspace, alpha=False):
    img = bpy.data.images.new(name, size, size, alpha=alpha, float_buffer=False)
    img.colorspace_settings.name = colorspace
    return img


def bake(low, highs, kind, samples, targets, margin=16):
    for mat_name, node in targets.items():
        nt = bpy.data.materials[mat_name].node_tree
        for n in nt.nodes:
            n.select = False
        node.select = True
        nt.nodes.active = node
    scn = bpy.context.scene
    scn.cycles.samples = samples
    select_only(highs + [low], low)
    t = time.time()
    kw = dict(use_selected_to_active=True, cage_extrusion=0.004, max_ray_distance=0.014, margin=margin, use_clear=True, target='IMAGE_TEXTURES')
    if kind == 'NORMAL':
        bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', **kw)
    else:
        bpy.ops.object.bake(type=kind, **kw)
    log('baked', kind, 'in %.1fs' % (time.time() - t))


def blur_ao(img, size):
    a = np.empty(size * size * 4, np.float32)
    img.pixels.foreach_get(a)
    ao = a.reshape(size, size, 4)[:, :, 0]
    rad = max(1, size // 512)
    k = 2 * rad + 1
    pad = np.pad(ao, rad, mode='edge')
    cs = np.cumsum(np.cumsum(pad, 0), 1)
    cs = np.pad(cs, ((1, 0), (1, 0)))
    return (cs[k:, k:] - cs[:-k, k:] - cs[k:, :-k] + cs[:-k, :-k]) / (k * k)


def fold_ao(img_color, img_ao, size, strength=0.55):
    c = np.empty(size * size * 4, np.float32)
    img_color.pixels.foreach_get(c)
    c = c.reshape(-1, 4)
    ao = blur_ao(img_ao, size).reshape(-1, 1)
    c[:, :3] *= (1.0 - strength * (1.0 - np.power(np.clip(ao, 0, 1), 1.2)))
    img_color.pixels.foreach_set(c.ravel())
    img_color.update()


def save_image(img, tex_dir):
    img.filepath_raw = os.path.join(tex_dir, img.name + '.png')
    img.file_format = 'PNG'
    img.save()
    img.filepath = '//textures/' + img.name + '.png'


# ------------------------------------------------------------------------------------------ main
def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.device = 'CPU'
    scn.render.fps = 30

    coat_p = M.coat_material()
    detail_p = M.detail_material()
    coat_p.use_fake_user = True
    detail_p.use_fake_user = True
    mats = [coat_p, detail_p]

    log('generating game mesh')
    parts = G.build_all(1)
    total = 0
    for k, p in parts.items():
        log('  %-10s %6d tris' % (k, p.tris()))
        total += p.tris()
    log('total tris (all pieces)', total)
    objs = {k: part_object(p, mats) for k, p in parts.items()}

    # head and torso share their seam ring: weld them into one surface before anything else
    body = join([objs['torso'], objs['head']], 'body')
    weld(body)
    objs['body'] = body
    del objs['torso'], objs['head']
    pack_uvs([objs[k] for k in ('body', 'flipper.L', 'flipper.R', 'hind.L', 'hind.R')], 0.003)
    pack_uvs([objs[k] for k in DETAIL_PARTS], 0.006)
    for ob in objs.values():
        smooth_custom_normals(ob)

    log('rig')
    arm = R.build_armature()
    log('actions')
    R.build_actions(arm)
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)

    tex_dir = os.path.join(HERE, 'textures')
    os.makedirs(tex_dir, exist_ok=True)
    baked_mats = None
    if not NOBAKE:
        log('bake low copy')
        low_parts = []
        for k, ob in objs.items():
            c = duplicate(ob, 'bakelow_' + k)
            if k in OFFSET_PARTS:
                translate_mesh(c, BAKE_OFFSET)
            low_parts.append(c)
        low = join(low_parts, 'Seal_BakeLow')
        hide_from_rays(low)
        for ob in list(objs.values()) + [arm]:
            hide_from_rays(ob)
        log('generating bake source mesh (res 3)')
        hparts = G.build_all(3)
        hobjs = {k: part_object(p, mats, 'high_' + k) for k, p in hparts.items()}
        for k in OFFSET_PARTS:
            translate_mesh(hobjs[k], BAKE_OFFSET)
        high_fl = hobjs.pop('flipper.L')
        high = join(list(hobjs.values()), 'Seal_BakeHigh')
        for h in (high, high_fl):
            mod = h.modifiers.new('sub', 'SUBSURF')
            mod.levels = mod.render_levels = 1
        log('high tris', (sum(len(pg.vertices) - 2 for pg in high.data.polygons) + sum(len(pg.vertices) - 2 for pg in high_fl.data.polygons)) * 4)

        imgs, baked = {}, {}
        for key, proc, size in (('Coat', coat_p, TEX), ('Detail', detail_p, DTEX)):
            ic = new_image('Seal_%s_albedo' % key, size, 'sRGB')
            ir = new_image('Seal_%s_roughness' % key, size, 'Non-Color')
            inn = new_image('Seal_%s_normal' % key, size, 'Non-Color')
            iao = new_image('Seal_%s_ao' % key, size, 'Non-Color')
            mat, nodes = M.baked_material('Seal_%s' % key, ic, ir, inn)
            aonode = mat.node_tree.nodes.new('ShaderNodeTexImage')
            aonode.image = iao
            imgs[key] = (ic, ir, inn, iao, size)
            baked[key] = (mat, nodes, aonode, proc)
        low.data.materials[0] = baked['Coat'][0]
        low.data.materials[1] = baked['Detail'][0]
        if scn.world is None:
            scn.world = bpy.data.worlds.new('BakeWorld')
        scn.world.light_settings.distance = 0.22
        for proc in (coat_p, detail_p):
            M.set_infect(proc, 0.0)
        for sig, idx, kind, samples in (('color', 0, 'EMIT', 4), ('rough', 1, 'EMIT', 4), ('normal', 2, 'NORMAL', 4), ('ao', 3, 'AO', AO_SAMPLES)):
            for key in ('Coat', 'Detail'):
                M.set_bake_signal(baked[key][3], sig)
            targets = {}
            for key in ('Coat', 'Detail'):
                mat, nodes, aonode, proc = baked[key]
                targets[mat.name] = aonode if sig == 'ao' else nodes[idx]
            bake(low, [high, high_fl], kind, samples, targets)
        for key in ('Coat', 'Detail'):
            M.set_bake_signal(baked[key][3], 'normal')
            ic, ir, inn, iao, size = imgs[key]
            fold_ao(ic, iao, size)

        # the infected flipper, into its own atlas through UV2
        log('infection bake (UV2)')
        inf_low = duplicate(objs['flipper.L'], 'bakelow_infect')
        me = inf_low.data
        bm = bmesh.new()
        bm.from_mesh(me)
        tag_layer = bm.faces.layers.int.get('tag')
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f[tag_layer] != 1], context='FACES')
        bm.to_mesh(me)
        bm.free()
        hide_from_rays(inf_low)
        me.uv_layers.active = me.uv_layers['UV2']
        for layer in me.uv_layers:
            layer.active_render = layer.name == 'UV2'
        i_col = new_image('Seal_Infect_color', ITEX, 'sRGB')
        i_h = new_image('Seal_Infect_height', ITEX, 'Non-Color')
        i_ao = new_image('Seal_Infect_ao', ITEX, 'Non-Color')
        tmat = bpy.data.materials.new('InfectTarget')
        tmat.use_nodes = True
        tnode = tmat.node_tree.nodes.new('ShaderNodeTexImage')
        me.materials.clear()
        me.materials.append(tmat)
        me.polygons.foreach_set('material_index', [0] * len(me.polygons))
        M.set_infect(coat_p, 1.0)
        for sig, img, kind, samples in (('color', i_col, 'EMIT', 4), ('height', i_h, 'EMIT', 4), ('ao', i_ao, 'AO', AO_SAMPLES)):
            M.set_bake_signal(coat_p, sig if sig != 'ao' else 'normal')
            tnode.image = img
            bake(inf_low, [high_fl], kind, samples, {tmat.name: tnode}, margin=8)
        M.set_bake_signal(coat_p, 'normal')
        M.set_infect(coat_p, 0.0)
        fold_ao(i_col, i_ao, ITEX)
        i_out = new_image('Seal_Infect', ITEX, 'sRGB', alpha=True)
        c = np.empty(ITEX * ITEX * 4, np.float32)
        hpx = np.empty(ITEX * ITEX * 4, np.float32)
        i_col.pixels.foreach_get(c)
        i_h.pixels.foreach_get(hpx)
        c = c.reshape(-1, 4)
        c[:, 3] = hpx.reshape(-1, 4)[:, 0]
        i_out.pixels.foreach_set(c.ravel())
        i_out.alpha_mode = 'STRAIGHT'

        for key in ('Coat', 'Detail'):
            for img in imgs[key][:4]:
                save_image(img, tex_dir)
            mat, nodes, aonode, proc = baked[key]
            mat.node_tree.nodes.remove(aonode)
        for img in (i_col, i_h, i_ao, i_out):
            save_image(img, tex_dir)
        for ob in (high, high_fl, low, inf_low):
            bpy.data.objects.remove(ob, do_unlink=True)
        bpy.data.materials.remove(tmat)
        baked_mats = [baked['Coat'][0], baked['Detail'][0]]
        for ob in list(objs.values()) + [arm]:
            show_to_rays(ob)
        log('textures saved')

    # ------------------------------------------------------------------ the game pieces
    log('assembling game pieces')
    for ob in objs.values():
        if baked_mats:
            ob.data.materials[0] = baked_mats[0]
            ob.data.materials[1] = baked_mats[1]
    paddle = split_by_tag(objs['flipper.L'], 1, 'paddle')
    ctr, T, U, V = G.fl_frame(G.CUT_S)
    cut_frame = frame_matrix(ctr * G.SCALE, T, U, V)

    # severed paddle: the paddle, its claws, the line and the cap reflected through the cut plane
    sev_pieces = [duplicate(paddle, 'sev_paddle'), duplicate(objs['claws_f.L'], 'sev_claws'), duplicate(objs['line.L'], 'sev_line')]
    sev_cap = duplicate(objs['cap.L'], 'sev_cap')
    C, Tb = to_bp(ctr), to_b(T).normalized()
    for v in sev_cap.data.vertices:
        v.co = v.co - Tb * (2.0 * (v.co - C).dot(Tb))
    bm = bmesh.new()
    bm.from_mesh(sev_cap.data)
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.to_mesh(sev_cap.data)
    bm.free()
    smooth_custom_normals(sev_cap)
    sev_pieces.append(sev_cap)
    severed = join(sev_pieces, 'Seal_PaddleSevered_L')
    severed.vertex_groups.clear()

    body_obj = join([objs['body'], objs['flipper.L'], objs['flipper.R'], objs['eyes'], objs['whiskers'], objs['claws_f.R'],
                     objs['hind.L'], objs['hind.R'], objs['claws_h.L'], objs['claws_h.R']], 'Seal_Body')
    paddle_obj = join([paddle, objs['claws_f.L']], 'Seal_Paddle_L')
    cap_obj = objs['cap.L']
    cap_obj.name = cap_obj.data.name = 'Seal_StumpCap_L'
    cap_obj.vertex_groups.clear()
    line_obj = objs['line.L']
    line_obj.name = line_obj.data.name = 'Seal_FishingLine_L'

    for ob in (body_obj, paddle_obj, line_obj):
        ob.parent = arm
        mod = ob.modifiers.new('Armature', 'ARMATURE')
        mod.object = arm
        select_only([ob])
        bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
        bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    bpy.context.view_layer.update()

    def to_bone(ob, bone, world):
        ob.data.transform(world.inverted())
        ob.matrix_world = world
        ob.parent = arm
        ob.parent_type = 'BONE'
        ob.parent_bone = bone
        bpy.context.view_layer.update()
        ob.matrix_world = world
    to_bone(cap_obj, 'flipper_fore.L', cut_frame)
    to_bone(severed, 'flipper_fore.L', cut_frame)

    site_info = {}
    for nm, (origin, X, Y, Z, bone, sec) in G.sites().items():
        e = bpy.data.objects.new('site_' + nm, None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.06
        scn.collection.objects.link(e)
        world = frame_matrix(origin, X, Y, Z)
        e.parent = arm
        e.parent_type = 'BONE'
        e.parent_bone = bone
        bpy.context.view_layer.update()
        e.matrix_world = world
        site_info[nm] = {'origin': [round(c, 4) for c in origin], 'x': [round(c, 4) for c in X], 'y': [round(c, 4) for c in Y],
                         'z': [round(c, 4) for c in Z], 'bone': bone, 'section': {k: round(v, 4) if isinstance(v, float) else v for k, v in sec.items()}}
    site_info['_cut_centre'] = [round(c * G.SCALE, 4) for c in ctr]
    site_info['_scale'] = G.SCALE
    site_info['_stats'] = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in (body_obj, paddle_obj, cap_obj, line_obj, severed)}
    with open(os.path.join(HERE, 'seal_sites.json'), 'w') as f:
        json.dump(site_info, f, indent=1)
    log('stats', site_info['_stats'])

    # remove helper attributes the game does not need from the final meshes (keep SealMask, UVMap, UV2)
    for ob in (body_obj, paddle_obj, cap_obj, line_obj, severed):
        for a in list(ob.data.attributes):
            if a.name in ('tag',):
                ob.data.attributes.remove(a)

    arm.animation_data.action = bpy.data.actions['Idle']
    scn.frame_set(0)
    bpy.context.preferences.filepaths.save_version = 0
    blend_path = os.path.join(HERE, 'seal.blend')
    bpy.ops.wm.save_as_mainfile(filepath=blend_path, relative_remap=True, compress=True)
    log('saved', blend_path)
    if NOEXPORT:
        return

    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)
    select_only([arm, body_obj, paddle_obj, cap_obj, line_obj, severed] + [o for o in scn.objects if o.name.startswith('site_')], arm)
    glb = os.path.join(os.path.dirname(HERE), 'seal_embedded.glb')
    bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='ACTIONS', export_force_sampling=True, export_skins=True,
                              export_influence_nb=4, export_yup=True, export_apply=False, export_materials='EXPORT',
                              export_image_format='AUTO', export_def_bones=False, export_anim_slide_to_zero=True,
                              export_vertex_color='NAME', export_vertex_color_name='SealMask', export_all_vertex_colors=False,
                              export_active_vertex_color_when_no_material=False, export_texcoords=True, export_normals=True)
    log('exported', glb, os.path.getsize(glb) // 1024, 'KB')
    import seal_glb_extern
    os.makedirs(GAME_DIR, exist_ok=True)
    game_glb = os.path.join(GAME_DIR, 'seal.glb')
    files, size = seal_glb_extern.extern(glb, game_glb)
    log('game copy', game_glb, size // 1024, 'KB, textures:', ', '.join(f for f, _ in files))
    inf_src = os.path.join(tex_dir, 'Seal_Infect.png')
    if os.path.exists(inf_src):
        import shutil
        shutil.copyfile(inf_src, os.path.join(GAME_DIR, 'textures', 'Seal_Infect.png'))
        log('copied Seal_Infect.png')


main()
