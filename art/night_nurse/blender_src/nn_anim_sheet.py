"""Contact sheets of the Idle and Walk clips (a strip of frames per clip).

blender --background night_nurse.blend --python nn_anim_sheet.py -- [--only=walk,idle] [--cell=360x540]
"""
import os
import sys
import math
import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
OUT = os.path.join(os.path.dirname(HERE), 'renders')
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
ONLY = next((a.split('=', 1)[1].split(',') for a in ARGS if a.startswith('--only=')), ['walk', 'idle', 'walk_front'])
CW, CH = [int(v) for v in next((a.split('=', 1)[1] for a in ARGS if a.startswith('--cell=')), '360x540').split('x')]

scn = bpy.context.scene
rig = bpy.data.objects['NightNurse_Rig']
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = 12
scn.render.resolution_x, scn.render.resolution_y = CW, CH
scn.view_settings.view_transform = 'AgX'
scn.render.film_transparent = False

w = bpy.data.worlds.new('sheet')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.03, 0.035, 0.04, 1)
w.node_tree.nodes['Background'].inputs['Strength'].default_value = 1.0
scn.world = w


def add_light(loc, energy, size):
    ld = bpy.data.lights.new('l', 'AREA')
    ld.energy, ld.size = energy, size
    ob = bpy.data.objects.new('l', ld)
    scn.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector((0, 0, 1.2)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


add_light((-2.5, -3.5, 3.2), 120, 2.0)
add_light((2.5, 3.0, 3.0), 120, 2.0)
me = bpy.data.meshes.new('floor')
me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
scn.collection.objects.link(bpy.data.objects.new('floor', me))

cam_data = bpy.data.cameras.new('cam')
cam = bpy.data.objects.new('cam', cam_data)
scn.collection.objects.link(cam)
scn.camera = cam


def sheet(name, action, frames, cam_loc, lens, target=(0, 0, 1.15)):
    rig.animation_data.action = bpy.data.actions[action]
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
    strip = np.concatenate(cells, axis=1)
    out = bpy.data.images.new(name, strip.shape[1], strip.shape[0], alpha=False)
    out.pixels = strip.ravel()
    out.filepath_raw = os.path.join(OUT, name + '.png')
    out.file_format = 'PNG'
    out.save()
    print('[nn_anim_sheet] wrote', out.filepath_raw, flush=True)


if 'walk' in ONLY:
    sheet('anim_walk_side', 'Walk', [0, 6, 12, 18, 24, 30, 36, 42], (6.5, 0.0, 1.2), 60)
if 'walk_front' in ONLY:
    sheet('anim_walk_front', 'Walk', [0, 12, 24, 36], (1.8, -6.2, 1.3), 60)
if 'idle' in ONLY:
    sheet('anim_idle', 'Idle', [0, 30, 40, 50, 84, 101], (2.2, -5.8, 1.5), 60)
