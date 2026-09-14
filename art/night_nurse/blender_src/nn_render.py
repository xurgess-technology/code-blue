"""Render the Night Nurse look-dev sheet from night_nurse.blend.

blender --background night_nurse.blend --python nn_render.py -- [--only=front,side] [--engine=eevee|cycles]
        [--samples=64] [--res=1600x1200] [--action=Frozen] [--frame=0]
"""
import sys
import os
import math
import bpy
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath)) if bpy.data.filepath else os.path.dirname(os.path.abspath(__file__))
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


ONLY = [s for s in arg('only', '').split(',') if s]
ENGINE = arg('engine', 'eevee')
SAMPLES = arg('samples', 64)
RES = [int(v) for v in arg('res', '1600x1200').split('x')]
ACTION = arg('action', 'Frozen')
FRAME = arg('frame', 0)
OUT = os.path.join(os.path.dirname(HERE), 'renders')
os.makedirs(OUT, exist_ok=True)

scn = bpy.context.scene
nurse = bpy.data.objects['NightNurse']
rig = bpy.data.objects['NightNurse_Rig']
rig.animation_data.action = bpy.data.actions[ACTION] if ACTION != "none" else None
if ACTION == "none":
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
scn.frame_set(FRAME)
scn.render.resolution_x, scn.render.resolution_y = RES
scn.render.resolution_percentage = 100
scn.view_settings.view_transform = 'AgX'
scn.view_settings.look = 'AgX - Medium High Contrast'


def set_engine(kind, samples):
    if kind == 'cycles':
        scn.render.engine = 'CYCLES'
        scn.cycles.device = 'CPU'
        scn.cycles.samples = samples
        scn.cycles.use_denoising = True
        scn.cycles.max_bounces = 6
    else:
        scn.render.engine = 'BLENDER_EEVEE'
        e = scn.eevee
        e.taa_render_samples = samples
        for prop, val in (('use_raytracing', True), ('use_shadows', True), ('volumetric_tile_size', '4'),
                          ('use_volumetric_shadows', True), ('volumetric_samples', 96), ('shadow_resolution_scale', 1.0)):
            try:
                setattr(e, prop, val)
            except Exception:
                pass


def bone_world(name, tail=False):
    pb = rig.pose.bones[name]
    return rig.matrix_world @ (pb.tail if tail else pb.head)


def clear_temp():
    for ob in list(bpy.data.objects):
        if ob.get('nn_temp'):
            bpy.data.objects.remove(ob, do_unlink=True)


def temp(ob):
    ob['nn_temp'] = True
    scn.collection.objects.link(ob)
    return ob


def camera(loc, target, lens=70.0, dof=None):
    cam_data = bpy.data.cameras.new('cam')
    cam_data.lens = lens
    cam_data.clip_start = 0.02
    cam = temp(bpy.data.objects.new('cam', cam_data))
    cam.location = loc
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    if dof:
        cam_data.dof.use_dof = True
        cam_data.dof.focus_distance = d.length
        cam_data.dof.aperture_fstop = dof
    scn.camera = cam
    return cam


def light(kind, loc, target, energy, color=(1, 1, 1), size=1.0, spot=None, name='L'):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == 'AREA':
        ld.size = size
    elif kind in ('POINT', 'SPOT'):
        ld.shadow_soft_size = size
    if spot and kind == 'SPOT':
        ld.spot_size, ld.spot_blend = spot
    ob = temp(bpy.data.objects.new(name, ld))
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return ob


def world(color, strength, volume=None):
    w = bpy.data.worlds.get('NNWorld') or bpy.data.worlds.new('NNWorld')
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    bg = nt.nodes.new('ShaderNodeBackground')
    bg.inputs['Color'].default_value = (*color, 1)
    bg.inputs['Strength'].default_value = strength
    out = nt.nodes.new('ShaderNodeOutputWorld')
    nt.links.new(bg.outputs[0], out.inputs['Surface'])
    scn.world = w


def mat(name, color, rough=0.8, emission=None):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Roughness'].default_value = rough
    if emission:
        b.inputs['Emission Color'].default_value = (*emission[0], 1)
        b.inputs['Emission Strength'].default_value = emission[1]
    return m


def box(name, center, size, material):
    me = bpy.data.meshes.new(name)
    sx, sy, sz = [s * 0.5 for s in size]
    v = [(-sx, -sy, -sz), (sx, -sy, -sz), (sx, sy, -sz), (-sx, sy, -sz), (-sx, -sy, sz), (sx, -sy, sz), (sx, sy, sz), (-sx, sy, sz)]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    me.from_pydata(v, [], f)
    me.materials.append(material)
    ob = temp(bpy.data.objects.new(name, me))
    ob.location = center
    return ob


def studio_floor():
    m = mat('studio_floor', (0.05, 0.05, 0.055), 0.6)
    me = bpy.data.meshes.new('floor')
    me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(m)
    temp(bpy.data.objects.new('floor', me))


def studio_lights():
    world((0.012, 0.013, 0.016), 1.0)
    light('AREA', (-2.5, -3.5, 3.2), (0, 0, 1.3), 80, (1.0, 0.95, 0.9), 2.0, name='key')
    light('AREA', (3.0, -2.5, 1.6), (0, 0, 1.2), 14, (0.8, 0.88, 1.0), 3.0, name='fill')
    light('AREA', (1.5, 3.5, 3.0), (0, 0, 1.5), 110, (0.75, 0.85, 1.0), 1.5, name='rim')


def shot_turn(name, loc, target=(0, 0, 1.15), lens=70):
    studio_floor()
    studio_lights()
    camera(loc, target, lens)


def shot_head():
    studio_floor()
    studio_lights()
    h = bone_world('head')
    t = bone_world('head', True)
    c = h.lerp(t, 0.42)
    m3 = rig.matrix_world.to_3x3() @ rig.pose.bones['head'].matrix.to_3x3()
    fwd = (m3 @ Vector((0, 0, 1))).normalized()
    if fwd.y > 0:
        fwd = -fwd
    up = (m3 @ Vector((0, 1, 0))).normalized()
    side = fwd.cross(up).normalized()
    camera(c + fwd * 0.95 + side * 0.22 + Vector((0, 0, -0.06)), c, 100, dof=5.6)
    light('SPOT', c + fwd * 0.8 - side * 0.7 + Vector((0, 0, 0.7)), c, 30, (1.0, 0.95, 0.9), 0.1, (math.radians(30), 0.4), name='headkey')


def shot_hands():
    studio_floor()
    studio_lights()
    a = bone_world('hand.R')
    b = bone_world('middle3.R', True)
    c = a.lerp(b, 0.5)
    camera(c + Vector((-0.55, -0.75, 0.12)), c, 90, dof=5.6)
    light('SPOT', c + Vector((-0.6, -0.7, 0.8)), c, 25, (1.0, 0.95, 0.9), 0.1, (math.radians(35), 0.4), name='handkey')


def shot_wire():
    studio_floor()
    studio_lights()
    w = nurse.copy()
    w.data = nurse.data
    for mod in list(w.modifiers):
        if mod.type != 'ARMATURE':
            w.modifiers.remove(mod)
    wm = w.modifiers.new('wire', 'WIREFRAME')
    wm.thickness = 0.0016
    wm.use_replace = True
    wm.use_even_offset = False
    wm.material_offset = 10
    temp(w)
    wire_mat = mat('wire_mat', (0.9, 0.55, 0.1), 0.5, ((1.0, 0.55, 0.1), 1.5))
    # all slots on the copy: object-linked materials so the original is untouched
    w.data = nurse.data.copy()
    w.data.materials.clear()
    for _ in range(12):
        w.data.materials.append(wire_mat)
    clay = mat('clay', (0.22, 0.22, 0.23), 0.7)
    base = nurse.copy()
    base.data = nurse.data.copy()
    base.data.materials.clear()
    base.data.materials.append(clay)
    base.data.materials.append(clay)
    temp(base)
    nurse.hide_render = True
    camera((2.6, -3.9, 1.55), (0, 0, 1.2), 62)


def shot_corridor():
    world((0.0005, 0.0006, 0.0008), 1.0)
    nurse.hide_render = False
    W, H, Lc = 2.6, 2.9, 22.0
    floor_m = bpy.data.materials.new('corr_floor')
    floor_m.use_nodes = True
    nt = floor_m.node_tree
    bsdf = nt.nodes['Principled BSDF']
    brick = nt.nodes.new('ShaderNodeTexBrick')
    brick.inputs['Scale'].default_value = 1.0
    brick.inputs['Color1'].default_value = (0.20, 0.21, 0.19, 1)
    brick.inputs['Color2'].default_value = (0.16, 0.17, 0.16, 1)
    brick.inputs['Mortar'].default_value = (0.05, 0.05, 0.045, 1)
    brick.inputs['Brick Width'].default_value = 0.6
    brick.inputs['Row Height'].default_value = 0.6
    brick.inputs['Mortar Size'].default_value = 0.006
    brick.offset = 0.0
    tc = nt.nodes.new('ShaderNodeTexCoord')
    nt.links.new(tc.outputs['Object'], brick.inputs['Vector'])
    nz = nt.nodes.new('ShaderNodeTexNoise')
    nz.inputs['Scale'].default_value = 3.0
    nt.links.new(tc.outputs['Object'], nz.inputs['Vector'])
    mix = nt.nodes.new('ShaderNodeMix')
    mix.data_type = 'RGBA'
    mix.inputs[0].default_value = 0.35
    nt.links.new(brick.outputs['Color'], mix.inputs[6])
    nt.links.new(nz.outputs['Fac'], mix.inputs[7])
    nt.links.new(mix.outputs[2], bsdf.inputs['Base Color'])
    rmap = nt.nodes.new('ShaderNodeMapRange')
    nt.links.new(nz.outputs['Fac'], rmap.inputs['Value'])
    rmap.inputs['To Min'].default_value = 0.12
    rmap.inputs['To Max'].default_value = 0.5
    nt.links.new(rmap.outputs[0], bsdf.inputs['Roughness'])
    wall_m = mat('corr_wall', (0.30, 0.34, 0.30), 0.7)
    band_m = mat('corr_band', (0.07, 0.10, 0.09), 0.5)
    ceil_m = mat('corr_ceil', (0.25, 0.25, 0.24), 0.9)
    dark_m = mat('corr_dark', (0.02, 0.02, 0.02), 0.9)
    fixture_m = mat('corr_fixture', (0.8, 0.9, 1.0), 0.3, ((0.72, 0.86, 1.0), 9.0))
    y0 = -12.0
    box('floor', (0, y0 + Lc / 2, -0.05), (W, Lc, 0.1), floor_m)
    box('ceil', (0, y0 + Lc / 2, H + 0.05), (W, Lc, 0.1), ceil_m)
    for sx in (-1, 1):
        box('wall', (sx * (W / 2 + 0.05), y0 + Lc / 2, H / 2), (0.1, Lc, H), wall_m)
        box('band', (sx * (W / 2 - 0.01), y0 + Lc / 2, 0.45), (0.03, Lc, 0.9), band_m)
        box('rail', (sx * (W / 2 - 0.04), y0 + Lc / 2, 0.95), (0.05, Lc, 0.06), mat('rail', (0.35, 0.33, 0.3), 0.4))
        for k in range(4):
            box('door', (sx * (W / 2 - 0.02), y0 + 3 + k * 5.0, 1.05), (0.05, 1.1, 2.1), dark_m)
    # end wall with a black doorway
    box('endwall_l', (-0.9, 5.0, H / 2), (0.8, 0.1, H), wall_m)
    box('endwall_r', (0.9, 5.0, H / 2), (0.8, 0.1, H), wall_m)
    box('endwall_t', (0, 5.0, 2.55), (1.0, 0.1, 0.7), wall_m)
    box('beyond', (0, 7.5, H / 2), (W, 0.1, H), dark_m)
    # the one working fixture, just in front of her, and a dead one nearer the camera
    box('fixture', (0, 0.15, H - 0.02), (0.35, 1.1, 0.04), fixture_m)
    box('fixture_dead', (0, -6.0, H - 0.02), (0.35, 1.1, 0.04), mat('dead', (0.3, 0.3, 0.3), 0.4))
    light('AREA', (0, 0.15, H - 0.06), (0, 0.15, 0), 170, (0.70, 0.84, 1.0), 0.9, name='fixture_light')
    light('POINT', (0, 3.5, 2.2), (0, 3.5, 0), 6, (0.6, 0.75, 1.0), 0.3, name='bounce')
    # light haze
    vol = box('haze', (0, y0 + Lc / 2, H / 2), (W, Lc, H), bpy.data.materials.new('haze'))
    vm = vol.data.materials[0]
    vm.use_nodes = True
    vnt = vm.node_tree
    vnt.nodes.remove(vnt.nodes['Principled BSDF'])
    pv = vnt.nodes.new('ShaderNodeVolumePrincipled')
    pv.inputs['Density'].default_value = 0.035
    pv.inputs['Color'].default_value = (0.8, 0.9, 1.0, 1)
    vnt.links.new(pv.outputs[0], vnt.nodes['Material Output'].inputs['Volume'])
    nurse_root = rig
    rig.location = (0.25, 0.5, 0)
    rig.rotation_euler = (0, 0, math.radians(-12))
    scn.frame_set(FRAME)
    camera((-0.45, -9.0, 1.62), (0.15, 0.5, 1.45), 42, dof=None)


SHOTS = {
    'front': lambda: shot_turn('front', (0, -6.8, 1.25)),
    'side': lambda: shot_turn('side', (6.8, 0, 1.25)),
    'back': lambda: shot_turn('back', (0, 6.8, 1.25)),
    'three_quarter': lambda: shot_turn('three_quarter', (4.3, -5.3, 1.6)),
    'head': shot_head,
    'hands': shot_hands,
    'wireframe': shot_wire,
    'corridor': shot_corridor,
}

for name, fn in SHOTS.items():
    if ONLY and name not in ONLY:
        continue
    clear_temp()
    nurse.hide_render = False
    rig.location = (0, 0, 0)
    rig.rotation_euler = (0, 0, 0)
    scn.frame_set(FRAME)
    set_engine('cycles' if name == 'wireframe' and ENGINE == 'cycles' else ENGINE, SAMPLES)
    fn()
    scn.render.filepath = os.path.join(OUT, '%s.png' % name)
    bpy.ops.render.render(write_still=True)
    print('[nn_render] wrote', scn.render.filepath, flush=True)
