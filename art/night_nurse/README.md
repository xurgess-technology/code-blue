# Night Nurse: the Blender sources

**In the game since 2026-09-18** (the stylized restyle; the first model, in the game from 2026-09-14,
is kept in `deprecated/night_nurse/`). The model the game loads is
`assets/models/monsters/night_nurse/night_nurse.glb` (asset key `monster/night_nurse`) with its six maps as
separate PNGs in `textures/` beside it. How the game uses it is in `scripts/monsters/night_nurse_rig.gd` and
`docs/CONTRACTS.md` ("The Night Nurse's model", "The Night Nurse's grab"). This folder has a `.gdignore`,
so Godot never imports it.

She is modelled entirely from Python in Blender 5.2, headless: no AI generation, no downloaded models,
no hand sculpting. Every vertex, UV, weight, keyframe and texel comes from `blender_src/`, so she can be
rebuilt from scratch in about 4 minutes. The art style she follows is in
[DESIGN.md, "Art style"](../../DESIGN.md#art-style-characters-and-models).

## Rebuild

```
cd art/night_nurse/blender_src
blender --background --factory-startup --python nn_build.py -- --tex=2048 --ao-samples=32 --export   # ~4 min
blender --background night_nurse.blend --python nn_render.py -- --samples=64               # front, side, back, head, hands, corridor...
blender --background night_nurse.blend --python nn_anim_sheet.py                           # the Idle and Walk strips
blender --background night_nurse.blend --python nn_lineup.py                               # beside the old model and the surgeon
blender --background night_nurse.blend --python nn_closeup.py -- --action=none              # shoulders and apron up close
blender --background night_nurse.blend --python nn_closeup.py -- --action=Walk --frame=36 --only=close_skirt_side   # the skirt mid-stride
# quick iteration: --nobake (about 10 s, procedural materials), or --tex=1024 --ao-samples=8 (under a minute)

cd ../../..
godot --headless --path . --import
godot --headless --fixed-fps 60 --path . tools/monster_lab.tscn                          # her checks, the grab included
godot --path . --resolution 1280x720 tools/monster_lab.tscn -- --shots --only=nurse_walk_flashlight,nurse_face,nurse_grab_stare
```

Without `--export` the build only writes `night_nurse.blend` and `textures/`. With it, it also exports
`night_nurse_embedded.glb` (git-ignored) and `nn_glb_extern.py` writes the game copy with its textures as
separate PNGs, so Godot's per-texture import settings (VRAM compression, normal maps) stick.

## Files

| Path | What |
|---|---|
| `blender_src/nn_geometry.py` | Shape functions for every part (pure Python and mathutils) |
| `blender_src/nn_materials.py` | Procedural Cycles materials the maps are baked from |
| `blender_src/nn_rig.py` | Armature, weights (skirt, hair), the pose and the procedural clips |
| `blender_src/nn_build.py` | Runs everything: mesh, UV pack, rig, weights, actions, bake, `.blend`, `.glb` |
| `blender_src/nn_glb_extern.py` | Splits the exported GLB's images into PNGs and writes the game copy |
| `blender_src/nn_render.py`, `nn_anim_sheet.py`, `nn_lineup.py`, `nn_closeup.py` | Review renders into `renders/` |
| `blender_src/night_nurse.blend`, `blender_src/textures/` | The built scene and the baked maps (AO kept separately) |

## The model

**Skeleton and clips.** 53 bones (spine, neck, head, shoulders, arms, 15 finger bones per hand, legs, feet,
toes) and three clips: `Frozen` (the wrong-looking still pose), `Idle` (4 s loop: breathing, a head that
snaps sideways and crawls back, creeping fingers) and `Walk` (1.6 s loop, in place: pitched forward,
toe-first, arms swinging a beat late, the right foot dragging). The same skeleton and clips as the first
model, so the game's constants (`WALK_SPEED`, `EYE_OFFSET`, `WALK_LIFT`) carried over.

**Shapes** (`nn_geometry.py`), stylized: big simple soft forms, no sculpted anatomy.
- Soft figurine features under the mask: big round sockets with big glossy black eyes, a soft brow,
  small pressed ears.
- Thick, stiff cloth: a few broad rounded skirt folds, a thick apron and bib, wide straps, a chunky belt,
  a fat collar roll and thick starched cuffs.
- The sleeves grow out of the bodice: each starts thin, buried near the neck, and arcs over the
  shoulder (a raglan line), so there is no corner at the shoulder. The apron straps run over them.
- Over-long fingers as smooth tapering tubes on a full palm.
- Long loose hair: a solid shell on the scalp under 65 thick strands from the crown. They part round
  the face and fall onto the chest, stop above the shoulders at the sides (clear of the arms) and hang
  to the waist down the back (`hair_groups`, `hair_path`). No cap.
- The stockings start a hand above the hem (`LEG_TOP`): run up to mid-thigh inside the skirt, the
  forward leg used to poke out through its front on a long stride.

**Weights** (`nn_rig.py`). Automatic (bone heat) weights per part, restricted to the bones that part may
follow; the head parts are rigid. Below the waist the skirt and apron are replaced by a smooth blend
(`skirt_weights`): the hips carry them and the thighs push them, up to 0.8 at the hem so the legs stay
inside. The long hair is weighted by height (`hair_weights`): the head carries it to the jaw, then the
upper chest, chest and spine, so it lies with her body instead of swinging with her head.

**Paint** (`nn_materials.py`). The style puts grime, blood and wear in the paint, not the shapes: yellowed
age blotches, hem grime, tide lines, dirt in the creases, smudges, specks, sweat stains, old blood
splatter with brown halos, drips and wiped-hand smears on the apron, a light spray over the mask. The
mask is surgical green, with a painted too-wide grin and teeth and two thick black tears. The skin has
grey mottling, bruised and necrotic patches, sallow blotches, grimy knuckles and nails, fingertips dipped
in blood and red-raw rims round the sockets. What stays out is relief and anatomy lines: no weave,
slubs or wrinkles in the normal map, no pores, veins, crow's feet or furrows.

**Bake.** Cycles, selected-to-active from a dense copy (`res=3` plus one subdivision level): albedo and
roughness through an emission switch, a tangent-space normal map, and AO (0.25 m) box-blurred and
multiplied into the albedo, because the game's medium preset has no SSAO.

**Budget.** 26.7k triangles, 8.8k of them the hair (the style's target is about 20k; if it's too many:
fewer back strands, or 12 rows per strand instead of 16). 2 materials (`NightNurse_Cloth`,
`NightNurse_Skin`), 6 maps at 2048.

## Open

- Strand tips are a little blunt up close (4-sided tubes).
- When her head cocks hard (`Frozen`), the strands stretch a little between the jaw and the collar.
