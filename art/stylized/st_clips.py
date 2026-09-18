"""Clips the stylized characters add on top of the human pipeline's 11 (art/human/blender_src/hu_rig.py).
Same conventions: armature-space poses built with hu_rig.Pose, in place, 30 fps.
"""
import math
from mathutils import Vector
import hu_rig
from hu_rig import Pose, Rx, Rz, hand_relax

# name: (frames, loop, speed, what it is)
CLIPS = {
    'Dive': (20, True, None, 'sprint-dive in the air (and the belly slide after): flat out, arms thrust forward, legs flailing'),
}


def dive_pose(rig, f, n=20):
    """Superman belly-flop: the body flat and a little nose-up about 0.42 m over the origin (the feet's
    ground), arched with the head up, both arms thrust forward, legs trailing with a small flutter kick."""
    ph = f / n
    s = rig.body.s
    J = rig.body.J
    p = Pose(rig)
    wob = math.sin(math.tau * ph)
    body_W = Rz(0.05 * wob) @ Rx(math.radians(78))       # prone, head forward (-Y), nose a little up
    p.hips = Vector((0.0, 0.06 * s, 0.42 * s - J['hips'].z))
    p.absolute('hips', body_W)
    p.rel('spine', Rx(-0.10))
    p.rel('chest', Rx(-0.12))
    p.rel('upperchest', Rx(-0.06))
    p.rel('neck', Rx(-0.30))
    p.rel('head', Rx(-0.32) @ Rz(0.06 * wob))
    for side, sg, off in (('L', 1.0, 0.0), ('R', -1.0, 0.5)):
        fl = math.sin(math.tau * (ph + off))
        # arms: straight out ahead of the head, a little wide, flapping slightly
        ua = Vector((sg * (0.26 + 0.05 * fl), -1.0, 0.14 + 0.06 * fl))
        fa = Vector((sg * (0.20 + 0.04 * fl), -1.0, 0.20 + 0.05 * fl))
        p.aim('upperarm.' + side, ua, Vector((0, 0, 1)))
        p.aim('forearm.' + side, fa, Vector((0, 0, 1)))
        p.aim('hand.' + side, Vector((sg * 0.15, -1.0, 0.12)), Vector((0, 0, 1)))
        hand_relax(p, side, curl=0.12 + 0.08 * (fl * 0.5 + 0.5), thumb=0.1)
        # legs: trailing behind, a flutter kick
        kick = math.sin(math.tau * (ph + off) * 2.0)
        p.aim('thigh.' + side, Vector((sg * 0.07, 1.0, 0.10 + 0.06 * kick)), Vector((0, 0, -1)))
        p.aim('shin.' + side, Vector((sg * 0.05, 1.0, 0.16 + 0.22 * (kick * 0.5 + 0.5))), Vector((0, 0, -1)))
        p.aim('foot.' + side, Vector((0.0, 1.0, -0.15)), Vector((0, 0, -1)))
    return p


FNS = {'Dive': dive_pose}


def build_actions(arm, body):
    """Add these clips to an armature that already has the shared ones."""
    rig = hu_rig.Rig(arm, body)
    for name, (frames, loop, speed, _) in CLIPS.items():
        hu_rig.keyframe_action(arm, rig, name, frames, loop, FNS[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
