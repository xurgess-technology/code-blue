"""Contact strips of every clip (a row of frames per clip, side and three-quarter views).

blender --background <variant>.blend --python hu_anim_sheet.py -- [--only=Walk,Crawl] [--cell=300x420] [--out=DIR]
"""
import os
import sys
import math
import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
sys.path.insert(0, HERE)
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return a.split('=', 1)[1]
    return default


VAR = os.path.splitext(os.path.basename(bpy.data.filepath))[0]
OUT = os.path.abspath(arg('out', os.path.join(os.path.dirname(HERE), 'renders', VAR)))
os.makedirs(OUT, exist_ok=True)
ONLY = [x for x in arg('only', '').split(',') if x]
CW, CH = [int(v) for v in arg('cell', '300x420').split('x')]

scn = bpy.context.scene
rig = bpy.data.objects['Human_Rig']
for ob in bpy.data.objects:
    if ob.name.startswith('Site_'):
        ob.hide_render = True
# pieces the game hides by default stay hidden in the strips
for name in ('Human_TopRolled',):
    if name in bpy.data.objects:
        bpy.data.objects[name].hide_render = True
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = 12
scn.render.resolution_x, scn.render.resolution_y = CW, CH
scn.render.resolution_percentage = 100
scn.view_settings.view_transform = 'AgX'
w = bpy.data.worlds.new('sheet')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.05, 0.055, 0.06, 1)
scn.world = w


def add_light(loc, energy, size):
    ld = bpy.data.lights.new('l', 'AREA')
    ld.energy, ld.size = energy, size
    ob = bpy.data.objects.new('l', ld)
    scn.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector((0, 0, 1.0)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


add_light((-2.5, -3.5, 3.2), 260, 2.0)
add_light((3.0, 2.5, 3.0), 180, 2.0)
me = bpy.data.meshes.new('floor')
me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
fl = bpy.data.objects.new('floor', me)
scn.collection.objects.link(fl)
fm = bpy.data.materials.new('floor')
fm.use_nodes = True
fm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.12, 0.12, 0.13, 1)
me.materials.append(fm)
cam_data = bpy.data.cameras.new('cam')
cam = bpy.data.objects.new('cam', cam_data)
scn.collection.objects.link(cam)
scn.camera = cam


def shoot(frames, cam_loc, target, lens):
    cam.location = cam_loc
    cam.rotation_euler = (Vector(target) - Vector(cam_loc)).to_track_quat('-Z', 'Y').to_euler()
    cam_data.lens = lens
    cells = []
    tmp = os.path.join(OUT, '_cell.png')
    for f in frames:
        scn.frame_set(f)
        scn.render.filepath = tmp
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(tmp)
        px = np.array(img.pixels[:], dtype=np.float32).reshape(CH, CW, 4)
        bpy.data.images.remove(img)
        cells.append(px)
    os.remove(tmp)
    return np.concatenate(cells, axis=1)


def save(name, rows):
    strip = np.concatenate(rows[::-1], axis=0)
    out = bpy.data.images.new(name, strip.shape[1], strip.shape[0], alpha=False)
    out.pixels = strip.ravel()
    out.filepath_raw = os.path.join(OUT, name + '.png')
    out.file_format = 'PNG'
    out.save()
    print('[hu_anim_sheet] wrote', out.filepath_raw, flush=True)


H = rig.dimensions.z if rig.dimensions.z > 1 else 1.8
VIEWS = {
    'default': [((6.0, 0.0, 1.0), (0, 0, 0.9), 55), ((3.8, -4.6, 1.3), (0, 0, 0.9), 55)],
    'low': [((6.0, 0.4, 0.6), (0, -0.2, 0.3), 55), ((3.0, -4.8, 1.8), (0, -0.2, 0.2), 55)],
    'carried': [((6.0, 0.0, 1.2), (0, 0, 1.0), 55), ((3.8, -4.6, 1.8), (0, 0, 1.0), 55)],
}
for name, act in bpy.data.actions.items():
    if ONLY and name not in ONLY:
        continue
    rig.animation_data.action = act
    rig.location = (0, 0, 1.5 if name == 'Carried' else 0.0)
    fl.hide_render = name == 'Carried'
    a, b = [int(x) for x in act.frame_range]
    count = 8 if b - a >= 8 else b - a + 1
    frames = [int(round(a + (b - a) * i / count)) for i in range(count)]
    view = 'low' if name in ('Crawl', 'Lying') else ('carried' if name == 'Carried' else 'default')
    rows = [shoot(frames, *v) for v in VIEWS[view]]
    save('anim_%s' % name.lower(), rows)
