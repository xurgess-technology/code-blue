"""bpy helpers: Part -> object (UVs, UV2, masks, weights, custom normals, shape keys), cameras, lights."""
import math
import bpy
from mathutils import Vector
import hu_mesh as HM


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def part_object(part, mats, collection=None, with_weights=True, with_attrs=True):
    me = bpy.data.meshes.new(part.name)
    me.from_pydata([tuple(v) for v in part.v], [], part.f)
    uv = me.uv_layers.new(name='UVMap')
    flat = []
    for fu in part.fuv:
        for u, v in fu:
            flat += [u * part.uv_boost, v * part.uv_boost]
    uv.data.foreach_set('uv', flat)
    uv2 = me.uv_layers.new(name='UV2')
    flat2 = []
    for f in part.f:
        for i in f:
            flat2 += list(part.uv2[i])
    uv2.data.foreach_set('uv', flat2)
    me.uv_layers.active = uv
    uv.active_render = True
    if with_attrs:
        for k in HM.ATTRS:
            vals = part.attr[k]
            if not vals or max(vals) <= 0:
                continue
            a = me.attributes.new(k, 'FLOAT', 'POINT')
            a.data.foreach_set('value', vals)
    for mt in mats:
        me.materials.append(mt)
    idx = {'cloth': 0, 'skin': 1}.get(part.mat, 0)
    me.polygons.foreach_set('material_index', [idx] * len(me.polygons))
    me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    me.validate(clean_customdata=False)
    if part.nrm is not None and len(part.nrm) == len(me.vertices):
        me.normals_split_custom_set_from_vertices([tuple(n) for n in part.nrm])
    ob = bpy.data.objects.new(part.name, me)
    (collection or bpy.context.scene.collection).objects.link(ob)
    if with_weights:
        groups = {}
        for i, w in enumerate(part.w):
            for b, x in w.items():
                if x <= 0:
                    continue
                g = groups.get(b)
                if g is None:
                    g = groups[b] = ob.vertex_groups.new(name=b)
                g.add([i], x, 'REPLACE')
    if part.shape_keys:
        ob.shape_key_add(name='Basis', from_mix=False)
        for name, offs in part.shape_keys.items():
            sk = ob.shape_key_add(name=name, from_mix=False)
            co = []
            for p, d in zip(part.v, offs):
                co += [p.x + d.x, p.y + d.y, p.z + d.z]
            sk.data.foreach_set('co', co)
    return ob


def clay(name='clay', color=(0.55, 0.52, 0.50), rough=0.6):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Roughness'].default_value = rough
    return m


def camera(loc, target, lens=70.0, name='cam'):
    cd = bpy.data.cameras.new(name)
    cd.lens = lens
    cd.clip_start = 0.01
    cam = bpy.data.objects.new(name, cd)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    return cam


def light(kind, loc, target, energy, color=(1, 1, 1), size=1.0, name='L'):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == 'AREA':
        ld.size = size
    else:
        ld.shadow_soft_size = size
    ob = bpy.data.objects.new(name, ld)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return ob


def world(color, strength=1.0):
    w = bpy.data.worlds.new('W')
    w.use_nodes = True
    bg = w.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (*color, 1)
    bg.inputs['Strength'].default_value = strength
    bpy.context.scene.world = w


def eevee(samples=16, res=(1200, 900)):
    scn = bpy.context.scene
    scn.render.engine = 'BLENDER_EEVEE'
    scn.eevee.taa_render_samples = samples
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100
    scn.view_settings.view_transform = 'AgX'
    try:
        scn.view_settings.look = 'AgX - Medium High Contrast'
    except Exception:
        pass


def render(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print('[render] wrote', path, flush=True)
