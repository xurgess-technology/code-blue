"""Build one human variation: geometry, UV packing, rig, weights, clips, site markers, baked PBR maps,
.blend and the game GLB.

blender --background --factory-startup --python hu_build.py -- --variant=surgeon_a [--tex=2048] [--ao-samples=24] [--nobake] [--noexport]
"""
import sys
import os
import time
import json
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy
import numpy as np
from mathutils import Vector, Matrix
import hu_mesh, hu_body, hu_outfit, hu_params, hu_blender, hu_rig
for m in (hu_mesh, hu_body, hu_outfit, hu_params, hu_blender, hu_rig):
    importlib.reload(m)
try:
    import hu_materials
    importlib.reload(hu_materials)
except ImportError:
    hu_materials = None

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


VAR = arg('variant', 'surgeon_a')
TEX = arg('tex', 2048)
AO_SAMPLES = arg('ao-samples', 24)
BAKE_RES = arg('bake-res', 3)
NOBAKE = '--nobake' in ARGS
NOEXPORT = '--noexport' in ARGS
T0 = time.time()
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
GAME_DIR = os.path.join(ROOT, 'assets', 'models', 'characters', 'human')


def log(*a):
    print('[hu_build %s %6.1fs]' % (VAR, time.time() - T0), *a, flush=True)


def pack_uvs(objs, margin):
    if not objs:
        return
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, scale=True, margin_method='FRACTION', margin=margin)
    bpy.ops.object.mode_set(mode='OBJECT')


def join(objs, name):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def build_objects(parts, mats, prefix):
    """Part objects, UVs packed per material, joined per game piece."""
    objs = {}
    for p in parts:
        objs[p.name] = hu_blender.part_object(p, mats)
    pack_uvs([objs[p.name] for p in parts if p.mat == 'cloth'], 0.003)
    pack_uvs([objs[p.name] for p in parts if p.mat == 'skin'], 0.004)
    pieces = {}
    for p in parts:
        pieces.setdefault(p.meta.get('piece', 'Human'), []).append(objs[p.name])
    out = {}
    for piece, ol in pieces.items():
        # main body first so the joined object keeps its data name
        out[piece] = join(ol, prefix + piece if piece != 'Human' else prefix.rstrip('_'))
    return out


def new_image(name, colorspace, size=None):
    size = size or TEX
    img = bpy.data.images.new(name, size, size, alpha=False, float_buffer=False)
    img.colorspace_settings.name = colorspace
    return img


def bake(lows, high, kind, samples, targets):
    for mat_name, node in targets.items():
        nt = bpy.data.materials[mat_name].node_tree
        for n in nt.nodes:
            n.select = False
        node.select = True
        nt.nodes.active = node
    scn = bpy.context.scene
    scn.cycles.samples = samples
    for low in lows:
        bpy.ops.object.select_all(action='DESELECT')
        high.select_set(True)
        low.select_set(True)
        bpy.context.view_layer.objects.active = low
        t = time.time()
        kw = dict(use_selected_to_active=True, cage_extrusion=0.006, max_ray_distance=0.02, margin=12, use_clear=False, target='IMAGE_TEXTURES')
        if kind == 'NORMAL':
            bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', **kw)
        else:
            bpy.ops.object.bake(type=kind, **kw)
        log('baked', kind, low.name, 'in %.1fs' % (time.time() - t))


def place_sites(arm, info):
    """Empties parented to bones: the GLB carries them as nodes under the joints (Godot: BoneAttachment3D)."""
    bpy.context.view_layer.update()
    made = []
    for name, site in info['sites'].items():
        e = bpy.data.objects.new('Site_' + name, None)
        e.empty_display_type = 'ARROWS'
        e.empty_display_size = 0.05
        bpy.context.scene.collection.objects.link(e)
        e.parent = arm
        e.parent_type = 'BONE'
        e.parent_bone = site['bone']
        bpy.context.view_layer.update()
        e.matrix_world = site['matrix']
        made.append(e)
    bpy.context.view_layer.update()
    return made


def site_report(info, P):
    body = info['body']
    rep = {'variant': VAR, 'height': P['height'], 'sites': {}, 'arm_stations': {k: round(v, 4) for k, v in info['arm_stations'].items()}}
    for name, s in info['sites'].items():
        d = {'bone': s['bone']}
        for k in ('half_up', 'half_side', 'axis_depth', 'shape', 'infection_start', 'half_len', 'half_gap', 's'):
            if k in s:
                d[k] = round(float(s[k]), 4)
        o = s['origin']
        # Blender (x, y, z) -> glTF / Godot model space before the registry yaw (x, z, -y)
        d['origin_gltf'] = [round(o.x, 4), round(o.z, 4), round(-o.y, 4)]
        x, y = s['x'], s['y']
        d['x_gltf'] = [round(x.x, 3), round(x.z, 3), round(-x.y, 3)]
        d['y_gltf'] = [round(y.x, 3), round(y.z, 3), round(-y.y, 3)]
        rep['sites'][name] = d
    if 'forearm_cut' in info:
        fc = info['forearm_cut']
        rep['forearm_cut'] = {'s': round(fc['s'], 4), 'half_up': round(fc['half_up'], 4), 'half_side': round(fc['half_side'], 4)}
    if 'gown_window' in info:
        rep['gown_window'] = {'theta_rad': info['gown_window']['theta'], 'z_m': [round(v, 4) for v in info['gown_window']['z']]}
    return rep


def main():
    hu_blender.reset()
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.device = 'CPU'
    scn.render.fps = hu_rig.FPS
    P = hu_params.get(VAR)
    prefix = 'Human_'

    if hu_materials and not NOBAKE:
        cloth_p = hu_materials.cloth_material(P)
        skin_p = hu_materials.skin_material(P)
    elif hu_materials:
        cloth_p = hu_materials.cloth_material(P)
        skin_p = hu_materials.skin_material(P)
    else:
        cloth_p = hu_blender.clay('HU_Cloth_Procedural', (0.25, 0.5, 0.45), 0.8)
        skin_p = hu_blender.clay('HU_Skin_Procedural', (0.62, 0.47, 0.40), 0.55)
    cloth_p.use_fake_user = True
    skin_p.use_fake_user = True

    log('generating game mesh')
    parts, info = hu_outfit.build_character(P, 1)
    body = info['body']
    total = 0
    by_piece = {}
    for p in parts:
        total += p.tris()
        by_piece[p.meta.get('piece', 'Human')] = by_piece.get(p.meta.get('piece', 'Human'), 0) + p.tris()
    log('total tris', total, by_piece)
    pieces = build_objects(parts, [cloth_p, skin_p], prefix)

    log('rig')
    arm = hu_rig.build_armature(body, 'Human_Rig')
    for ob in pieces.values():
        hu_rig.skin(ob, arm)
        bpy.ops.object.select_all(action='DESELECT')
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
        bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    bpy.ops.object.select_all(action='DESELECT')
    log('actions')
    hu_rig.build_actions(arm, body)
    sites = place_sites(arm, info)
    report = site_report(info, P)
    report['tris'] = by_piece
    report['tris_total'] = total
    report['clips'] = {k: {'frames': v[0], 'loop': v[1], 'speed': v[2], 'about': v[3]} for k, v in hu_rig.CLIPS.items()}
    report['fps'] = hu_rig.FPS

    tex_dir = os.path.join(HERE, 'textures', VAR)
    os.makedirs(tex_dir, exist_ok=True)
    if not NOBAKE and hu_materials:
        log('generating bake source mesh (res %d)' % BAKE_RES)
        hparts, _ = hu_outfit.build_character(P, BAKE_RES)
        hobjs = [hu_blender.part_object(p, [cloth_p, skin_p], with_weights=False) for p in hparts]
        high = join(hobjs, 'HU_BakeSource')
        for sk in list(high.data.shape_keys.key_blocks) if high.data.shape_keys else []:
            pass
        if high.data.shape_keys:
            high.shape_key_clear()
        mod = high.modifiers.new('sub', 'SUBSURF')
        mod.levels = mod.render_levels = 1
        log('high tris', sum(len(pg.vertices) - 2 for pg in high.data.polygons) * 4)

        imgs, baked = {}, {}
        for key, proc in (('Cloth', cloth_p), ('Skin', skin_p)):
            ic = new_image('%s_%s_albedo' % (VAR, key), 'sRGB')
            ir = new_image('%s_%s_roughness' % (VAR, key), 'Non-Color')
            inn = new_image('%s_%s_normal' % (VAR, key), 'Non-Color')
            iao = new_image('%s_%s_ao' % (VAR, key), 'Non-Color')
            imk = new_image('%s_%s_mask' % (VAR, key), 'Non-Color', TEX // 2)
            mat, nodes = hu_materials.baked_material('Human_%s' % key, ic, ir, inn)
            aonode = mat.node_tree.nodes.new('ShaderNodeTexImage')
            aonode.image = iao
            mknode = mat.node_tree.nodes.new('ShaderNodeTexImage')
            mknode.image = imk
            imgs[key] = (ic, ir, inn, iao, imk)
            baked[key] = (mat, nodes, aonode, mknode, proc)
        for ob in pieces.values():
            for i, slot in enumerate(ob.data.materials):
                if slot == cloth_p:
                    ob.data.materials[i] = baked['Cloth'][0]
                elif slot == skin_p:
                    ob.data.materials[i] = baked['Skin'][0]
        if scn.world is None:
            scn.world = bpy.data.worlds.new('BakeWorld')
        scn.world.light_settings.distance = 0.20
        lows = list(pieces.values())
        # the bake source is in rest pose; so are the pieces (no action assigned)
        arm.animation_data.action = None
        for pb in arm.pose.bones:
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.location = (0, 0, 0)
        for img_tuple in imgs.values():
            for img in img_tuple:
                px = np.zeros(img.size[0] * img.size[1] * 4, np.float32)
                px[3::4] = 1.0
                img.pixels.foreach_set(px)
        for sig, idx, kind, samples in (('color', 0, 'EMIT', 4), ('rough', 1, 'EMIT', 4), ('mask', 'mask', 'EMIT', 2),
                                         ('normal', 2, 'NORMAL', 4), ('ao', 'ao', 'AO', AO_SAMPLES)):
            for key in ('Cloth', 'Skin'):
                hu_materials.set_bake_signal(baked[key][4], sig)
            targets = {}
            for key in ('Cloth', 'Skin'):
                mat, nodes, aonode, mknode, proc = baked[key]
                targets[mat.name] = aonode if sig == 'ao' else (mknode if sig == 'mask' else nodes[idx])
            bake(lows, high, kind, samples, targets)
        for key in ('Cloth', 'Skin'):
            hu_materials.set_bake_signal(baked[key][4], 'normal')
        for key in ('Cloth', 'Skin'):
            ic, ir, inn, iao, imk = imgs[key]
            c = np.empty(TEX * TEX * 4, np.float32)
            a = np.empty(TEX * TEX * 4, np.float32)
            ic.pixels.foreach_get(c)
            iao.pixels.foreach_get(a)
            c = c.reshape(-1, 4)
            ao = a.reshape(TEX, TEX, 4)[:, :, 0]
            rad = max(1, TEX // 512)
            k = 2 * rad + 1
            pad = np.pad(ao, rad, mode='edge')
            cs = np.cumsum(np.cumsum(pad, 0), 1)
            cs = np.pad(cs, ((1, 0), (1, 0)))
            ao = (cs[k:, k:] - cs[:-k, k:] - cs[k:, :-k] + cs[:-k, :-k]) / (k * k)
            ao = ao.reshape(-1, 1)
            c[:, :3] *= (1.0 - 0.50 * (1.0 - np.power(np.clip(ao, 0, 1), 1.2)))
            ic.pixels.foreach_set(c.ravel())
            ic.update()
        for key in ('Cloth', 'Skin'):
            for img in imgs[key]:
                img.filepath_raw = os.path.join(tex_dir, img.name + '.png')
                img.file_format = 'PNG'
                img.save()
                img.filepath = '//textures/%s/%s.png' % (VAR, img.name)
            mat, nodes, aonode, mknode, proc = baked[key]
            mat.node_tree.nodes.remove(aonode)
            mat.node_tree.nodes.remove(mknode)
        bpy.data.objects.remove(high, do_unlink=True)
        log('textures saved')

    scn.frame_set(0)
    arm.animation_data.action = bpy.data.actions['Idle']
    bpy.context.preferences.filepaths.save_version = 0
    blend_path = os.path.join(HERE, '%s.blend' % VAR)
    bpy.ops.wm.save_as_mainfile(filepath=blend_path, relative_remap=True, compress=True)
    log('saved', blend_path)
    with open(os.path.join(HERE, '%s_sites.json' % VAR), 'w') as fh:
        json.dump(report, fh, indent=1)

    if NOEXPORT:
        return
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    bpy.ops.object.select_all(action='DESELECT')
    for ob in pieces.values():
        ob.select_set(True)
    for e in sites:
        e.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    glb = os.path.join(os.path.dirname(HERE), '%s_embedded.glb' % VAR)
    bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='ACTIONS', export_force_sampling=True, export_skins=True,
                              export_influence_nb=4, export_yup=True, export_apply=False, export_materials='EXPORT',
                              export_image_format='AUTO', export_def_bones=False, export_anim_slide_to_zero=True,
                              export_morph=True, export_morph_normal=False, export_texcoords=True, export_normals=True)
    log('exported', glb, os.path.getsize(glb) // 1024, 'KB')
    import hu_glb_extern
    os.makedirs(GAME_DIR, exist_ok=True)
    game_glb = os.path.join(GAME_DIR, '%s.glb' % VAR)
    files, size = hu_glb_extern.extern(glb, game_glb, 'textures')
    log('game copy', game_glb, size // 1024, 'KB, textures:', ', '.join(f for f, _ in files))
    if not NOBAKE:
        # the tint/site masks are not referenced by the glTF: copy them beside the maps
        import shutil
        for key in ('Cloth', 'Skin'):
            src = os.path.join(tex_dir, '%s_%s_mask.png' % (VAR, key))
            if os.path.exists(src):
                shutil.copyfile(src, os.path.join(GAME_DIR, 'textures', os.path.basename(src)))


main()
