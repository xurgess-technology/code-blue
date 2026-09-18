"""The Sonographer's clips, on the shared human skeleton plus the cart bones st_build.add_cart_bones
adds (art/human/blender_src/hu_rig.py conventions: armature-space poses built with hu_rig.Pose, in
place, no root motion, 30 fps).

Two postures, and the character lives in the difference between them.

**Dragging.** It walks sideways. Its chest faces the way it always faces (-Y), it side-steps toward
its own left (+X), its right arm is stretched out to its right holding the cart, and its head is
turned hard over its left shoulder to face where it is going. The spine stays upright in every clip
on purpose: in the dark it must never read like the Hive, which is bent double.

**Rushing.** It swings round to face its target and comes at them head on, the left arm flailing out
in front, the cart hauled round behind it.

The cart is part of the model. Every clip but the lying one puts the right hand back on the handle
(`_anchor`, the right wrist's rest position, which is where the cart is authored) and sets the cart's
pivot bone in armature space, so the cart is always in the same place relative to the body and always
upright. `yaw` is how far round the pivot the cart is swung: 0 leaves it out to the right where it
was built, CART_BEHIND swings it round behind for the rush. Chunk B drives that same angle in code
for the trailer swing, so these are only its resting values.

The throat and line glow, the ears turning and the head tracking a sound are not clips either: the
game drives them on top of whatever is playing (scripts/monsters/sonographer_rig.gd).
"""
import math
from mathutils import Vector
import hu_rig
from hu_rig import (Pose, spine, arm_hang, arm_to, hand_relax, planted, gait_pose, lying_pose,
                    Rx, Ry, Rz, FPS)
from hu_mesh import smooth01, lerp

# name: (frames, loop, speed m/s or None, what it is)
CLIPS = {
    'SonoIdle': (150, True, None, 'standing sideways over the cart, head turned, a slow listening sway'),
    'SonoDrag': (52, True, 0.95, 'the sideways drag-walk, head turned to where it is going; 0.95 m/s'),
    'SonoListen': (40, True, None, 'frozen mid-step, the head locked over one ear, only a tremor'),
    'SonoCharge': (36, False, None, 'the head lifts off the shoulders and the jaw drops open; holds'),
    'SonoEcho': (18, False, None, 'the pulse: the head punches out and the chest empties'),
    'SonoTurn': (26, False, None, 'swinging round out of the drag to face its target, hauling the cart after it'),
    'SonoRush': (30, True, 3.10, 'head-on run, the left arm flailing, the cart bouncing behind; 3.1 m/s'),
    'SonoWail': (78, False, None, 'a one-armed flurry of blows, left, with two pauses in it'),
    'SonoStagger': (24, False, None, 'shoved: the chest goes back and the head whips after it'),
    'SonoLying': (90, True, None, 'straight on its back for the table (the shared Lying pose, no cart)'),
}
DRAG_SPEED = CLIPS['SonoDrag'][2]
RUSH_SPEED = CLIPS['SonoRush'][2]

LEAN = 0.05           # near nothing: it is upright, the neck does the leaning
NECK_OUT = 0.42       # the neck carried forward out of the shoulders
HEAD_UP = -0.28       # the head levelled back up at the end of that neck
COCK = 0.24           # tipped over toward one ear
TURN = 1.30           # how far the head is turned toward where it is going while it drags
CART_BEHIND = -1.50   # the pivot's yaw that swings the cart round behind it for the rush
CASTOR_BONES = ('castor_fl', 'castor_fr', 'castor_bl', 'castor_br')

_ANCHOR = None


def _anchor(rig):
    """Where the cart's handle is: the right wrist's rest position, which is what the cart was built
    around, so putting the hand back here puts the cart exactly where it was authored."""
    global _ANCHOR
    if _ANCHOR is None:
        J = rig.body.J
        _ANCHOR = Vector((-J['wrist'].x, J['wrist'].y, J['wrist'].z))
    return _ANCHOR


def _cart(p, yaw=0.0, jostle=0.0, spin=0.0):
    """Put the cart where it belongs: upright, yawed `yaw` about the pivot at the right hand, with a
    little jostle off the floor, and the castors rolled to `spin`."""
    p.absolute('cart_pivot', Rz(yaw) @ Rx(0.02 * jostle) @ Ry(0.03 * jostle))
    for name in CASTOR_BONES:
        p.absolute(name, Rz(yaw) @ Ry(spin))


def _hand_on_handle(p, rig, back=0.0, out=0.0):
    """The right hand back on the cart's handle. `back` slides the grip toward the body's back and
    `out` away from its side, which is how the rush hauls the cart round behind it."""
    a = _anchor(rig)
    target = Vector((a.x - out, a.y + back, a.z))
    arm_to(p, 'R', target, Vector((-0.6, -0.2, -1.0)), palm_ref=Vector((0, 0, 1)),
           hand_dir=Vector((0.15, -1.0, -0.1)))
    hand_relax(p, 'R', curl=0.85, thumb=0.45)


def _head(p, out=1.0, cock=1.0, turn=0.0, jaw=0.0):
    """The listening head: pushed out ahead on the long neck, levelled, cocked over one ear, and
    turned `turn` radians toward its own left (+X, where it is going while it drags)."""
    # +Rz on this chain turns the face toward +X, which is the way it side-steps
    p.rel('neck', Rx(NECK_OUT * out) @ Rz(turn * 0.42))
    p.rel('head', Rx(HEAD_UP * out - 0.18 * jaw) @ Ry(COCK * cock) @ Rz(turn * 0.58))


# ====================================================================== dragging
def idle_pose(rig, f, n=150):
    """Standing over the cart, side on, weight rocking slowly, the head turned and listening."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    br = math.sin(t * math.tau * 3)
    sway = math.sin(t * math.tau) * 0.8 + 0.25 * math.sin(t * math.tau * 2 + 0.7)
    listen = math.sin(t * math.tau * 2 + 1.4)
    p.hips = Vector((0.010 * s * sway, 0.0, -0.006 * s + 0.002 * s * br))
    spine(p, lean=LEAN + 0.015 * br, yaw=0.10 + 0.03 * sway, roll=0.03 * sway, breathe=br, neck_comp=0.0)
    _head(p, out=1.0 + 0.05 * br, cock=1.0 + 0.12 * listen, turn=TURN * 0.82 + 0.08 * listen)
    for side, sg, spread in (('L', 1.0, 1.35), ('R', -1.0, 1.05)):
        ball = Vector((rig.ball[side].x * spread, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=(0.28 if side == 'L' else 0.10))
    arm_hang(p, 'L', swing=0.05 + 0.03 * sway, abduct=0.10, bend=0.20, wrist=0.05, twist=0.0)
    hand_relax(p, 'L', curl=0.32, thumb=0.15)
    _hand_on_handle(p, rig)
    _cart(p, 0.0, jostle=0.25 * sway, spin=0.0)
    return p


def drag_pose(rig, f, n=52):
    """The sideways drag-walk: it side-steps toward its own left (+X) with the cart hauled along on
    its right, the trunk upright and square on, the head turned over its shoulder to where it is
    going. The lead (left) foot reaches out, the trailing (right) foot is pulled in after it."""
    ph = f / n
    T = n / FPS
    v = DRAG_SPEED
    s = rig.body.s
    p = Pose(rig)
    stride = v * T
    heave = math.cos(math.tau * (ph - 0.15))            # +1 when its weight is over the lead foot
    p.hips = Vector((0.018 * s * heave, 0.0, -0.022 * s + 0.014 * s * math.cos(math.tau * 2 * ph)))
    spine(p, lean=LEAN + 0.03, yaw=0.12 - 0.06 * heave, roll=0.05 * heave,
          breathe=0.4 * math.sin(math.tau * 2 * ph), neck_comp=0.0)
    _head(p, out=1.0, cock=0.85, turn=TURN + 0.06 * math.sin(math.tau * ph))
    # both feet travel in +X: planted they slide back at exactly the body's speed, swung they reach out
    for side, off, duty, lift, spread in (('L', 0.0, 0.56, 0.055 * s, 1.35), ('R', 0.5, 0.60, 0.030 * s, 1.00)):
        q = (ph + off) % 1.0
        front = stride * duty * 0.5
        if q < duty:
            u = q / duty
            x = front - stride * u
            zb = rig.ball[side].z
            pitch = 0.08 + 0.40 * smooth01((u - 0.55) / 0.45) ** 1.5
        else:
            w = (q - duty) / (1 - duty)
            x = lerp(front - stride * duty, front, smooth01(w))
            zb = rig.ball[side].z + lift * math.sin(math.pi * w)
            pitch = lerp(0.48, 0.05, smooth01(w * 1.4))
        bx = rig.ball[side].x * spread + x
        planted(p, side, Vector((bx, rig.ball[side].y, zb)), pitch, yaw=(0.30 if side == 'L' else 0.10))
    # the free (left) arm swings a little across the front; the right one stays on the handle
    sw = math.cos(math.tau * (ph - 0.1))
    arm_hang(p, 'L', swing=0.16 + 0.22 * sw, abduct=0.12, bend=0.30, wrist=0.1, twist=0.1)
    hand_relax(p, 'L', curl=0.40)
    _hand_on_handle(p, rig, back=0.02 * math.sin(math.tau * ph))
    _cart(p, 0.06 * math.sin(math.tau * ph), jostle=math.sin(math.tau * 2 * ph),
          spin=-math.tau * 4.0 * ph)
    return p


def listen_pose(rig, f, n=40):
    """Frozen: it has stopped dead mid-step, its head round over one ear. Nothing moves but a tremor
    in the neck and the breath it is holding."""
    t = f / n
    s = rig.body.s
    p = Pose(rig)
    trem = math.sin(t * math.tau * 6) * math.sin(t * math.tau)
    p.hips = Vector((0.012 * s, 0.004 * s, -0.014 * s))
    spine(p, lean=LEAN + 0.04, yaw=0.16, roll=0.02, breathe=0.0, neck_comp=0.0)
    _head(p, out=1.12, cock=1.55 + 0.04 * trem, turn=TURN * 1.05 + 0.02 * trem)
    planted(p, 'L', Vector((rig.ball['L'].x * 1.45, rig.ball['L'].y, rig.ball['L'].z)), 0.0, yaw=0.32)
    planted(p, 'R', Vector((rig.ball['R'].x * 1.00, rig.ball['R'].y, rig.ball['R'].z)), 0.28, yaw=0.10)
    arm_hang(p, 'L', swing=0.10, abduct=0.11, bend=0.26, wrist=0.05, twist=0.1)
    hand_relax(p, 'L', curl=0.45)
    _hand_on_handle(p, rig)
    _cart(p, 0.0, jostle=0.0, spin=0.0)
    return p


def charge_pose(rig, f, n=36):
    """The charge: the head comes up off the end of the neck until the throat points where the echo
    is going, the jaw drops, the chest fills. The right hand never leaves the handle. Holds."""
    t = min(f / max(n - 1, 1), 1.0)
    k = smooth01(t)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.006 * s, 0.0, 0.010 * s * k))
    spine(p, lean=LEAN - 0.12 * k, yaw=0.14 + 0.10 * k, breathe=-1.2 * k, neck_comp=0.0)
    p.rel('neck', Rx(NECK_OUT * (1 - 0.70 * k) - 0.28 * k) @ Rz(TURN * 0.42))
    p.rel('head', Rx(HEAD_UP * (1 - k) - 0.48 * k) @ Ry(COCK * (1 - 0.7 * k)) @ Rz(TURN * 0.58))
    planted(p, 'L', Vector((rig.ball['L'].x * 1.35, rig.ball['L'].y, rig.ball['L'].z)), 0.0, yaw=0.28)
    planted(p, 'R', Vector((rig.ball['R'].x * 1.05, rig.ball['R'].y, rig.ball['R'].z)), 0.0, yaw=0.10)
    arm_hang(p, 'L', swing=lerp(0.10, -0.30, k), abduct=lerp(0.12, 0.36, k), bend=lerp(0.28, 0.70, k),
             wrist=-0.15, twist=0.2)
    hand_relax(p, 'L', curl=lerp(0.40, 0.15, k), thumb=0.3)
    _hand_on_handle(p, rig)
    _cart(p, 0.0, jostle=0.0, spin=0.0)
    return p


def echo_pose(rig, f, n=18):
    """The pulse leaves: the head punches out off the charge and the chest empties, then it settles
    back a little. One-shot, straight out of SonoCharge's last frame."""
    t = min(f / max(n - 1, 1), 1.0)
    punch = smooth01(t / 0.22)
    back = smooth01((t - 0.35) / 0.65)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.006 * s, -0.008 * s * punch, 0.010 * s * (1 - back * 0.7)))
    spine(p, lean=LEAN - 0.12 + 0.26 * punch - 0.12 * back, yaw=0.24 - 0.06 * back,
          breathe=lerp(-1.2, 0.6, punch), neck_comp=0.0)
    p.rel('neck', Rx(-0.28 + 0.56 * punch - 0.20 * back) @ Rz(TURN * 0.42))
    p.rel('head', Rx(-0.48 + 0.38 * punch + 0.10 * back) @ Ry(COCK * 0.3 * back) @ Rz(TURN * 0.58))
    planted(p, 'L', Vector((rig.ball['L'].x * 1.35, rig.ball['L'].y, rig.ball['L'].z)), 0.0, yaw=0.28)
    planted(p, 'R', Vector((rig.ball['R'].x * 1.05, rig.ball['R'].y, rig.ball['R'].z)), 0.0, yaw=0.10)
    arm_hang(p, 'L', swing=lerp(-0.30, 0.10, back), abduct=lerp(0.36, 0.14, back), bend=0.50, wrist=-0.1, twist=0.2)
    hand_relax(p, 'L', curl=lerp(0.15, 0.40, back), thumb=0.3)
    _hand_on_handle(p, rig)
    _cart(p, 0.0, jostle=0.0, spin=0.0)
    return p


# ====================================================================== rushing
def turn_pose(rig, f, n=26):
    """Out of the drag and round to face you: the head comes round first, the hips swing after it,
    the feet shuffle in under the body, and the cart is hauled round behind on its pivot. One-shot,
    and it ends in exactly the pose SonoRush starts from."""
    t = min(f / max(n - 1, 1), 1.0)
    k = smooth01(t)
    early = smooth01(t / 0.45)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.016 * s * (1 - k), 0.0, -0.030 * s * math.sin(math.pi * t) - 0.012 * s))
    spine(p, lean=LEAN + 0.10 * k, yaw=lerp(0.12, -0.10, k), roll=0.08 * math.sin(math.pi * t), neck_comp=0.0)
    # the head is already round at the start and unwinds as the body catches it up
    _head(p, out=lerp(1.0, 0.8, k), cock=lerp(0.85, 0.35, k), turn=TURN * (1.0 - early))
    for side, sg, spread in (('L', 1.0, 1.35), ('R', -1.0, 1.05)):
        bx = rig.ball[side].x * lerp(spread, 1.0, k)
        by = rig.ball[side].y + (0.10 * s * k if side == 'R' else -0.06 * s * k)
        lift = 0.05 * s * math.sin(math.pi * min(1.0, t / 0.8)) * (1.0 if side == 'R' else 0.5)
        planted(p, side, Vector((bx, by, rig.ball[side].z + lift)), 0.15 * k,
                yaw=lerp(0.30 if side == 'L' else 0.10, sg * 0.08, k))
    arm_hang(p, 'L', swing=lerp(0.16, 0.85, k), abduct=lerp(0.12, 0.30, k), bend=lerp(0.30, 0.75, k),
             wrist=0.1, twist=0.1)
    hand_relax(p, 'L', curl=lerp(0.40, 0.25, k))
    _hand_on_handle(p, rig, back=0.30 * k, out=0.16 * k)
    _cart(p, CART_BEHIND * k, jostle=2.0 * math.sin(math.pi * t), spin=-6.0 * k)
    return p


def rush_pose(rig, f, n=30):
    """Head on, at speed: long strides, the trunk driving forward but still upright, the left arm
    thrown out ahead and flailing, the right arm back hauling the cart, which bounces along behind."""
    s = rig.body.s
    p = gait_pose(rig, f, n, RUSH_SPEED, 0.38, 0.115 * s, LEAN + 0.22, 0.030 * s, True, 0.0, 0.0, arms=False)
    ph = f / n
    _head(p, out=0.70, cock=0.30, turn=0.08 * math.sin(math.tau * ph))
    # the left arm is not running, it is reaching: thrown out in front and thrashing
    flail = math.sin(math.tau * ph * 2.0)
    arm_hang(p, 'L', swing=1.55 + 0.35 * flail, abduct=0.26 + 0.18 * math.sin(math.tau * (ph * 2.0 + 0.25)),
             bend=0.45 - 0.30 * flail, wrist=-0.35 + 0.3 * flail, twist=0.25)
    hand_relax(p, 'L', curl=0.30 + 0.35 * (0.5 + 0.5 * flail), thumb=0.2)
    _hand_on_handle(p, rig, back=0.30, out=0.16)
    _cart(p, CART_BEHIND + 0.07 * math.sin(math.tau * ph), jostle=2.0 * math.sin(math.tau * 2 * ph),
          spin=-math.tau * 6.0 * ph)
    return p


# the wail: four left-handed blows with a gap after the second and after the fourth, so there is
# always a way out of it
_BLOWS = (0.00, 0.17, 0.46, 0.63)
_BLOW_LEN = 0.15


def wail_pose(rig, f, n=78):
    """A one-armed flurry: the left arm comes over and down again and again, with two pauses in it.
    The right arm never lets go of the cart, so the whole machine rocks with every blow."""
    t = min(f / max(n - 1, 1), 1.0)
    s = rig.body.s
    p = Pose(rig)
    k = 0.0
    for t0 in _BLOWS:
        u = (t - t0) / _BLOW_LEN
        if -0.45 <= u <= 1.0:
            k = smooth01(u) if u >= 0.0 else -smooth01(-u / 0.45) * 0.55
    drive = max(0.0, k)
    up = max(0.0, -k)
    p.hips = Vector((-0.012 * s * drive, -0.030 * s * drive, -0.016 * s - 0.010 * s * drive))
    spine(p, lean=LEAN + 0.10 + 0.30 * drive, yaw=-0.16 * drive + 0.10 * up,
          roll=0.10 * up - 0.06 * drive, neck_comp=0.0)
    _head(p, out=0.55, cock=0.25, jaw=0.6 + 0.4 * drive)
    planted(p, 'L', Vector((rig.ball['L'].x * 1.05, rig.ball['L'].y - 0.10 * s, rig.ball['L'].z)), 0.0, yaw=0.08)
    planted(p, 'R', Vector((rig.ball['R'].x * 1.05, rig.ball['R'].y + 0.10 * s, rig.ball['R'].z)), 0.18, yaw=-0.08)
    arm_hang(p, 'L', swing=lerp(0.35, -0.60, up) + 2.00 * drive, abduct=0.22 + 0.18 * up,
             bend=lerp(1.20, 1.60, up) - 1.00 * drive, wrist=-0.2 + 0.5 * drive, twist=0.2)
    hand_relax(p, 'L', curl=0.92 - 0.25 * drive, thumb=0.5)
    _hand_on_handle(p, rig, back=0.28, out=0.14)
    _cart(p, CART_BEHIND, jostle=3.0 * drive, spin=-0.6 * drive)
    return p


def stagger_pose(rig, f, n=24):
    """Shoved: the chest goes back off its feet, the long neck whips after it, the cart jerks."""
    t = min(f / max(n - 1, 1), 1.0)
    hit = smooth01(t / 0.25)
    recover = smooth01((t - 0.40) / 0.60)
    k = hit * (1.0 - recover)
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.055 * s * k, -0.035 * s * k))
    spine(p, lean=LEAN - 0.42 * k, yaw=0.12 + 0.14 * k, roll=-0.10 * k, neck_comp=0.0)
    p.rel('neck', Rx(NECK_OUT + 0.55 * k) @ Rz(TURN * 0.30))
    p.rel('head', Rx(HEAD_UP - 0.20 * k) @ Ry(COCK * (1 + 0.8 * k)) @ Rz(TURN * 0.40))
    planted(p, 'L', Vector((rig.ball['L'].x * 1.20, rig.ball['L'].y + 0.16 * s * k, rig.ball['L'].z)), 0.10 * k, yaw=0.20)
    planted(p, 'R', Vector((rig.ball['R'].x * 1.05, rig.ball['R'].y + 0.05 * s * k, rig.ball['R'].z)), 0.0, yaw=0.0)
    arm_hang(p, 'L', swing=0.10 + 1.05 * k, abduct=0.14 + 0.30 * k, bend=0.30 + 0.35 * k, wrist=-0.3 * k, twist=0.1)
    hand_relax(p, 'L', curl=0.35 - 0.20 * k, thumb=0.2)
    _hand_on_handle(p, rig, back=0.10 * k)
    _cart(p, 0.22 * k, jostle=4.0 * k, spin=1.5 * k)
    return p


def lying_sono(rig, f, n=90):
    """On its back on the table. No cart: the game hides the cart's pieces in this mode and leaves a
    copy of it standing wherever the Sonographer went down."""
    return lying_pose(rig, f, n)


FNS = {
    'SonoIdle': idle_pose,
    'SonoDrag': drag_pose,
    'SonoListen': listen_pose,
    'SonoCharge': charge_pose,
    'SonoEcho': echo_pose,
    'SonoTurn': turn_pose,
    'SonoRush': rush_pose,
    'SonoWail': wail_pose,
    'SonoStagger': stagger_pose,
    'SonoLying': lying_sono,
}


def build_actions(arm, body):
    global _ANCHOR
    _ANCHOR = None
    rig = hu_rig.Rig(arm, body)
    for name, (frames, loop, speed, _) in CLIPS.items():
        hu_rig.keyframe_action(arm, rig, name, frames, loop, FNS[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    return rig
