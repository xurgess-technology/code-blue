"""Render the seal look-dev sheet from seal.blend.

blender --background seal.blend --python seal_render.py -- [--only=three_quarter,face] [--engine=eevee|cycles]
        [--samples=64] [--res=1600x1200] [--action=Idle] [--frame=0] [--prefix=]
"""
import sys
import os
import math
import bpy
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
sys.path.insert(0, HERE)
import seal_geometry as G

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
ACTION = arg('action', 'Idle')
FRAME = arg('frame', 0)
PREFIX = arg('prefix', '')
OUT = os.path.join(os.path.dirname(HERE), 'renders')
os.makedirs(OUT, exist_ok=True)

scn = bpy.context.scene
rig = bpy.data.objects['Seal_Rig']
body = bpy.data.objects['Seal_Body']
paddle = bpy.data.objects['Seal_Paddle_L']
cap = bpy.data.objects['Seal_StumpCap_L']
line = bpy.data.objects['Seal_FishingLine_L']
severed = bpy.data.objects['Seal_PaddleSevered_L']
PIECES = [body, paddle, cap, line, severed]
scn.render.resolution_x, scn.render.resolution_y = RES
scn.render.resolution_percentage = 100
scn.view_settings.view_transform = 'AgX'
scn.view_settings.look = 'AgX - Medium High Contrast'


def to_b(v):
    return Vector((v[0], -v[2], v[1])) * G.SCALE


def set_engine(kind, samples):
    if kind == 'cycles':
        scn.render.engine = 'CYCLES'
        scn.cycles.device = 'CPU'
        scn.cycles.samples = samples
        scn.cycles.use_denoising = True
    else:
        scn.render.engine = 'BLENDER_EEVEE'
        e = scn.eevee
        e.taa_render_samples = samples
        for prop, val in (('use_raytracing', True), ('use_shadows', True), ('shadow_resolution_scale', 1.0)):
            try:
                setattr(e, prop, val)
            except Exception:
                pass


def clear_temp():
    for ob in list(bpy.data.objects):
        if ob.get('seal_temp'):
            bpy.data.objects.remove(ob, do_unlink=True)


def temp(ob):
    ob['seal_temp'] = True
    scn.collection.objects.link(ob)
    return ob


def camera(loc, target, lens=50.0, dof=None, up=None):
    cam_data = bpy.data.cameras.new('cam')
    cam_data.lens = lens
    cam_data.clip_start = 0.01
    cam = temp(bpy.data.objects.new('cam', cam_data))
    cam.location = loc
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler() if abs(d.normalized().z) < 0.999 else (0.0, 0.0, 0.0)
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


def world(color, strength):
    w = bpy.data.worlds.get('SealWorld') or bpy.data.worlds.new('SealWorld')
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    bg = nt.nodes.new('ShaderNodeBackground')
    bg.inputs['Color'].default_value = (*color, 1)
    bg.inputs['Strength'].default_value = strength
    out = nt.nodes.new('ShaderNodeOutputWorld')
    nt.links.new(bg.outputs[0], out.inputs['Surface'])
    scn.world = w


def mat(name, color, rough=0.8, emission=None, metal=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Roughness'].default_value = rough
    b.inputs['Metallic'].default_value = metal
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


def table():
    top = mat('table_top', (0.55, 0.57, 0.58), 0.35, metal=0.6)
    sheet = mat('table_sheet', (0.30, 0.42, 0.40), 0.85)
    box('table', (0.0, 0.0, -0.054), (2.1, 0.95, 0.1), top)
    box('sheet', (0.0, 0.0, -0.002), (1.95, 0.85, 0.004), sheet)
    box('floor', (0.0, 0.0, -0.9), (12, 12, 0.02), mat('floor', (0.05, 0.055, 0.055), 0.6))


def studio():
    world((0.010, 0.012, 0.014), 1.0)
    light('AREA', (-1.6, -2.4, 2.6), (0, 0, 0.15), 180, (1.0, 0.95, 0.9), 2.0, name='key')
    light('AREA', (2.4, -1.2, 1.2), (0, 0, 0.15), 40, (0.8, 0.88, 1.0), 2.5, name='fill')
    light('AREA', (1.2, 2.6, 2.2), (0, 0, 0.2), 160, (0.75, 0.85, 1.0), 1.5, name='rim')
    table()


def or_lamp():
    world((0.004, 0.006, 0.006), 1.0)
    light('SPOT', (0.1, -0.2, 1.7), (0.0, 0.0, 0.0), 160, (1.0, 0.96, 0.88), 0.25, (math.radians(55), 0.5), name='lamp')
    light('AREA', (1.8, 1.8, 2.0), (0, 0, 0.2), 40, (0.6, 0.85, 0.8), 3.0, name='teal')
    table()


def site_world(name):
    e = bpy.data.objects['site_' + name]
    return e.matrix_world.copy()


def axes(name, length=0.07):
    m = site_world(name)
    o = m.translation
    for axis, colr in ((0, (1, 0.1, 0.1)), (2, (0.2, 1, 0.2)), (1, (0.2, 0.4, 1))):
        d = m.to_3x3().col[axis].normalized()
        if axis == 1:
            d = -d          # Blender -Y local is the glTF / Godot +Z
        me = bpy.data.meshes.new('ax')
        import bmesh
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=0.0022, radius2=0.0022, depth=length)
        bm.to_mesh(me)
        bm.free()
        me.materials.append(mat('ax_%d' % axis, colr, 0.5, (colr, 3.0)))
        ob = temp(bpy.data.objects.new('ax', me))
        ob.location = o + d * length * 0.5
        ob.rotation_euler = d.to_track_quat('Z', 'Y').to_euler()


def overlay(obj, channel, color, strength=0.8):
    """Tint a mesh by one SealMask channel (0 r, 1 g, 2 b, 3 a) on a copy of its materials."""
    for i, slot in enumerate(obj.material_slots):
        if slot.material is None:
            continue
        m = slot.material.copy()
        m.name = slot.material.name + '_ov%d' % channel
        nt = m.node_tree
        bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
        vc = nt.nodes.new('ShaderNodeVertexColor')
        vc.layer_name = 'SealMask'
        if channel < 3:
            sep = nt.nodes.new('ShaderNodeSeparateColor')
            nt.links.new(vc.outputs['Color'], sep.inputs[0])
            fac = sep.outputs[channel]
        else:
            fac = vc.outputs['Alpha']
        bsdf.inputs['Emission Color'].default_value = (*color, 1)
        mul = nt.nodes.new('ShaderNodeMath')
        mul.operation = 'MULTIPLY'
        nt.links.new(fac, mul.inputs[0])
        mul.inputs[1].default_value = strength
        nt.links.new(mul.outputs[0], bsdf.inputs['Emission Strength'])
        slot.link = 'OBJECT'
        slot.material = m


def infected_look(obj):
    """Blend the UV2 infected atlas over the albedo by the SealMask red channel (what the game shader does)."""
    path = os.path.join(HERE, 'textures', 'Seal_Infect.png')
    for slot in obj.material_slots:
        m = slot.material
        if m is None:
            continue
        if 'INFECT' in m.node_tree.nodes:
            m2 = m.copy()
            m2.node_tree.nodes['INFECT'].outputs[0].default_value = 1.0
            slot.link = 'OBJECT'
            slot.material = m2
            continue
        if not m.name.startswith('Seal_Coat') or not os.path.exists(path):
            continue
        m2 = m.copy()
        nt = m2.node_tree
        bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
        link = bsdf.inputs['Base Color'].links[0]
        src = link.from_socket
        img = nt.nodes.new('ShaderNodeTexImage')
        img.image = bpy.data.images.load(path, check_existing=True)
        uvn = nt.nodes.new('ShaderNodeUVMap')
        uvn.uv_map = 'UV2'
        nt.links.new(uvn.outputs[0], img.inputs['Vector'])
        vc = nt.nodes.new('ShaderNodeVertexColor')
        vc.layer_name = 'SealMask'
        sep = nt.nodes.new('ShaderNodeSeparateColor')
        nt.links.new(vc.outputs['Color'], sep.inputs[0])
        mix = nt.nodes.new('ShaderNodeMix')
        mix.data_type = 'RGBA'
        nt.links.new(sep.outputs[0], mix.inputs[0])
        nt.links.new(src, mix.inputs[6])
        nt.links.new(img.outputs['Color'], mix.inputs[7])
        nt.links.new(mix.outputs[2], bsdf.inputs['Base Color'])
        rl = bsdf.inputs['Roughness'].links
        rsrc = rl[0].from_socket if rl else None
        rmix = nt.nodes.new('ShaderNodeMix')
        rmix.data_type = 'FLOAT'
        nt.links.new(sep.outputs[0], rmix.inputs[0])
        if rsrc:
            nt.links.new(rsrc, rmix.inputs[2])
        rmix.inputs[3].default_value = 0.24
        nt.links.new(rmix.outputs[0], bsdf.inputs['Roughness'])
        slot.link = 'OBJECT'
        slot.material = m2


def state(amputation=False, cut=False):
    paddle.hide_render = cut
    cap.hide_render = not cut
    line.hide_render = not amputation or cut
    severed.hide_render = True
    if amputation:
        infected_look(body)
        infected_look(paddle)


def show_severed(where):
    """Drop the severed copy on the table at `where` (patient frame), lying flat."""
    c = severed.copy()
    c.data = severed.data
    temp(c)
    c.parent = None
    ctr, T, U, V = G.fl_frame(G.CUT_S)
    m = Matrix.Translation(to_b(where)) @ Matrix.Rotation(math.radians(-50), 4, 'Z') @ Matrix.Translation(-to_b(ctr)) @ \
        severed.matrix_world
    c.matrix_world = m
    c.hide_render = False
    infected_look(c)
    return c


def reset_materials():
    for ob in PIECES:
        for slot in ob.material_slots:
            slot.link = 'DATA'


def P(x, y, z):
    return to_b((x, y, z))


def look_site(name, dist, offset, lens=60, dof=None):
    m = site_world(name)
    o = m.translation
    camera(o + Vector(offset).normalized() * dist, o, lens, dof)


SHOTS = {
    'three_quarter': lambda: (studio(), camera(P(1.25, 1.05, 1.55), P(-0.12, 0.12, 0.02), 45)),
    'side': lambda: (studio(), camera(P(-0.12, 0.22, 2.6), P(-0.12, 0.16, 0.0), 45)),
    'top': lambda: (studio(), camera(P(-0.12, 2.6, 0.0), P(-0.12, 0.0, 0.0), 45)),
    'front': lambda: (studio(), camera(P(-2.4, 0.35, 0.0), P(0.0, 0.14, 0.0), 45)),
    'back': lambda: (studio(), camera(P(2.2, 0.55, -0.6), P(0.0, 0.12, 0.0), 45)),
    'face': lambda: (studio(), camera(P(-1.18, 0.30, 0.46), P(-0.78, 0.15, 0.03), 85, 4.0),
                     light('SPOT', P(-1.2, 0.8, 0.8), P(-0.8, 0.15, 0.0), 18, (1.0, 0.95, 0.9), 0.1, (math.radians(30), 0.4), 'facekey')),
    'face_front': lambda: (studio(), camera(P(-1.35, 0.26, 0.10), P(-0.80, 0.15, 0.0), 90, 4.0),
                           light('SPOT', P(-1.2, 0.8, -0.5), P(-0.8, 0.15, 0.0), 18, (1.0, 0.95, 0.9), 0.1, (math.radians(30), 0.4), 'facekey')),
    'flipper': lambda: (studio(), look_site('limb_cut', 0.75, P(0.35, 0.75, 0.55), 55)),
    'amputation': lambda: (state(amputation=True), or_lamp(), look_site('limb_cut', 0.8, P(0.45, 0.8, 0.55), 50)),
    'cut': lambda: (state(amputation=True, cut=True), studio(), show_severed((0.22, 0.0, 0.55)),
                    look_site('limb_cut', 0.62, P(0.55, 0.65, 0.35), 50)),
    'cut_face': lambda: (state(amputation=True, cut=True), studio(), look_site('limb_cut', 0.32, P(0.9, 0.35, 0.35), 70),
                         light('SPOT', to_b(G.fl_frame(G.CUT_S)[0]) + Vector((0.5, -0.3, 0.6)), to_b(G.fl_frame(G.CUT_S)[0]), 40, (1, 0.95, 0.9), 0.1, (math.radians(35), 0.5), 'capkey')),
    'severed_face': lambda: (state(amputation=True, cut=True), studio(), severed_close()),
    'infection_mask': lambda: (overlay(body, 0, (1.0, 0.1, 0.05), 1.2), overlay(paddle, 0, (1.0, 0.1, 0.05), 1.2), studio(),
                               axes('limb'), axes('limb_cut'), look_site('limb_cut', 0.75, P(0.3, 0.8, 0.45), 50)),
    'flank': lambda: (overlay(body, 3, (1.0, 0.55, 0.05), 0.5), studio(), axes('gunshot'),
                      look_site('gunshot', 0.75, P(0.2, 0.9, -0.5), 50)),
    'neck': lambda: (overlay(body, 2, (0.15, 0.45, 1.0), 0.9), studio(), axes('injection'),
                     look_site('injection', 0.75, P(0.35, 0.9, 0.45), 50)),
    'wireframe': lambda: wire(),
}


def severed_close():
    c = show_severed((0.25, 0.0, 0.62))
    face = c.matrix_world.translation.copy()
    # the cut face looks back along -X of its node (up the flipper)
    back = -(c.matrix_world.to_3x3().col[0]).normalized()
    camera(face + back * 0.24 + Vector((0.0, 0.0, 0.16)), face, 70)
    light('SPOT', face + back * 0.4 + Vector((0.1, -0.2, 0.5)), face, 30, (1, 0.95, 0.9), 0.1, (math.radians(35), 0.5), 'sevkey')


def wire():
    studio()
    for src in (body, paddle):
        w = src.copy()
        w.data = src.data.copy()
        temp(w)
        w.data.materials.clear()
        wm = mat('wire_mat', (0.9, 0.55, 0.1), 0.5, ((1.0, 0.55, 0.1), 1.5))
        clay = mat('clay', (0.22, 0.22, 0.23), 0.7)
        w.data.materials.append(wm)
        mod = w.modifiers.new('wire', 'WIREFRAME')
        mod.thickness = 0.0012
        mod.use_replace = True
        mod.use_even_offset = False
        base = src.copy()
        base.data = src.data.copy()
        temp(base)
        base.data.materials.clear()
        base.data.materials.append(clay)
        base.data.materials.append(clay)
        src.hide_render = True
    camera(P(1.0, 0.95, 1.2), P(-0.2, 0.12, 0.0), 45)


for name, fn in SHOTS.items():
    if ONLY and name not in ONLY:
        continue
    clear_temp()
    reset_materials()
    for ob in PIECES:
        ob.hide_render = False
    state()
    rig.animation_data.action = bpy.data.actions[ACTION] if ACTION != 'none' else None
    if ACTION == 'none':
        for pb in rig.pose.bones:
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.scale = (1, 1, 1)
    scn.frame_set(FRAME)
    set_engine(ENGINE, SAMPLES)
    fn()
    scn.render.filepath = os.path.join(OUT, '%s%s.png' % (PREFIX, name))
    bpy.ops.render.render(write_still=True)
    print('[seal_render] wrote', scn.render.filepath, flush=True)
