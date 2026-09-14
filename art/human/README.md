# The human: Blender sources (art pass, for review)

**Not in the game yet.** This pass builds the base human, the players/surgeons, Bob and the
paramedics the same way as the Night Nurse (scripted in Blender 5.2.1, headless, no downloaded or
generated models) and stops for review. No game script uses these models. The game copies are in
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
