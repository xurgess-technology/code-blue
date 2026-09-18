# Stylized characters

The players' surgeon (`assets/models/characters/human/surgeon_st.glb`, key `char/human_surgeon_st`) and the
start of the Hive, in one stylized look, built entirely from Python in Blender 5.2 (headless). No
downloaded or generated models. Replaces the realistic `art/human` surgeons for players (2026-09-18).

## Style rules

- People, not dolls: near-normal proportions, simple soft forms, no pores, wrinkles or anatomy lines.
- Figurine faces: a short full face, a small nose, small ears pressed to the head, painted brows, a mouth
  line, big clear eyes. Surgeons are bald, no cap, no mask; short-sleeved scrubs, bare hands.
- Stiff, chunky clothing with thick hems.
- Every eye is a separate object in a socket cut to the eyeball, so a graft can swap it.

## Files

| File | What |
|---|---|
| `st_sdf.py` | Signed distance fields in numpy (smooth unions, round cones, noise) and a surface-nets mesher |
| `st_char.py` | The characters as data plus shapes: skeleton numbers, the head (v2 = the surgeon's), hands, limbs, scrubs, gown, gash pieces, per-vertex paint |
| `st_build.py` | Blender driver: meshes every part, weights it to the human pipeline's skeleton, poses and renders review shots, animation strips (`--anim`), the game export (`--export`) |
| `st_export.py` | Game export: decimation (~21.7k tris), UV atlas per material, bakes from the dense sculpt (albedo + AO, roughness, normals, shader masks), the belly gash pieces, sites, the 11 clips, GLB |

The skeleton, bone names, clips and posing helpers come from `art/human/blender_src` (`hu_body`, `hu_rig`),
so the game's human code (`scripts/human/human_model.gd`, `body_hands.gd`, the downed table) drives these
models unchanged.

## Rebuild

```
blender --background --factory-startup --python art/stylized/st_build.py -- --only=surgeon                  # review renders into renders/
blender --background --factory-startup --python art/stylized/st_build.py -- --only=surgeon --anim           # the 11 clips as frame strips
blender --background --factory-startup --python art/stylized/st_build.py -- --only=surgeon --export         # writes the game GLB + textures (~5 min)
godot --headless --path . --import
godot --headless --path . --script tools/style_lab/report.gd                                            # tris, bones, clips, sites
godot --path . --resolution 1280x720 tools/style_lab/style_lab.tscn                                     # in-game look shots
```

`--fast` meshes at a coarser resolution for quick iteration. Variants: `surgeon`, `surgeon_graft` (the left eye
swapped for a Hive eye, stitched), `hive` (still on the first-pass head; next up).

## Game pieces (the human contract)

`Human` (body), `Human_Eye_L` / `Human_Eye_R`, `Human_TopLower` (hide to bare the belly), `Human_TopRolled`
(hidden by default), `Human_GashSkin` (blend shape `GashOpen`). Materials `Human_Skin` / `Human_Cloth`; cloth mask R
= player tint zone, skin mask G = the gash. Sites: `Site_eyes` (head), `Site_injection` (forearm.L), `Site_gash` (spine).

## Known issues

- First-person arms (`scripts/hands/fp_arms.gd`) still draw a scrub sleeve to the wrist; the body has short sleeves.
- Teammates see no torch in the third-person hand (true of the old surgeons too).
- Skin reads a little hot under the flashlight at close range.
- A small lip at the back of the shoulder when the arms reach forward (Push, Carrying).
- The trouser waistband reads thick from above on the player table.
