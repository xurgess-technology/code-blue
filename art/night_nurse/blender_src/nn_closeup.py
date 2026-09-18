"""Close-up review shots of trouble spots: the shoulders (front, three-quarter, back) and the apron.

blender --background night_nurse.blend --python nn_closeup.py -- [--action=none|Frozen|Walk] [--frame=0] [--only=a,b] [--samples=48]
"""
import os
import sys
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
OUT = os.path.join(os.path.dirname(HERE), 'renders')
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    return next((type(default)(a.split('=', 1)[1]) for a in ARGS if a.startswith('--' + name + '=')), default)


ACTION = arg('action', 'Frozen')
scn = bpy.context.scene
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = arg('samples', 48)
scn.view_settings.view_transform = 'AgX'
scn.view_settings.look = 'AgX - Medium High Contrast'
rig = bpy.data.objects['NightNurse_Rig']
rig.animation_data.action = bpy.data.actions[ACTION] if ACTION != 'none' else None
if ACTION == 'none':
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
scn.frame_set(arg('frame', 0))


def look(ob, loc, target):
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


w = bpy.data.worlds.new('CloseWorld')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.022, 0.026, 1)
scn.world = w
for name, loc, energy, color in (('key', (-2.0, -3.0, 3.0), 90, (1.0, 0.95, 0.9)),
                                 ('fill', (3.0, -2.0, 1.8), 25, (0.8, 0.88, 1.0)),
                                 ('rim', (0.5, 3.5, 3.0), 90, (0.75, 0.85, 1.0))):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.energy, ld.color, ld.size = energy, color, 2.5
    ob = bpy.data.objects.new(name, ld)
    scn.collection.objects.link(ob)
    look(ob, loc, (0, 0, 1.5))

cd = bpy.data.cameras.new('cam')
cd.lens = 55
cam = bpy.data.objects.new('cam', cd)
scn.collection.objects.link(cam)
scn.camera = cam
scn.render.resolution_x, scn.render.resolution_y = 1400, 1000
SHOTS = {
    'close_shoulders_front': ((0.0, -1.5, 1.75), (0.0, 0.0, 1.66)),
    'close_shoulder_3q': ((0.95, -1.05, 1.85), (0.12, 0.0, 1.68)),
    'close_shoulders_back': ((0.0, 1.5, 1.75), (0.0, 0.0, 1.66)),
    'close_apron': ((0.25, -1.9, 1.05), (0.0, 0.0, 0.95)),
    'close_skirt_front': ((0.0, -2.2, 0.8), (0.0, 0.0, 0.75)),
    'close_skirt_side': ((1.6, -1.2, 0.8), (0.0, 0.0, 0.75)),
}
only = [s for s in arg('only', '').split(',') if s]
for name, (loc, target) in SHOTS.items():
    if only and name not in only:
        continue
    look(cam, loc, target)
    scn.render.filepath = os.path.join(OUT, name + '.png')
    bpy.ops.render.render(write_still=True)
    print('[nn_closeup] wrote', scn.render.filepath, flush=True)
