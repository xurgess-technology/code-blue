# Night Nurse: Blender-only look-dev test

This is an art test. Nothing here is wired into the game, and no game script was changed.

The Night Nurse is modelled entirely from Python in Blender 5.2.1, headless. No AI generation,
no downloaded models, no hand sculpting. Every vertex, UV, weight, keyframe and texel comes from
the scripts in `blender_src/`, so the character can be rebuilt, retuned and re-baked from scratch
in about 6 minutes.

## Folder

| Path | What |
|---|---|
| `night_nurse.glb` | Game-ready export: skinned mesh, 2 materials, 3 animations, textures embedded |
| `viewer.tscn` / `viewer.gd` | Standalone Godot viewer. It uses the monster-lab corridor, the game's `Look` environment and post layer, the player's flashlight numbers, and the current primitive nurse next to it |
| `godot_shots/` | Windowed 1280x720 screenshots from the viewer |
| `renders/` | Blender Eevee renders at 1600x1200, plus animation contact sheets |
| `blender_src/nn_geometry.py` | Shape functions for every part (pure Python and mathutils) |
| `blender_src/nn_materials.py` | Procedural Cycles materials that the maps are baked from |
| `blender_src/nn_rig.py` | Armature, weighting, the pose and the procedural animation |
| `blender_src/nn_build.py` | Runs everything: mesh, UV pack, rig, weights, actions, bake, `.blend`, `.glb` |
| `blender_src/nn_render.py`, `nn_anim_sheet.py` | The render sheet and the animation strips |
| `blender_src/night_nurse.blend` | Blender source (baked materials, rig, actions; procedural materials kept as fake users) |
| `blender_src/textures/` | The baked maps as PNG, including the AO maps before they were folded into albedo |

## Rebuild

```
cd art_tests/night_nurse_blender/blender_src
blender --background --factory-startup --python nn_build.py -- --tex=2048 --ao-samples=32   # ~6 min
blender --background night_nurse.blend --python nn_render.py -- --samples=64               # ~1 min, Eevee
blender --background night_nurse.blend --python nn_anim_sheet.py
# quick iteration: --nobake (about 10 s, procedural materials), or --tex=1024 --ao-samples=8 (about 1 min)

cd ../../..
godot --headless --path . --import
godot --path . --resolution 1280x720 art_tests/night_nurse_blender/viewer.tscn            # writes godot_shots/
godot --path . --resolution 1280x720 art_tests/night_nurse_blender/viewer.tscn -- --hold  # stays open, Idle playing
```

## How it is made

- **Geometry.** Every part is a swept tube, a ring stack or a thin closed slab built from analytic
  shape functions:
  - The dress uses a monotone-spline profile with vertical skirt folds, waistband gathers, ribs and
    shoulder blades showing through the bodice, and a turned-up inner hem.
  - The head is a warped ellipsoid with Gaussian "sculpt" features: deep sockets, brow, temples,
    cheekbones, nose and chin under the mask, and ears. Wet eyes sit at the bottom of the sockets.
  - The mask is draped over a hollow-free version of the head, with pleats and ties.
  - The hands have a flat palm, knuckle bumps and extensor tendons. The fingers are over-long and
    three-jointed, with bony knuckles, rounded tips and nails.
  - The rest: the apron and bib, straps, belt, a folded cap, scraped-back hair with a bun and loose
    strands over one eye, a stringy neck, stockinged legs and old lace-up shoes.
- **Two resolutions from the same functions.** `res=1` is the game mesh. `res=3` plus one
  subdivision level (about 600k triangles) is the bake source, so the normal and AO maps carry
  detail that the game mesh cannot represent.
- **UVs** come straight from the generator (cylindrical per tube, planar per slab). They are scaled
  to real-world size, boosted for the head, mask and cap, and packed per material.
- **Materials** are procedural Cycles node trees driven by object-space noise and per-vertex masks
  written by the generator (apron, blood zone, socket, knuckle, nail and so on):
  - Cloth: yellowed age blotches, hem grime, crease dirt, smudges, sweat stains at the armpits and
    collar, linen slubs, old blood splatter and drips, and wiped-hand smears on the apron. The mask
    has a too-wide grin of old blood with teeth marks, and black tears run down from the sockets.
  - Skin: grey mottled skin with bruise and necrotic patches, veins, crow's-feet creases, forehead
    furrows, bruised wet rims round the sockets, and dirty nails.
- **Bake.** Cycles, selected-to-active from the dense mesh: albedo and roughness through an emission
  switch, a tangent-space normal map including the shader bump, and AO with a 0.25 m distance. The
  AO is box-blurred and multiplied into albedo, because the game's medium preset has no SSAO.
- **Rig.** 53 bones: spine, neck, head, shoulders, arms, 15 finger bones per hand, legs, feet and
  toes. Each part gets Blender automatic (bone heat) weights restricted to the bones that part may
  follow; the head parts are rigid. The skirt's weights below the waist are then replaced with a
  smooth hips/thigh blend so strides don't tear it.
- **Animation** is hand-authored procedurally in armature space (`nn_rig.py`):
  - `Frozen` (10 frames): the wrong-looking still pose. Hunched, head cocked hard and turned, one
    shoulder dropped, the left index finger pointing while the others curl unevenly, the right hand
    splayed and reaching.
  - `Idle` (120 frames, 4 s loop): slow breathing and a listening head drift. The head snaps
    sideways in 2 frames, holds, then crawls back. The right fingers flex once, the left fingers
    creep one after another, and the left index finger twitches.
  - `Walk` (48 frames, 1.6 s loop, in place): a stalking walk. It is pitched forward from the hips
    with long toe-first strides. The arms hang plumb from the hunch and swing a beat late. The head
    stays level and cocked while the body bobs under it, and the right foot drags.

## Stats

- **Triangles:** 19,036 (Godot reports the same after import). The dress is 3.4k, the head 2.7k,
  the mask 1.4k, the fingers 1.2k per hand, and the hair with strands 2k.
- **Materials:** 2 (`NightNurse_Cloth`, `NightNurse_Skin`).
- **Textures:** 6 maps at 2048x2048 (albedo, roughness, normal for each material), with AO in the
  albedo.
- **GLB size:** about 25 MB, because the textures are embedded as PNG. On import Godot extracts
  them next to the GLB; those copies are git-ignored because they regenerate.
- **Bones:** 53. Up to 4 influences per vertex.
- **Animations:** Frozen, Idle, Walk. Godot imports them as named clips; the viewer sets them to
  loop.
- **Time spent:** about 2.5 hours, including building the pipeline, several look iterations,
  bakes and the Godot viewer.

## What the approach does well

- Proportions, silhouette and pose are exact and art-directable. Every number is a named constant,
  so "longer fingers" or "a deeper hunch" is a one-line change and a rebuild.
- The topology is clean, quad-based and deliberate. The UVs are sensible, the triangle count is
  predictable, the skin weights follow part boundaries, and the model deforms properly.
- Consistent PBR maps come from the same source that defines the shape, and the grime can be
  placed with intent: blood where the hands wipe, tears under the eyes, grime at the hem.
- It is fully reproducible and diffable, with no binary-only authoring step.
- The rig and animation are real and game-ready, and it runs in Godot as-is.

## What it cannot do well

- **Organic surface sculpting.** Faces, hands and cloth are built from tubes and Gaussian bumps,
  so they read as stylised or "puppet-like" up close rather than photoreal. The face works here
  only because it is mostly mask and sockets. A bare face or a realistic hand would need a real
  sculpt or scan.
- **Cloth folds** are procedural noise, not simulated drape, so the fabric does not pool, hang
  under gravity or stack at joints convincingly. The hem and apron edges are the weakest spots.
- **The cap** is a simple band shape and reads a little like a chef or sailor hat from behind.
- **Automatic weights** are fine for this stiff character, but the skirt is a compromise (no
  cloth bones), so very wide strides pull the fabric.
- **Hand-keyed procedural animation** is fine for a creature that is meant to move wrongly, but
  it is not motion-capture quality. There is no root motion, so the game would drive the speed.

## What it would take to use it in the game

1. **Swap the look.** Add an alternative to `NurseLook.build` / `monster_model.gd` that
   instantiates the GLB instead of reshaping the Kenney rig. Map the logical clips: idle to `Idle`,
   walk to `Walk`, and frozen to `Frozen` or `Idle` with `speed_scale = 0`. The Night Nurse already
   freezes its clip when observed.
2. **Hook up the other anchors.** Point `hand_point()` at the `hand.L`/`hand.R` bones, and make the
   collision capsule match the 2.3 m height, which is already used.
3. **Register it** in `Assets` and `ASSETS.md` (the licence is "made for this project"), and add
   it to `scripts/warmup.gd` so its shaders precompile.
4. **Performance.** 19k triangles and 2 draw calls are fine for one or two nurses on the 890M. For
   distance, add a LOD (for example, decimate to about 5k), and consider 1024 textures on the low
   preset.
5. **Optional extra clips.** A lunge/attack, a turn-in-place, and a "caught" snap pose would make
   the observed/unobserved switching read better. These are more poses in `nn_rig.py`.
