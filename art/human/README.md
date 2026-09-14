# The human: Blender sources (art pass, for review)

**In the game since 2026-09-14** (players, Bob, the paramedics and the downed player on the table:
`scripts/human/human_model.gd`, `scripts/patients/bob_model_builder.gd`, docs/CONTRACTS.md "The human
models"). The art pass below built the base human, the players/surgeons, Bob and the
paramedics the same way as the Night Nurse (scripted in Blender 5.2.1, headless, no downloaded or
generated models) and stopped for review; the wiring came after. The game copies are in
`assets/models/characters/human/` (one GLB per variation, maps as separate PNGs); the look-dev
viewer is `art/human/viewer/human_viewer.tscn`; sources, renders and screenshots are here.

## Folder

| Path | What |
|---|---|
| `../../assets/models/characters/human/<variant>.glb` | Skinned pieces, 2 materials, 11 clips, site markers |
| `../../assets/models/characters/human/textures/` | albedo (AO folded in), roughness, normal per material at 2048; `*_mask.png` at 1024 |
| `../../assets/models/characters/human/shaders/` | Reference shaders: player tint, reflective strips, vein, gash, wound, infection |
| `blender_src/hu_params.py` | **The variations as data** (height, build, face, colours, hair, outfit, surgery pieces) |
| `blender_src/hu_body.py` | Skeleton, the SDF skin (trunk, neck, head), face features, eyes and lids, ears, arms, hands, legs, weights |
| `blender_src/hu_outfit.py` | Hair, cap, mask, scrubs, gown, paramedic uniform, footwear, skin culling, the surgery pieces, site frames |
| `blender_src/hu_mesh.py` | Part container: grids, fans, slabs, splits with shared seams, custom normals, shape keys |
| `blender_src/hu_materials.py` | Procedural Cycles materials the maps are baked from, and the mask channels |
| `blender_src/hu_rig.py` | Armature, the poser (armature-space rotations + two-bone IK) and every clip |
| `blender_src/hu_build.py` | One variation end to end: mesh, UV pack, rig, clips, sites, bake, `.blend`, GLB, sites JSON |
| `blender_src/hu_render.py`, `hu_anim_sheet.py`, `hu_lineup.py`, `hu_preview.py` | Look-dev renders, clip strips, the lineup, quick clay previews |
| `blender_src/<variant>.blend`, `<variant>_sites.json` | Built sources; the JSON has every site in numbers |
| `renders/<variant>/`, `renders/lineup*.png` | Blender renders |
| `godot_shots/` | In-engine 1280x720 screenshots from the viewer |

## Rebuild

```
cd art/human/blender_src
blender --background --factory-startup --python hu_build.py -- --variant=bob [--tex=2048] [--ao-samples=24]   # 10-35 min with a full bake
./run_all.sh                                   # every variation in parallel (THREADS, TEX, AO env vars)
blender --background bob.blend --python hu_render.py                 # look-dev sheet into renders/bob/
blender --background bob.blend --python hu_anim_sheet.py             # clip strips
blender --background --factory-startup --python hu_lineup.py         # renders/lineup*.png
# iterate fast: --nobake (about 40 s, procedural materials, render with --engine=cycles), or
# hu_preview.py -- --variant=bob [--skin-only] for clay shots of the geometry alone (about 10 s)

cd ../../..
godot --headless --path . --import
godot --path . --resolution 1280x720 art/human/viewer/human_viewer.tscn [-- --only=or_bob_gunshot]
godot --headless --path . art/human/viewer/human_viewer.tscn -- --report      # tris, bones, clips, sites per GLB
```

## Design

Slender, normally proportioned adults (not chibi, not the Nurse's stretched horror), grim and a
little tired: dirty scrubs with blood spatter, a sallow patient, worn uniforms. Everything is
parameterised in `hu_params.py`; a new variation is a dict, not a copy.

| Variation | Who | Height | Build | Outfit | Hair / face |
|---|---|---|---|---|---|
| `surgeon_a` | player | 1.80 | slender (girth 0.94) | teal scrubs, tie cap, mask, clogs | dark crop, stubble, grey-blue eyes |
| `surgeon_b` | player | 1.68 | slender female | scrubs, bouffant cap over a bun, mask, sneakers | dark skin, full lips |
| `surgeon_c` | player | 1.75 | a bit broader | scrubs, tie cap, mask, sneakers | pale, ginger crop, heavy stubble |
| `bob` | patient | 1.75 | heavier (girth 1.16, paunch) | printed gown, grip socks | 50s, balding horseshoe, moustache stubble, sallow |
| `paramedic_a` | crew | 1.83 | broad shoulders | dark green uniform, reflective strips, belt, cargo pockets, boots | buzz cut, beard stubble |
| `paramedic_b` | crew | 1.70 | slender female | same uniform | ponytail |

## How it is made

- **Skin.** Trunk, neck and head are one continuous grid. Up to the ear canals each row is a
  horizontal slice: rays from the body axis, marched *inwards from outside* against a smooth-union
  signed distance field (superellipse trunk slices, a neck capsule, and ellipsoids for the cranium,
  forehead, midface, mouth, jaw, chin, jaw angles and cheekbones). Above, rays from the head centre
  rise to the crown. Row heights are placed by arc length along eight meridians, with more rows
  across the face (and across the belly on the players, for the gash). The face features (nose
  ridge and tip, alae and nostrils, lips and mouth line, philtrum, brows, cheek pads, nasolabial
  folds, jowls) are displacements along the ray; the sockets are carved under the lid shells.
- **Eyes and lids.** Eyeballs with a cornea bulge; each lid is a shell over the eyeball whose
  margin touches the ball and whose far rows blend into the uncarved skin, so the opening is an
  almond with a real lid thickness. **Ears** are closed slabs with a helix rim, antihelix and concha.
- **Arms** are one sweep from inside the shoulder to the knuckles (deltoid, biceps, olecranon,
  forearm taper, wrist bones, thenar and hypothenar pads, knuckle bumps, a rounded palm end), with
  finger tubes buried in the palm. **Legs** are sweeps from inside the pelvis to inside the footwear.
- **Garments** are offset surfaces of the same field (trunk) or the same limb profiles (sleeves,
  trouser legs), with folds, hems turned inwards and bands. Skin hidden under a garment is culled
  (with margins), except where a surgery exposes it.
- **Two resolutions from the same functions.** `res=1` is the game mesh; `res=3` plus one
  subdivision (about 1.2 M triangles) is the bake source.
- **Bake.** Cycles selected-to-active, **per material against a source of that material only**
  (so skin under a garment never catches cloth), then dilated: albedo, roughness, tangent normals
  and a mask texture; AO comes from a local-only AO node (0.18 m) and is folded into the albedo.
- **Weights** are analytic, written at generation: the spine chain blends by height, the head
  weight comes from which SDF primitive owns the point, the shoulders and thighs pull nearby trunk
  skin, the limbs blend by arc length at each joint, fingers per phalanx. Garments use the same
  functions (the gown's skirt blends hips into thighs). Up to 4 influences.
- **Clips** are authored procedurally in armature space: absolute bone orientations plus analytic
  two-bone IK. The gaits plant the ball of the foot and move it back at exactly the clip speed,
  rolling onto the toes before lifting, so they do not slide at their documented speed.

## Stats (per GLB, Godot's import agrees)

| Variation | Tris total | Main `Human` | Pieces | Surfaces | Bones |
|---|---|---|---|---|---|
| surgeon_a | 19,876 | 16,440 | TopLower 560, TopRolled 704, GashSkin 536, Cap 760, Mask 876 | 7 | 53 |
| surgeon_b | 20,056 | 16,688 | TopLower 560, TopRolled 704, GashSkin 556, Cap 672, Mask 876 | 7 | 53 |
| surgeon_c | 20,048 | 16,610 | TopLower 560, TopRolled 704, GashSkin 538, Cap 760, Mask 876 | 7 | 53 |
| bob | 16,864 | 15,168 | GownPanel 120, Forearm_R 1,576 | 4 | 53 |
| paramedic_a | 16,880 | 16,880 | none | 2 | 53 |
| paramedic_b | 16,736 | 16,736 | none | 2 | 53 |

What is drawn at once is lower: a standing player never shows TopRolled (-704), a player on the
table hides TopLower and usually the mask. Two materials per character (`Human_Cloth`,
`Human_Skin`), six 2048 maps plus two 1024 masks, VRAM-compressed on import. GLB about 1.3-1.5 MB,
textures about 25 MB per variation on disk.

## Game pieces (mesh nodes under the one Skeleton3D)

| Node | Variations | Default | What |
|---|---|---|---|
| `Human` | all | shown | body, hair, clothes, footwear |
| `Human_Cap`, `Human_Mask` | surgeons | shown | the cap/mask option: hide either |
| `Human_TopLower` | surgeons | shown | the scrub top below the ring at z 1.262·s |
| `Human_TopRolled` | surgeons | **hide** | the rolled-up hem; show it and hide TopLower to bare the belly |
| `Human_GashSkin` | surgeons | shown | the belly skin round the gash, blend shape `GashOpen` |
| `Human_GownPanel` | bob | shown | the gown panel over the gunshot site; hide it for the forceps step |
| `Human_Forearm_R` | bob | shown | the right forearm and hand (with its own cut cap); hide it when amputated |

Pieces share positions and custom normals along their seams, so there is no visible line.
`Site_<name>` nodes ride the bones (imported as children of `BoneAttachment3D`).

## Clips (30 fps, in place, no root motion; rates = speed / clip speed)

| Clip | Frames | Loop | Speed | Notes |
|---|---|---|---|---|
| `Idle` | 120 | yes | 0 | breathing, weight shifts, a slow look round |
| `Walk` | 32 | yes | 1.40 m/s | crew and patients; the Walk-In's 0.8-1.8 m/s |
| `Jog` | 22 | yes | 3.40 m/s | the players' `C.WALK_SPEED` |
| `Sprint` | 18 | yes | 5.60 m/s | `C.SPRINT_SPEED` |
| `Push` | 34 | yes | 1.25 m/s | hands on a bar 0.98·s up, 0.50·s ahead, 0.44·s apart (the crew's gurney speed) |
| `Interact` | 30 | no | - | reach and press/grab at chest height 0.56·s ahead |
| `PickUp` | 42 | no | - | squat, grab 0.36·s ahead on the floor, stand holding it at chest height |
| `Crawl` | 48 | yes | 0.75 m/s | downed, prone; `CRAWL_SPEED`; planted hands keep pace |
| `Carried` | 60 | yes | - | slung over a right shoulder; **origin = the belly contact point** |
| `Carrying` | 60 | yes | - | the carrier's upper body; blend it over Walk/Idle with a bone mask |
| `Lying` | 90 | yes | - | on the back, breathing; **origin = middle of the back on the table top**, head towards model -Z (Blender +Y), arms at the sides within ±0.33 m |

`s` = height / 1.78. Carry: put the Carried model's origin at the carrier's model-space point
(-0.150, 1.535, -0.030)·s (glTF/Godot axes before the registry yaw) with the carrier's basis;
the viewer's `carry` shot does exactly this.

## Axes

Blender: Z up, faces -Y, left is +X. The GLB (Godot, before any yaw): Y up, **faces +Z**, left
is +X, feet at y 0. An `Assets` entry with `yaw: 180` makes it face -Z like the other characters.
Bone names: `hips spine chest upperchest neck head`, `shoulder upperarm forearm hand`,
`thumb1-3 index1-3 middle1-3 ring1-3 pinky1-3`, `thigh shin foot toe`, each `.L`/`.R`, plus `root`.

## Surgery sites

Every site is a `Site_<name>` node in the GLB, parented to its bone, in the PatientBody convention:
**+Y out of the skin, +X along the limb (distal) or along the body towards the feet, Z = X cross Y**.
They follow the pose, so in `Lying` they point up off the table. The numbers for each variation
(bone, glTF-space origin and axes in the rest pose, sections, infection distances) are in
`blender_src/<variant>_sites.json`; `s` below = height / 1.78. Arc lengths along the arm are
measured from the shoulder joint and are what UV2.x stores.

| Site | Bone | Where (rest) | Section / extras (Bob; the others scale) |
|---|---|---|---|
| `limb` (tourniquet) | `upperarm.R` | 7.5·s cm above the elbow, front (thumb side) of the right arm | `half_up` 0.049, `half_side` 0.049, `axis_depth` = half_up, `shape` 2.2; infection starts 0.172 m along +X |
| `limb_cut` | `forearm.R` | 7·s cm below the elbow, **exactly on the ring where Forearm_R splits** | `half_up` 0.041, `half_side` 0.038, `shape` 2.2; infection starts 0.030 m past the cut, fully rotten 0.05 m later |
| `injection` | `forearm.L` | the inner left elbow (antecubital fossa), between the front and the palm side | the arm's section there; the vein is mask R |
| `gunshot` | `hips` | right lower belly (azimuth -0.62 rad, 1.035·s up), inside the gown window | mask B is the wound disc, radius 3·s cm |
| `gash` | `spine` | right of the navel (azimuth -0.34 rad), centre 1.11·s up, vertical | `half_len` 0.096·s, `half_gap` 0.016·s (players only) |
| `eyes` | `head` | between the eyes | camera and eye anchor |

In the patient frame of `patient_body.gd` (lying along X, head -X, face up) the character's right
arm is on +Z, so the amputation arm is the right arm and the injection arm the left, as today.

### Bob, gunshot (forceps)

The gown has a real opening: `Human_GownPanel` is the gown between azimuths -1.30 and +0.02 rad and
0.90-1.15·s up (about 30 x 25 cm), sharing its seam with the gown, which is edged with piping.
Hide the panel and the belly skin is there (kept, never culled), with the wound site in the middle
and at least 10 cm of bare skin round it. Around the window the gown sits 1.2-2 cm off the skin, so
nothing pokes through the forceps skin patch (`PATCH_Y` 0.02 over the site plane). The skin
shader's `wound` uniform paints the entry wound from mask B; the game's own wound overlay can keep
hanging on `Site_gunshot`.

### Bob, amputation (tourniquet, saw, gauze)

- The right arm sweep has a ring exactly at the cut. `Human_Forearm_R` is everything past it plus
  the right fingers; the upper arm in `Human` ends at the same ring with a **stump cap** (skin edge,
  a fat ring, muscle, the bone ends), always present and hidden back to back inside the arm while
  the forearm shows. **Hide `Human_Forearm_R` to amputate**; no bone scaling is needed.
- The severed piece: `Human_Forearm_R` carries its own flesh cap at the cut, so
  `MeshInstance3D.bake_mesh_from_current_skeleton_pose()` on it gives the severed forearm posed where
  it is (`hu_render.py` shot `forearm_cut` shows exactly that).
- Infection past the cut: UV2.x is metres along the arm and UV2.y is +1 on the right arm (forearm,
  hand and fingers included), so a shader grades it without vertex colours. The reference
  `human_skin.gdshader` does it with `infect`, `infect_from` and `infect_full`.
- `site_section()` for `limb` and `limb_cut` is in the JSON. The forearm there is a flattened
  ellipse, so `shape` 2.2 fits better than the Kenney rig's boxy 6.

### Anesthetic

The inner left elbow has a blue vein line in the albedo (and a faint old-needle bruise on Bob).
Mask R is that vein, for the minigame's always-visible target (`vein_glow` in the shader).

### Stitches (players)

- The belly has denser rows and columns warped towards the gash line, so the gash crosses about
  20 rows at 1 cm spacing with columns about 1 cm apart. `Human_GashSkin` is that patch as its own
  small mesh with the blend shape **`GashOpen`** (0 closed skin, 1 the edges pulled 1.6·s cm apart
  and sunk 1·s cm along the line). Only this 540-triangle piece carries a blend shape.
- Mask G is the gash for the shader (`gash` uniform: raw flesh by the same amount).
- To bare it: hide `Human_TopLower` and show `Human_TopRolled`, a rolled hem on the exact ring the
  top splits at. The trousers stay on; the belly skin between the waistband and the roll is kept.

### Carrying, the table, crawling

`Carried` hangs the body over a right shoulder with the head behind, the chest facing the
carrier's back, the legs down the front and the arms dangling. `Lying` is flat on the back with
the arms at the sides, inside a 1.1 m table. `Crawl` is a prone pull with the chest lifted and the
head up. None of them self-intersect badly; the gown does not drape when lying (it keeps its
standing shape a few centimetres above the belly).

## Deriving the Walk-In and the Discharged

- Start from `hu_params.py`: a new entry (or a new `outfit`) covers most changes, and the whole
  pipeline (skin, rig, clips, bake, GLB, sites JSON) comes for free. Keep the skeleton: the clips,
  weights and sites all depend on the bone names and the A-pose.
- **Walk-In (a diseased, broken human)**: Bob's gown or torn scrubs; `age` and `girth` for gaunt or
  bloated; the skin material already has mottling, vein and bruise inputs (push them, and add
  necrosis like the Nurse's). A limp or a dragged foot is a change to `gait_pose` in `hu_rig.py`,
  as the Nurse's drag was. Filmed eyes, jowls and an open mouth are head features in
  `hu_body._head_feats` plus the eye material. The forearm split and the UV2 arc length work for
  any missing or rotting limb.
- **Discharged (2.1 m, eyeless, large ears)**: `height` 2.1, `head_scale`, `ears` above 1. For
  sealed, stitched sockets skip `build_eyes` and replace the socket carve with a sunken seam (a head
  feature) and a stitch texture. The dissection head stays the separate openable mesh in
  `scripts/dissection/monster_head.gd`; `Site_eyes` and the `head` bone give its placement.
- Useful seams: the head is rigid to `head` above the jaw (the neck/head blend is owned by the SDF),
  so a head swap is clean; hair, cap and mask are separate parts; the `cover` predicates in
  `hu_outfit` decide which skin is culled, so a torn garment is a predicate change plus geometry.

## Known problems

- **Bare faces are the weak point**, as the Nurse's README predicted. Built from SDF primitives and
  displacements they read as people at game distance and above a mask, but close up under a torch
  they are stiff: a flat midface, lips that look painted on, eyelids a little thick. A sculpt or a
  scan would do better; within this approach, more face rows and a hand-shaped mouth corner are
  the next steps.
- **Hands** are four finger tubes and a thumb on a rounded palm, with no palm creases in the
  geometry. They are fine at arm's length.
- **Cloth** is offset surfaces with noise, not drape: the gown is boxy on the shoulders and does not
  settle on a lying body; sleeves and the body of a garment meet by intersection at the armpits.
- **Garment weights** follow the body closely, but extreme poses (the PickUp squat, Crawl) can push
  some skin through the trouser seat and the armpits. This was checked in the clip strips, not in
  every frame.
- **Ears** are slabs: they read from the side and behind, but from the front the attachment is a
  thin edge.
- The scrub top shows a faint dark line at the ring where `TopLower` splits off (the two pieces
  are baked separately), and the trousers' front below the top's hem reads a little boxy.
- A sliver of belly skin can show at one corner of Bob's gown window, and the infection tint does
  not show on the stump cap itself (the cap has the cut's UV2, just short of `infect_from`).
- The gaits are hand-keyed IK, not motion capture; the Jog and Sprint arms are stiff.
- Build time: a full bake of all six in parallel takes about an hour on this machine (the AO and
  normal passes dominate); `--tex=1024 --ao-samples=8 --bake-res=2` takes about 4 minutes each.

## Review images

- Blender: `renders/lineup.png`, `lineup_three_quarter.png`, `lineup_back.png`; per variation
  `renders/<variant>/front|side|back|three_quarter|face|face_side|hands|wireframe.png`; Bob's
  `gown_wound.png`, `gown_wound_table.png`, `forearm_cut.png`, `vein.png`; a player's `gash.png`;
  `renders/surgeon_a/carry.png`, `lying.png`; clip strips `renders/bob/anim_*.png` and
  `renders/surgeon_a/anim_*.png` (side and three-quarter rows).
- Godot (1280x720, the game's environment, post layer, torch and work lamp): `godot_shots/lineup_lit.png`,
  `lineup_flashlight.png`, `players_tinted.png`, `walk_flashlight.png`, `face_bob_flashlight.png`,
  `face_paramedic_flashlight.png`, `side_by_side_kenney.png`, `or_bob_gunshot.png`,
  `or_bob_amputation.png`, `or_player_gash.png`, `paramedics_push.png`, `crawl_downed.png`, `carry.png`.
