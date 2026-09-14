"""Armature, skinning and the hand-authored procedural clips shared by every human variation.

Posing works in armature space. A pose sets, per bone, an absolute rotation delta W (how the bone is
turned from its rest orientation, in armature axes) or a relative one R (on top of its parent). Limbs are
solved with analytic two-bone IK against targets, so a planted foot moves at exactly the clip's speed.
Clips are in place: no root motion. 30 frames per second.

Blender axes: Z up, the character faces -Y, its left is +X.
"""
import math
import bpy
from mathutils import Vector, Matrix, Quaternion
from hu_mesh import smooth01, lerp, clamp, mirror_bone
import hu_body

FPS = 30
FINGERS = ['index', 'middle', 'ring', 'pinky', 'thumb']

# clip name: (frames, loop, speed m/s or None, what it is)
CLIPS = {
    'Idle': (120, True, 0.0, 'standing, breathing, weight shifts, looks around'),
    'Walk': (32, True, 1.40, 'walk, planted feet keep pace at 1.40 m/s'),
    'Jog': (22, True, 3.40, 'the players\' walk speed (C.WALK_SPEED 3.4)'),
    'Sprint': (18, True, 5.60, 'C.SPRINT_SPEED 5.6'),
    'Push': (34, True, 1.25, 'pushing a gurney: hands on a bar 0.98 m up, 0.50 m ahead; crew speed 1.25'),
    'Interact': (30, False, None, 'reach forward and press/grab at chest height, one-shot'),
    'PickUp': (42, False, None, 'squat, grab from the floor 0.40 m ahead, stand up holding it, one-shot'),
    'Crawl': (48, True, 0.75, 'downed: prone crawl, planted hands keep pace at CRAWL_SPEED 0.75'),
    'Carried': (60, True, None, 'slung over a carrier\'s right shoulder; origin = the belly contact point'),
    'Carrying': (60, True, None, 'carrier holding a body on the right shoulder (arms and upper body only)'),
    'Lying': (90, True, None, 'on the back on a table, breathing; origin = middle of the back on the table top'),
}


# ====================================================================== armature
def bone_defs(body):
    J = body.joints
    defs = [('hips', 'root'), ('spine', 'hips'), ('chest', 'spine'), ('upperchest', 'chest'), ('neck', 'upperchest'), ('head', 'neck'),
            ('shoulder.L', 'upperchest'), ('upperarm.L', 'shoulder.L'), ('forearm.L', 'upperarm.L'), ('hand.L', 'forearm.L'),
            ('thigh.L', 'hips'), ('shin.L', 'thigh.L'), ('foot.L', 'shin.L'), ('toe.L', 'foot.L')]
    for f in FINGERS:
        for k in range(3):
            defs.append(('%s%d.L' % (f, k + 1), 'hand.L' if k == 0 else '%s%d.L' % (f, k)))
    out = []
    for name, parent in defs:
        h, t = J[name]
        out.append((name, Vector(h), Vector(t), parent))
        if name.endswith('.L'):
            out.append((mirror_bone(name), Vector((-h.x, h.y, h.z)), Vector((-t.x, t.y, t.z)), mirror_bone(parent)))
    return out


def build_armature(body, name='Human_Rig'):
    arm_data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones
    root = eb.new('root')
    root.head, root.tail = (0, 0, 0), (0, 0, 0.2)
    defs = bone_defs(body)
    for n, h, t, p in defs:
        b = eb.new(n)
        b.head, b.tail = h, t
    for n, h, t, p in defs:
        b = eb[n]
        b.parent = eb[p]
        b.use_connect = (h - eb[p].tail).length < 1e-4 and p != 'root'
        d = (t - h).normalized()
        # roll: bone Z towards the front for vertical bones, up for the rest
        if abs(d.z) > 0.7:
            b.align_roll(Vector((0, -1, 0)))
        elif n.startswith(('foot', 'toe')):
            b.align_roll(Vector((0, 0, 1)))
        else:
            b.align_roll(Vector((0, 0, 1)) if abs(d.y) > 0.7 else Vector((0, -1, 0)))
    bpy.ops.object.mode_set(mode='OBJECT')
    for b in arm.data.bones:
        b.use_deform = b.name != 'root'
    return arm


def skin(obj, arm):
    obj.parent = arm
    mod = obj.modifiers.new('Armature', 'ARMATURE')
    mod.object = arm


# ====================================================================== posing
class Rig:
    def __init__(self, arm, body):
        self.arm = arm
        self.body = body
        self.bones = {}
        for b in arm.data.bones:
            self.bones[b.name] = {
                'head': b.head_local.copy(), 'tail': b.tail_local.copy(), 'M': b.matrix_local.to_3x3(),
                'parent': b.parent.name if b.parent else None}
        order = []

        def visit(n):
            if n in order:
                return
            p = self.bones[n]['parent']
            if p:
                visit(p)
            order.append(n)
        for n in self.bones:
            visit(n)
        self.order = order
        self.len = {n: (d['tail'] - d['head']).length for n, d in self.bones.items()}
        J = body.J
        self.ball = {'L': Vector(J['ball']), 'R': Vector((-J['ball'].x, J['ball'].y, J['ball'].z))}


class Pose:
    def __init__(self, rig):
        self.rig = rig
        self.W = {}
        self.R = {}
        self.hips = Vector()
        self._fk = None

    # -------------------------------------------------------------- setters
    def rel(self, bone, M):
        self.R[bone] = M @ self.R.get(bone, Matrix.Identity(3))
        self._fk = None

    def absolute(self, bone, M):
        self.W[bone] = M
        self._fk = None

    def aim(self, bone, direction, ref=None):
        """Turn `bone` so it points along `direction`; `ref` (optional) is where its rest front (-Y, or
        up for bones along Y) should face."""
        b = self.rig.bones[bone]
        d0 = (b['tail'] - b['head']).normalized()
        r0 = Vector((0, -1, 0)) if abs(d0.y) < 0.8 else Vector((0, 0, 1))
        d1 = Vector(direction).normalized()
        if ref is None:
            W = d0.rotation_difference(d1).to_matrix()
        else:
            W = frame(d1, Vector(ref)) @ frame(d0, r0).inverted()
        self.absolute(bone, W)

    # -------------------------------------------------------------- evaluation
    def fk(self):
        if self._fk is not None:
            return self._fk
        rig = self.rig
        Wf, head, tail = {}, {}, {}
        for n in rig.order:
            b = rig.bones[n]
            p = b['parent']
            Wp = Wf[p] if p else Matrix.Identity(3)
            if n in self.W:
                W = self.W[n]
            else:
                W = Wp @ self.R.get(n, Matrix.Identity(3))
            Wf[n] = W
            if p is None:
                h = b['head'].copy()
            else:
                h = head[p] + Wp @ (b['head'] - rig.bones[p]['head'])
            if n == 'hips':
                h = h + self.hips
            head[n] = h
            tail[n] = h + W @ (b['tail'] - b['head'])
        self._fk = (Wf, head, tail)
        return self._fk

    def world(self, bone, rest_point):
        """Where a rest-pose point that follows `bone` ends up."""
        Wf, head, _ = self.fk()
        return head[bone] + Wf[bone] @ (Vector(rest_point) - self.rig.bones[bone]['head'])

    def apply(self, arm, frame_no=None):
        Wf, head, _ = self.fk()
        rig = self.rig
        for pb in arm.pose.bones:
            n = pb.name
            b = rig.bones[n]
            p = b['parent']
            Wp = Wf[p] if p else Matrix.Identity(3)
            rel = Wp.inverted() @ Wf[n]
            M = b['M']
            q = (M.inverted() @ rel @ M).to_quaternion()
            pb.rotation_mode = 'QUATERNION'
            pb.rotation_quaternion = q
            if n == 'hips':
                pb.location = M.inverted() @ self.hips
            else:
                pb.location = (0, 0, 0)
            if frame_no is not None:
                pb.keyframe_insert('rotation_quaternion', frame=frame_no)
                if n == 'hips':
                    pb.keyframe_insert('location', frame=frame_no)

    # -------------------------------------------------------------- IK
    def two_bone(self, upper, lower, target, hint, twist_ref=None):
        """Solve upper/lower so lower's tail reaches target; the middle joint bends towards `hint`."""
        Wf, head, tail = self.fk()
        A = head[upper]
        l1, l2 = self.rig.len[upper], self.rig.len[lower]
        d = Vector(target) - A
        D = clamp(d.length, abs(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
        dh = d.normalized()
        ca = clamp((l1 * l1 + D * D - l2 * l2) / (2 * l1 * D), -1.0, 1.0)
        sa = math.sqrt(1 - ca * ca)
        h = Vector(hint)
        u = (h - dh * h.dot(dh))
        if u.length < 1e-6:
            u = Vector((0, 0, 1)) - dh * dh.z
        u.normalize()
        mid = A + dh * (l1 * ca) + u * (l1 * sa)
        end = A + dh * D
        ref = u if twist_ref is None else twist_ref
        self.aim(upper, mid - A, ref)
        self.aim(lower, end - mid, ref)
        return mid, end


def frame(d, ref):
    x = d.normalized()
    y = ref - x * ref.dot(x)
    if y.length < 1e-6:
        y = Vector((0, 0, 1)) - x * x.z
    y.normalize()
    z = x.cross(y)
    return Matrix((x, y, z)).transposed()


def Rx(a):
    return Matrix.Rotation(a, 3, 'X')


def Ry(a):
    return Matrix.Rotation(a, 3, 'Y')


def Rz(a):
    return Matrix.Rotation(a, 3, 'Z')


def mirror_v(v, side):
    return Vector((v.x * side, v.y, v.z))


# ====================================================================== pieces of poses
def spine(pose, lean=0.0, yaw=0.0, roll=0.0, breathe=0.0, look=(0.0, 0.0), neck_comp=1.0, hips_rot=None):
    """Pitch the trunk forward by `lean` (spread over the spine), twist and roll, keep the head level."""
    H = hips_rot if hips_rot is not None else Rx(lean * 0.35) @ Rz(yaw) @ Ry(roll)
    pose.absolute('hips', H)
    pose.rel('spine', Rx(lean * 0.25) @ Rz(-yaw * 0.45))
    pose.rel('chest', Rx(lean * 0.22 - breathe * 0.020) @ Rz(-yaw * 0.40))
    pose.rel('upperchest', Rx(lean * 0.18 - breathe * 0.012) @ Rz(-yaw * 0.35) @ Ry(-roll * 0.8))
    pose.rel('neck', Rx(-lean * 0.45 * neck_comp + look[1] * 0.4) @ Rz(look[0] * 0.4))
    pose.rel('head', Rx(-lean * 0.55 * neck_comp + look[1] * 0.6) @ Rz(look[0] * 0.6))


def hand_relax(pose, side, curl=0.35, spread=0.0, thumb=0.2):
    rig = pose.rig
    sfx = '.' + side
    for i, f in enumerate(FINGERS):
        for k in range(3):
            n = '%s%d%s' % (f, k + 1, sfx)
            b = rig.bones[n]
            d0 = (b['tail'] - b['head']).normalized()
            hb = rig.bones['hand' + sfx]
            # the palm side of the hand in rest: the hand's frame B (towards the body and down)
            T, N, B = rig.body.arm_frame()
            if side == 'R':
                B = Vector((-B.x, B.y, B.z))
            axis = d0.cross(B)
            if axis.length < 1e-6:
                continue
            axis.normalize()
            c = curl * (1.0 + 0.25 * i) * (0.8 if k == 0 else 1.0)
            if f == 'thumb':
                c = thumb * (0.6 + 0.3 * k)
            pose.rel(n, Matrix.Rotation(c, 3, axis))


def arm_hang(pose, side, swing=0.0, abduct=0.16, bend=0.25, wrist=0.0, twist=0.0):
    """An arm hanging from the shoulder, swung forward (+) or back (-)."""
    sg = 1.0 if side == 'L' else -1.0
    Wf, head, tail = pose.fk()
    # directions in the chest's frame so the arms follow the trunk
    C = Wf['upperchest']
    down = Vector((sg * math.sin(abduct), 0.0, -math.cos(abduct)))
    S = Rx(-swing)
    ua = C @ S @ down
    thumb = C @ S @ Rz(sg * twist) @ Vector((sg * 0.25, -1.0, 0.0))
    pose.aim('upperarm.' + side, ua, thumb)
    fa = C @ S @ Rx(-bend) @ down
    thumb_f = C @ S @ Rx(-bend) @ Rz(sg * twist) @ Vector((sg * 0.35, -1.0, 0.0))
    pose.aim('forearm.' + side, fa, thumb_f)
    pose.aim('hand.' + side, C @ S @ Rx(-bend - wrist) @ down, thumb_f)


def arm_to(pose, side, target, elbow_hint, palm_ref=None, hand_dir=None):
    sg = 1.0 if side == 'L' else -1.0
    mid, end = pose.two_bone('upperarm.' + side, 'forearm.' + side, target, elbow_hint)
    fwd = (end - mid).normalized()
    ref = palm_ref if palm_ref is not None else Vector((0, 0, 1))
    pose.aim('hand.' + side, hand_dir if hand_dir is not None else fwd, ref)


def leg_to(pose, side, ankle, knee_hint, foot_W):
    pose.two_bone('thigh.' + side, 'shin.' + side, ankle, knee_hint)
    pose.absolute('foot.' + side, foot_W)
    pose.rel('toe.' + side, Matrix.Identity(3))


def planted(pose, side, ball, pitch, yaw=0.0):
    """Foot placement from the ball of the foot: pitch > 0 lifts the heel (rolling over the toes)."""
    rig = pose.rig
    J = rig.body.J
    sg = 1.0 if side == 'L' else -1.0
    ank_rest = Vector((J['ankle'].x * sg, J['ankle'].y, J['ankle'].z))
    ball_rest = rig.ball[side]
    F = Rz(yaw) @ Rx(pitch)
    ankle = Vector(ball) + F @ (ank_rest - ball_rest)
    # the toes stay on the ground while the heel lifts
    foot_W = F
    leg_to(pose, side, ankle, Rz(yaw) @ Vector((sg * 0.12, -1.0, 0.25)), foot_W)
    if pitch > 0:
        pose.absolute('toe.' + side, Rz(yaw) @ Rx(min(pitch, 0.0) * 0.0))
    return ankle


# ====================================================================== clips
def idle_pose(rig, f, n=120, lean=0.0, yaw=0.0, roll=0.0, look_add=(0.0, 0.0), arms=True):
    t = f / n
    p = Pose(rig)
    s = rig.body.s
    br = math.sin(t * math.tau * 3)                     # three breaths in four seconds
    shift = math.sin(t * math.tau) * 0.5 + 0.5 * math.sin(t * math.tau * 2 + 0.7) * 0.3
    p.hips = Vector((0.018 * s * shift, 0.004 * s, -0.012 * s + 0.002 * s * br))
    look = (0.20 * math.sin(t * math.tau + 0.4) * smooth01(abs(math.sin(t * math.tau * 0.5)) * 1.5) + look_add[0],
            0.04 * math.sin(t * math.tau * 2) + look_add[1])
    spine(p, lean=0.02 + lean, yaw=0.04 * math.sin(t * math.tau) + yaw, roll=-0.03 * shift + roll, breathe=br, look=look)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 1.05, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.10)
        if arms:
            arm_hang(p, side, swing=0.04 + 0.015 * br, abduct=0.13 + 0.01 * br, bend=0.22, wrist=0.05, twist=0.05)
            hand_relax(p, side, curl=0.30 + 0.04 * math.sin(t * math.tau * 2 + sg))
    return p


def gait_pose(rig, f, n, v, duty, lift, lean, bob, run, arm_swing, elbow, stride_bias=0.0, arms=True, crouch=0.0):
    ph = f / n
    T = n / FPS
    p = Pose(rig)
    s = rig.body.s
    J = rig.body.J
    travel = v * T * duty
    front = travel * lerp(0.42, 0.36, 1.0 if run else 0.0) + stride_bias
    # hips: bob twice a cycle, sway over the stance foot
    if run:
        z = -crouch - 0.02 * s + bob * math.cos(math.tau * (2 * ph - duty))        # low at mid-stance
    else:
        z = -crouch - 0.018 * s + bob * math.cos(math.tau * (2 * ph - duty))
    sway = 0.018 * s * math.sin(math.tau * (ph - duty * 0.5 + 0.25)) * (0.4 if run else 1.0)
    p.hips = Vector((sway, 0.0, z))
    yaw = -0.10 * math.cos(math.tau * ph) * (1.3 if run else 1.0)
    roll = 0.035 * math.sin(math.tau * (ph - 0.25))
    spine(p, lean=lean, yaw=yaw, roll=roll, breathe=0.3 * math.sin(math.tau * 2 * ph))
    for side, off, sg in (('L', 0.0, 1.0), ('R', 0.5, -1.0)):
        q = (ph + off) % 1.0
        bx = rig.ball[side].x * 0.92
        if q < duty:
            u = q / duty
            y = -front + v * T * q
            zb = rig.ball[side].z
            pitch = lerp(-0.18 if not run else 0.0, 0.0, smooth01(u / 0.15)) + (0.95 if run else 0.75) * smooth01((u - 0.50) / 0.50) ** 1.5
            if u < 0.12 and not run:
                # heel strike: the ball comes down onto the ground
                zb += 0.035 * s * (1 - smooth01(u / 0.12))
        else:
            w = (q - duty) / (1 - duty)
            y0 = -front + v * T * duty
            y1 = -front
            e = smooth01(w)
            y = lerp(y0, y1, e)
            zb = rig.ball[side].z + lift * math.sin(math.pi * w) ** (0.8 if run else 1.2) + (0.02 * s if run else 0.0) * math.sin(math.pi * w)
            pitch = lerp(0.95 if run else 0.75, -0.25 if not run else 0.10, smooth01(w * 1.4))
        planted(p, side, Vector((bx, rig.ball[side].y + y, zb)), pitch, yaw=sg * 0.05)
        if arms:
            q2 = (ph + off + 0.5) % 1.0
            sw = arm_swing * -math.cos(math.tau * (q2 - 0.02))
            arm_hang(p, side, swing=sw, abduct=0.14 + (0.10 if run else 0.0), bend=elbow + max(0.0, sw) * (0.5 if run else 0.3), wrist=0.1, twist=0.1)
            hand_relax(p, side, curl=0.45 if run else 0.30)
    return p


def push_pose(rig, f, n=34):
    p = gait_pose(rig, f, n, 1.25, 0.60, 0.07 * rig.body.s, 0.20, 0.010 * rig.body.s, False, 0.0, 0.0, arms=False)
    s = rig.body.s
    sway = 0.012 * s * math.sin(math.tau * f / n)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        target = Vector((sg * 0.22 * s + sway * 0.3, -0.50 * s, 0.98 * s))
        arm_to(p, side, target, Vector((sg * 0.6, 0.3, -1.0)), palm_ref=Vector((0, 0, 1)), hand_dir=Vector((sg * -0.2, -1.0, -0.15)))
        hand_relax(p, side, curl=0.75, thumb=0.5)
    return p


def interact_pose(rig, f, n=30):
    t = f / (n - 1)
    s = rig.body.s
    reach = smooth01(t / 0.35) * (1 - smooth01((t - 0.62) / 0.38))
    press = math.exp(-((t - 0.48) / 0.08) ** 2)
    p = idle_pose(rig, 0, 120, lean=0.10 * reach, yaw=-0.12 * reach, look_add=(-0.10 * reach, -0.18 * reach), arms=False)
    target = Vector((-0.12 * s, -0.56 * s - 0.03 * s * press, 1.18 * s))
    Wf, head, tail = p.fk()
    idle_hand = Vector((-0.30 * s, -0.08 * s, 0.86 * s))
    goal = idle_hand.lerp(target, reach)
    arm_to(p, 'R', goal, Vector((-0.8, 0.4, -0.6)), palm_ref=Vector((1, 0, 0)), hand_dir=Vector((0.05, -1.0, 0.15 - 0.6 * press)))
    hand_relax(p, 'R', curl=lerp(0.30, 0.10, reach) + 0.4 * press, thumb=0.3)
    arm_hang(p, 'L', swing=0.05, abduct=0.13, bend=0.25)
    hand_relax(p, 'L', curl=0.30)
    return p


def pickup_pose(rig, f, n=42):
    t = f / (n - 1)
    s = rig.body.s
    J = rig.body.J
    down = smooth01(t / 0.42) * (1 - smooth01((t - 0.62) / 0.38))
    grab = smooth01((t - 0.40) / 0.08)
    p = Pose(rig)
    p.hips = Vector((0.0, 0.17 * s * down, -0.36 * s * down))
    spine(p, lean=1.30 * down, breathe=0.0, look=(0.0, -0.20 * down), neck_comp=0.6)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 1.25, rig.ball[side].y - 0.02 * s, rig.ball[side].z))
        planted(p, side, ball, 0.35 * down, yaw=sg * 0.22)
        # knees go forward and out over the toes
        ank = p.world('foot.' + side, rig.bones['foot.' + side]['head'])
        leg_to(p, side, ank, Vector((sg * 0.5, -1.0, 0.1)), Rz(sg * 0.22) @ Rx(0.35 * down))
    floor = Vector((0.0, -0.36 * s, 0.09 * s))
    held = Vector((0.0, -0.30 * s, 1.00 * s))
    for side, sg in (('L', 1.0), ('R', -1.0)):
        hang = Vector((sg * 0.28 * s, -0.10 * s, 0.85 * s))
        grip = floor + Vector((sg * 0.10 * s, 0, 0))
        hold = held + Vector((sg * 0.12 * s, 0, 0))
        if t < 0.45:
            goal = hang.lerp(grip, smooth01(t / 0.45))
        else:
            goal = grip.lerp(hold, smooth01((t - 0.45) / 0.55))
        arm_to(p, side, goal, Vector((sg * 1.0, 0.3, -0.2)), palm_ref=Vector((-sg, 0, 0)), hand_dir=Vector((0, -0.3, -1.0)).lerp(Vector((0, -1, 0)), smooth01((t - 0.5) / 0.4)))
        hand_relax(p, side, curl=lerp(0.25, 0.9, grab), thumb=lerp(0.2, 0.7, grab))
    return p


def crawl_pose(rig, f, n=48):
    """Downed prone crawl: belly low, head up, alternate arms reach and pull, one knee drives."""
    ph = f / n
    T = n / FPS
    v = 0.75
    s = rig.body.s
    J = rig.body.J
    p = Pose(rig)
    duty = 0.55
    travel = v * T * duty
    body_W = Rx(math.radians(90))           # prone: head forward (-Y), front down
    wob = math.sin(math.tau * ph)
    H = Rz(0.10 * wob) @ body_W @ Ry(0.06 * wob)
    # hips low over the floor
    hip_h = 0.14 * s + 0.012 * s * abs(math.sin(math.tau * ph))
    rest_h = J['hips']
    p.hips = Vector((0.03 * s * wob, 0.0, hip_h - rest_h.z))
    p.absolute('hips', H)
    p.rel('spine', Rx(-0.10) @ Rz(-0.06 * wob))
    p.rel('chest', Rx(-0.16) @ Rz(-0.06 * wob))
    p.rel('upperchest', Rx(-0.14))
    p.rel('neck', Rx(-0.35) @ Rz(0.05 * wob))
    p.rel('head', Rx(-0.30))
    # after rotating, the hips head sits where? place so the pelvis front is just above the floor
    for side, off, sg in (('L', 0.0, 1.0), ('R', 0.5, -1.0)):
        q = (ph + off) % 1.0
        Wf, head, tail = p.fk()
        sh = head['upperarm.' + side]
        if q < duty:
            u = q / duty
            y = -0.30 * s - travel * 0.5 + v * T * q
            z = 0.02 * s
        else:
            w = (q - duty) / (1 - duty)
            y = lerp(-0.30 * s + travel * 0.5, -0.30 * s - travel * 0.5, smooth01(w))
            z = 0.02 * s + 0.08 * s * math.sin(math.pi * w)
        # hands relative to the chest's forward reach
        base_y = sh.y
        hand = Vector((sh.x + sg * 0.10 * s, base_y + y, z))
        arm_to(p, side, hand, Vector((sg * 1.0, 0.2, 0.6)), palm_ref=Vector((sg * -0.3, -1.0, 0.0)), hand_dir=Vector((sg * -0.15, -1.0, -0.4)))
        hand_relax(p, side, curl=0.5 if q < duty else 0.25, thumb=0.3)
        # legs: dragged, one knee pulls up while that side's arm pulls
        kq = (q + 0.25) % 1.0
        pull = max(0.0, math.sin(math.tau * kq))
        hip = head['thigh.' + side]
        ankle = Vector((hip.x + sg * (0.10 + 0.08 * pull) * s, hip.y + (0.80 - 0.35 * pull) * s, 0.10 * s + 0.05 * s * pull))
        leg_to(p, side, ankle, Vector((sg * 0.8, 0.0, -1.0)), Rx(math.radians(150)) @ Rz(sg * 0.3))
    return p


def lying_pose(rig, f, n=90):
    t = f / n
    s = rig.body.s
    J = rig.body.J
    p = Pose(rig)
    br = 0.5 - 0.5 * math.cos(math.tau * t * 2)
    W = Rx(math.radians(-90))                # face up, head towards +Y
    p.absolute('hips', W)
    p.rel('spine', Rx(0.02))
    p.rel('chest', Rx(-0.03 * br))
    p.rel('upperchest', Rx(-0.02 * br))
    p.rel('neck', Rx(0.10))
    p.rel('head', Rx(0.06))
    # origin at the middle of the back, on the table top
    body = rig.body
    back = Vector((0.0, body.T_RY(1.18 * s) + body.T_CY(1.18 * s) - 0.006 * s, 1.18 * s))
    p.hips = -(W @ (back - J['hips'])) - J['hips'] + Vector((0, 0, 0.004 * s * br))
    # arms along the sides, palms in, thumbs up
    for side, sg in (('L', 1.0), ('R', -1.0)):
        Wf, head, tail = p.fk()
        along = Vector((sg * 0.20, -1.0, 0.0)).normalized()      # towards the feet (-Y), a little out
        p.aim('upperarm.' + side, along, Vector((0, 0, 1)))
        p.aim('forearm.' + side, Vector((sg * 0.10, -1.0, 0.02)).normalized(), Vector((0, 0, 1)))
        p.aim('hand.' + side, Vector((sg * 0.02, -1.0, -0.05)).normalized(), Vector((0, 0, 1)))
        hand_relax(p, side, curl=0.35)
        p.aim('thigh.' + side, Vector((sg * 0.04, -1.0, 0.0)), Vector((0, 0, 1)))
        p.aim('shin.' + side, Vector((sg * 0.03, -1.0, 0.0)), Vector((0, 0, 1)))
        p.aim('foot.' + side, Vector((sg * 0.40, -0.25, 1.0)).normalized(), Vector((0, 1, 0)))
    return p


def carried_pose(rig, f, n=60):
    t = f / n
    s = rig.body.s
    J = rig.body.J
    p = Pose(rig)
    bounce = math.sin(math.tau * t * 2)
    swing = math.sin(math.tau * t)
    # the trunk hangs head-down behind the carrier (+Y), chest facing the carrier's back
    up = Vector((0.0, 0.42, -0.91)).normalized()
    front = Vector((0.0, -0.91, -0.42)).normalized()
    Rb = Matrix((front.cross(up) * -1, -front, up)).transposed()     # columns: X, Y(=back), Z(=up)
    H = Rz(0.05 * swing) @ Rb
    p.absolute('hips', H)
    p.rel('spine', Rx(0.10))
    p.rel('chest', Rx(0.12 + 0.02 * bounce))
    p.rel('upperchest', Rx(0.10))
    p.rel('neck', Rx(0.15 + 0.04 * bounce))
    p.rel('head', Rx(0.10) @ Rz(0.10 * swing))
    contact = Vector((0.0, -0.105 * s, 0.975 * s))                   # lower belly, on the shoulder
    p.hips = -(H @ (contact - J['hips'])) - J['hips'] + Vector((0, 0, 0.006 * s * bounce))
    Wf, head, tail = p.fk()
    for side, sg in (('L', 1.0), ('R', -1.0)):
        # arms dangle straight down behind the carrier
        p.aim('upperarm.' + side, Vector((sg * 0.18, 0.10 + 0.05 * swing * sg, -1.0)), Vector((0, -1, 0)))
        p.aim('forearm.' + side, Vector((sg * 0.10, 0.02 + 0.06 * swing * sg, -1.0)), Vector((0, -1, 0)))
        p.aim('hand.' + side, Vector((sg * 0.05, 0.0, -1.0)), Vector((0, -1, 0)))
        hand_relax(p, side, curl=0.4)
        # legs hang down the carrier's front, knees a little bent
        p.aim('thigh.' + side, Vector((sg * 0.10, -0.62, -0.78)), Vector((0, -0.8, 0.6)))
        p.aim('shin.' + side, Vector((sg * 0.05, -0.05 + 0.04 * swing, -1.0)), Vector((0, -1, 0)))
        p.aim('foot.' + side, Vector((sg * 0.1, -0.45, -1.0)), Vector((0, 0, 1)))
    return p


def carrying_pose(rig, f, n=60):
    """The carrier's upper body: right arm round the carried legs, shoulder hunched under the load."""
    t = f / n
    s = rig.body.s
    p = idle_pose(rig, int(t * 120) % 120, 120, lean=0.10, roll=0.08, arms=False)
    arm_to(p, 'R', Vector((-0.06 * s, -0.20 * s, 1.34 * s)), Vector((-1.0, -0.2, -0.6)), palm_ref=Vector((0, 1, 0)), hand_dir=Vector((1.0, 0.1, 0.0)))
    hand_relax(p, 'R', curl=0.7, thumb=0.5)
    arm_hang(p, 'L', swing=0.05, abduct=0.16, bend=0.30)
    return p


# where the carried body's origin sits in the carrier's frame (rest pose of a 1.78 m carrier)
CARRY_CONTACT = Vector((-0.150, 0.030, 1.535))


def keyframe_action(arm, rig, name, frames, loop, pose_fn):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    count = frames + 1 if loop else frames
    for f in range(count):
        pose_fn(rig, f % frames if loop else f, frames).apply(arm, frame_no=f)
    try:
        act.frame_range = (0, frames if loop else frames - 1)
        act.use_frame_range = True
        act.use_cyclic = loop
    except Exception:
        pass
    return act


def build_actions(arm, body):
    rig = Rig(arm, body)
    s = body.s
    fns = {
        'Idle': idle_pose,
        'Walk': lambda r, f, n: gait_pose(r, f, n, 1.40, 0.56, 0.085 * s, 0.05, 0.016 * s, False, 0.32, 0.28),
        'Jog': lambda r, f, n: gait_pose(r, f, n, 3.40, 0.40, 0.17 * s, 0.14, 0.030 * s, True, 0.55, 1.25, crouch=0.02 * s),
        'Sprint': lambda r, f, n: gait_pose(r, f, n, 5.60, 0.32, 0.26 * s, 0.30, 0.036 * s, True, 0.85, 1.45, crouch=0.035 * s),
        'Push': push_pose,
        'Interact': interact_pose,
        'PickUp': pickup_pose,
        'Crawl': crawl_pose,
        'Carried': carried_pose,
        'Carrying': carrying_pose,
        'Lying': lying_pose,
    }
    for name, (frames, loop, speed, _) in CLIPS.items():
        keyframe_action(arm, rig, name, frames, loop, fns[name])
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    return rig
