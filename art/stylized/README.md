# Stylized characters

The art style itself (what it is, why, the rules) is in [DESIGN.md, "Art style: characters and models"](../../DESIGN.md#art-style-characters-and-models).

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
| `st_sono_clips.py` | The Sonographer's own clips: idle, wander, listen, charge, echo, rush, wail, search, stagger, lying (the neck's crane is not a clip: the game blends it on top) |
| `st_clips.py` | Clips added on top of the shared 11: `Dive` (the sprint-dive, flat out in the air and belly-sliding; body_hands plays it) |
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
swapped for a Hive eye, stitched), `hive` (the surgeon's head and kit: charcoal skin, the skull broken open with a pale shelf fungus in place of the
brain, `Fungus` a separate piece; orange eyes, whose glow is in the eye mask: R = the pinpoint, G = the whole ball,
lit by the material's `Lock` value, 0 wandering and 1 locked on). Hive shots: `hive_front`, `hive_34`, `hive_side`,
`hive_back`, `hive_top`, `face_hive`, `face_hive_lock`, `hive_dark(_lock)`, `hive_black(_lock)`.
`sonographer` (the Sonographer: a blind doctor in old tattered whites, tall and thin, the head low on a
hunched neck and cocked over one ear, the eye sockets scarred flat with a faint seam and no eye pieces at all.
Big swivelling ears, a violet windpipe behind a see-through pane of throat skin, an ultrasound probe grown
into the right palm with three runs of cable up the arm, and gel drips, all their own pieces.
`st_build.add_neck_bones` cuts the neck into a chain of four so it can stretch about 0.6 m: `--shots` renders
everything twice, at rest and with `set_crane` at full).
Sono shots: `sono_front`, `sono_side`, `sono_34`, `sono_back`, `sono_throat(_charge)`, `sono_dark(_charge)`,
`face_sono`; `set_charge(0..1)` lights the windpipe for the charge shots.
`--only=sonographer --export` writes `assets/models/monsters/sonographer/sonographer_st.glb` with its own clips
(`st_sono_clips.py`). In the game: `scripts/monsters/sonographer_rig.gd`.

`--only=hive --export` writes `assets/models/monsters/hive/hive_st.glb` with the Hive's own clips
(`st_hive_clips.py`: HiveIdle, HiveWalk, HiveAttack) instead of the shared human ones; `--only=hive --anim`
renders their strips. In the game: `scripts/monsters/hive_rig.gd`.

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
