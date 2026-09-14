"""Look-dev renders of one variation from <variant>.blend.

blender --background <variant>.blend --python hu_render.py -- [--only=front,face] [--samples=48] [--res=1200x1500] [--out=DIR]

Shots: front side back three_quarter face face_side hands wireframe, and by variation: gash (players),
gown_wound, forearm_cut, vein (Bob), carry (Carrying + Carried pair).
"""
import os
import sys
import math
import json
import bpy
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


VAR = os.path.splitext(os.path.basename(bpy.data.filepath))[0]
ONLY = [x for x in arg('only', '').split(',') if x]
SAMPLES = arg('samples', 48)
RES = [int(v) for v in arg('res', '1200x1500').split('x')]
OUT = os.path.abspath(arg('out', os.path.join(os.path.dirname(HERE), 'renders', VAR)))
os.makedirs(OUT, exist_ok=True)
SITES = json.load(open(os.path.join(HERE, VAR + '_sites.json')))

scn = bpy.context.scene
rig = bpy.data.objects['Human_Rig']
pieces = {o.name: o for o in bpy.data.objects if o.type == 'MESH' and o.parent == rig}
main = bpy.data.objects.get('Human')
if arg('engine', 'eevee') == 'cycles':
    scn.render.engine = 'CYCLES'
    scn.cycles.device = 'CPU'
    scn.cycles.samples = SAMPLES
    scn.cycles.use_denoising = True
else:
    scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = SAMPLES
for prop, val in (('use_raytracing', True), ('use_shadows', True)):
    try:
        setattr(scn.eevee, prop, val)
    except Exception:
        pass
scn.view_settings.view_transform = 'AgX'
try:
    scn.view_settings.look = 'AgX - Medium High Contrast'
except Exception:
    pass
for o in bpy.data.objects:
    if o.name.startswith('Site_'):
        o.hide_render = True


def temp(ob):
    ob['hu_temp'] = True
    if ob.name not in scn.collection.objects:
        scn.collection.objects.link(ob)
    return ob


def clear():
    for ob in list(bpy.data.objects):
        if ob.get('hu_temp'):
            bpy.data.objects.remove(ob, do_unlink=True)
    rig.location = (0, 0, 0)
    rig.rotation_euler = (0, 0, 0)
    for o in pieces.values():
        o.hide_render = False
        if o.data.shape_keys:
            for kb in o.data.shape_keys.key_blocks[1:]:
                kb.value = 0.0
    for name in ('Human_TopRolled',):
        if name in pieces:
            pieces[name].hide_render = True
    set_action('Idle', 0)


def set_action(name, frame):
    rig.animation_data.action = bpy.data.actions[name]
    scn.frame_set(frame)


def camera(loc, target, lens=70.0, dof=None):
    cd = bpy.data.cameras.new('cam')
    cd.lens = lens
    cd.clip_start = 0.01
    cam = temp(bpy.data.objects.new('cam', cd))
    cam.location = loc
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    if dof:
        cd.dof.use_dof = True
        cd.dof.focus_distance = d.length
        cd.dof.aperture_fstop = dof
    scn.camera = cam


def light(kind, loc, target, energy, color=(1, 1, 1), size=1.0, name='L'):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == 'AREA':
        ld.size = size
    else:
        ld.shadow_soft_size = size
    ob = temp(bpy.data.objects.new(name, ld))
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


def studio(target_z=1.0, key=1.0):
    w = bpy.data.worlds.get('HUWorld') or bpy.data.worlds.new('HUWorld')
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.012, 0.013, 0.016, 1)
    scn.world = w
    m = bpy.data.materials.get('studio_floor') or bpy.data.materials.new('studio_floor')
    m.use_nodes = True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.05, 0.05, 0.055, 1)
    me = bpy.data.meshes.new('floor')
    me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(m)
    temp(bpy.data.objects.new('floor', me))
    light('AREA', (-2.5, -3.5, 3.2), (0, 0, target_z), 90 * key, (1.0, 0.95, 0.9), 2.0, 'key')
    light('AREA', (3.0, -2.5, 1.6), (0, 0, target_z), 18 * key, (0.8, 0.88, 1.0), 3.0, 'fill')
    light('AREA', (1.5, 3.5, 3.0), (0, 0, target_z), 120 * key, (0.75, 0.85, 1.0), 1.5, 'rim')


def bone_head(name):
    pb = rig.pose.bones[name]
    return rig.matrix_world @ pb.head


def site_world(name):
    e = bpy.data.objects.get('Site_' + name)
    return e.matrix_world if e else None


def mask_mix(channel, color, strength=1.0):
    """Preview what a game shader would do with the skin mask: blend a wound colour by one channel."""
    mat = bpy.data.materials.get('Human_Skin')
    if mat is None:
        return None
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    albedo_link = bsdf.inputs['Base Color'].links[0]
    src = albedo_link.from_socket
    path = os.path.join(HERE, 'textures', VAR, '%s_Skin_mask.png' % VAR)
    if not os.path.exists(path):
        return None
    img = bpy.data.images.load(path, check_existing=True)
    img.colorspace_settings.name = 'Non-Color'
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = img
    sep = nt.nodes.new('ShaderNodeSeparateColor')
    nt.links.new(tex.outputs['Color'], sep.inputs[0])
    mr = nt.nodes.new('ShaderNodeMapRange')
    nt.links.new(sep.outputs[channel], mr.inputs['Value'])
    mr.inputs['From Min'].default_value = 0.15
    mr.inputs['From Max'].default_value = 0.6
    mr.inputs['To Max'].default_value = strength
    mix = nt.nodes.new('ShaderNodeMix')
    mix.data_type = 'RGBA'
    nt.links.new(mr.outputs['Result'], mix.inputs[0])
    nt.links.new(src, mix.inputs[6])
    mix.inputs[7].default_value = (*color, 1)
    nt.links.new(mix.outputs[2], bsdf.inputs['Base Color'])
    return (nt, [tex, sep, mr, mix], src, bsdf)


def mask_unmix(state):
    if not state:
        return
    nt, nodes, src, bsdf = state
    nt.links.new(src, bsdf.inputs['Base Color'])
    for n in nodes:
        nt.nodes.remove(n)


H = SITES['height']


def shot_turn(loc, target=None, lens=55):
    studio()
    camera(loc, target or (0, 0, H * 0.53), lens)


def shot_face(side=False):
    studio(H * 0.9, 1.2)
    set_action('Idle', 0)
    eyes = site_world('eyes')
    c = eyes.translation if eyes else Vector((0, -0.08, H - 0.12))
    c = c + Vector((0, 0.06, -0.03))
    if side:
        camera(c + Vector((0.95, -0.35, 0.03)), c, 105, dof=8)
    else:
        camera(c + Vector((0.25, -0.98, 0.04)), c, 105, dof=8)
    light('SPOT', c + Vector((-0.6, -0.8, 0.7)), c, 22, (1.0, 0.93, 0.86), 0.08, 'facekey')


def shot_hands():
    studio(1.0, 1.0)
    set_action('Idle', 0)
    a = bone_head('hand.R')
    b = rig.matrix_world @ rig.pose.bones['middle3.R'].tail
    c = a.lerp(b, 0.45)
    camera(c + Vector((-0.45, -0.62, 0.18)), c, 100, dof=8)
    light('SPOT', c + Vector((-0.5, -0.7, 0.8)), c, 20, (1.0, 0.95, 0.9), 0.1, 'handkey')


def shot_wire():
    studio()
    for o in list(pieces.values()):
        if o.hide_render:
            continue
        w = temp(o.copy())
        w.data = o.data.copy()
        w.data.materials.clear()
        wm = bpy.data.materials.get('wire') or bpy.data.materials.new('wire')
        wm.use_nodes = True
        bs = wm.node_tree.nodes['Principled BSDF']
        bs.inputs['Base Color'].default_value = (0.9, 0.55, 0.1, 1)
        bs.inputs['Emission Color'].default_value = (1.0, 0.55, 0.1, 1)
        bs.inputs['Emission Strength'].default_value = 1.2
        w.data.materials.append(wm)
        mod = w.modifiers.new('wire', 'WIREFRAME')
        mod.thickness = 0.0014
        mod.use_replace = True
        mod.use_even_offset = False
        clay = temp(o.copy())
        clay.data = o.data.copy()
        clay.data.materials.clear()
        cm = bpy.data.materials.get('clay') or bpy.data.materials.new('clay')
        cm.use_nodes = True
        cm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.2, 0.2, 0.21, 1)
        clay.data.materials.append(cm)
        o.hide_render = True
    camera((1.6, -2.3, H * 0.75), (0, 0, H * 0.62), 50)


def shot_gash():
    studio(1.1, 1.1)
    set_action('Idle', 0)
    for n in ('Human_TopLower', 'Human_Mask'):
        if n in pieces:
            pieces[n].hide_render = True
    if 'Human_TopRolled' in pieces:
        pieces['Human_TopRolled'].hide_render = False
    g = pieces.get('Human_GashSkin')
    if g and g.data.shape_keys:
        g.data.shape_keys.key_blocks['GashOpen'].value = 1.0
    m = site_world('gash')
    c = m.translation
    camera(c + Vector((-0.30, -0.62, 0.10)), c, 85, dof=11)
    light('SPOT', c + Vector((-0.4, -0.8, 0.9)), c, 18, (1.0, 0.95, 0.9), 0.1, 'gkey')
    return mask_mix('Green', (0.35, 0.02, 0.02), 0.95)


def shot_gown_wound():
    studio(1.0, 1.1)
    set_action('Idle', 0)
    if 'Human_GownPanel' in pieces:
        pieces['Human_GownPanel'].hide_render = True
    c = site_world('gunshot').translation
    camera(c + Vector((-0.45, -0.75, 0.25)), c, 70, dof=11)
    light('SPOT', c + Vector((-0.4, -0.8, 0.9)), c, 18, (1.0, 0.95, 0.9), 0.1, 'wkey')
    return mask_mix('Blue', (0.25, 0.02, 0.02), 0.9)


def shot_gown_wound_lying():
    """The table view the forceps step looks from: straight down on the site, panel hidden."""
    studio(0.2, 1.1)
    set_action('Lying', 0)
    rig.location = (0, 0, 0.9)
    if 'Human_GownPanel' in pieces:
        pieces['Human_GownPanel'].hide_render = True
    bpy.context.view_layer.update()
    c = site_world('gunshot').translation
    camera(c + Vector((0.02, 0.05, 0.55)), c, 45)
    light('SPOT', c + Vector((0.2, -0.3, 1.2)), c, 30, (1.0, 0.97, 0.93), 0.2, 'wkey')
    return mask_mix('Blue', (0.25, 0.02, 0.02), 0.9)


def shot_forearm_cut():
    studio(1.0, 1.2)
    set_action('Idle', 0)
    fore = pieces.get('Human_Forearm_R')
    if fore is None:
        return None
    # a static copy of the severed forearm, laid beside the arm
    sev = temp(fore.copy())
    sev.data = fore.data.copy()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = fore.evaluated_get(dg)
    sev.data = bpy.data.meshes.new_from_object(ev, depsgraph=dg)
    sev.modifiers.clear()
    sev.parent = None
    sev.matrix_world = fore.matrix_world.copy()
    sev.location += Vector((-0.10, -0.16, -0.05))
    fore.hide_render = True
    cut = site_world('limb_cut').translation
    camera(cut + Vector((-0.55, -0.55, 0.12)), cut + Vector((-0.02, -0.08, -0.06)), 70, dof=10)
    light('SPOT', cut + Vector((-0.5, -0.6, 0.7)), cut, 22, (1.0, 0.95, 0.9), 0.1, 'ckey')
    # tourniquet line: a thin marker band at the limb site
    lm = site_world('limb')
    bpy.ops.mesh.primitive_torus_add(major_radius=SITES['sites']['limb']['half_up'] * 1.08, minor_radius=0.005, location=lm.translation)
    t = temp(bpy.context.active_object)
    xax = lm.to_3x3() @ Vector((1, 0, 0))
    t.rotation_euler = xax.to_track_quat('Z', 'Y').to_euler()
    tm = bpy.data.materials.new('tq')
    tm.use_nodes = True
    tm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.05, 0.25, 0.05, 1)
    t.data.materials.append(tm)
    return None


def shot_vein():
    studio(1.0, 1.1)
    set_action('Idle', 0)
    m = site_world('injection')
    c = m.translation
    y = m.to_3x3() @ Vector((0, 0, 1))
    camera(c + y * 0.45 + Vector((0.1, -0.15, 0.1)), c, 85, dof=11)
    light('SPOT', c + y * 0.8 + Vector((0, -0.3, 0.5)), c, 18, (1.0, 0.95, 0.9), 0.1, 'vkey')
    return mask_mix('Red', (0.05, 0.25, 0.05), 0.35)


def shot_carry():
    studio(1.2, 1.0)
    set_action('Carrying', 10)
    # a second copy of the character, slung over the shoulder
    new_rig = temp(rig.copy())
    new_rig.data = rig.data
    new_rig.animation_data_create()
    new_rig.animation_data.action = bpy.data.actions['Carried']
    for o in list(pieces.values()):
        if o.hide_render:
            continue
        c = temp(o.copy())
        c.parent = new_rig
        for mod in c.modifiers:
            if mod.type == 'ARMATURE':
                mod.object = new_rig
    s = H / 1.78
    contact = Vector((-0.150, 0.030, 1.535)) * s
    new_rig.location = contact
    scn.frame_set(10)
    camera((3.6, -3.0, 1.6), (0, 0, 1.1), 42)


def shot_lineup_pose(action, frame, loc):
    studio(0.5)
    set_action(action, frame)
    camera(loc, (0, 0, 0.3), 45)


SHOTS = {
    'front': lambda: shot_turn((0, -6.2, H * 0.58)),
    'side': lambda: shot_turn((6.2, 0, H * 0.58)),
    'back': lambda: shot_turn((0, 6.2, H * 0.58)),
    'three_quarter': lambda: shot_turn((3.9, -4.8, H * 0.7)),
    'face': lambda: shot_face(False),
    'face_side': lambda: shot_face(True),
    'hands': shot_hands,
    'wireframe': shot_wire,
    'gash': shot_gash,
    'gown_wound': shot_gown_wound,
    'gown_wound_table': shot_gown_wound_lying,
    'forearm_cut': shot_forearm_cut,
    'vein': shot_vein,
    'carry': shot_carry,
    'lying': lambda: shot_lineup_pose('Lying', 0, (1.8, -1.6, 1.4)),
}
APPLIES = {
    'gash': lambda: 'Site_gash' in bpy.data.objects,
    'gown_wound': lambda: 'Human_GownPanel' in pieces,
    'gown_wound_table': lambda: 'Human_GownPanel' in pieces,
    'forearm_cut': lambda: 'Human_Forearm_R' in pieces,
    'vein': lambda: VAR == 'bob',
}

for name, fn in SHOTS.items():
    if ONLY and name not in ONLY:
        continue
    if not ONLY and name in ('carry', 'lying'):
        continue
    if name in APPLIES and not APPLIES[name]():
        continue
    clear()
    square = name not in ('front', 'side', 'back', 'three_quarter', 'wireframe')
    scn.render.resolution_x, scn.render.resolution_y = (RES[0], RES[0]) if square else RES
    state = fn()
    bpy.context.view_layer.update()
    scn.render.filepath = os.path.join(OUT, '%s.png' % name)
    bpy.ops.render.render(write_still=True)
    print('[hu_render] wrote', scn.render.filepath, flush=True)
    if isinstance(state, tuple):
        mask_unmix(state)
