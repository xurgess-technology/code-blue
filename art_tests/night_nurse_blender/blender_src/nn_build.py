"""Build the Night Nurse: geometry, UVs, rig, weights, animations, baked PBR maps, .blend and .glb.

blender --background --factory-startup --python nn_build.py -- [--tex=2048] [--ao-samples=24] [--nobake]
"""
import sys
import os
import time
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy
import numpy as np
from mathutils import Vector
import nn_geometry as G
import nn_materials as M
import nn_rig as R
for m in (G, M, R):
    importlib.reload(m)

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


TEX = arg('tex', 2048)
AO_SAMPLES = arg('ao-samples', 24)
NOBAKE = '--nobake' in ARGS
T0 = time.time()


def log(*a):
    print('[nn_build %6.1fs]' % (time.time() - T0), *a, flush=True)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def part_object(part, mats):
    me = bpy.data.meshes.new(part.name)
    me.from_pydata([tuple(v) for v in part.v], [], part.f)
    uv = me.uv_layers.new(name='UVMap')
    flat = []
    for fu in part.fuv:
        for u, v in fu:
            flat += [u * part.uv_boost, v * part.uv_boost]
    uv.data.foreach_set('uv', flat)
    for k in G.ATTRS:
        vals = part.attr[k]
        if max(vals) <= 0:
            continue
        a = me.attributes.new(k, 'FLOAT', 'POINT')
        a.data.foreach_set('value', vals)
    for mt in mats:
        me.materials.append(mt)
    idx = 0 if part.mat == 'cloth' else 1
    me.polygons.foreach_set('material_index', [idx] * len(me.polygons))
    me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    me.validate(clean_customdata=False)
    ob = bpy.data.objects.new(part.name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def pack_uvs(objs, margin):
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
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def new_image(name, colorspace):
    img = bpy.data.images.new(name, TEX, TEX, alpha=False, float_buffer=False)
    img.colorspace_settings.name = colorspace
    return img


def bake(low, high, kind, samples, targets):
    """targets: {material_name: image node} made active on the low object's materials."""
    for mat_name, node in targets.items():
        nt = bpy.data.materials[mat_name].node_tree
        for n in nt.nodes:
            n.select = False
        node.select = True
        nt.nodes.active = node
    scn = bpy.context.scene
    scn.cycles.samples = samples
    bpy.ops.object.select_all(action='DESELECT')
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    t = time.time()
    kw = dict(use_selected_to_active=True, cage_extrusion=0.004, max_ray_distance=0.014, margin=16, use_clear=True, target='IMAGE_TEXTURES')
    if kind == 'NORMAL':
        bpy.ops.object.bake(type='NORMAL', normal_space='TANGENT', **kw)
    else:
        bpy.ops.object.bake(type=kind, **kw)
    log('baked', kind, 'in %.1fs' % (time.time() - t))


def main():
    reset()
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.device = 'CPU'
    scn.render.fps = 30

    cloth_p = M.cloth_material()
    skin_p = M.skin_material()
    cloth_p.use_fake_user = True
    skin_p.use_fake_user = True

    log('generating game mesh')
    parts, joints = G.build_all(1)
    total = 0
    for p in parts:
        log('  %-12s %6d tris' % (p.name, p.tris()))
        total += p.tris()
    log('total tris', total)
    objs = {p.name: part_object(p, [cloth_p, skin_p]) for p in parts}
    pack_uvs([objs[p.name] for p in parts if p.mat == 'cloth'], 0.004)
    pack_uvs([objs[p.name] for p in parts if p.mat == 'skin'], 0.006)

    log('rig')
    arm = R.build_armature(joints)
    for p in parts:
        R.skin_part(objs[p.name], arm, p.bones)
    for b in arm.data.bones:
        b.use_deform = b.name != 'root'
    for nm in ('dress', 'apron'):
        R.skirt_weights(objs[nm])
    low = join([objs['dress']] + [objs[p.name] for p in parts if p.name != 'dress'], 'NightNurse')
    bpy.ops.object.select_all(action='DESELECT')
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=4)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    bpy.ops.object.select_all(action='DESELECT')
    log('actions')
    R.build_actions(arm)
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)

    tex_dir = os.path.join(HERE, 'textures')
    os.makedirs(tex_dir, exist_ok=True)
    if not NOBAKE:
        log('generating bake source mesh (res 3)')
        hparts, _ = G.build_all(3)
        hobjs = [part_object(p, [cloth_p, skin_p]) for p in hparts]
        high = join(hobjs, 'NN_BakeSource')
        mod = high.modifiers.new('sub', 'SUBSURF')
        mod.levels = mod.render_levels = 1
        log('high tris', sum(len(pg.vertices) - 2 for pg in high.data.polygons) * 4)

        imgs = {}
        baked = {}
        for key, proc in (('Cloth', cloth_p), ('Skin', skin_p)):
            ic = new_image('NN_%s_albedo' % key, 'sRGB')
            ir = new_image('NN_%s_roughness' % key, 'Non-Color')
            inn = new_image('NN_%s_normal' % key, 'Non-Color')
            iao = new_image('NN_%s_ao' % key, 'Non-Color')
            mat, nodes = M.baked_material('NightNurse_%s' % key, ic, ir, inn)
            aonode = mat.node_tree.nodes.new('ShaderNodeTexImage')
            aonode.image = iao
            imgs[key] = (ic, ir, inn, iao)
            baked[key] = (mat, nodes, aonode, proc)
        # replace slots in place: clearing the slot list would reset every face's material index
        low.data.materials[0] = baked['Cloth'][0]
        low.data.materials[1] = baked['Skin'][0]
        if scn.world is None:
            scn.world = bpy.data.worlds.new('BakeWorld')
        scn.world.light_settings.distance = 0.25   # local cavity occlusion only

        for sig, idx, kind, samples in (('color', 0, 'EMIT', 4), ('rough', 1, 'EMIT', 4), ('normal', 2, 'NORMAL', 4), ('ao', 3, 'AO', AO_SAMPLES)):
            for key in ('Cloth', 'Skin'):
                M.set_bake_signal(baked[key][3], sig)
            targets = {}
            for key in ('Cloth', 'Skin'):
                mat, nodes, aonode, proc = baked[key]
                targets[mat.name] = aonode if sig == 'ao' else nodes[idx]
            bake(low, high, kind, samples, targets)
        for key in ('Cloth', 'Skin'):
            M.set_bake_signal(baked[key][3], 'normal')
        # fold ambient occlusion into the albedo (the medium preset has no SSAO)
        for key in ('Cloth', 'Skin'):
            ic, ir, inn, iao = imgs[key]
            c = np.empty(TEX * TEX * 4, np.float32)
            a = np.empty(TEX * TEX * 4, np.float32)
            ic.pixels.foreach_get(c)
            iao.pixels.foreach_get(a)
            c = c.reshape(-1, 4)
            ao = a.reshape(TEX, TEX, 4)[:, :, 0]
            # small box blur to take the sampling noise out of the AO
            rad = max(1, TEX // 512)
            k = 2 * rad + 1
            pad = np.pad(ao, rad, mode='edge')
            cs = np.cumsum(np.cumsum(pad, 0), 1)
            cs = np.pad(cs, ((1, 0), (1, 0)))
            ao = (cs[k:, k:] - cs[:-k, k:] - cs[k:, :-k] + cs[:-k, :-k]) / (k * k)
            ao = ao.reshape(-1, 1)
            c[:, :3] *= (1.0 - 0.55 * (1.0 - np.power(np.clip(ao, 0, 1), 1.2)))
            ic.pixels.foreach_set(c.ravel())
            ic.update()
            del c, a
        for key in ('Cloth', 'Skin'):
            for img in imgs[key]:
                img.filepath_raw = os.path.join(tex_dir, img.name + '.png')
                img.file_format = 'PNG'
                img.save()
                img.filepath = '//textures/' + img.name + '.png'
            # AO is folded into albedo; drop the AO node so the glTF exporter ignores it
            mat, nodes, aonode, proc = baked[key]
            mat.node_tree.nodes.remove(aonode)
        bpy.data.objects.remove(high, do_unlink=True)
        log('textures saved')

    # final scene
    low.select_set(False)
    arm.animation_data.action = bpy.data.actions['Frozen']
    scn.frame_set(0)
    bpy.context.preferences.filepaths.save_version = 0
    blend_path = os.path.join(HERE, 'night_nurse.blend')
    bpy.ops.wm.save_as_mainfile(filepath=blend_path, relative_remap=True, compress=True)
    log('saved', blend_path)

    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    bpy.ops.object.select_all(action='DESELECT')
    low.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    glb = os.path.join(os.path.dirname(HERE), 'night_nurse.glb')
    bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='ACTIONS', export_force_sampling=True, export_skins=True,
                              export_influence_nb=4, export_yup=True, export_apply=False, export_materials='EXPORT',
                              export_image_format='AUTO', export_def_bones=False, export_anim_slide_to_zero=True)
    log('exported', glb, os.path.getsize(glb) // 1024, 'KB')


main()
