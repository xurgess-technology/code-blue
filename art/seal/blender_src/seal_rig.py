"""Armature, weights and hand-authored procedural animation for the seal patient.

Bones are defined in the patient frame (x nose->tail, y up, z = seal's left) and converted to
Blender axes with to_b(). Weights come from the generator (analytic, by position along the
spine and along each flipper) rather than bone heat: the seal is a smooth tube, so exact
position-based blends deform better and keep the cut loop 100% on flipper_fore.L, which is what
lets the stump cap and the paddle stay welded to it in every pose.

Clips (30 fps, all in place):
  Idle      120 f loop   slow breathing, a sad little head drift, flipper digits and hind toes stirring
  Stir       36 f once   jolt: head and neck snap up, fore flippers flap, hind flippers lift, settle
  Fidget     90 f loop   awake-ish: head turns side to side, the right flipper scratches, toes fan
  Twitch     60 f loop   low vitals: fast shallow breaths, tremors, the head sagging
  Flatline   10 f loop   dead still: no breath, head slumped onto the table, flippers limp
"""
import math
import bpy
from mathutils import Vector, Matrix
import seal_geometry as G


def to_b(v):
    return Vector((v[0], -v[2], v[1]))


def to_bp(v):
    return to_b(v) * G.SCALE


def mirror_z(v):
    return Vector((v[0], v[1], -v[2]))


def bone_defs():
    fc = G.fl_centre
    hf = lambda s: G.hind_frame(s)[0]
    d = [
        ('spine', (0.12, 0.16, 0.0), (-0.10, 0.16, 0.0), 'root'),
        ('chest', (-0.10, 0.16, 0.0), (-0.36, 0.155, 0.0), 'spine'),
        ('neck', (-0.36, 0.155, 0.0), (-0.585, 0.15, 0.0), 'chest'),
        ('head', (-0.585, 0.15, 0.0), (-0.86, 0.12, 0.0), 'neck'),
        ('lumbar', (0.12, 0.16, 0.0), (0.34, 0.13, 0.0), 'spine'),
        ('pelvis', (0.34, 0.13, 0.0), (0.50, 0.08, 0.0), 'lumbar'),
        ('ribs', (-0.36, 0.16, 0.0), (0.04, 0.16, 0.0), 'spine'),
    ]
    left = [
        ('flipper_upper.L', tuple(fc(-0.075)), tuple(fc(0.04)), 'chest'),
        ('flipper_fore.L', tuple(fc(0.04)), tuple(fc(G.CUT_S)), 'flipper_upper.L'),
        ('flipper_hand.L', tuple(fc(G.CUT_S)), tuple(fc(0.27)), 'flipper_fore.L'),
        ('flipper_digits.L', tuple(fc(0.27)), tuple(fc(0.35)), 'flipper_hand.L'),
        ('hind.L', tuple(hf(0.0)), tuple(hf(0.17)), 'pelvis'),
        ('hind_toes.L', tuple(hf(0.17)), tuple(hf(0.31)), 'hind.L'),
    ]
    for name, h, t, p in left:
        d.append((name, h, t, p))
        d.append((G.mirror_bone(name), tuple(mirror_z(Vector(h))), tuple(mirror_z(Vector(t))), G.mirror_bone(p)))
    return d


def build_armature():
    arm_data = bpy.data.armatures.new('Seal_Rig')
    arm = bpy.data.objects.new('Seal_Rig', arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones
    root = eb.new('root')
    root.head, root.tail = to_bp((0, 0, 0)), to_bp((0, 0.12, 0))
    defs = bone_defs()
    for name, h, t, parent in defs:
        b = eb.new(name)
        b.head, b.tail = to_bp(h), to_bp(t)
    for name, h, t, parent in defs:
        b = eb[name]
        b.parent = eb[parent]
        b.use_connect = (to_bp(h) - eb[parent].tail).length < 1e-5
        b.align_roll(Vector((0, 0, 1)))
    bpy.ops.object.mode_set(mode='OBJECT')
    for b in arm_data.bones:
        b.use_deform = b.name != 'root'
    return arm


# ------------------------------------------------------------------ posing
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)


class Poser:
    def __init__(self, arm):
        self.arm = arm
        self.rest = {b.name: b.matrix_local.to_3x3() for b in arm.data.bones}

    def rot(self, name, rots):
        """rots: list of (patient axis, angle), applied in order. Rotations listed for a .R bone are
        taken as written; use side() to mirror a left-side motion."""
        R = Matrix.Identity(3)
        for ax, ang in rots:
            R = Matrix.Rotation(ang, 3, to_b(ax).normalized()) @ R
        M = self.rest[name]
        return (M.inverted() @ R @ M).to_quaternion()

    def apply(self, pose, frame=None):
        for pb in self.arm.pose.bones:
            pb.rotation_mode = 'QUATERNION'
            pb.rotation_quaternion = self.rot(pb.name, pose.get(pb.name, []))
            sc = pose.get('_scale', {}).get(pb.name, 1.0)
            pb.scale = (sc, 1.0, sc) if isinstance(sc, float) else sc
            if frame is not None:
                pb.keyframe_insert('rotation_quaternion', frame=frame)
                if pb.name == 'ribs':
                    pb.keyframe_insert('scale', frame=frame)


def add(pose, bone, *rots):
    pose.setdefault(bone, []).extend(rots)


def side(pose, bone_l, *rots):
    """Add a left-side motion to bone_l and its mirror to the .R bone."""
    add(pose, bone_l, *rots)
    add(pose, G.mirror_bone(bone_l), *[((-a[0], -a[1], a[2]), ang) for a, ang in rots])


def lift_head(p, bone, a):
    add(p, bone, (Z, -a))          # nose up for a -X pointing bone


def breathe(p, amount):
    p.setdefault('_scale', {})['ribs'] = 1.0 + 0.036 * amount
    add(p, 'chest', (Z, 0.010 * amount))
    lift_head(p, 'neck', 0.006 * amount)


def fore_lift(p, sd, a):
    """Raise a fore flipper off the table (sd 'L' or 'R')."""
    ax = (-1, 0, 0) if sd == 'L' else (1, 0, 0)
    add(p, 'flipper_upper.' + sd, (ax, a * 0.55))
    add(p, 'flipper_fore.' + sd, (ax, a * 0.45))


def fore_curl(p, sd, a):
    """Curl the paddle tip down (a > 0) or up, about the flipper's across axis."""
    V = G.fl_frame(G.CUT_S)[3]
    if sd == 'R':
        V = Vector((-V.x, -V.y, V.z))      # the mirror of a rotation axis across the z plane
    add(p, 'flipper_hand.' + sd, (tuple(V), -a * 0.5))
    add(p, 'flipper_digits.' + sd, (tuple(V), -a))


def fore_sweep(p, sd, a):
    """Swing a fore flipper forward toward the head (a > 0) along the table."""
    add(p, 'flipper_upper.' + sd, (Y, a if sd == 'R' else -a))


def hind_lift(p, a):
    for sd in ('L', 'R'):
        add(p, 'hind.' + sd, (Z, a * 0.6))
        add(p, 'hind_toes.' + sd, (Z, a * 0.4))


def hind_fan(p, a):
    """Spread (a > 0) or close the hind flippers: yaw apart and roll the outer edges up."""
    side(p, 'hind.L', (Y, -a * 0.5), (X, -a * 0.4))
    side(p, 'hind_toes.L', (X, -a * 0.6))


def rest_pose():
    """The patient's resting look: head a little turned and tilted, chin sunk, flippers slack."""
    p = {}
    add(p, 'neck', (Y, 0.06), (X, -0.03))
    lift_head(p, 'neck', 0.05)
    add(p, 'head', (Y, 0.12), (X, -0.09))
    lift_head(p, 'head', 0.09)
    fore_curl(p, 'L', 0.05)
    fore_curl(p, 'R', 0.08)
    hind_fan(p, 0.05)
    return p


def spike(f, f0, rise, hold, fall):
    if f < f0:
        return 0.0
    if f < f0 + rise:
        return G.smooth01((f - f0) / rise)
    if f < f0 + rise + hold:
        return 1.0
    return max(0.0, 1.0 - G.smooth01((f - f0 - rise - hold) / fall))


def idle_pose(f, n=120):
    t = f / n
    p = rest_pose()
    br = 0.5 - 0.5 * math.cos(t * math.tau * 2)
    breathe(p, br)
    lift_head(p, 'head', 0.025 * math.sin(t * math.tau) + 0.012 * br)
    add(p, 'head', (Y, 0.035 * math.sin(t * math.tau + 0.8)))
    # a slow, tired look toward the room and back
    look = spike(f, 50, 14, 20, 26)
    add(p, 'head', (Y, 0.10 * look), (X, 0.04 * look))
    lift_head(p, 'neck', 0.03 * look)
    fore_curl(p, 'L', 0.06 * math.sin(t * math.tau * 2 + 0.5))
    fore_curl(p, 'R', 0.07 * math.sin(t * math.tau * 2 + 2.0))
    hind_fan(p, 0.07 * math.sin(t * math.tau))
    hind_lift(p, 0.02 * math.sin(t * math.tau + 1.2))
    return p


def stir_pose(f, n=36):
    p = rest_pose()
    e = spike(f, 0, 4, 5, 26)
    osc = math.sin(f * 0.95) * spike(f, 0, 3, 8, 20)
    breathe(p, 1.0 * e)
    lift_head(p, 'neck', 0.24 * e)
    lift_head(p, 'head', 0.20 * e)
    add(p, 'head', (Y, 0.18 * osc))
    add(p, 'chest', (Z, 0.05 * e))
    add(p, 'lumbar', (Z, 0.05 * e))
    fore_lift(p, 'L', 0.20 * e + 0.12 * osc)
    fore_lift(p, 'R', 0.20 * e - 0.12 * osc)
    fore_curl(p, 'L', -0.25 * e)
    fore_curl(p, 'R', -0.25 * e)
    hind_lift(p, 0.35 * e + 0.08 * osc)
    hind_fan(p, 0.3 * e)
    return p


def fidget_pose(f, n=90):
    t = f / n
    p = rest_pose()
    br = 0.5 - 0.5 * math.cos(t * math.tau * 2)
    breathe(p, br)
    add(p, 'neck', (Y, 0.10 * math.sin(t * math.tau)))
    add(p, 'head', (Y, 0.16 * math.sin(t * math.tau)))
    lift_head(p, 'head', 0.07 * max(0.0, math.sin(t * math.tau * 2)))
    lift_head(p, 'neck', 0.05 * max(0.0, math.sin(t * math.tau * 2 + 0.3)))
    # the right fore flipper lifts and rubs back and forth, the left only twitches
    sc = spike(f, 20, 10, 36, 14)
    fore_lift(p, 'R', 0.30 * sc)
    fore_sweep(p, 'R', 0.18 * sc * (0.5 + 0.5 * math.sin((f - 20) * 0.45)))
    fore_curl(p, 'R', -0.2 * sc)
    fore_curl(p, 'L', 0.1 * math.sin(t * math.tau * 3))
    hind_fan(p, 0.20 * math.sin(t * math.tau * 2))
    hind_lift(p, 0.10 * max(0.0, math.sin(t * math.tau + 2.0)))
    add(p, 'lumbar', (Y, 0.03 * math.sin(t * math.tau)))
    return p


def twitch_pose(f, n=60):
    t = f / n
    p = rest_pose()
    br = 0.5 - 0.5 * math.cos(t * math.tau * 4)
    breathe(p, 0.45 * br)
    lift_head(p, 'neck', -0.02)
    lift_head(p, 'head', -0.04)
    add(p, 'head', (X, -0.06))
    k1 = spike(f, 8, 1, 2, 4)
    k2 = spike(f, 31, 1, 1, 3)
    k3 = spike(f, 47, 1, 2, 5)
    add(p, 'head', (Y, 0.05 * k1 - 0.04 * k3), (X, 0.03 * k2))
    lift_head(p, 'head', 0.03 * k2)
    fore_curl(p, 'L', -0.18 * k1 + 0.06 * math.sin(f * 1.7))
    fore_curl(p, 'R', -0.2 * k3 + 0.05 * math.sin(f * 1.9 + 1))
    fore_lift(p, 'R', 0.06 * k3)
    hind_fan(p, 0.12 * k2 + 0.03 * math.sin(f * 2.3))
    hind_lift(p, 0.05 * k1)
    return p


def flatline_pose(f=0):
    p = {}
    add(p, 'neck', (Y, 0.08), (X, -0.08))
    add(p, 'head', (Y, 0.12), (X, -0.24), (Z, 0.03))
    p.setdefault('_scale', {})['ribs'] = 0.985
    fore_curl(p, 'L', 0.14)
    fore_curl(p, 'R', 0.16)
    hind_fan(p, -0.04)
    hind_lift(p, -0.03)
    return p


def keyframe_action(arm, poser, name, frames, pose_fn, cyclic=True):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    for f in range(frames + 1):
        poser.apply(pose_fn(f), frame=f)
    try:
        act.frame_range = (0, frames)
        act.use_frame_range = True
        act.use_cyclic = cyclic
    except Exception:
        pass
    return act


def build_actions(arm):
    poser = Poser(arm)
    keyframe_action(arm, poser, 'Idle', 120, idle_pose, cyclic=True)
    keyframe_action(arm, poser, 'Stir', 36, stir_pose, cyclic=False)
    keyframe_action(arm, poser, 'Fidget', 90, fidget_pose, cyclic=True)
    keyframe_action(arm, poser, 'Twitch', 60, twitch_pose, cyclic=True)
    keyframe_action(arm, poser, 'Flatline', 10, flatline_pose, cyclic=True)
    arm.animation_data.action = bpy.data.actions['Idle']
    return poser
