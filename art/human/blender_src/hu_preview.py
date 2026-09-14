"""Quick clay look at the generated geometry (no rig, no bake).

blender --background --factory-startup --python hu_preview.py -- --variant=surgeon_a [--only=front,face] [--out=DIR] [--skin-only]
"""
import sys
import os
import time
import importlib
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
from mathutils import Vector
import hu_mesh, hu_body, hu_params, hu_blender
for m in (hu_mesh, hu_body, hu_params, hu_blender):
    importlib.reload(m)
try:
    import hu_outfit
    importlib.reload(hu_outfit)
except ImportError:
    hu_outfit = None

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return type(default)(a.split('=', 1)[1])
    return default


VAR = arg('variant', 'surgeon_a')
ONLY = [x for x in arg('only', '').split(',') if x]
OUT = arg('out', os.path.join(os.path.dirname(HERE), 'renders', 'preview'))
os.makedirs(OUT, exist_ok=True)
T0 = time.time()

hu_blender.reset()
P = hu_params.get(VAR)
body = hu_body.Body(P, 1)
skin_m = hu_blender.clay('skin', (0.62, 0.47, 0.40), 0.55)
cloth_m = hu_blender.clay('cloth', (0.25, 0.45, 0.42), 0.8)
parts = []
if hu_outfit and '--skin-only' not in ARGS:
    parts = hu_outfit.build_character(P, 1)[0]
else:
    parts.append(body.build_skin())
    e, l = body.build_eyes()
    parts += [e, l]
    ear = body.build_ear()
    parts += [ear, ear.mirrored('ear.R')]
    arm = body.build_arm()
    fing = body.build_fingers()
    leg = body.build_leg()
    for p in (arm, fing, leg):
        parts += [p, p.mirrored(p.name[:-2] + '.R')]
tot = 0
for p in parts:
    print('  %-16s %6d tris' % (p.name, p.tris()))
    tot += p.tris()
    hu_blender.part_object(p, [cloth_m, skin_m], with_weights=False, with_attrs=False)
print('total tris', tot, 'in %.1fs' % (time.time() - T0))

scn = bpy.context.scene
hu_blender.eevee(24, (900, 1200))
hu_blender.world((0.02, 0.02, 0.025))
me = bpy.data.meshes.new('floor')
me.from_pydata([(-5, -5, 0), (5, -5, 0), (5, 5, 0), (-5, 5, 0)], [], [(0, 1, 2, 3)])
fl = bpy.data.objects.new('floor', me)
scn.collection.objects.link(fl)
me.materials.append(hu_blender.clay('floor', (0.1, 0.1, 0.1)))
hu_blender.light('AREA', (-2.0, -3.0, 3.0), (0, 0, 1.2), 300, size=2.0, name='key')
hu_blender.light('AREA', (2.5, -2.0, 1.5), (0, 0, 1.2), 80, (0.8, 0.9, 1.0), 3.0, name='fill')
hu_blender.light('AREA', (1.0, 3.0, 2.8), (0, 0, 1.4), 200, (0.9, 0.9, 1.0), 2.0, name='rim')
H = P['height']
HC = body.HC
shots = {
    'front': ((0, -5.2, H * 0.55), (0, 0, H * 0.52), 50),
    'side': ((5.2, 0, H * 0.55), (0, 0, H * 0.52), 50),
    'three_quarter': ((3.4, -3.9, H * 0.62), (0, 0, H * 0.52), 50),
    'back': ((0, 5.2, H * 0.55), (0, 0, H * 0.52), 50),
    'face': ((0.18, -0.85, HC.z + 0.02), (0, 0, HC.z - 0.02), 85),
    'face_side': ((0.85, -0.18, HC.z + 0.02), (0, 0, HC.z - 0.02), 85),
    'face_front': ((0.0, -0.85, HC.z), (0, 0, HC.z - 0.02), 85),
    'hand': ((1.25, 0.1, 0.55), (body.J['knuckle'].x, body.J['knuckle'].y, body.J['knuckle'].z), 70),
    'hand_back': ((0.9, -0.3, 1.9), (body.J['knuckle'].x, body.J['knuckle'].y, body.J['knuckle'].z), 70),
}
for name, (loc, tgt, lens) in shots.items():
    if ONLY and name not in ONLY:
        continue
    if name.startswith('face') or name == 'hand':
        scn.render.resolution_x, scn.render.resolution_y = 1000, 1000
    else:
        scn.render.resolution_x, scn.render.resolution_y = 900, 1200
    hu_blender.camera(loc, tgt, lens)
    hu_blender.render(os.path.join(OUT, '%s_%s.png' % (VAR, name)))
print('done in %.1fs' % (time.time() - T0))
