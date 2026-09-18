"""The Hive's clips, on the shared human skeleton (art/human/blender_src/hu_rig.py conventions: armature
space poses built with hu_rig.Pose, in place, no root motion, 30 fps).

The Hive is hunched far forward with its head hung and tipped to one side; it drags its right leg. The
head coming up to look at whoever it has locked on to is not a clip: the game turns the neck and head
toward its target on top of whatever clip is playing (scripts/monsters/hive_rig.gd).
"""
import math
from mathutils import Vector
import hu_rig
from hu_rig import Pose, spine, arm_hang, hand_relax, planted, Rx, Ry, Rz, FPS
from hu_mesh import smooth01, lerp

# name: (frames, loop, speed m/s or None, what it is)
CLIPS = {
    'HiveIdle': (150, True, None, 'hunched, head hung and tipped, a slow sway, breathing through its open mouth'),
    'HiveWalk': (44, True, 0.85, 'a shamble: short steps on the left leg, the right dragged on its toes; 0.85 m/s'),
    'HiveAttack': (20, False, None, 'a lunge: the body pitches forward and both arms reach and grab, one-shot'),
}
WALK_SPEED = CLIPS['HiveWalk'][2]

LEAN = 0.55           # the hunch (spine() lean)


def _head(p, sway=0.0, loll=0.0):
    """The hung head: dropped forward and tipped to its right."""
    p.rel('neck', Rx(0.10 + 0.04 * loll))
    p.rel('head', Ry(-0.20 - 0.06 * sway) @ Rx(0.10 + 0.05 * loll) @ Rz(0.05 * sway))


def idle_pose(rig, f, n=150):
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    br = math.sin(t * math.tau * 3)                         # three slow breaths
    sway = math.sin(t * math.tau) * 0.7 + 0.3 * math.sin(t * math.tau * 2 + 1.1)
    p.hips = Vector((0.010 * s + 0.012 * s * sway, 0.015 * s, -0.018 * s + 0.002 * s * br))
    spine(p, lean=LEAN + 0.02 * br, yaw=0.08 + 0.04 * sway, roll=0.05 + 0.03 * sway, breathe=br,
          look=(0.18 + 0.06 * math.sin(t * math.tau + 0.5), 0.0), neck_comp=0.0)
    _head(p, sway, 0.5 + 0.5 * math.sin(t * math.tau * 2 + 0.3))
    ballL = Vector((rig.ball['L'].x * 1.1, rig.ball['L'].y - 0.05 * s, rig.ball['L'].z))
    ballR = Vector((rig.ball['R'].x * 1.2, rig.ball['R'].y + 0.20 * s, rig.ball['R'].z))
    planted(p, 'L', ballL, 0.0, yaw=0.12)
    planted(p, 'R', ballR, 0.22, yaw=-0.30)
    arm_hang(p, 'L', swing=0.30 + 0.05 * sway, abduct=0.10, bend=0.28, wrist=0.15, twist=0.2)
    arm_hang(p, 'R', swing=0.06 + 0.03 * sway, abduct=0.16, bend=0.12, wrist=0.05, twist=0.0)
    hand_relax(p, 'L', curl=0.55 + 0.08 * math.sin(t * math.tau * 5))
    hand_relax(p, 'R', curl=0.35)
    return p


def walk_pose(rig, f, n=44):
    """The good (left) leg takes a short, heavy step; the body lurches over it; the right leg is pulled
    along behind on its toes, barely lifting, the foot turned out."""
    ph = f / n
    T = n / FPS
    v = WALK_SPEED
    s = rig.body.s
    p = Pose(rig)
    stride = v * T
    # weight: sags onto the bad leg while the good one swings, lurches up over the good one
    good_stance = 0.72
    phL = ph
    phR = (ph + 0.5) % 1.0
    lurch = math.cos(math.tau * (ph - 0.30))               # +1 when the body is up over the left
    p.hips = Vector((0.020 * s + 0.018 * s * lurch, 0.012 * s, -0.030 * s + 0.018 * s * lurch))
    spine(p, lean=LEAN + 0.05 - 0.04 * lurch, yaw=0.08 - 0.10 * math.sin(math.tau * ph),
          roll=0.05 + 0.07 * lurch, breathe=0.4 * math.sin(math.tau * 2 * ph), look=(0.16, 0.0), neck_comp=0.0)
    # the head lags the lurch: it bobs down a beat after the body drops
    _head(p, sway=math.sin(math.tau * (ph - 0.15)), loll=0.5 - 0.5 * math.cos(math.tau * (ph - 0.2)))
    for side, q, duty, lift, yaw in (('L', phL, good_stance, 0.055 * s, 0.10), ('R', phR, 0.52, 0.010 * s, -0.30)):
        bx = rig.ball[side].x * (1.05 if side == 'L' else 1.2)
        front = stride * duty * (0.45 if side == 'L' else 0.20)
        if q < duty:
            u = q / duty
            y = -front + stride * duty * u               # planted: slides back at exactly the body's speed
            zb = rig.ball[side].z
            if side == 'L':
                pitch = 0.60 * smooth01((u - 0.55) / 0.45) ** 1.5
            else:
                pitch = 0.30 + 0.12 * u                  # the bad foot never lies flat: it stands on its toes
        else:
            w = (q - duty) / (1 - duty)
            y0 = -front + stride * duty
            e = smooth01(w) if side == 'L' else w ** 1.4 * (0.9 + 0.1 * math.sin(math.pi * w))
            y = lerp(y0, -front, e)
            zb = rig.ball[side].z + lift * math.sin(math.pi * w)
            pitch = lerp(0.60, -0.10, smooth01(w * 1.4)) if side == 'L' else 0.42 + 0.10 * math.sin(math.pi * w)
        planted(p, side, Vector((bx, rig.ball[side].y + y + (0.16 * s if side == 'R' else 0.0), zb)), pitch, yaw=yaw)
    # the arms dangle and swing loose, a beat behind the body
    sw = math.cos(math.tau * (ph - 0.1))
    arm_hang(p, 'L', swing=0.30 + 0.12 * sw, abduct=0.10, bend=0.28, wrist=0.15, twist=0.2)
    arm_hang(p, 'R', swing=0.08 - 0.08 * sw, abduct=0.16 + 0.03 * lurch, bend=0.14, wrist=0.05, twist=0.0)
    hand_relax(p, 'L', curl=0.55)
    hand_relax(p, 'R', curl=0.35)
    return p


def attack_pose(rig, f, n=20):
    """Pitch forward and grab: both arms thrown out ahead at chest height, hands open, the head up and
    pushed out; hold at the end."""
    t = min(f / max(n - 1, 1), 1.0)
    k = smooth01(t / 0.45)                                  # the reach lands in the first 45%
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, -0.06 * s * k, -0.030 * s * k - 0.018 * s))
    spine(p, lean=LEAN + 0.18 * k, yaw=0.08 * (1 - k), roll=0.05 * (1 - k), look=(0.0, 0.0), neck_comp=0.0)
    # the head comes up out of its hang toward the target
    p.rel('neck', Rx(0.10 - 0.55 * k))
    p.rel('head', Ry(-0.20 * (1 - k)) @ Rx(0.10 - 0.45 * k))
    ballL = Vector((rig.ball['L'].x * 1.1, rig.ball['L'].y - (0.05 + 0.18 * k) * s, rig.ball['L'].z))
    ballR = Vector((rig.ball['R'].x * 1.2, rig.ball['R'].y + 0.20 * s, rig.ball['R'].z))
    planted(p, 'L', ballL, 0.0, yaw=0.12)
    planted(p, 'R', ballR, 0.22 + 0.2 * k, yaw=-0.30)
    for side in ('L', 'R'):
        rest_swing = 0.30 if side == 'L' else 0.06
        arm_hang(p, side, swing=lerp(rest_swing, 1.85, k), abduct=lerp(0.12, 0.26, k), bend=lerp(0.25, 0.10, k),
                 wrist=lerp(0.1, -0.3, k), twist=0.1)
        hand_relax(p, side, curl=lerp(0.5, 0.05, smooth01(t / 0.3)) + 0.5 * smooth01((t - 0.55) / 0.3))
    return p


FNS = {'HiveIdle': idle_pose, 'HiveWalk': walk_pose, 'HiveAttack': attack_pose}


def build_actions(arm, body):
    rig = hu_rig.Rig(arm, body)
    for name, (frames, loop, speed, _) in CLIPS.items():
        hu_rig.keyframe_action(arm, rig, name, frames, loop, FNS[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    return rig
