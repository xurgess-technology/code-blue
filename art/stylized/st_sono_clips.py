"""The Sonographer's clips, on the shared human skeleton (art/human/blender_src/hu_rig.py conventions:
armature-space poses built with hu_rig.Pose, in place, no root motion, 30 fps).

The Sonographer stands up straight. Everything that makes it read is above the shoulders: a long neck
carrying the head out in front of the chest, cocked over to one ear. It must never look like the Hive,
which is bent double; so the spine lean stays near zero in every clip and the neck does the work.

The throat and cable glow, the ears swivelling and the head turning toward a sound are not clips: the
game drives them on top of whatever is playing (scripts/monsters/sonographer_rig.gd).
"""
import math
from mathutils import Vector
import hu_rig
from hu_rig import Pose, spine, arm_hang, hand_relax, planted, gait_pose, lying_pose, Rx, Ry, Rz, FPS
from hu_mesh import smooth01, lerp

# name: (frames, loop, speed m/s or None, what it is)
CLIPS = {
    'SonoIdle': (150, True, None, 'standing tall, the neck out and the head cocked, a slow listening sway'),
    'SonoWalk': (48, True, 1.05, 'a long unhurried stride, both hands out ahead on the cart handle; 1.05 m/s'),
    'SonoListen': (40, True, None, 'frozen mid-step, the head locked over one ear, only a tremor'),
    'SonoCharge': (36, False, None, 'the head lifts off the shoulders and the jaw drops open; holds'),
    'SonoEcho': (18, False, None, 'the pulse: the head punches forward and the chest empties'),
    'SonoRush': (34, True, 3.10, 'a long-legged run, one arm back dragging the cart; 3.1 m/s'),
    'SonoWail': (78, False, None, 'a flurry of overhand blows with two pauses in it'),
    'SonoStagger': (24, False, None, 'shoved: the chest goes back and the head whips after it'),
    'SonoLying': (90, True, None, 'straight on its back for the table (the shared Lying pose)'),
}
WALK_SPEED = CLIPS['SonoWalk'][2]
RUSH_SPEED = CLIPS['SonoRush'][2]

LEAN = 0.05           # near nothing: it is upright, the neck does the leaning
NECK_OUT = 0.44       # the neck carried forward out of the shoulders
HEAD_UP = -0.30       # the head levelled back up at the end of that neck
COCK = 0.26           # tipped over toward its left ear


def _head(p, out=1.0, cock=1.0, turn=0.0, jaw=0.0):
    """The listening head: pushed out ahead on the neck, levelled, and cocked over one ear.
    `turn` swings it left (+) or right, `jaw` drops it open (the open jaw is in the mesh's mouth gap;
    the pose just tips the head back with it)."""
    p.rel('neck', Rx(NECK_OUT * out) @ Rz(turn * 0.45))
    p.rel('head', Rx(HEAD_UP * out - 0.18 * jaw) @ Ry(COCK * cock) @ Rz(turn * 0.55))


def _arms_cart(p, reach=1.0, height=0.0, spread=1.0):
    """Both arms out ahead at the cart's handle: elbows soft, hands turned in as if gripping a bar."""
    for side in ('L', 'R'):
        arm_hang(p, side, swing=1.05 * reach + height, abduct=0.13 * spread, bend=0.62 * reach,
                 wrist=-0.25 * reach, twist=0.30)
        hand_relax(p, side, curl=0.75, thumb=0.35)


def idle_pose(rig, f, n=150):
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    br = math.sin(t * math.tau * 3)
    sway = math.sin(t * math.tau) * 0.8 + 0.25 * math.sin(t * math.tau * 2 + 0.7)
    listen = math.sin(t * math.tau * 2 + 1.4)
    p.hips = Vector((0.008 * s * sway, 0.0, -0.004 * s + 0.002 * s * br))
    spine(p, lean=LEAN + 0.015 * br, yaw=0.03 * sway, roll=0.02 * sway, breathe=br, neck_comp=0.0)
    _head(p, out=1.0 + 0.05 * br, cock=1.0 + 0.12 * listen, turn=0.10 * listen)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 0.86, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.05)
        arm_hang(p, side, swing=0.04 + 0.03 * sway * sg, abduct=0.09, bend=0.16, wrist=0.05, twist=0.0)
        hand_relax(p, side, curl=0.30, thumb=0.15)
    return p


def walk_pose(rig, f, n=48):
    """A long, unhurried stride, the trunk upright, both hands out ahead on the cart's handle."""
    s = rig.body.s
    p = gait_pose(rig, f, n, WALK_SPEED, 0.58, 0.075 * s, LEAN, 0.014 * s, False, 0.0, 0.0, arms=False)
    ph = f / n
    _head(p, out=1.0, cock=1.0, turn=0.06 * math.sin(math.tau * ph))
    _arms_cart(p, reach=1.0, height=0.05 * math.sin(math.tau * 2 * ph))
    return p


def listen_pose(rig, f, n=40):
    """Frozen: it has stopped dead mid-step with its head round over one ear. Nothing moves but a
    tremor in the neck and the breath it is holding."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    trem = math.sin(t * math.tau * 6) * math.sin(t * math.tau)
    p.hips = Vector((0.0, 0.006 * s, -0.010 * s))
    spine(p, lean=LEAN + 0.04, yaw=-0.06, roll=0.01, breathe=0.0, neck_comp=0.0)
    _head(p, out=1.12, cock=1.55 + 0.04 * trem, turn=0.34 + 0.02 * trem)
    # feet caught apart, weight forward on the front one
    planted(p, 'L', Vector((rig.ball['L'].x * 0.86, rig.ball['L'].y - 0.11 * s, rig.ball['L'].z)), 0.0, yaw=0.05)
    planted(p, 'R', Vector((rig.ball['R'].x * 0.86, rig.ball['R'].y + 0.13 * s, rig.ball['R'].z)), 0.32, yaw=-0.06)
    arm_hang(p, 'L', swing=0.80, abduct=0.12, bend=0.52, wrist=-0.20, twist=0.30)
    arm_hang(p, 'R', swing=0.72, abduct=0.12, bend=0.50, wrist=-0.18, twist=0.30)
    hand_relax(p, 'L', curl=0.72, thumb=0.35)
    hand_relax(p, 'R', curl=0.72, thumb=0.35)
    return p


def charge_pose(rig, f, n=36):
    """The charge: the head comes up off the end of the neck until the throat is pointing at you, the
    jaw drops, the chest fills and the hands come off the handle. Holds on the last frame."""
    t = min(f / max(n - 1, 1), 1.0)
    k = smooth01(t)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.0, 0.010 * s * k))
    spine(p, lean=LEAN - 0.14 * k, roll=0.0, breathe=-1.2 * k, neck_comp=0.0)
    # the neck straightens and stands up; the head tips back and the jaw opens
    p.rel('neck', Rx(NECK_OUT * (1 - 0.75 * k) - 0.30 * k) @ Rz(0.06 * k))
    p.rel('head', Rx(HEAD_UP * (1 - k) - 0.50 * k) @ Ry(COCK * (1 - 0.7 * k)))
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 0.86, rig.ball[side].y - 0.02 * s * k, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.05)
        arm_hang(p, side, swing=lerp(0.95, -0.28, k), abduct=lerp(0.13, 0.34, k), bend=lerp(0.60, 0.72, k),
                 wrist=-0.15, twist=0.2)
        hand_relax(p, side, curl=lerp(0.72, 0.18, k), thumb=0.3)
    return p


def echo_pose(rig, f, n=18):
    """The pulse leaves: the head punches forward and down off the charge, the chest empties, and it
    settles back a little. One-shot, straight out of SonoCharge's last frame."""
    t = min(f / max(n - 1, 1), 1.0)
    punch = smooth01(t / 0.22)
    back = smooth01((t - 0.35) / 0.65)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, -0.012 * s * punch, 0.010 * s * (1 - back * 0.7)))
    spine(p, lean=LEAN - 0.14 + 0.30 * punch - 0.14 * back, breathe=lerp(-1.2, 0.6, punch), neck_comp=0.0)
    p.rel('neck', Rx(-0.30 + 0.62 * punch - 0.22 * back))
    p.rel('head', Rx(-0.50 + 0.40 * punch + 0.10 * back) @ Ry(COCK * 0.3 * back))
    for side, sg in (('L', 1.0), ('R', -1.0)):
        planted(p, side, Vector((rig.ball[side].x * 0.86, rig.ball[side].y, rig.ball[side].z)), 0.0, yaw=sg * 0.05)
        arm_hang(p, side, swing=lerp(-0.28, 0.20, back), abduct=lerp(0.34, 0.16, back), bend=0.66, wrist=-0.15, twist=0.2)
        hand_relax(p, side, curl=lerp(0.18, 0.55, back), thumb=0.3)
    return p


def rush_pose(rig, f, n=34):
    """A long-legged run with the trunk still fairly upright, the left arm thrown back low behind it
    where the cart is being hauled along, the right arm driving."""
    s = rig.body.s
    p = gait_pose(rig, f, n, RUSH_SPEED, 0.40, 0.11 * s, LEAN + 0.20, 0.028 * s, True, 0.0, 0.0, arms=False)
    ph = f / n
    _head(p, out=0.75, cock=0.45, turn=0.05 * math.sin(math.tau * ph))
    drive = math.cos(math.tau * ph)
    # the hauling arm: back and low, barely swinging, the hand shut on the handle
    arm_hang(p, 'L', swing=-0.95 + 0.10 * drive, abduct=0.16, bend=0.30, wrist=-0.10, twist=0.25)
    hand_relax(p, 'L', curl=0.85, thumb=0.4)
    arm_hang(p, 'R', swing=0.55 * drive, abduct=0.20, bend=0.85 + 0.25 * max(0.0, drive), wrist=0.1, twist=0.1)
    hand_relax(p, 'R', curl=0.55)
    return p


# the wail: four blows with a gap after the second and after the fourth, so there is always a way out
_BLOWS = ((0.00, 'R'), (0.17, 'L'), (0.46, 'R'), (0.63, 'L'))
_BLOW_LEN = 0.15


def wail_pose(rig, f, n=78):
    """A flurry of overhand blows, alternating, with two pauses in it. Between blows it hangs there
    with its arms half up, so the pauses read as gaps you could slip out through."""
    t = min(f / max(n - 1, 1), 1.0)
    s = rig.body.s
    p = Pose(rig)
    # the strongest blow near t decides the trunk's drive
    drive = 0.0
    swing = {'L': 0.0, 'R': 0.0}
    for t0, side in _BLOWS:
        u = (t - t0) / _BLOW_LEN
        if -0.45 <= u <= 1.0:
            # wind up (u < 0), then throw
            k = smooth01(u) if u >= 0.0 else -smooth01(-u / 0.45) * 0.55
            swing[side] = max(swing[side], k) if k > 0 else min(swing[side], k)
            drive = max(drive, max(0.0, k) * (1 - max(0.0, (u - 0.6) / 0.4)))
    p.hips = Vector((0.010 * s * drive, -0.030 * s * drive, -0.016 * s - 0.010 * s * drive))
    spine(p, lean=LEAN + 0.10 + 0.34 * drive, yaw=0.10 * (swing['R'] - swing['L']),
          roll=0.05 * (swing['L'] - swing['R']), neck_comp=0.0)
    _head(p, out=0.55, cock=0.30, jaw=0.6 + 0.4 * drive)
    planted(p, 'L', Vector((rig.ball['L'].x * 0.88, rig.ball['L'].y - 0.10 * s, rig.ball['L'].z)), 0.0, yaw=0.08)
    planted(p, 'R', Vector((rig.ball['R'].x * 0.88, rig.ball['R'].y + 0.10 * s, rig.ball['R'].z)), 0.18, yaw=-0.08)
    for side in ('L', 'R'):
        k = swing[side]
        # k < 0 is the wind-up (arm high and back), k > 0 the blow coming down and through
        up = max(0.0, -k)
        thr = max(0.0, k)
        arm_hang(p, side, swing=lerp(0.35, -0.55, up) + 1.85 * thr, abduct=0.20 + 0.16 * up,
                 bend=lerp(1.15, 1.55, up) - 0.95 * thr, wrist=-0.2 + 0.5 * thr, twist=0.2)
        hand_relax(p, side, curl=0.90 - 0.25 * thr, thumb=0.5)
    return p


def stagger_pose(rig, f, n=24):
    """Shoved: the chest goes back off its feet, the long neck whips after it, then it catches itself."""
    t = min(f / max(n - 1, 1), 1.0)
    hit = smooth01(t / 0.25)
    recover = smooth01((t - 0.40) / 0.60)
    k = hit * (1.0 - recover)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.055 * s * k, -0.035 * s * k))
    spine(p, lean=LEAN - 0.42 * k, yaw=0.14 * k, roll=-0.10 * k, neck_comp=0.0)
    # the head lags and whips: still out in front while the body goes back
    p.rel('neck', Rx(NECK_OUT + 0.55 * k) @ Rz(-0.18 * k))
    p.rel('head', Rx(HEAD_UP - 0.20 * k) @ Ry(COCK * (1 + 0.8 * k)))
    planted(p, 'L', Vector((rig.ball['L'].x * 0.90, rig.ball['L'].y + 0.16 * s * k, rig.ball['L'].z)), 0.10 * k, yaw=0.06)
    planted(p, 'R', Vector((rig.ball['R'].x * 0.90, rig.ball['R'].y + 0.05 * s * k, rig.ball['R'].z)), 0.0, yaw=-0.10)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        arm_hang(p, side, swing=0.10 + 1.05 * k, abduct=0.14 + 0.30 * k, bend=0.30 + 0.35 * k, wrist=-0.3 * k, twist=0.1)
        hand_relax(p, side, curl=0.35 - 0.20 * k, thumb=0.2)
    return p


FNS = {
    'SonoIdle': idle_pose,
    'SonoWalk': walk_pose,
    'SonoListen': listen_pose,
    'SonoCharge': charge_pose,
    'SonoEcho': echo_pose,
    'SonoRush': rush_pose,
    'SonoWail': wail_pose,
    'SonoStagger': stagger_pose,
    'SonoLying': lying_pose,
}


def build_actions(arm, body):
    rig = hu_rig.Rig(arm, body)
    for name, (frames, loop, speed, _) in CLIPS.items():
        hu_rig.keyframe_action(arm, rig, name, frames, loop, FNS[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    return rig
