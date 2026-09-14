"""Armature, weights and hand-authored procedural animation for the Night Nurse."""
import math
import bpy
from mathutils import Vector, Matrix
import nn_geometry as G

SPINE = [
    ('hips', (0, 0.0, 1.12), (0, 0.0, 1.27), 'root'),
    ('spine', (0, 0.0, 1.27), (0, 0.002, 1.44), 'hips'),
    ('chest', (0, 0.002, 1.44), (0, 0.004, 1.60), 'spine'),
    ('upperchest', (0, 0.004, 1.60), tuple(G.NECK_BASE), 'chest'),
    ('neck', tuple(G.NECK_BASE), (0, 0.012, 1.985), 'upperchest'),
    ('head', (0, 0.012, 1.985), (0, 0.0, 2.24), 'neck'),
]


def left_bones(joints):
    x = G.ANKLE.x
    out = [
        ('shoulder.L', (0.03, 0.008, 1.75), tuple(G.SHOULDER), 'upperchest'),
        ('upperarm.L', tuple(G.SHOULDER), tuple(G.ELBOW), 'shoulder.L'),
        ('forearm.L', tuple(G.ELBOW), tuple(G.WRIST), 'upperarm.L'),
        ('hand.L', tuple(joints['hand.L'][0]), tuple(joints['hand.L'][1]), 'forearm.L'),
        ('thigh.L', tuple(G.HIP), tuple(G.KNEE), 'hips'),
        ('shin.L', tuple(G.KNEE), tuple(G.ANKLE), 'thigh.L'),
        ('foot.L', tuple(G.ANKLE), (x, -0.085, 0.022), 'shin.L'),
        ('toe.L', (x, -0.085, 0.022), (x, -0.172, 0.02), 'foot.L'),
    ]
    for f in G.FINGER_NAMES + ['thumb']:
        for k in range(3):
            h, t = joints['%s%d.L' % (f, k + 1)]
            parent = 'hand.L' if k == 0 else '%s%d.L' % (f, k)
            out.append(('%s%d.L' % (f, k + 1), tuple(h), tuple(t), parent))
    return out


def mirror_def(d):
    name, h, t, parent = d
    return (G.mirror_bone(name), (-h[0], h[1], h[2]), (-t[0], t[1], t[2]), G.mirror_bone(parent))


def build_armature(joints):
    arm_data = bpy.data.armatures.new('NN_Rig')
    arm = bpy.data.objects.new('NightNurse_Rig', arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones
    root = eb.new('root')
    root.head, root.tail = (0, 0, 0), (0, 0, 0.25)
    root.use_deform = False
    defs = list(SPINE)
    for d in left_bones(joints):
        defs.append(d)
        defs.append(mirror_def(d))
    for name, h, t, parent in defs:
        b = eb.new(name)
        b.head, b.tail = Vector(h), Vector(t)
    for name, h, t, parent in defs:
        b = eb[name]
        b.parent = eb[parent]
        b.use_connect = (Vector(h) - eb[parent].tail).length < 1e-4
        b.align_roll(Vector((0, -1, 0)) if abs(Vector(t)[2] - Vector(h)[2]) > 0.5 * (Vector(t) - Vector(h)).length else Vector((0, 0, 1)))
    bpy.ops.object.mode_set(mode='OBJECT')
    return arm


def nearest_bone_weights(obj, arm, allowed):
    """Give every unweighted vertex to the nearest allowed bone segment."""
    segs = []
    for b in arm.data.bones:
        if b.name in allowed:
            segs.append((b.name, b.head_local.copy(), b.tail_local.copy()))
    groups = {g.name: g for g in obj.vertex_groups}
    for v in obj.data.vertices:
        tot = sum(g.weight for g in v.groups)
        if tot > 0.01:
            continue
        best, bd = None, 1e9
        for name, h, t in segs:
            ab = t - h
            k = max(0.0, min(1.0, (v.co - h).dot(ab) / max(ab.length_squared, 1e-9)))
            d = (v.co - (h + ab * k)).length
            if d < bd:
                best, bd = name, d
        if best not in groups:
            groups[best] = obj.vertex_groups.new(name=best)
        groups[best].add([v.index], 1.0, 'REPLACE')


def skin_part(obj, arm, allowed):
    for b in arm.data.bones:
        b.use_deform = b.name in allowed
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    if len(allowed) == 1:
        bpy.ops.object.parent_set(type='ARMATURE_NAME')
        g = obj.vertex_groups.get(allowed[0]) or obj.vertex_groups.new(name=allowed[0])
        g.add(list(range(len(obj.data.vertices))), 1.0, 'REPLACE')
    else:
        bpy.ops.object.parent_set(type='ARMATURE_AUTO')
    nearest_bone_weights(obj, arm, allowed)


def skirt_weights(obj):
    """Replace heat weights below the waist with a smooth blend: hips carry the skirt, thighs push it."""
    vg = {g.name: g for g in obj.vertex_groups}
    for name in ('hips', 'thigh.L', 'thigh.R'):
        if name not in vg:
            vg[name] = obj.vertex_groups.new(name=name)
    idx_of = {g.index: g.name for g in obj.vertex_groups}
    for v in obj.data.vertices:
        z = v.co.z
        blend = G.smooth01((1.20 - z) / 0.12)       # 0 above the waist: keep heat weights
        if blend <= 0:
            continue
        leg = 0.62 * G.smooth01((1.12 - z) / 0.55)
        side = G.smooth01(v.co.x / 0.22 + 0.5)       # 1 = left
        target = {'hips': 1 - leg, 'thigh.L': leg * side, 'thigh.R': leg * (1 - side)}
        cur = {idx_of[g.group]: g.weight for g in v.groups}
        names = set(cur) | set(target)
        for n in names:
            w = cur.get(n, 0.0) * (1 - blend) + target.get(n, 0.0) * blend
            if n not in vg:
                vg[n] = obj.vertex_groups.new(name=n)
            if w > 1e-4:
                vg[n].add([v.index], w, 'REPLACE')
            else:
                vg[n].remove([v.index])


# ------------------------------------------------------------------ posing
class Poser:
    def __init__(self, arm):
        self.arm = arm
        self.rest = {b.name: b.matrix_local.to_3x3() for b in arm.data.bones}

    def rot(self, name, rots):
        """rots: list of (axis, angle) in armature space (applied in order). Right side mirrored."""
        R = Matrix.Identity(3)
        right = name.endswith('.R')
        for ax, ang in rots:
            if right and ax in ('Y', 'Z'):
                ang = -ang
            R = Matrix.Rotation(ang, 3, ax) @ R
        M = self.rest[name]
        return (M.inverted() @ R @ M).to_quaternion()

    def apply(self, pose, frame=None):
        """pose: {bone: [(axis, angle), ...]}, plus optional '_hips_loc': Vector (armature space)."""
        pbs = self.arm.pose.bones
        for pb in pbs:
            pb.rotation_mode = 'QUATERNION'
            q = self.rot(pb.name, pose.get(pb.name, []))
            pb.rotation_quaternion = q
            if frame is not None:
                pb.keyframe_insert('rotation_quaternion', frame=frame)
        loc = pose.get('_hips_loc', Vector())
        M = self.rest['hips']
        pbs['hips'].location = M.inverted() @ Vector(loc)
        if frame is not None:
            pbs['hips'].keyframe_insert('location', frame=frame)


def add(pose, bone, *rots):
    pose.setdefault(bone, []).extend(rots)


def frozen_pose(t=0.0):
    """The creepy rest: hunched, head cocked hard, one shoulder dropped, hands wrong."""
    p = {}
    add(p, 'hips', ('X', 0.02), ('Z', 0.05))
    add(p, 'spine', ('X', 0.04), ('Y', -0.03))
    add(p, 'chest', ('X', 0.09), ('Y', -0.04))
    add(p, 'upperchest', ('X', 0.16), ('Z', 0.06))
    add(p, 'neck', ('X', 0.10), ('Y', 0.12))
    add(p, 'head', ('X', -0.12), ('Y', 0.46), ('Z', -0.22))
    add(p, 'shoulder.L', ('Y', 0.16))
    add(p, 'shoulder.R', ('Y', 0.02), ('Z', 0.05))
    add(p, 'upperarm.L', ('X', -0.10), ('Y', 0.04))
    add(p, 'upperarm.R', ('X', -0.30), ('Y', 0.02))
    add(p, 'forearm.L', ('X', -0.12))
    add(p, 'forearm.R', ('X', -0.42), ('Z', 0.3))
    add(p, 'hand.L', ('X', -0.05), ('Z', 0.25))
    add(p, 'hand.R', ('X', -0.25), ('Y', -0.25), ('Z', 0.5))
    # left hand: index pointing straight, the rest curled unevenly
    for f, c in (('index', (0.0, -0.10, -0.05)), ('middle', (0.25, 0.35, 0.2)), ('ring', (0.35, 0.55, 0.35)), ('pinky', (0.5, 0.6, 0.45))):
        for k in range(3):
            add(p, '%s%d.L' % (f, k + 1), ('Y', c[k]))
    # right hand: splayed, fingers reaching
    for f, c, s in (('index', (-0.15, 0.1, 0.1), -0.15), ('middle', (-0.05, 0.15, 0.1), -0.05), ('ring', (0.0, 0.2, 0.15), 0.08), ('pinky', (0.05, 0.3, 0.2), 0.2)):
        for k in range(3):
            add(p, '%s%d.R' % (f, k + 1), ('Y', c[k]))
        add(p, '%s1.R' % f, ('X', s))
    add(p, 'thumb1.R', ('X', 0.25))
    add(p, 'thigh.L', ('X', -0.10), ('Y', -0.02))
    add(p, 'thigh.R', ('X', -0.02), ('Y', 0.03))
    add(p, 'shin.L', ('X', 0.10))
    add(p, 'shin.R', ('X', 0.06))
    add(p, 'foot.L', ('X', 0.0), ('Z', -0.15))
    add(p, 'foot.R', ('X', -0.04), ('Z', 0.12))
    p['_hips_loc'] = Vector((0.0, 0.01, -0.02))
    return p


def keyframe_action(arm, poser, name, frames, pose_fn, cyclic=True):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    for f in range(frames + 1 if cyclic else frames):
        poser.apply(pose_fn(f), frame=f)
    try:
        act.frame_range = (0, frames)
        act.use_frame_range = True
        act.use_cyclic = cyclic
    except Exception:
        pass
    return act


def idle_pose(f, n=120):
    t = f / n
    p = frozen_pose()
    br = math.sin(t * math.tau * 2)          # two slow breaths per loop
    add(p, 'chest', ('X', -0.018 * br))
    add(p, 'upperchest', ('X', -0.014 * br))
    add(p, 'shoulder.L', ('Z', 0.012 * br))
    add(p, 'shoulder.R', ('Z', 0.012 * br))
    add(p, 'neck', ('X', 0.012 * br))
    # a sudden head jerk: snap in 2 frames, hold, crawl back
    def spike(f0, rise, hold, fall):
        if f < f0:
            return 0.0
        if f < f0 + rise:
            return (f - f0) / rise
        if f < f0 + rise + hold:
            return 1.0
        return max(0.0, 1.0 - (f - f0 - rise - hold) / fall)
    j = spike(38, 2, 10, 30)
    add(p, 'head', ('Y', 0.22 * j), ('X', 0.05 * j))
    add(p, 'neck', ('Z', -0.08 * j))
    add(p, 'shoulder.L', ('Y', -0.06 * j))
    # the right hand's fingers flex and release
    k = spike(82, 3, 4, 10)
    for fn in ('index', 'middle', 'ring', 'pinky'):
        for s in range(3):
            add(p, '%s%d.R' % (fn, s + 1), ('Y', 0.45 * k))
    # left index finger twitches
    k2 = spike(100, 1, 2, 5)
    add(p, 'index1.L', ('Y', 0.3 * k2))
    add(p, 'index2.L', ('Y', 0.35 * k2))
    # the left fingers creep one after another, slow and continuous
    for i, fn in enumerate(('pinky', 'ring', 'middle')):
        wave = max(0.0, math.sin(t * math.tau * 2 - i * 0.9)) ** 2
        for s in range(3):
            add(p, '%s%d.L' % (fn, s + 1), ('Y', 0.22 * wave))
    # a slow drift of the whole head, as if listening
    add(p, 'head', ('Y', 0.05 * math.sin(t * math.tau + 0.6)), ('Z', 0.06 * math.sin(t * math.tau)))
    return p


def walk_pose(f, n=48):
    """A stalking walk: pitched forward from the hips, long careful strides placed toe-first,
    arms hanging straight down from the hunch and swinging late, the head held level and cocked
    while the body bobs under it, and a dragging right foot."""
    ph = f / n * math.tau
    s, c = math.sin(ph), math.cos(ph)
    p = {}
    HIPS_PITCH = 0.12
    add(p, 'hips', ('X', HIPS_PITCH), ('Z', 0.10 * s), ('Y', 0.03 * c))
    add(p, 'spine', ('X', 0.05), ('Z', -0.06 * s))
    add(p, 'chest', ('X', 0.16), ('Z', -0.05 * s), ('Y', -0.025 * c))
    add(p, 'upperchest', ('X', 0.24), ('Z', 0.04))
    torso = HIPS_PITCH + 0.05 + 0.16 + 0.24
    add(p, 'neck', ('X', 0.05), ('Y', 0.10))
    # keep the face up and level: undo the torso pitch and the hip yaw, keep the cock
    bob2 = math.sin(2 * ph)
    add(p, 'head', ('X', -torso - 0.10 + 0.03 * bob2), ('Y', 0.46), ('Z', -0.10 * s - 0.15))
    add(p, 'shoulder.L', ('Y', 0.14))
    add(p, 'shoulder.R', ('Y', 0.02))
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ss, cc = s * sg, c * sg
        drag = 0.6 if side == 'R' else 1.0
        swing = max(0.0, cc) ** 1.3                       # 0..1 while this foot travels forward
        stance = max(0.0, -cc)
        thigh = -HIPS_PITCH - 0.40 * ss - 0.10 * swing * drag
        shin = 0.14 + 0.78 * swing * drag + 0.04 * stance
        # foot: toe hangs during the swing, flat through stance, peels off the heel at push-off
        flat = -(HIPS_PITCH + thigh + shin)
        toe_down = 0.35 * swing * (1.2 if side == 'R' else 1.0)
        add(p, 'thigh.' + side, ('X', thigh))
        add(p, 'shin.' + side, ('X', shin))
        add(p, 'foot.' + side, ('X', flat + toe_down + 0.18 * max(0.0, ss) * stance))
        add(p, 'toe.' + side, ('X', -0.25 * max(0.0, ss) * stance))
        # arms hang plumb from the hunch and swing a beat late, barely
        lag = math.sin(ph - 1.1) * sg
        add(p, 'upperarm.' + side, ('X', -torso * 0.85 + 0.09 * lag), ('Y', 0.03))
        add(p, 'forearm.' + side, ('X', -0.08 - 0.06 * max(0.0, lag)))
        add(p, 'hand.' + side, ('X', -0.05 * lag))
    # fingers hang loose, a little crooked
    for fn, cr in (('index', 0.10), ('middle', 0.22), ('ring', 0.30), ('pinky', 0.40)):
        for k in range(3):
            add(p, '%s%d.L' % (fn, k + 1), ('Y', cr * (0.6 + 0.2 * k)))
            add(p, '%s%d.R' % (fn, k + 1), ('Y', cr * 0.8 + 0.05 * math.sin(ph + k)))
    bob = -0.045 * s * s
    p['_hips_loc'] = Vector((-0.03 * c, 0.02, bob - 0.05))
    return p


def build_actions(arm):
    poser = Poser(arm)
    keyframe_action(arm, poser, 'Frozen', 10, lambda f: frozen_pose(), cyclic=True)
    keyframe_action(arm, poser, 'Idle', 120, idle_pose, cyclic=True)
    keyframe_action(arm, poser, 'Walk', 48, walk_pose, cyclic=True)
    arm.animation_data.action = bpy.data.actions['Frozen']
    return poser
