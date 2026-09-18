"""Build the stylized test characters in Blender, pose them and render review shots.

blender --background --factory-startup --python st_build.py -- [--only=surgeon,hive,surgeon_graft] [--shots=pair,face_surgeon,...] [--fast]

Geometry comes from st_char (smooth blended distance fields meshed with surface nets), coloured per
vertex; the skeleton, bone layout and posing helpers are the human pipeline's (art/human/blender_src),
so these characters share its 11 clips. Renders land in renders/.
"""
import sys
import os
import time
import math
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
HUMAN = os.path.normpath(os.path.join(HERE, '..', 'human', 'blender_src'))
sys.path.insert(0, HERE)
sys.path.insert(1, HUMAN)

import bpy
import numpy as np
from mathutils import Vector, Matrix
import hu_params, hu_body, hu_rig
import st_sdf, st_char, st_clips, st_hive_clips, st_sono_clips
for m in (st_sdf, st_char, st_clips, st_hive_clips, st_sono_clips):
    importlib.reload(m)

ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []


def arg(name, default):
    for a in ARGS:
        if a.startswith('--' + name + '='):
            return a.split('=', 1)[1]
    return default


FAST = '--fast' in ARGS
ONLY = arg('only', 'surgeon,hive,surgeon_graft').split(',')
SHOTS = arg('shots', 'all')
OUT = os.path.join(HERE, 'renders')
T0 = time.time()


def log(*a):
    print('[st_build %6.1fs]' % (time.time() - T0), *a, flush=True)


# ====================================================================== skeleton
def body_for(V):
    P = hu_params.get('surgeon_a' if V['outfit'] == 'scrubs' else 'bob')
    P.update(height=V['height'], girth=V['girth'], head_scale=V['head_scale'], fem=V['fem'])
    b = hu_body.Body(P, 1)
    ext = V.get('neck_ext', 0.0)
    if ext:
        # a long neck: push the head joint, the crown and the head centre straight up. The neck bone
        # grows by exactly that much and the head's geometry (st_char.Head.neck_sdf_local) grows down
        # to meet the shoulders again, so nothing below the collarbones moves.
        up = Vector((0.0, 0.0, ext))
        b.J['headj'] = b.J['headj'] + up
        b.J['crown'] = b.J['crown'] + up
        b.HC = b.HC + up
    b.spine_joints()
    b.build_arm()
    b.build_fingers()
    b.build_leg()
    return b


# ====================================================================== materials
def attr_material(name, sss=0.0, coat=0.0, spec=0.5, sheen=0.0, emit=None):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    ca = nt.nodes.new('ShaderNodeAttribute')
    ca.attribute_name = 'Col'
    ra = nt.nodes.new('ShaderNodeAttribute')
    ra.attribute_name = 'rough'
    nt.links.new(ca.outputs['Color'], b.inputs['Base Color'])
    nt.links.new(ra.outputs['Fac'], b.inputs['Roughness'])
    b.inputs['Specular IOR Level'].default_value = spec
    if sss > 0:
        b.inputs['Subsurface Weight'].default_value = sss
        b.inputs['Subsurface Radius'].default_value = (1.0, 0.35, 0.2)
        b.inputs['Subsurface Scale'].default_value = 0.006
    if coat > 0:
        b.inputs['Coat Weight'].default_value = coat
        b.inputs['Coat Roughness'].default_value = 0.03
    if sheen > 0:
        b.inputs['Sheen Weight'].default_value = sheen
        b.inputs['Sheen Roughness'].default_value = 0.5
    if emit is not None:
        nt.links.new(ca.outputs['Color'], b.inputs['Emission Color'])
        b.inputs['Emission Strength'].default_value = emit
    return m


HIVE_GLOW = (1.0, 0.36, 0.035)      # linear orange
PIN_EMIT, LOCK_EMIT = 14.0, 9.0     # emission: the pinpoint at rest, the whole ball when locked on


def hive_eye_material():
    """The Hive's eye: the painted ball plus orange emission, a soft point from the mask's R channel,
    the whole ball (G) scaled by the node 'Lock' (0 wandering, 1 locked on); set_lock() drives it."""
    m = bpy.data.materials.get('ST_HiveEye')
    if m:
        return m
    m = bpy.data.materials.new('ST_HiveEye')
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    ca = nt.nodes.new('ShaderNodeAttribute')
    ca.attribute_name = 'Col'
    mk = nt.nodes.new('ShaderNodeAttribute')
    mk.attribute_name = 'maskc'
    sep = nt.nodes.new('ShaderNodeSeparateColor')
    nt.links.new(mk.outputs['Color'], sep.inputs[0])
    lock = nt.nodes.new('ShaderNodeValue')
    lock.name = 'Lock'
    lock.outputs[0].default_value = 0.0
    # base colour: the painted ball, washed to bright orange as it locks on
    mixn = nt.nodes.new('ShaderNodeMix')
    mixn.data_type = 'RGBA'
    ins = [s for s in mixn.inputs if s.type == 'RGBA']
    nt.links.new(lock.outputs[0], mixn.inputs['Factor'])
    nt.links.new(ca.outputs['Color'], ins[0])
    ins[1].default_value = (1.0, 0.45, 0.08, 1.0)
    nt.links.new([o for o in mixn.outputs if o.type == 'RGBA'][0], b.inputs['Base Color'])
    # emission strength = R * PIN + Lock * LOCK
    m1 = nt.nodes.new('ShaderNodeMath')
    m1.operation = 'MULTIPLY'
    nt.links.new(sep.outputs[0], m1.inputs[0])
    m1.inputs[1].default_value = PIN_EMIT
    m2 = nt.nodes.new('ShaderNodeMath')
    m2.operation = 'MULTIPLY_ADD'
    nt.links.new(lock.outputs[0], m2.inputs[0])
    m2.inputs[1].default_value = LOCK_EMIT
    nt.links.new(m1.outputs[0], m2.inputs[2])
    nt.links.new(m2.outputs[0], b.inputs['Emission Strength'])
    b.inputs['Emission Color'].default_value = HIVE_GLOW + (1.0,)
    b.inputs['Roughness'].default_value = 0.08
    b.inputs['Coat Weight'].default_value = 1.0
    b.inputs['Coat Roughness'].default_value = 0.03
    return m


def set_lock(v):
    m = bpy.data.materials.get('ST_HiveEye')
    if m:
        m.node_tree.nodes['Lock'].outputs[0].default_value = v


SONO_GLOW = (0.10, 0.60, 1.0)       # linear cold blue: the light inside the windpipe
SONO_EMIT = 26.0                    # emission at a full charge (it idles at a twentieth of that)


def sono_glow_material():
    """The Sonographer's windpipe: pale cartilage lit from inside. The node 'Charge' ramps it,
    0 quiet through 1 charging an echo; set_charge() drives it for the review shots."""
    m = bpy.data.materials.get('ST_SonoGlow')
    if m:
        return m
    m = bpy.data.materials.new('ST_SonoGlow')
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    ca = nt.nodes.new('ShaderNodeAttribute')
    ca.attribute_name = 'Col'
    nt.links.new(ca.outputs['Color'], b.inputs['Base Color'])
    ch = nt.nodes.new('ShaderNodeValue')
    ch.name = 'Charge'
    ch.outputs[0].default_value = 0.0
    ma = nt.nodes.new('ShaderNodeMath')
    ma.operation = 'MULTIPLY_ADD'
    nt.links.new(ch.outputs[0], ma.inputs[0])
    ma.inputs[1].default_value = SONO_EMIT
    ma.inputs[2].default_value = SONO_EMIT / 20.0
    nt.links.new(ma.outputs[0], b.inputs['Emission Strength'])
    b.inputs['Emission Color'].default_value = SONO_GLOW + (1.0,)
    b.inputs['Roughness'].default_value = 0.22
    return m


def sono_pane_material():
    """The thin skin over the throat: wet, and see-through enough that the rings show."""
    m = bpy.data.materials.get('ST_SonoPane')
    if m:
        return m
    m = attr_material('ST_SonoPane', spec=0.6)
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Alpha'].default_value = 0.40
    for attr, val in (('surface_render_method', 'BLENDED'), ('blend_method', 'BLEND'), ('show_transparent_back', False)):
        try:
            setattr(m, attr, val)
        except Exception:
            pass
    return m


def set_charge(v):
    m = bpy.data.materials.get('ST_SonoGlow')
    if m:
        m.node_tree.nodes['Charge'].outputs[0].default_value = v


def material_for(kind, hive_eye=False):
    if kind == st_char.GLOW:
        return sono_glow_material()
    if kind == st_char.PANE:
        return sono_pane_material()
    if kind == st_char.SKIN:
        return attr_material('ST_Skin', sss=0.12, spec=0.45)
    if kind == st_char.EYE:
        if hive_eye:
            return hive_eye_material()
        return attr_material('ST_Eye', coat=1.0, spec=0.6)
    if kind == st_char.FUNGUS:
        return attr_material('ST_Fungus', sss=0.25, coat=0.12, spec=0.4)
    if kind in (st_char.CLOTH, st_char.CAP):
        return attr_material('ST_Cloth', spec=0.3, sheen=0.3)
    if kind == st_char.SHOE:
        return attr_material('ST_Shoe', spec=0.5)
    return attr_material('ST_Plain', spec=0.4)


# ====================================================================== meshing
def mesh_part(prefix, part, V, coll):
    t = time.time()
    h = part.h * (1.6 if FAST else 1.0)
    verts, quads = st_sdf.surface_nets(part.f, part.lo, part.hi, h, project=part.project)
    if len(verts) == 0:
        log('  EMPTY part', part.name)
        return None
    col, rough = part.paint(verts)
    me = bpy.data.meshes.new(prefix + part.name)
    me.from_pydata(verts.tolist(), [], quads.tolist())
    me.validate()
    ca = me.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT')
    rgba = np.concatenate([np.clip(col, 0, 1), np.ones((len(col), 1))], axis=1).astype(np.float32)
    ca.data.foreach_set('color', rgba.ravel())
    ra = me.attributes.new('rough', 'FLOAT', 'POINT')
    ra.data.foreach_set('value', np.clip(rough, 0.02, 1.0).astype(np.float32))
    # shader mask channels: cloth R = player tint zone; skin G = the players' gash
    if part.mask is not None:
        mk = part.mask(verts)
    else:
        mk = np.zeros((len(verts), 3))
        if part.name in ('Top', 'Pants'):
            mk[:, 0] = 1.0
    ma = me.color_attributes.new('maskc', 'FLOAT_COLOR', 'POINT')
    ma.data.foreach_set('color', np.concatenate([mk, np.ones((len(mk), 1))], axis=1).astype(np.float32).ravel())
    me.color_attributes.active_color = me.color_attributes['Col']
    me.polygons.foreach_set('use_smooth', [True] * len(me.polygons))
    me.materials.append(material_for(part.mat, getattr(part, 'eye_kind', '') == 'hive'))
    ob = bpy.data.objects.new(prefix + part.name, me)
    coll.objects.link(ob)
    log('  %-12s %7d verts %7d quads  %.1fs' % (part.name, len(verts), len(quads), time.time() - t))
    return ob


# ====================================================================== weights
ALLOWED = {
    'Head': ['head', 'neck', 'upperchest', 'chest'],
    'Top': ['hips', 'spine', 'chest', 'upperchest', 'shoulder.L', 'shoulder.R', 'upperarm.L', 'upperarm.R', 'forearm.L', 'forearm.R'],
    'Gown': ['hips', 'spine', 'chest', 'upperchest', 'shoulder.L', 'shoulder.R', 'upperarm.L', 'upperarm.R'],
    'Pants': ['hips', 'thigh.L', 'thigh.R', 'shin.L', 'shin.R'],
    'Wristband': ['forearm.L'],
}


def limb_bones(side):
    fing = ['%s%d.%s' % (f, k, side) for f in ('index', 'middle', 'ring', 'pinky', 'thumb') for k in (1, 2, 3)]
    return fing


def allowed_for(name):
    if name in ALLOWED:
        return ALLOWED[name]
    side = name[-1]
    if name.startswith(('Glove_', 'Arm_')):
        b = ['forearm.' + side, 'hand.' + side] + limb_bones(side)
        return (['shoulder.' + side, 'upperarm.' + side] if name.startswith('Arm_') else ['upperarm.' + side]) + b
    if name.startswith('Leg_'):
        return ['thigh.' + side, 'shin.' + side, 'foot.' + side, 'toe.' + side]
    if name.startswith('Shoe_'):
        return ['foot.' + side]
    return ['head']


def seg_dist(P, a, b):
    ab = b - a
    t = np.clip(((P - a) @ ab) / (ab @ ab), 0.0, 1.0)
    return np.linalg.norm(P - (a + np.outer(t, ab)), axis=1)


def trunk_weights(P, sk, arms=True, legs=False, leg_k=1.0, skirt=False):
    """Garment weights: the trunk blends by height along the spine; past the shoulder joint along the
    upper arm the sleeve belongs to the arm (upper arm / forearm by distance); below the hip joint along
    the thigh the trouser leg belongs to the leg. skirt: a loose garment over both legs (the Hive's gown):
    below the hips each side follows its thigh more and more toward the hem, wide enough to take the whole
    skirt round that leg and blended across the middle, so a thigh swinging forward carries the cloth in
    front of it instead of poking through, and the two halves never tear apart at a seam."""
    sm = st_char.smooth01
    z = P[:, 2]
    spine = ['hips', 'spine', 'chest', 'upperchest']
    cz = [0.5 * (sk.bones[n][0][2] + sk.bones[n][1][2]) for n in spine]
    ws = []
    for i, n in enumerate(spine):
        w = np.ones(len(P))
        if i > 0:
            w *= np.clip((z - cz[i - 1]) / (cz[i] - cz[i - 1]), 0, 1)
        if i < len(spine) - 1:
            w *= np.clip((cz[i + 1] - z) / (cz[i + 1] - cz[i]), 0, 1)
        ws.append(w)
    out = {n: w for n, w in zip(spine, ws)}
    rest = np.ones(len(P))
    limb = {}
    for side, sg in (('L', 1.0), ('R', -1.0)):
        if arms:
            a, e = sk.bones['upperarm.' + side]
            d = (e - a) / np.linalg.norm(e - a)
            t = (P - a) @ d
            du = seg_dist(P, *sk.bones['upperarm.' + side])
            df = seg_dist(P, *sk.bones['forearm.' + side])
            perp = np.minimum(du, df)
            wa = sm((t + 0.045) / 0.11) * sm((0.115 - perp) / 0.06) * (P[:, 0] * sg > 0)
            iu, if_ = 1 / np.maximum(du, 0.004) ** 6, 1 / np.maximum(df, 0.004) ** 6
            limb['upperarm.' + side] = wa * iu / (iu + if_)
            limb['forearm.' + side] = wa * if_ / (iu + if_)
            rest -= wa
        if legs and skirt:
            a, e = sk.bones['thigh.' + side]
            d = (e - a) / np.linalg.norm(e - a)
            t = (P - a) @ d
            share = sm((P[:, 0] * sg + 0.07) / 0.14)            # half each at the middle
            wl = sm(t / 0.20) * share * leg_k
            limb['thigh.' + side] = wl
            rest -= wl
        elif legs:
            a, e = sk.bones['thigh.' + side]
            d = (e - a) / np.linalg.norm(e - a)
            t = (P - a) @ d
            perp = np.linalg.norm((P - a) - np.outer(t, d), axis=1)
            wl = sm((t - 0.02) / 0.10) * sm((0.13 - perp) / 0.03) * sm((P[:, 0] * sg + 0.01) / 0.02) * leg_k
            dt = seg_dist(P, *sk.bones['thigh.' + side])
            dsh = seg_dist(P, *sk.bones['shin.' + side])
            it, ish = 1 / np.maximum(dt, 0.004) ** 6, 1 / np.maximum(dsh, 0.004) ** 6
            limb['thigh.' + side] = wl * it / (it + ish)
            limb['shin.' + side] = wl * ish / (it + ish)
            rest -= wl
    rest = np.clip(rest, 0, 1)
    tot = sum(out.values())
    for n in out:
        out[n] = out[n] / np.maximum(tot, 1e-9) * rest
    out.update(limb)
    s = sum(out.values())
    return {n: w / np.maximum(s, 1e-9) for n, w in out.items()}


def assign_weights(ob, part, sk, arm):
    me = ob.data
    P = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get('co', P)
    P = P.reshape(-1, 3)
    names = [part.rigid] if part.rigid else allowed_for(part.name)
    groups = {n: ob.vertex_groups.new(name=n) for n in names}
    if len(names) == 1:
        groups[names[0]].add(list(range(len(P))), 1.0, 'REPLACE')
    elif part.name == 'Head':
        # by height up the neck: chest below the neck joint, the head from just under the jaw
        z = P[:, 2]
        zn = sk.J['neck'][2]
        zh = sk.J['headj'][2]
        w_head = st_char.smooth01((z - (zh - 0.085)) / 0.035)
        w_neck = st_char.smooth01((z - (zn - 0.03)) / 0.05) * (1 - w_head)
        w_up = (1 - w_head - w_neck) * st_char.smooth01((z - 1.25 * sk.s) / 0.08)
        w_ch = 1 - w_head - w_neck - w_up
        for n, w in (('head', w_head), ('neck', w_neck), ('upperchest', w_up), ('chest', w_ch)):
            for i in np.nonzero(w > 1e-3)[0]:
                groups[n].add([int(i)], float(w[i]), 'REPLACE')
    elif part.name in ('Top', 'Gown', 'Pants', 'Belly', 'TopRolled'):
        arms = part.name in ('Top', 'Gown')
        legs = part.name in ('Gown', 'Pants')
        W = trunk_weights(P, sk, arms=arms, legs=legs, leg_k=1.0 if part.name == 'Pants' else 0.85,
                          skirt=part.name == 'Gown')
        for n, w in W.items():
            if n not in groups:
                groups[n] = ob.vertex_groups.new(name=n)
            for i in np.nonzero(w > 1e-3)[0]:
                groups[n].add([int(i)], float(w[i]), 'REPLACE')
    else:
        D = np.stack([seg_dist(P, *sk.bones[n]) for n in names], axis=1)
        W = 1.0 / np.maximum(D, 0.004) ** 6
        order = np.argsort(-W, axis=1)
        keep = np.zeros_like(W, dtype=bool)
        np.put_along_axis(keep, order[:, :3], True, axis=1)
        W = np.where(keep, W, 0.0)
        W /= W.sum(axis=1, keepdims=True)
        for j, n in enumerate(names):
            idx = np.nonzero(W[:, j] > 1e-3)[0]
            g = groups[n]
            for i in idx:
                g.add([int(i)], float(W[i, j]), 'REPLACE')
    ob.parent = arm
    mod = ob.modifiers.new('Armature', 'ARMATURE')
    mod.object = arm


# ====================================================================== poses
def pose_surgeon(rig):
    """A plain neutral stand: weight even, feet under the hips, arms hanging close, hands relaxed."""
    from hu_rig import Pose, spine, arm_hang, hand_relax, planted
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.0, -0.004 * s))
    spine(p, lean=0.03)
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 1.10, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.08)
        arm_hang(p, side, swing=0.03, abduct=0.11, bend=0.14, wrist=0.0, twist=0.0)
        hand_relax(p, side, curl=0.22, thumb=0.12)
    return p


def pose_hive(rig):
    """Hunched forward, head hung and tipped to one side, the left arm dangling ahead of the body,
    the right leg trailing (it drags that leg), knees soft."""
    from hu_rig import Pose, spine, arm_hang, hand_relax, planted, Rx, Ry, Rz
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.010 * s, 0.015 * s, -0.018 * s))
    spine(p, lean=0.55, yaw=0.08, roll=0.05, look=(0.18, 0.0), neck_comp=0.0)
    p.rel('neck', Rx(0.10))
    p.rel('head', Ry(-0.20) @ Rx(0.10))
    ballL = Vector((rig.ball['L'].x * 1.1, rig.ball['L'].y - 0.05 * s, rig.ball['L'].z))
    ballR = Vector((rig.ball['R'].x * 1.2, rig.ball['R'].y + 0.20 * s, rig.ball['R'].z))
    planted(p, 'L', ballL, 0.0, yaw=0.12)
    planted(p, 'R', ballR, 0.22, yaw=-0.30)
    arm_hang(p, 'L', swing=0.30, abduct=0.10, bend=0.28, wrist=0.15, twist=0.2)
    arm_hang(p, 'R', swing=0.06, abduct=0.16, bend=0.12, wrist=0.05, twist=0.0)
    hand_relax(p, 'L', curl=0.55)
    hand_relax(p, 'R', curl=0.35)
    return p


def pose_sono(rig):
    """Standing tall and straight, the long neck carrying the head out ahead of the chest and cocked
    over one ear, both hands out in front where the cart's handle is. Never the Hive's hunch."""
    from hu_rig import Pose, spine, arm_hang, hand_relax, planted, Rx, Ry, Rz
    s = rig.body.s
    p = Pose(rig)
    p.hips = Vector((0.0, 0.0, -0.004 * s))
    spine(p, lean=0.05, yaw=0.02, roll=0.01, neck_comp=0.0)
    p.rel('neck', Rx(0.44) @ Rz(0.05))
    p.rel('head', Rx(-0.30) @ Ry(0.26) @ Rz(0.06))
    for side, sg in (('L', 1.0), ('R', -1.0)):
        ball = Vector((rig.ball[side].x * 0.86, rig.ball[side].y, rig.ball[side].z))
        planted(p, side, ball, 0.0, yaw=sg * 0.05)
        arm_hang(p, side, swing=1.05, abduct=0.13, bend=0.62, wrist=-0.25, twist=0.30)
        hand_relax(p, side, curl=0.75, thumb=0.35)
    return p


def pose_for(V):
    if V.get('sono'):
        return pose_sono
    return pose_hive if V['outfit'] == 'gown' else pose_surgeon


def clips_for(V):
    """The variant's own clip module, or None for the shared human set."""
    if V.get('hive'):
        return st_hive_clips
    if V.get('sono'):
        return st_sono_clips
    return None


# ====================================================================== build
def build_variant(name, x_off):
    V = st_char.get(name)
    body = body_for(V)
    log('variant', name)
    parts, info = st_char.build(name, body)
    sk = info['sk']
    coll = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(coll)
    arm = hu_rig.build_armature(body, name + '_Rig')
    bpy.context.scene.collection.objects.unlink(arm)
    coll.objects.link(arm)
    obs = []
    for part in parts:
        ob = mesh_part(name + '_', part, V, coll)
        if ob is None:
            continue
        assign_weights(ob, part, sk, arm)
        if part.name == 'TopRolled':
            # only shown in the game while a downed player's top is rolled up
            ob.hide_render = True
            ob.hide_set(True)
        obs.append(ob)
    rig = hu_rig.Rig(arm, body)
    pose = pose_for(V)(rig)
    pose.apply(arm)
    arm.location = (x_off, 0, 0)
    return {'V': V, 'arm': arm, 'coll': coll, 'obs': obs, 'body': body, 'head': info['head'], 'rig': rig, 'pose': pose}


# ====================================================================== render setup
def setup_render(res):
    scn = bpy.context.scene
    scn.render.engine = 'BLENDER_EEVEE'
    scn.eevee.taa_render_samples = 32 if FAST else 96
    try:
        scn.eevee.use_raytracing = True
        scn.eevee.ray_tracing_options.resolution_scale = '1'
    except Exception:
        pass
    try:
        scn.eevee.use_shadows = True
    except Exception:
        pass
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100
    scn.view_settings.view_transform = 'AgX'
    try:
        scn.view_settings.look = 'AgX - Medium High Contrast'
    except Exception:
        pass
    scn.render.film_transparent = False


def studio():
    """A dark grey cyclorama, a soft key, a fill and a cool rim."""
    lights = []
    bpy.ops.mesh.primitive_plane_add(size=30, location=(0, 0, 0))
    floor = bpy.context.active_object
    floor.name = 'Floor'
    bpy.ops.mesh.primitive_plane_add(size=30, location=(0, 6, 5), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.active_object
    wall.name = 'Wall'
    m = bpy.data.materials.new('Backdrop')
    m.use_nodes = True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.05, 0.055, 0.06, 1)
    m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.8
    floor.data.materials.append(m)
    wall.data.materials.append(m)
    w = bpy.data.worlds.new('W')
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.025, 0.03, 1)
    w.node_tree.nodes['Background'].inputs['Strength'].default_value = 1.0
    bpy.context.scene.world = w
    return [floor, wall]


def add_light(kind, loc, target, energy, color=(1, 1, 1), size=1.0, name='L', spot=None):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == 'AREA':
        ld.size = size
    else:
        ld.shadow_soft_size = size
    if kind == 'SPOT' and spot:
        ld.spot_size = math.radians(spot[0])
        ld.spot_blend = spot[1]
    ob = bpy.data.objects.new(name, ld)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return ob


def camera(loc, target, lens):
    cd = bpy.data.cameras.new('cam')
    cd.lens = lens
    cd.clip_start = 0.01
    cam = bpy.data.objects.new('cam', cd)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    return cam


def clear(objs):
    for o in objs:
        bpy.data.objects.remove(o, do_unlink=True)


def render(name, res):
    setup_render(res)
    path = os.path.join(OUT, name + '.png')
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    log('wrote', path)


def show_only(chars, keys):
    for k, c in chars.items():
        vis = k in keys
        c['coll'].hide_render = not vis
        c['coll'].hide_viewport = not vis


def head_point(c, local=(0, -0.03, 0.0)):
    """Where a head-local point (at rest) is now, posed, in world space."""
    hd = c['head']
    rest = Vector(tuple(hd.world(np.array(local))))
    wp = c['pose'].world('head', rest)
    return c['arm'].matrix_world @ wp


# ====================================================================== animation strips
def char_bounds(c):
    """World bounding box of a character's posed meshes (evaluated, armature applied)."""
    dg = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in c['obs']:
        ev = ob.evaluated_get(dg)
        for corner in ev.bound_box:
            p = ev.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
    return lo, hi


def anim_strips(c, frames_per=6, clips=None):
    """Every clip of the shared human set, played on this character: a row of frames per clip."""
    arm = c['arm']
    body = c['body']
    clip_mods = (clips_for(c['V']),) if clips_for(c['V']) else (hu_rig, st_clips)
    for mod in clip_mods:
        mod.build_actions(arm, body)
    scn = bpy.context.scene
    tmp = os.path.join(OUT, '_tmp')
    os.makedirs(tmp, exist_ok=True)
    all_clips = []
    for mod in clip_mods:
        all_clips += list(mod.CLIPS.items())
    for name, (nf, loop, speed, about) in all_clips:
        if clips and name not in clips:
            continue
        act = bpy.data.actions[name]
        arm.animation_data.action = act
        # the Carried clip's origin is the belly on a carrier's shoulder: lift it to shoulder height
        base_z = arm.location.z
        if name == 'Carried':
            arm.location.z = base_z + 1.535 * body.s
        last = nf - 1
        fr = [int(round(last * i / (frames_per - 1 if not loop else frames_per))) for i in range(frames_per)]
        # frame the whole clip: the union of the bounds over its frames
        lo = Vector((1e9, 1e9, 1e9))
        hi = Vector((-1e9, -1e9, -1e9))
        for f in fr:
            scn.frame_set(f)
            a, b2 = char_bounds(c)
            lo = Vector((min(lo.x, a.x), min(lo.y, a.y), min(lo.z, a.z)))
            hi = Vector((max(hi.x, b2.x), max(hi.y, b2.y), max(hi.z, b2.z)))
        ctr = (lo + hi) * 0.5
        size = max((hi - lo).length, 0.8)
        d = Vector((0.95, -1.45, 0.30)).normalized()
        L = [add_light('AREA', ctr + Vector((-2.2, -3.0, 2.0)), ctr, 900, (1.0, 0.95, 0.88), 2.0, 'Key'),
             add_light('AREA', ctr + Vector((3.0, -2.0, 0.6)), ctr, 260, (0.85, 0.92, 1.0), 3.0, 'Fill'),
             add_light('AREA', ctr + Vector((1.5, 2.5, 1.8)), ctr, 700, (0.75, 0.88, 1.0), 1.5, 'Rim')]
        cam = camera(ctr + d * size * 2.1, ctr, 50)
        paths = []
        for i, f in enumerate(fr):
            scn.frame_set(f)
            p = os.path.join(tmp, '%s_%02d.png' % (name, i))
            setup_render((420, 560))
            scn.render.filepath = p
            bpy.ops.render.render(write_still=True)
            paths.append(p)
        clear(L + [cam])
        rows = []
        for p in paths:
            im = bpy.data.images.load(p)
            w, h = im.size
            px = np.empty(w * h * 4, np.float32)
            im.pixels.foreach_get(px)
            rows.append(px.reshape(h, w, 4))
            bpy.data.images.remove(im)
        strip = np.concatenate(rows, axis=1)
        H, W = strip.shape[:2]
        out = bpy.data.images.new('strip_' + name, W, H, alpha=True)
        out.pixels.foreach_set(strip.ravel())
        out.filepath_raw = os.path.join(OUT, 'anim_%s.png' % name)
        out.file_format = 'PNG'
        out.save()
        bpy.data.images.remove(out)
        arm.location.z = base_z
        log('strip', name, fr)
    arm.animation_data.action = None


# ====================================================================== game-ready export
def export_and_compare(c, name):
    import st_export
    importlib.reload(st_export)
    import hu_glb_extern
    variant = name + '_st'
    out_dir = os.path.join(HERE, 'out')
    os.makedirs(out_dir, exist_ok=True)
    orig = {o.name: list(o.data.materials) for o in c['obs']}
    is_hive = c['V'].get('hive', False)
    cm = clips_for(c['V'])
    res = st_export.export(c, out_dir, variant, tex=int(arg('tex', '2048')), ao_samples=int(arg('ao', '24')),
                           clips=(cm,) if cm else None)
    if is_hive:
        game_dir = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'models', 'monsters', 'hive'))
    elif c['V'].get('sono'):
        game_dir = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'models', 'monsters', 'sonographer'))
    else:
        game_dir = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'models', 'characters', 'human'))
    os.makedirs(game_dir, exist_ok=True)
    files, size = hu_glb_extern.extern(res['glb'], os.path.join(game_dir, variant + '.glb'), 'textures')
    import shutil
    for key in ('Skin', 'Cloth'):
        src = os.path.join(out_dir, 'textures', '%s_%s_mask.png' % (variant, key))
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(game_dir, 'textures', os.path.basename(src)))
    log('game copy', game_dir, size // 1024, 'KB', [f for f, _ in files])
    # before / after: the dense sculpt and the game mesh in the same pose, same camera
    for ob in c['obs']:
        ob.data.materials.clear()
        for m in orig[ob.name]:
            ob.data.materials.append(m)
    arm = c['arm']
    arm.animation_data.action = None
    rig = hu_rig.Rig(arm, c['body'])
    pose_for(c['V'])(rig).apply(arm)
    bpy.context.view_layer.update()
    shots = []
    for tag, show_high in (('dense', True), ('game', False)):
        for ob in c['obs']:
            ob.hide_render = not show_high
            ob.hide_set(not show_high)
        for ob in res['pieces']:
            ob.hide_render = show_high
            ob.hide_set(show_high)
        for view, cam_at, tgt, lens, rs in (('body', (2.0, -4.4, 1.25), (0, 0, 0.93), 70, (700, 1000)),
                                            ('face', None, None, 85, (800, 800))):
            if view == 'face':
                hp = head_point(c, (0, -0.02, 0.0))
                fwd = head_point(c, (0, -0.3, 0.0)) - hp
                fwd.z *= 0.6
                fwd.normalize()
                side = Vector((-fwd.y, fwd.x, 0))
                d = (fwd * math.cos(0.35) + side * math.sin(0.35)).normalized()
                cam_at, tgt = hp + d * 0.62 + Vector((0, 0, 0.02)), hp
            L = [add_light('AREA', Vector(tgt) + Vector((-2.2, -3.0, 2.0)), tgt, 900 if view == 'body' else 225, (1.0, 0.95, 0.88), 2.0, 'Key'),
                 add_light('AREA', Vector(tgt) + Vector((3.0, -2.0, 0.6)), tgt, 260 if view == 'body' else 65, (0.85, 0.92, 1.0), 3.0, 'Fill'),
                 add_light('AREA', Vector(tgt) + Vector((1.5, 2.5, 1.8)), tgt, 700 if view == 'body' else 175, (0.75, 0.88, 1.0), 1.5, 'Rim')]
            cam = camera(cam_at, tgt, lens)
            render('export_%s_%s' % (view, tag), rs)
            clear(L + [cam])
    for view in ('body', 'face'):
        rows = []
        for tag in ('dense', 'game'):
            im = bpy.data.images.load(os.path.join(OUT, 'export_%s_%s.png' % (view, tag)))
            w, h = im.size
            px = np.empty(w * h * 4, np.float32)
            im.pixels.foreach_get(px)
            rows.append(px.reshape(h, w, 4))
            bpy.data.images.remove(im)
        strip = np.concatenate(rows, axis=1)
        H, W = strip.shape[:2]
        o = bpy.data.images.new('cmp', W, H, alpha=True)
        o.pixels.foreach_set(strip.ravel())
        o.filepath_raw = os.path.join(OUT, 'compare_%s.png' % view)
        o.file_format = 'PNG'
        o.save()
    log('tris', res['tris'])


def want(shot):
    return SHOTS == 'all' or shot in SHOTS.split(',')


def main():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    os.makedirs(OUT, exist_ok=True)
    chars = {}
    layout = {'surgeon': -0.45, 'hive': 0.50, 'surgeon_graft': 3.0, 'sonographer': 0.50}
    for name in ONLY:
        chars[name] = build_variant(name, layout[name])
    studio()
    bpy.context.view_layer.update()
    if '--export' in ARGS:
        export_and_compare(chars[ONLY[0]], ONLY[0])
        log('done')
        return
    if '--anim' in ARGS:
        clips = arg('clips', '')
        anim_strips(chars[ONLY[0]], clips=clips.split(',') if clips else None)
        log('done')
        return
    std = []

    def std_lights(target=(0, 0, 1.2), spread=1.0):
        return [
            add_light('AREA', (target[0] - 2.2, target[1] - 3.0, 3.0), target, 900 * spread, (1.0, 0.95, 0.88), 2.0, 'Key'),
            add_light('AREA', (target[0] + 3.0, target[1] - 2.0, 1.6), target, 260 * spread, (0.85, 0.92, 1.0), 3.0, 'Fill'),
            add_light('AREA', (target[0] + 1.5, target[1] + 2.5, 2.8), target, 700 * spread, (0.75, 0.88, 1.0), 1.5, 'Rim'),
        ]

    if 'surgeon' in chars and 'hive' in chars:
        show_only(chars, ('surgeon', 'hive'))
        if want('pair'):
            L = std_lights((0.0, 0.0, 1.0))
            cam = camera((1.2, -4.3, 1.25), (0.02, 0, 0.92), 50)
            render('pair', (1600, 1000))
            clear(L + [cam])
        if want('pair_side'):
            L = std_lights((0.0, 0.0, 1.0))
            cam = camera((4.4, -0.9, 1.15), (0.0, 0, 0.92), 50)
            render('pair_side', (1600, 1000))
            clear(L + [cam])
        if want('pair_dark'):
            # the game's look: near dark, a teal ambient, a warm flashlight from the viewer
            bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.004, 0.012, 0.012, 1)
            cam = camera((0.35, -4.0, 1.62), (0.05, 0, 1.05), 32)
            fl = add_light('SPOT', (0.55, -3.9, 1.50), (0.05, 0, 1.05), 900, (1.0, 0.82, 0.58), 0.05, 'Flash', spot=(40, 0.6))
            amb = add_light('AREA', (0, 0, 3.0), (0, 0, 0), 40, (0.35, 0.8, 0.75), 4.0, 'Amb')
            render('pair_dark', (1600, 1000))
            clear([cam, fl, amb])
            bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.025, 0.03, 1)
    if 'surgeon' in chars:
        show_only(chars, ('surgeon',))
        x0 = layout['surgeon']
        for shot, cam_at in (('surgeon_front', (x0, -5.2, 1.0)), ('surgeon_side', (x0 + 5.2, 0.0, 1.0)),
                             ('surgeon_34', (x0 + 2.4, -4.4, 1.25))):
            if not want(shot):
                continue
            L = std_lights((x0, 0.0, 1.0))
            cam = camera(cam_at, (x0, 0, 0.93), 70)
            render(shot, (900, 1200))
            clear(L + [cam])
    def eye_lights(c, on):
        """Orange spill from each glowing eye (only when locked on)."""
        if not on:
            return []
        hd = c['head']
        out = []
        for sx in (1, -1):
            ec = hd.eye_c
            p = head_point(c, (sx * ec[0], ec[1] - hd.eye_r * 1.6, ec[2]))
            out.append(add_light('POINT', tuple(p), tuple(p + Vector((0, -1, 0))), 0.12, HIVE_GLOW, 0.004, 'EyeGlow'))
        return out

    if 'hive' in chars:
        show_only(chars, ('hive',))
        c = chars['hive']
        x0 = layout['hive']
        for shot, cam_at, tgt, lens, res in (('hive_side', (3.9, -1.2, 1.1), (0.5, 0, 0.9), 50, (1000, 1000)),
                                             ('hive_front', (x0, -5.2, 1.1), (x0, 0, 0.9), 70, (900, 1200)),
                                             ('hive_34', (x0 + 2.4, -4.4, 1.35), (x0, 0, 0.9), 70, (900, 1200)),
                                             ('hive_back', (x0 - 1.6, 4.6, 1.5), (x0, 0, 0.95), 70, (900, 1200))):
            if want(shot):
                L = std_lights((x0, 0.0, 1.0))
                cam = camera(cam_at, tgt, lens)
                render(shot, res)
                clear(L + [cam])
        if want('hive_top'):
            # looking down at the open skull from above and in front
            hp = head_point(c, (0, 0.01, 0.07))
            L = std_lights(tuple(hp), 0.25)
            cam = camera(hp + Vector((0.18, -0.32, 0.42)), hp, 70)
            render('hive_top', (1000, 1000))
            clear(L + [cam])
        for lock in (0.0, 1.0):
            set_lock(lock)
            sfx = '_lock' if lock else ''
            if want('hive_dark' + sfx):
                # the game's look: near dark, a teal ambient, a warm flashlight from the viewer
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.004, 0.012, 0.012, 1)
                tgt = (x0, 0, 1.2)
                cam = camera((x0 + 0.3, -3.2, 1.62), tgt, 32)
                fl = add_light('SPOT', (x0 + 0.5, -3.1, 1.50), tgt, 700, (1.0, 0.82, 0.58), 0.05, 'Flash', spot=(40, 0.6))
                amb = add_light('AREA', (x0, 0, 3.0), (x0, 0, 0), 40, (0.35, 0.8, 0.75), 4.0, 'Amb')
                el = eye_lights(c, lock)
                render('hive_dark' + sfx, (1400, 1000))
                clear([cam, fl, amb] + el)
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.025, 0.03, 1)
            if want('hive_black' + sfx):
                # no flashlight at all: what you see of it down a dark corridor
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.002, 0.005, 0.005, 1)
                cam = camera((x0 + 0.2, -3.6, 1.55), (x0, 0, 1.25), 40)
                amb = add_light('AREA', (x0, 0, 3.0), (x0, 0, 0), 12, (0.35, 0.8, 0.75), 4.0, 'Amb')
                el = eye_lights(c, lock)
                render('hive_black' + sfx, (1400, 1000))
                clear([cam, amb] + el)
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.025, 0.03, 1)
        set_lock(0.0)
    if 'sonographer' in chars:
        show_only(chars, ('sonographer',))
        c = chars['sonographer']
        x0 = layout['sonographer']
        for shot, cam_at, tgt, lens, res in (('sono_front', (x0, -5.6, 1.15), (x0, 0, 1.02), 70, (900, 1300)),
                                             ('sono_side', (x0 + 5.0, -0.5, 1.15), (x0, 0, 1.02), 70, (900, 1300)),
                                             ('sono_34', (x0 + 2.6, -4.8, 1.45), (x0, 0, 1.02), 70, (900, 1300)),
                                             ('sono_back', (x0 - 1.7, 4.8, 1.60), (x0, 0, 1.05), 70, (900, 1300))):
            if want(shot):
                L = std_lights((x0, 0.0, 1.1))
                cam = camera(cam_at, tgt, lens)
                render(shot, res)
                clear(L + [cam])
        nz = 0.5 * (c['body'].J['neck'].z + c['body'].HC.z)
        for charge in (0.0, 1.0):
            set_charge(charge)
            sfx = '_charge' if charge else ''
            if want('sono_throat' + sfx):
                # the long neck and the window in it, from the front and a little below
                tgt = (x0, 0.0, nz)
                L = std_lights(tgt, 0.3)
                cam = camera((x0 + 0.10, -0.85, nz - 0.08), tgt, 85)
                render('sono_throat' + sfx, (900, 1100))
                clear(L + [cam])
            if want('sono_dark' + sfx):
                # the game's look: near dark, a teal ambient, a warm flashlight from the viewer
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.004, 0.012, 0.012, 1)
                tgt = (x0, 0, 1.35)
                cam = camera((x0 + 0.3, -3.4, 1.70), tgt, 32)
                fl = add_light('SPOT', (x0 + 0.5, -3.3, 1.58), tgt, 700, (1.0, 0.82, 0.58), 0.05, 'Flash', spot=(40, 0.6))
                amb = add_light('AREA', (x0, 0, 3.4), (x0, 0, 0), 40, (0.35, 0.8, 0.75), 4.0, 'Amb')
                render('sono_dark' + sfx, (1400, 1100))
                clear([cam, fl, amb])
                bpy.context.scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.02, 0.025, 0.03, 1)
        set_charge(0.0)
    for key, shot in (('surgeon', 'face_surgeon'), ('hive', 'face_hive'), ('hive', 'face_hive_lock'),
                      ('sonographer', 'face_sono'), ('surgeon_graft', 'face_graft')):
        if key not in chars or not want(shot):
            continue
        show_only(chars, (key,))
        c = chars[key]
        lock = shot.endswith('_lock')
        set_lock(1.0 if lock else 0.0)
        hp = head_point(c, (0, -0.02, 0.0))
        fwd = head_point(c, (0, -0.3, 0.0)) - hp
        fwd.z *= 0.6
        fwd.normalize()
        side = Vector((-fwd.y, fwd.x, 0))
        angles = (('', 0.35, 0.62), ('_front', 0.0, 0.58)) if lock else (('', 0.35, 0.62), ('_front', 0.0, 0.58), ('_side', 1.45, 0.55))
        for tag, ang, dist in angles:
            d = (fwd * math.cos(ang) + side * math.sin(ang)).normalized()
            L = std_lights(tuple(hp), 0.25) + eye_lights(c, lock)
            cam = camera(hp + d * dist + Vector((0, 0, 0.02)), hp, 85)
            render(shot + tag, (1000, 1000))
            clear(L + [cam])
        set_lock(0.0)
    if 'surgeon_graft' in chars and want('graft_full'):
        show_only(chars, ('surgeon_graft',))
        L = std_lights((3.0, 0.0, 1.0))
        cam = camera((3.9, -3.0, 1.35), (3.0, 0, 0.95), 50)
        render('graft_full', (1000, 1200))
        clear(L + [cam])
    if want('save'):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, 'stylized_test.blend'), compress=True)
    log('done')


main()
