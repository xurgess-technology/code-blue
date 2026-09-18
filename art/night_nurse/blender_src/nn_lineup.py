"""The comparison shot: the old (deprecated) Night Nurse, this one and the players' surgeon, side by side
under the same studio lights (renders/lineup.png, renders/lineup_heads.png).

blender --background night_nurse.blend --python nn_lineup.py -- [--samples=64]
"""
import os
import sys
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(bpy.data.filepath))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
OUT = os.path.join(os.path.dirname(HERE), 'renders')
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
SAMPLES = int(next((a.split('=', 1)[1] for a in ARGS if a.startswith('--samples=')), 64))

scn = bpy.context.scene
scn.render.engine = 'BLENDER_EEVEE'
scn.eevee.taa_render_samples = SAMPLES
scn.view_settings.view_transform = 'AgX'
scn.view_settings.look = 'AgX - Medium High Contrast'

rig = bpy.data.objects['NightNurse_Rig']
rig.animation_data.action = bpy.data.actions['Frozen']
scn.frame_set(0)


def import_glb(path, x, action_hint=None):
    before = set(bpy.data.objects)
    acts_before = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=path)
    own = [ac for ac in bpy.data.actions if ac not in acts_before]    # only this GLB's clips
    new = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in new if o.parent is None]
    for r in roots:
        r.location.x += x
    arms = [o for o in new if o.type == 'ARMATURE']
    for a in arms:
        if a.animation_data:
            a.animation_data.action = None
        if action_hint:
            act = next((ac for ac in own if ac.name.startswith(action_hint)), None)
            if act:
                a.animation_data_create().action = act
    return new


# left to right: the old model (deprecated/night_nurse), this one (the .blend's own, at the origin), the surgeon
OLD = os.path.join(ROOT, 'deprecated', 'night_nurse', 'assets', 'night_nurse.glb')
if os.path.exists(OLD):
    import_glb(OLD, -0.95, 'Frozen')
import_glb(os.path.join(ROOT, 'assets', 'models', 'characters', 'human', 'surgeon_st.glb'), 0.95, 'Idle')
scn.frame_set(0)


def look(ob, loc, target):
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


def light(name, loc, target, energy, color, size):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.energy, ld.color, ld.size = energy, color, size
    ob = bpy.data.objects.new(name, ld)
    scn.collection.objects.link(ob)
    look(ob, loc, target)


w = bpy.data.worlds.new('LineupWorld')
w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.012, 0.013, 0.016, 1)
scn.world = w
fm = bpy.data.materials.new('lineup_floor')
fm.use_nodes = True
fm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.05, 0.05, 0.055, 1)
me = bpy.data.meshes.new('floor')
me.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
me.materials.append(fm)
scn.collection.objects.link(bpy.data.objects.new('floor', me))
light('key', (-2.5, -4.5, 3.4), (0, 0, 1.3), 160, (1.0, 0.95, 0.9), 3.0)
light('fill', (3.5, -3.5, 1.8), (0, 0, 1.2), 30, (0.8, 0.88, 1.0), 3.0)
light('rim', (0.5, 4.0, 3.2), (0, 0, 1.5), 160, (0.75, 0.85, 1.0), 3.0)

cd = bpy.data.cameras.new('cam')
cam = bpy.data.objects.new('cam', cd)
scn.collection.objects.link(cam)
scn.camera = cam
for name, lens, loc, target, res in (('lineup', 40, (0, -7.2, 1.35), (0, 0, 1.1), (1800, 1100)),
                                     ('lineup_heads', 45, (0, -3.6, 1.90), (0, 0, 1.85), (1800, 800))):
    cd.lens = lens
    look(cam, loc, target)
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.filepath = os.path.join(OUT, name + '.png')
    bpy.ops.render.render(write_still=True)
    print('[nn_lineup] wrote', scn.render.filepath, flush=True)
