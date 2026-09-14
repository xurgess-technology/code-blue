"""The human variations as data. Every variation shares topology rules, the skeleton layout and the
animations; only these numbers change. hu_geometry reads a merged dict (BASE, then the variation).

Units: metres. Blender axes: Z up, the character faces -Y, its left is +X.
"""

BASE = {
    'name': 'base',
    'height': 1.78,        # crown height; the whole skeleton scales from the 1.78 m reference
    'fem': 0.0,            # 0 male .. 1 female: shoulders, hips, waist, chest, jaw, brow
    'girth': 1.0,          # limb and trunk radius multiplier (slender is ~0.95)
    'belly': 0.0,          # 0 flat .. 1 a real paunch
    'shoulders': 1.0,      # shoulder width multiplier
    'age': 0.3,            # 0 young .. 1 old: sag, nasolabial folds, jowls, skin creases
    'head_scale': 1.0,
    # face
    'jaw': 0.5,            # 0 narrow pointed .. 1 wide square
    'chin': 0.5,           # chin projection
    'brow': 0.5,           # brow ridge
    'nose_len': 0.5, 'nose_w': 0.5, 'nose_bridge': 0.5,
    'lips': 0.5,           # fullness
    'cheek': 0.5,          # cheekbone prominence
    'eye_w': 0.5,          # eye opening width
    'eye_open': 0.5,       # tired heavy lids .. wide
    'ears': 0.5,
    'face_seed': 1,        # small asymmetries
    # colours (linear-ish sRGB triplets; the material converts)
    'skin': (0.62, 0.45, 0.36),
    'skin_red': 0.5,       # flush on cheeks, nose, ears, knuckles
    'iris': (0.25, 0.17, 0.10),
    'hair_col': (0.06, 0.045, 0.035),
    'hair': 'crop',        # crop | buzz | balding | bun | ponytail
    'hair_len': 1.0,
    'brows_col': None,     # default: hair colour
    'beard': 0.0,          # 0 clean-shaven .. 1 heavy stubble / short beard (texture)
    'moustache': False,
    # clothes
    'outfit': 'scrubs',    # scrubs | gown | paramedic
    'cloth_col': (0.24, 0.56, 0.50),   # scrubs are baked in C.PLAYER_COLORS[0] and recoloured in engine
    'cap': 'tie',          # none | tie | bouffant
    'mask': True,          # a separate mesh the game can hide
    'shoes': 'clog',       # clog | sneaker | boot | sock
    'grime': 0.5,
    'blood': 0.4,
    'seed': 3,
    # surgery sites
    'gash': False,         # players: belly gash topology + GashOpen shape key + rolled-up top pieces
    'amputee_arm': False,  # Bob: separate right forearm + stump cap + infection UV2
    'gown_window': False,  # Bob: gown panel over the gunshot site
}

VARIANTS = {
    # ---------------------------------------------------------------- players / surgeons
    'surgeon_a': dict(
        name='surgeon_a', height=1.80, fem=0.0, girth=0.94, shoulders=1.0, age=0.35,
        jaw=0.55, chin=0.55, brow=0.6, nose_len=0.6, nose_w=0.45, nose_bridge=0.65, lips=0.4, cheek=0.55,
        eye_w=0.5, eye_open=0.35, ears=0.5, face_seed=11,
        skin=(0.80, 0.63, 0.53), skin_red=0.55, iris=(0.20, 0.26, 0.30), hair_col=(0.05, 0.035, 0.025),
        hair='crop', beard=0.35, cap='tie', mask=True, shoes='clog', gash=True, blood=0.45, seed=5),
    'surgeon_b': dict(
        name='surgeon_b', height=1.68, fem=1.0, girth=0.93, shoulders=0.98, age=0.25,
        jaw=0.35, chin=0.45, brow=0.25, nose_len=0.45, nose_w=0.6, nose_bridge=0.35, lips=0.75, cheek=0.7,
        eye_w=0.55, eye_open=0.5, ears=0.4, face_seed=23,
        skin=(0.36, 0.23, 0.16), skin_red=0.25, iris=(0.12, 0.07, 0.04), hair_col=(0.025, 0.02, 0.018),
        hair='bun', beard=0.0, cap='bouffant', mask=True, shoes='sneaker', gash=True, blood=0.35, seed=8),
    'surgeon_c': dict(
        name='surgeon_c', height=1.75, fem=0.0, girth=1.0, shoulders=1.04, age=0.45,
        jaw=0.7, chin=0.4, brow=0.5, nose_len=0.45, nose_w=0.6, nose_bridge=0.45, lips=0.5, cheek=0.35,
        eye_w=0.45, eye_open=0.45, ears=0.65, face_seed=37,
        skin=(0.90, 0.74, 0.64), skin_red=0.8, iris=(0.30, 0.38, 0.22), hair_col=(0.30, 0.13, 0.05),
        hair='crop', hair_len=0.7, beard=0.7, cap='tie', mask=True, shoes='sneaker', gash=True, blood=0.5, seed=13),
    # ---------------------------------------------------------------- Bob, the patient
    'bob': dict(
        name='bob', height=1.75, fem=0.0, girth=1.16, belly=1.0, shoulders=1.02, age=0.85,
        jaw=0.65, chin=0.35, brow=0.55, nose_len=0.65, nose_w=0.7, nose_bridge=0.5, lips=0.4, cheek=0.35,
        eye_w=0.45, eye_open=0.3, ears=0.7, face_seed=51,
        skin=(0.84, 0.70, 0.60), skin_red=0.7, iris=(0.22, 0.20, 0.16), hair_col=(0.34, 0.32, 0.30),
        hair='balding', beard=0.45, moustache=True, outfit='gown', cloth_col=(0.42, 0.55, 0.60),
        cap='none', mask=False, shoes='sock', grime=0.6, blood=0.2, seed=21,
        amputee_arm=True, gown_window=True),
    # ---------------------------------------------------------------- paramedics
    'paramedic_a': dict(
        name='paramedic_a', height=1.83, fem=0.0, girth=0.97, shoulders=1.05, age=0.4,
        jaw=0.6, chin=0.6, brow=0.55, nose_len=0.5, nose_w=0.65, nose_bridge=0.4, lips=0.6, cheek=0.5,
        eye_w=0.5, eye_open=0.45, ears=0.45, face_seed=67,
        skin=(0.56, 0.40, 0.30), skin_red=0.3, iris=(0.10, 0.06, 0.04), hair_col=(0.02, 0.018, 0.016),
        hair='buzz', beard=0.55, outfit='paramedic', cloth_col=(0.10, 0.16, 0.11),
        cap='none', mask=False, shoes='boot', grime=0.6, blood=0.3, seed=31),
    'paramedic_b': dict(
        name='paramedic_b', height=1.70, fem=1.0, girth=0.95, shoulders=1.0, age=0.3,
        jaw=0.4, chin=0.5, brow=0.3, nose_len=0.5, nose_w=0.45, nose_bridge=0.55, lips=0.55, cheek=0.6,
        eye_w=0.5, eye_open=0.5, ears=0.45, face_seed=79,
        skin=(0.88, 0.72, 0.62), skin_red=0.6, iris=(0.24, 0.30, 0.34), hair_col=(0.16, 0.10, 0.06),
        hair='ponytail', beard=0.0, outfit='paramedic', cloth_col=(0.10, 0.16, 0.11),
        cap='none', mask=False, shoes='boot', grime=0.55, blood=0.25, seed=43),
}

ORDER = ['surgeon_a', 'surgeon_b', 'surgeon_c', 'bob', 'paramedic_a', 'paramedic_b']


def get(name):
    p = dict(BASE)
    p.update(VARIANTS[name])
    if p['brows_col'] is None:
        p['brows_col'] = tuple(c * 0.8 for c in p['hair_col']) if p['hair'] != 'balding' else (0.18, 0.16, 0.15)
    return p
