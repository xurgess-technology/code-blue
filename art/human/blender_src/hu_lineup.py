"""Every variation side by side (appended from the built .blend files), plus a pose lineup.

blender --background --factory-startup --python hu_lineup.py -- [--samples=64] [--out=DIR]
"""
import os
import sys
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hu_params

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


SAMPLES = arg('samples', 64)
OUT = os.path.abspath(arg('out', os.path.join(os.path.dirname(HERE), 'renders')))
scn = bpy.context.scene
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = SAMPLES
scn.view_settings.view_transform = 'AgX'
try:
    scn.view_settings.look = 'AgX - Medium High Contrast'
except Exception:
    pass
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)

rigs = []
for i, v in enumerate(hu_params.ORDER):
    path = os.path.join(HERE, v + '.blend')
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.objects = [n for n in src.objects if n.startswith('Human') and not n.startswith('Site_')]
    rig = None
    for ob in dst.objects:
        if ob is None:
            continue
        scn.collection.objects.link(ob)
        if ob.type == 'ARMATURE':
            rig = ob
        if ob.name.startswith('Human_TopRolled'):
            ob.hide_render = True
    rig.location = ((i - 2.5) * 0.85, 0, 0)
    rigs.append((v, rig))

w = bpy.data.worlds.new('W')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.012, 0.013, 0.016, 1)
scn.world = w
m = bpy.data.materials.new('floor')
m.use_nodes = True
m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.05, 0.05, 0.055, 1)
me = bpy.data.meshes.new('floor')
me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
me.materials.append(m)
scn.collection.objects.link(bpy.data.objects.new('floor', me))


def light(loc, target, energy, color, size):
    ld = bpy.data.lights.new('L', 'AREA')
    ld.energy, ld.color, ld.size = energy, color, size
    ob = bpy.data.objects.new('L', ld)
    scn.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


light((-3.0, -4.5, 3.5), (0, 0, 1.0), 450, (1.0, 0.95, 0.9), 4.0)
light((4.0, -3.0, 2.0), (0, 0, 1.0), 120, (0.8, 0.88, 1.0), 4.0)
light((0.0, 4.0, 3.5), (0, 0, 1.3), 400, (0.75, 0.85, 1.0), 5.0)
cd = bpy.data.cameras.new('cam')
cd.lens = 38
cam = bpy.data.objects.new('cam', cd)
scn.collection.objects.link(cam)
scn.camera = cam


def shoot(name, loc, target, action=None, frames=None, res=(2400, 1200)):
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    for k, (v, rig) in enumerate(rigs):
        a = action if action else 'Idle'
        rig.animation_data.action = bpy.data.actions.get(a) or [x for x in bpy.data.actions if x.name.startswith(a)][0]
    scn.frame_set(frames or 0)
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.filepath = os.path.join(OUT, name + '.png')
    bpy.ops.render.render(write_still=True)
    print('[hu_lineup] wrote', scn.render.filepath, flush=True)


# appended actions keep their names with a suffix per file; give each rig its own file's Idle
def assign(action_base, frame):
    for v, rig in rigs:
        cand = [a for a in bpy.data.actions if a.name == action_base or a.name.startswith(action_base + '.')]
        # each appended rig's own action is the one its animation_data had in its file
        rig.animation_data.action = cand[0]
    scn.frame_set(frame)


shoot('lineup', (0.0, -6.8, 1.15), (0.0, 0.0, 0.95))
shoot('lineup_three_quarter', (4.2, -5.6, 1.5), (0.0, 0.0, 0.9))
shoot('lineup_back', (0.0, 6.8, 1.15), (0.0, 0.0, 0.95))
