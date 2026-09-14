"""Contact sheets of the seal's clips (a strip of frames per clip).

blender --background seal.blend --python seal_anim_sheet.py -- [--only=idle,stir,fidget,twitch,flatline] [--cell=480x300]
"""
import os
import sys
import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
OUT = os.path.join(os.path.dirname(HERE), 'renders')
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
ONLY = next((a.split('=', 1)[1].split(',') for a in ARGS if a.startswith('--only=')), ['idle', 'stir', 'fidget', 'twitch', 'flatline'])
CW, CH = [int(v) for v in next((a.split('=', 1)[1] for a in ARGS if a.startswith('--cell=')), '560x340').split('x')]

scn = bpy.context.scene
rig = bpy.data.objects['Seal_Rig']
for nm in ('Seal_StumpCap_L', 'Seal_FishingLine_L', 'Seal_PaddleSevered_L'):
    bpy.data.objects[nm].hide_render = True
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = 16
scn.render.resolution_x, scn.render.resolution_y = CW, CH
scn.view_settings.view_transform = 'AgX'
scn.render.film_transparent = False

w = bpy.data.worlds.new('sheet')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.03, 0.035, 0.04, 1)
scn.world = w


def add_light(loc, energy, size, target=(0, 0, 0.1)):
    ld = bpy.data.lights.new('l', 'AREA')
    ld.energy, ld.size = energy, size
    ob = bpy.data.objects.new('l', ld)
    scn.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


add_light((-1.6, -2.4, 2.6), 160, 2.0)
add_light((1.8, 2.2, 2.2), 120, 2.0)
me = bpy.data.meshes.new('floor')
me.from_pydata([(-3, -3, -0.002), (3, -3, -0.002), (3, 3, -0.002), (-3, 3, -0.002)], [], [(0, 1, 2, 3)])
fm = bpy.data.materials.new('sheet_floor')
fm.use_nodes = True
fm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.25, 0.33, 0.32, 1)
me.materials.append(fm)
scn.collection.objects.link(bpy.data.objects.new('floor', me))

cam_data = bpy.data.cameras.new('cam')
cam = bpy.data.objects.new('cam', cam_data)
scn.collection.objects.link(cam)
scn.camera = cam


def sheet(name, action, frames, cam_loc, lens, target=(-0.12, 0.0, 0.14)):
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
    print('[seal_anim_sheet] wrote', out.filepath_raw, flush=True)


# Blender axes: the seal's nose is -X, its left side -Y, up +Z. The camera sits off its left shoulder.
THREE_Q = (0.75, -1.55, 0.85)
SIDE = (-0.12, -2.0, 0.32)
if 'idle' in ONLY:
    sheet('anim_idle', 'Idle', [0, 30, 60, 90], THREE_Q, 42)
if 'stir' in ONLY:
    sheet('anim_stir', 'Stir', [0, 4, 8, 16, 26], SIDE, 38)
if 'fidget' in ONLY:
    sheet('anim_fidget', 'Fidget', [0, 22, 38, 60], THREE_Q, 42)
if 'twitch' in ONLY:
    sheet('anim_twitch', 'Twitch', [0, 9, 32, 48], THREE_Q, 42)
if 'flatline' in ONLY:
    sheet('anim_flatline', 'Flatline', [0, 5], THREE_Q, 42)
