# The seal patient: Blender sources

**Art test, not in the game yet.** The model is `assets/models/patients/seal/seal.glb` (skinned mesh,
2 materials, 5 clips) with its maps as separate PNGs in `textures/` beside it, plus
`seal_skin.gdshader`, the shader that drives it. The game still builds the procedural seal
(`scripts/patients/seal_builder.gd`); nothing in `scripts/` was changed. `tools/seal_viewer.tscn`
shows the new model on the OR table in every surgery state. This folder has a `.gdignore`, so Godot
never imports it.

Like the Night Nurse (`art/night_nurse/README.md`), the seal is modelled entirely from Python in
Blender 5.2.1, headless. No AI generation, downloaded models or hand sculpting: every vertex, UV,
weight, keyframe and texel comes from `blender_src/`.

## Folder

| Path | What |
|---|---|
| `../../assets/models/patients/seal/` | The game copy: `seal.glb`, `textures/`, `seal_skin.gdshader` |
| `blender_src/seal_geometry.py` | Shape functions for every part, in the patient frame (pure Python and mathutils) |
| `blender_src/seal_materials.py` | Procedural Cycles materials the maps are baked from (coat with an infection switch, detail) |
| `blender_src/seal_rig.py` | Armature and the procedural clips |
| `blender_src/seal_build.py` | Runs everything: mesh, UV pack, rig, bake, game pieces, sites, `.blend`, `.glb` |
| `blender_src/seal_render.py`, `seal_anim_sheet.py` | Look-dev renders and animation strips |
| `blender_src/seal_glb_extern.py` | Splits the exported GLB's images into PNG files (copy of the Night Nurse's) |
| `blender_src/seal_sites.json` | Written by the build: every site's frame, bone and section, and the triangle counts |
| `blender_src/seal.blend`, `blender_src/textures/` | Blender source and the baked maps (including AO and the infection inputs) |
| `renders/` | Blender renders (Eevee, baked materials) and animation strips |
| `godot_shots/` | 1280x720 screenshots from `tools/seal_viewer.tscn` |

## Rebuild

```
cd art/seal/blender_src
blender --background --factory-startup --python seal_build.py -- --tex=2048 --detail-tex=1024 --infect-tex=1024 --ao-samples=32   # ~10 min
blender --background seal.blend --python seal_render.py -- --samples=64
blender --background seal.blend --python seal_anim_sheet.py
# quick iteration: --tex=1024 --detail-tex=512 --ao-samples=8 (about 3 min); --nobake --noexport (10 s, procedural
# materials, preview with seal_render.py -- --engine=cycles: Eevee cannot compile the procedural materials)

cd ../../..
godot --headless --path . --import
godot --headless --path . tools/seal_viewer.tscn -- --check        # structure, sites and mask report
godot --path . --resolution 1280x720 tools/seal_viewer.tscn        # all shots into art/seal/godot_shots/
```

`seal_build.py` exports `art/seal/seal_embedded.glb` (git-ignored), then writes the game GLB and
its PNGs and copies `Seal_Infect.png` next to them. The PNG `.import` files are set to VRAM
compression with mipmaps (normal-map mode for the normals) and survive rebuilds.

## How it is made

- **Frame.** Everything is authored in the patient frame of `scripts/patient_body.gd`: nose toward
  -X, tail toward +X, belly on the table at y = 0, the seal's left on +Z. The build converts to Blender
  axes and the glTF +Y-up export converts back, so the GLB's root is the patient frame exactly.
  Geometry is authored at 1.0 and built at `SCALE = 1.08` (nose to hind-flipper tips 1.84 m, back
  0.37 m high), which matches the procedural seal's footprint on the table.
- **Body.** One ring loft from the tail to the nose: per-x half-width, height above and below the
  centre, and separate superellipse exponents for the back and the belly (so the belly spreads flat on
  the table and the blubber sags to the flanks). The head is the same loft with denser rings and
  columns, displaced by Gaussian "sculpt" features: sunken sockets with heavy drooping lids and a
  raised inner brow (the worried look), fat whisker pads either side of a philtrum groove, a cobbled
  rhinarium with V nostrils, the mouth line and chin, ear pits, and irregular fat folds on the neck.
- **Eyes** are separate wet globes (large, almost all pupil, a bloodshot sliver of white in the rear
  corner). **Whiskers:** 38 tapered, drooping, beaded tubes on the pads plus brow and nose whiskers.
- **Fore flippers** are lofts along a flipper axis: flattened oval arm, widening into a paddle with
  five digit ridges, a slanted tip (digit I longest) and five claws. **Hind flippers** fan out with the
  outer digits longest, a scalloped trailing edge and small claws.
- **Two resolutions from the same functions.** `res=1` is the game mesh; `res=3` plus one subdivision
  (about 570k triangles) is the bake source.
- **Materials.** Procedural Cycles node trees on per-vertex masks from the generator:
  - Coat: dark slate back, grey flanks, a dirty pale belly; dense irregular harbour-seal spots of
    three sizes; silvery guard-hair frosting; fur streaks lying nose to tail; dark flippers with paler
    palms; wet dark rims, tear stains running down from the eyes (seals have no tear ducts), whisker
    follicle pits, a black wet nose; grim wear: faint healed scars, a crescent bite scar on the right
    shoulder, moult patches, grime, abrasions and old blood where it lies on the table.
  - Detail: eyes, whiskers, claws, the cut faces (skin rim, thin fat, dark wet muscle with fibre ends
    and fascia, radius and ulna with cortex and marrow and saw scoring, blood welling at the bottom)
    and the fishing line.
  - Infection (coat with `INFECT = 1`, baked into its own atlas): swollen bruised skin with the fur
    sloughing off, wet ulcers rimmed with yellow fibrin, pus beads, black necrosis spreading from the
    tip and edges, raw grooves where three loops of fishing line have cut in, a bruised halo ahead.
- **Bake.** Cycles selected-to-active: albedo and roughness via an emission switch, a tangent-space
  normal map, and AO (0.22 m) blurred and folded into albedo. Every low-poly object is hidden from rays
  during the bake so it cannot shadow the AO. The stump cap and the fishing line are baked lifted away
  from the flipper so they don't occlude each other.
- **Rig.** 20 bones: `root`, `spine`, `chest`, `neck`, `head`, `lumbar`, `pelvis`, `ribs` (breathing,
  scaled), and per side `flipper_upper/fore/hand/digits` and `hind/hind_toes`. Weights are analytic
  (by position along the spine and along each flipper), not bone heat: the seal is a smooth tube and
  this keeps the amputation loop 100% on `flipper_fore.L` in every pose.

## Stats

- **Triangles:** `Seal_Body` 14,998 + `Seal_Paddle_L` 1,248 = **16,246** for the whole seal. The pieces
  that appear only during an amputation: `Seal_FishingLine_L` 684, `Seal_StumpCap_L` 238 (replaces the
  paddle), `Seal_PaddleSevered_L` 2,170 (the copy the saw drops). Godot reports the same after import.
- **Materials:** 2. `Seal_Coat` (albedo, roughness, normal at 2048) and `Seal_Detail` (1024), plus
  `Seal_Infect.png` (1024, RGBA: infected albedo with AO, height in alpha) for the coat shader.
- **Bones:** 20, up to 4 influences. **Clips:** Idle, Stir, Fidget, Twitch, Flatline.

## What is in the GLB

```
Seal (root = patient frame)
  Seal_Rig / Skeleton3D
    Seal_Body            skinned, surfaces Seal_Coat + Seal_Detail
    Seal_Paddle_L        skinned: the removable left paddle past the cut, and its claws
    Seal_FishingLine_L   skinned: three loops and a loose end; show for the amputation case only
    BoneAttachment3D neck            -> site_injection
    BoneAttachment3D spine           -> site_gunshot
    BoneAttachment3D flipper_fore_L  -> site_limb, site_limb_cut, Seal_StumpCap_L (hidden until cut),
                                        Seal_PaddleSevered_L (static; hide it and duplicate it)
  AnimationPlayer        Idle (120 f loop), Stir (36 f), Fidget (90 f loop), Twitch (60 f loop), Flatline (10 f)
```

The imported materials are plain StandardMaterial3Ds. For the game look, override both surfaces
with `seal_skin.gdshader` (see `_spawn_seal` in `tools/seal_viewer.gd`).

### Mesh data the shader reads

| Data | Meaning |
|---|---|
| `COLOR.r` | infection weight: 0 until 21.6 mm past the cut, smooth to 1 at 64.8 mm (left paddle only) |
| `COLOR.g` | breathing weight (thorax); `breath` pushes along the normal like the old coat shader |
| `COLOR.b` | injection site: a stripe along the dorsal midline of the neck, ±92 mm along X |
| `COLOR.a` | gunshot site: a 92 mm disc round the wound on the right flank |
| `COLOR.b = COLOR.a = 1` | the eyes (gets the catchlight) |
| `UV2` | the paddle's own infection atlas; `1 - UV2.y` is linear in distance from the cut (0.01 at the cut, 0.985 at the tip, 0.180 m), (0, 0) elsewhere |

Shader uniforms: `pallor`, `grey`, `infect`, `breath` (same names as `seal_coat.gdshader`),
`infect_front` (0..1 of the paddle past the cut that is infected, for a creeping infection),
`highlight_injection`, `highlight_gunshot` (pulsing emission through the masks), `eye_glint`.

## Surgery sites

All in the patient frame, rest pose, built scale. +Y is out of the skin; X runs along the limb
(distal) or along the body toward the tail. These are the `site_*` nodes in the GLB (they follow
their bone when the clips play); the numbers are also in `blender_src/seal_sites.json`.

| Site | Bone | Origin | X | Y | Z |
|---|---|---|---|---|---|
| `injection` | neck | (-0.464, 0.319, 0.000) | (0.966, 0.257, 0) | (-0.257, 0.966, 0) | (0, 0, 1) |
| `gunshot` | spine | (0.032, 0.328, -0.169) | (0.995, -0.088, 0.041) | (0.097, 0.902, -0.420) | (0, 0.422, 0.906) |
| `limb` | flipper_fore.L | (-0.174, 0.126, 0.320) | (0.855, -0.110, 0.507) | (0.095, 0.994, 0.056) | (-0.510, 0, 0.860) |
| `limb_cut` | flipper_fore.L | (-0.110, 0.111, 0.358) | same | same | same |

Sections (`site_section`), measured from the mesh ring at each site:

| Site | half_up | half_side | axis_depth | shape | infection_start | infection full |
|---|---|---|---|---|---|---|
| `limb` | 0.0335 | 0.0659 | 0.0335 | 2.3 | 0.0972 | 0.1404 |
| `limb_cut` | 0.0270 | 0.0626 | 0.0270 | 2.3 | 0.0216 | 0.0648 |

(`half_down`, below the axis, is 0.0261 and 0.0211: the flipper is flatter underneath.)

### How each surgery was designed

- **Anesthetic (`injection`).** The site sits on the dorsal midline at the back of the neck, fully
  weighted to `neck`, where the minigame's vein runs along X. `COLOR.b` is a matching stripe so the
  game can light the vein area (`highlight_injection`). The coat there is plain fur with no scars.
- **Gunshot (`gunshot`).** On the right flank, a hand's width below the spine, weighted to `spine`
  with little breathing movement (about 1 mm). The flank has an even quad grid with extra columns
  across the upper side, the right fore flipper lies well below and forward of the wound, and nothing
  sticks up into the forceps or gauze view. `COLOR.a` marks a disc for bruising or highlighting. The
  wound itself is still the kit's decal and bullet.
- **Amputation (`limb`, `limb_cut`, infection).**
  - The left fore flipper is one loft with a dedicated edge loop at the cut (`CUT_S`). Support loops
    sit 22.5 mm either side of `limb` for the tourniquet band.
  - The mesh is split at that loop: `Seal_Paddle_L` is the removable piece, and the cut loop is
    welded to the stub with shared custom normals, so there is no seam while it is attached.
  - The loop is 100% `flipper_fore.L`, so `Seal_StumpCap_L` (the cut face on the stub: skin, fat,
    muscle, radius and ulna, dished in) stays sealed to the stub in any pose.
  - `Seal_PaddleSevered_L` is the paddle with the reflected cut face (muscle standing proud, bone
    recessed) and the fishing line. Its node origin is the cut centre, with X along the flipper, so
    `make_severed_limb` is a duplicate placed at the paddle's current transform.
  - Order along the limb: tourniquet at 124 mm from the shoulder pivot, the cut at 200 mm, the
    infection from 221 mm. The saw always goes through healthy, spotted fur, and the stump face is
    clean flesh. The infection is baked, shown through `COLOR.r` and `infect`, and can creep forward
    with `infect_front`.

### Wiring it in later (not done)

1. In `seal_builder.gd`, instantiate the GLB under `b.rig` instead of lofting. Override the materials
   with `seal_skin.gdshader`, and add the coat material (and the detail one) to `b.skin_mats`.
2. Anchors: `b.anchors[site]` = the `site_*` nodes; `b._sites[site]` = the table above (with the
   body's identity transform); `b.sections` and `b.infection` from the section table.
3. `parts`: `limb_node` = `Seal_Paddle_L` (hide it, and hide `Seal_FishingLine_L`), `stump` =
   `Seal_StumpCap_L` (or keep the kit stump), `tourniquet` / `dress_stump` from the kit with the
   sections above, `wound` / `dress_wound` from the kit at `site_gunshot`. `make_severed_limb` =
   duplicate `Seal_PaddleSevered_L` and set its global transform from the paddle's cut frame.
4. `animate()`: play `Idle`, blend `Stir` by `jolt`/`env`, `Fidget` by `fidget`, `Twitch` by
   `twitch`, and `Flatline` when flat (an AnimationTree with add/blend nodes). Set `breath_amp` to 0
   (the ribs bone breathes), or keep the shader breath at a low amplitude.
5. Register the asset and add it to `scripts/warmup.gd` for shader precompile.

## Clips

All in place, 30 fps. The rest pose has the head lifted a little and turned toward its left, with
the chin just off the table.

- `Idle` (4 s loop): two slow breaths (the ribs swell), a tired look toward the room and back, and
  the digits and hind toes stirring.
- `Stir` (1.2 s): the head and neck snap up, the fore flippers flap, the hind flippers lift, then it
  settles back.
- `Fidget` (3 s loop): the head turns side to side, the right fore flipper lifts and scratches, and
  the toes fan.
- `Twitch` (2 s loop): fast shallow breaths, the head sagging, small tremors in the head and flippers.
- `Flatline` (still): no breath, the head slumped onto the table, the flippers limp.

## Known problems

- **Close-up organic detail.** Like the Nurse, this is tubes plus Gaussian bumps. The face holds up
  at gameplay distance; at macro distance the nostrils and lids are soft and the lid line against the
  eye globe is faceted.
- **The fore flipper root.** It is a tube pushed into the body wall with a flared root, not a
  modelled armpit, so the join reads as a crease. The flipper is splayed further from the body than a
  resting seal would hold it, to keep the tourniquet and the cut clear of the flank.
- **The stump floats.** After the cut, the stub ends in the air (the paddle is what rests on the table).
- **Infection shading** uses a screen-space bump from the height map. It has no normal map of its own,
  so grazing light shows less relief than the Blender renders.
- **The clips are procedural**, as with the Nurse. Stir and Fidget read clearly; Twitch is subtle.
- **The cut face reads too clean and red.** The two bone rings look a little like eyes, and the muscle
  is candy-red rather than dark. This is a tuning change in `seal_materials.py` plus a rebake.
- **The wound overlays** (kit decal, bullet, tourniquet, dressings) are the existing procedural
  pieces. They work at the sites but look simpler than the model.
