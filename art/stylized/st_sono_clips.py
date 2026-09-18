"""The Sonographer's clips, on the shared human skeleton with its neck cut into a chain
(st_build.add_neck_bones). Same conventions as everything else here: armature-space poses built with
hu_rig.Pose, in place, no root motion, 30 fps.

The character is a blind doctor who learned to see with sound. Tall and thin, shoulders rounded,
the head cocked to one side. **Calm, the neck is hunched down**: these clips all pose it hunched,
because the stretch is not a clip. The crane is a 0..1 blend the game lays on top of whatever is
playing (scripts/monsters/sonographer_rig.gd), driven by suspicion, and it is the suspicion meter:
the neck rises, the windpipe rings pull apart and the throat burns brighter.

The right hand has an ultrasound probe grown into it, so it is never a free hand: it hangs and
sways, it rises to point where the noise came from, and it clubs. The left hand is long-fingered and
spread, feeling the air. The ears turning, the throat and cable glow and the head tracking a sound
are all driven by the game on top of these.
"""
import math
from mathutils import Vector
import hu_rig
from hu_rig import (Pose, spine, arm_hang, arm_to, hand_relax, planted, gait_pose, lying_pose,
                    Rx, Ry, Rz, FPS)
from hu_mesh import smooth01, lerp

# name: (frames, loop, speed m/s or None, what it is)
CLIPS = {
    'SonoIdle': (150, True, None, 'neck low, head cocked, the free hand twitching, the jaw ticking with its clicks'),
    'SonoWander': (64, True, 0.80, 'a careful, high-stepping walk, the free hand out feeling the air; 0.8 m/s'),
    'SonoListen': (40, True, None, 'frozen mid-step, the ears snapped round, the head turned to the sound'),
    'SonoCharge': (36, False, None, 'the head tips up, the jaw drops and the probe arm rises to point; holds'),
    'SonoEcho': (26, False, None, 'a pulse through the body, a jolt back, and the neck snaps down'),
    'SonoRush': (30, True, 3.10, 'neck low and forward, head leading, both arms out, a loping run; 3.1 m/s'),
    'SonoWail': (96, False, None, 'clubbing with the probe and clawing with the free hand, with listening pauses'),
    'SonoSearch': (110, True, None, 'still, the neck slowly rising, the head sweeping side to side'),
    'SonoStagger': (26, False, None, 'shoved: it reels back, ears pinned, the neck recoiling down'),
    'SonoLying': (90, True, None, 'on its back for the table, the neck at rest and the probe hand at its side'),
}
WANDER_SPEED = CLIPS['SonoWander'][2]
RUSH_SPEED = CLIPS['SonoRush'][2]

LEAN = 0.10           # the trunk itself stays near upright; the neck does the work
HUNCH = 0.70          # how far the neck chain is folded down when it is calm
COCK = 0.30           # the head tipped over toward one ear
NECK = ('neck', 'neck2', 'neck3', 'neck4')
# how the hunch is shared down the chain: most of it low, so the head ends up forward and down
SHARE = (0.34, 0.28, 0.22, 0.16)


def neck(p, hunch=1.0, turn=0.0, lift=0.0, roll=0.0):
    """Fold the neck chain forward by `hunch` (1 = the calm hunch), swing it `turn` toward its left,
    and `lift` straightens it back up. The game's crane blend goes on top of this, so nothing here
    ever straightens it fully."""
    # +Rx on this chain folds the neck forward and down, which is the calm pose
    k = HUNCH * hunch - lift
    for i, b in enumerate(NECK):
        p.rel(b, Rx(k * SHARE[i]) @ Rz(turn * SHARE[i]) @ Ry(roll * SHARE[i]))


def head_pose(p, up=0.0, cock=1.0, turn=0.0, jaw=0.0):
    """The head on the end of it: levelled back up out of the hunch, cocked over one ear."""
    # -Rx brings the head back up out of the fold, so it ends up low and pushed forward, not hanging
    p.rel('head', Rx(-0.58 - up - 0.22 * jaw) @ Ry(COCK * cock) @ Rz(turn))


def probe_hang(p, swing=0.0, out=0.0, bend=0.30, twist=0.0):
    """The right arm, with the wand grown into it: heavier than the other, and it never opens."""
    arm_hang(p, 'R', swing=swing, abduct=0.12 + out, bend=bend, wrist=-0.10, twist=twist)
    # shut hard round the wand: the fingers wrap the grip and the thumb comes over them
    hand_relax(p, 'R', curl=1.15, thumb=0.95)


def feeler(p, reach=0.0, spread=1.0, curl=0.10):
    """The left hand, long fingers spread, feeling the air ahead of it."""
    arm_hang(p, 'L', swing=reach, abduct=0.14 + 0.10 * spread, bend=0.55 - 0.25 * reach,
             wrist=-0.30 * spread, twist=0.25)
    hand_relax(p, 'L', curl=curl, thumb=0.05, spread=0.6 * spread)


def _stand(p, rig, sway=0.0, spread=1.0):
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * spread, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.06)


# ====================================================================== calm
def idle_pose(rig, f, n=150):
    """Stood still, the neck low, the head cocked. The free hand's fingers twitch and the jaw ticks
    with every click."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    br = math.sin(t * math.tau * 3)
    sway = math.sin(t * math.tau) * 0.8 + 0.25 * math.sin(t * math.tau * 2 + 0.7)
    # a click about every second: the jaw ticks open for a frame or two
    click = max(0.0, math.sin(t * math.tau * 5.0)) ** 14
    p.hips = Vector((0.008 * s * sway, 0.0, -0.008 * s + 0.002 * s * br))
    spine(p, lean=LEAN + 0.02 * br, yaw=0.05 * sway, roll=0.03 * sway, breathe=br, neck_comp=0.0)
    neck(p, hunch=1.0 + 0.04 * br, turn=0.10 * sway)
    head_pose(p, cock=1.0 + 0.10 * math.sin(t * math.tau * 2 + 1.4), turn=0.12 * sway, jaw=click)
    _stand(p, rig, spread=1.0)
    probe_hang(p, swing=0.04 + 0.03 * sway, bend=0.26)
    feeler(p, reach=0.10, spread=1.0, curl=0.10 + 0.22 * max(0.0, math.sin(t * math.tau * 7.0)) ** 3)
    return p


def wander_pose(rig, f, n=64):
    """A careful, high-stepping walk: it lifts each foot well clear and sets it down deliberately,
    the free hand out in front feeling the air, the probe arm hanging and swaying."""
    s = rig.body.s
    p = gait_pose(rig, f, n, WANDER_SPEED, 0.62, 0.135 * s, LEAN, 0.020 * s, False, 0.0, 0.0, arms=False)
    ph = f / n
    neck(p, hunch=1.0, turn=0.12 * math.sin(math.tau * ph))
    head_pose(p, cock=0.9, turn=0.14 * math.sin(math.tau * ph))
    sw = math.cos(math.tau * (ph - 0.1))
    probe_hang(p, swing=0.06 + 0.24 * sw, bend=0.26 + 0.10 * sw)
    feeler(p, reach=0.75 + 0.18 * math.sin(math.tau * (ph + 0.3)), spread=1.0, curl=0.06)
    return p


def listen_pose(rig, f, n=40):
    """Frozen mid-step. The head has turned to the sound and everything else has stopped."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    trem = math.sin(t * math.tau * 6) * math.sin(t * math.tau)
    p.hips = Vector((0.010 * s, 0.006 * s, -0.012 * s))
    spine(p, lean=LEAN + 0.03, yaw=0.10, breathe=0.0, neck_comp=0.0)
    neck(p, hunch=0.88, turn=0.42 + 0.02 * trem, lift=0.06)
    head_pose(p, up=0.06, cock=1.5 + 0.05 * trem, turn=0.34)
    planted(p, 'L', Vector((rig.ball['L'].x, rig.ball['L'].y - 0.13 * s, rig.ball['L'].z)), 0.0, yaw=0.06)
    planted(p, 'R', Vector((rig.ball['R'].x, rig.ball['R'].y + 0.14 * s, rig.ball['R'].z)), 0.36, yaw=-0.08)
    probe_hang(p, swing=0.10, bend=0.30)
    feeler(p, reach=0.55, spread=1.0, curl=0.04)
    return p


def search_pose(rig, f, n=110):
    """It has lost you: stood still, the neck slowly rising, the head sweeping side to side. The
    rising here is only the clip's share of it; the crane blend does the rest."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    rise = smooth01(math.sin(t * math.tau - math.pi * 0.5) * 0.5 + 0.5)
    sweep = math.sin(t * math.tau * 2.0)
    p.hips = Vector((0.0, 0.0, -0.006 * s))
    spine(p, lean=LEAN - 0.04 * rise, yaw=0.10 * sweep, breathe=0.5 * math.sin(t * math.tau * 3), neck_comp=0.0)
    neck(p, hunch=1.0 - 0.45 * rise, turn=0.55 * sweep, lift=0.10 * rise)
    head_pose(p, up=0.10 * rise, cock=0.7 + 0.5 * abs(sweep), turn=0.45 * sweep)
    _stand(p, rig)
    probe_hang(p, swing=0.02, bend=0.22)
    feeler(p, reach=0.30 + 0.20 * rise, spread=1.0, curl=0.05)
    return p


# ====================================================================== the echo
def charge_pose(rig, f, n=36):
    """At full stretch: the head tips up, the jaw drops, and the probe arm comes up to point where
    it heard you. About 1.2 s, and it holds on the last frame while the glow runs down the cable."""
    t = min(f / max(n - 1, 1), 1.0)
    k = smooth01(t)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.010 * s * k, 0.012 * s * k))
    spine(p, lean=LEAN - 0.16 * k, yaw=0.06, breathe=-1.3 * k, neck_comp=0.0)
    # the clip only unfolds part of the hunch: the crane blend is what has it at full stretch
    neck(p, hunch=1.0 - 0.55 * k, lift=0.16 * k, turn=0.10 * (1 - k))
    head_pose(p, up=0.62 * k, cock=1.0 - 0.6 * k, jaw=1.2 * k)
    _stand(p, rig, spread=1.05)
    # the probe comes up and points forward and a little up
    probe_hang(p, swing=lerp(0.06, 1.62, k), out=0.10 * k, bend=lerp(0.26, 0.34, k), twist=0.2 * k)
    feeler(p, reach=lerp(0.10, -0.35, k), spread=1.0 - 0.4 * k, curl=0.10 + 0.5 * k)
    return p


def echo_pose(rig, f, n=26):
    """The pulse leaves the probe: it jolts back, then the neck snaps down again over about half a
    second. One-shot, straight out of SonoCharge's last frame."""
    t = min(f / max(n - 1, 1), 1.0)
    jolt = smooth01(t / 0.18) * (1.0 - smooth01((t - 0.18) / 0.35))
    down = smooth01((t - 0.25) / 0.75)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.030 * s * jolt + 0.010 * s * (1 - down), -0.016 * s * down))
    spine(p, lean=LEAN - 0.16 + 0.22 * jolt + 0.14 * down, breathe=lerp(-1.3, 0.8, down), neck_comp=0.0)
    neck(p, hunch=lerp(0.45, 1.0, down) + 0.18 * jolt, lift=0.16 * (1 - down))
    # the jaw is thrown wide for the pulse and only closes as the neck comes back down
    head_pose(p, up=lerp(0.62, 0.0, down) - 0.30 * jolt, cock=lerp(0.4, 1.0, down),
              jaw=2.6 * (1.0 - smooth01((t - 0.10) / 0.55)) + 0.5 * (1 - down))
    _stand(p, rig, spread=1.05)
    probe_hang(p, swing=lerp(1.62, 0.10, down) + 0.25 * jolt, out=0.10 * (1 - down), bend=0.30)
    feeler(p, reach=lerp(-0.35, 0.10, down), spread=1.0, curl=0.3 * (1 - down) + 0.1)
    return p


# ====================================================================== on you
def rush_pose(rig, f, n=30):
    """Neck low and forward, the head leading, both arms out, a fast loping stride."""
    s = rig.body.s
    p = gait_pose(rig, f, n, RUSH_SPEED, 0.36, 0.12 * s, LEAN + 0.26, 0.032 * s, True, 0.0, 0.0, arms=False)
    ph = f / n
    lope = math.sin(math.tau * ph)
    neck(p, hunch=1.25, turn=0.05 * lope)
    head_pose(p, up=0.30, cock=0.25, turn=0.06 * lope, jaw=0.5)
    probe_hang(p, swing=1.15 + 0.30 * lope, out=0.16, bend=0.42 - 0.18 * lope, twist=0.15)
    feeler(p, reach=1.25 - 0.30 * lope, spread=1.0, curl=0.02)
    return p


# the wail: two bursts of blows with a long listening pause after each, so there is always a way out
_BURSTS = ((0.04, 4), (0.52, 3))
_BLOW = 0.075


def wail_pose(rig, f, n=96):
    """Clubbing with the probe arm and clawing with the free hand, in bursts. Between them it stops
    dead and cocks its head to listen, and that pause is the way out."""
    t = min(f / max(n - 1, 1), 1.0)
    s = rig.body.s
    p = Pose(rig)
    club = 0.0
    claw = 0.0
    busy = 0.0
    for t0, count in _BURSTS:
        for i in range(count):
            u = (t - (t0 + i * _BLOW)) / _BLOW
            if -0.6 <= u <= 1.0:
                k = smooth01(u) if u >= 0.0 else -smooth01(-u / 0.6) * 0.6
                busy = 1.0
                if i % 2 == 0:
                    club = k
                else:
                    claw = k
    drive = max(0.0, club) + max(0.0, claw)
    p.hips = Vector((0.010 * s * club, -0.028 * s * drive, -0.018 * s - 0.010 * s * drive))
    spine(p, lean=LEAN + 0.12 + 0.30 * drive, yaw=-0.18 * club + 0.16 * claw,
          roll=0.08 * max(0.0, -club), neck_comp=0.0)
    # in the pauses the neck comes back and the head cocks over: it is listening for you
    neck(p, hunch=1.0 - 0.25 * drive, turn=0.35 * (1.0 - busy))
    head_pose(p, up=0.20 * drive, cock=0.4 + 0.9 * (1.0 - busy), turn=0.30 * (1.0 - busy), jaw=0.7 * drive)
    planted(p, 'L', Vector((rig.ball['L'].x, rig.ball['L'].y - 0.10 * s, rig.ball['L'].z)), 0.0, yaw=0.08)
    planted(p, 'R', Vector((rig.ball['R'].x, rig.ball['R'].y + 0.10 * s, rig.ball['R'].z)), 0.18, yaw=-0.08)
    up_c, thr_c = max(0.0, -club), max(0.0, club)
    probe_hang(p, swing=lerp(0.20, -0.75, up_c) + 2.20 * thr_c, out=0.20 * up_c,
               bend=lerp(1.05, 1.55, up_c) - 0.95 * thr_c, twist=0.2)
    up_f, thr_f = max(0.0, -claw), max(0.0, claw)
    arm_hang(p, 'L', swing=lerp(0.25, -0.55, up_f) + 1.95 * thr_f, abduct=0.22 + 0.20 * up_f,
             bend=lerp(1.00, 1.45, up_f) - 0.85 * thr_f, wrist=-0.2 + 0.5 * thr_f, twist=0.2)
    hand_relax(p, 'L', curl=0.15 + 0.25 * thr_f, thumb=0.1, spread=0.7)
    return p


def stagger_pose(rig, f, n=26):
    """Shoved: it reels back and the long neck recoils down into its shoulders."""
    t = min(f / max(n - 1, 1), 1.0)
    hit = smooth01(t / 0.22)
    recover = smooth01((t - 0.40) / 0.60)
    k = hit * (1.0 - recover)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.060 * s * k, -0.040 * s * k))
    spine(p, lean=LEAN - 0.40 * k, yaw=0.14 * k, roll=-0.10 * k, neck_comp=0.0)
    neck(p, hunch=1.0 + 0.55 * k, turn=-0.20 * k)
    head_pose(p, up=-0.18 * k, cock=1.0 + 0.7 * k, turn=-0.14 * k, jaw=0.5 * k)
    planted(p, 'L', Vector((rig.ball['L'].x, rig.ball['L'].y + 0.17 * s * k, rig.ball['L'].z)), 0.10 * k, yaw=0.06)
    planted(p, 'R', Vector((rig.ball['R'].x, rig.ball['R'].y + 0.06 * s * k, rig.ball['R'].z)), 0.0, yaw=-0.06)
    probe_hang(p, swing=0.10 + 0.95 * k, out=0.26 * k, bend=0.30 + 0.30 * k)
    feeler(p, reach=0.10 + 1.05 * k, spread=1.0, curl=0.05)
    return p


def lying_sono(rig, f, n=90):
    """On its back for the table and for dragging: the neck at rest length (the game takes the crane
    to 0) and the probe hand down at its side."""
    return lying_pose(rig, f, n)


FNS = {
    'SonoIdle': idle_pose,
    'SonoWander': wander_pose,
    'SonoListen': listen_pose,
    'SonoCharge': charge_pose,
    'SonoEcho': echo_pose,
    'SonoRush': rush_pose,
    'SonoWail': wail_pose,
    'SonoSearch': search_pose,
    'SonoStagger': stagger_pose,
    'SonoLying': lying_sono,
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
