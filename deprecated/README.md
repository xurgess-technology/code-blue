# Deprecated

Things the game no longer uses but that are worth keeping in case they come back. Nothing here is loaded
or built: the folder has a `.gdignore`, so Godot never imports it, and no script or doc outside it points
in. To bring something back, move it to where its README says it lived and re-import.

| Folder | What | Retired | Replaced by |
|---|---|---|---|
| `night_nurse/` | The first Blender Night Nurse: `art/` (its build scripts, `.blend`, renders) and `assets/` (the GLB and maps the game loaded as `monster/night_nurse`) | 2026-09-18 | The stylized model in `art/night_nurse/` |
| `unused_models/` | Registered models nothing used: the Kenney/Quaternius stand-ins from before the in-house models (`monster/nurse`, `lurker`, `orderly`, `cthulhu`; `patient/ghost`, `wolf`, `bull`; `char/surgeon_b`) and three spare props (`prop/desk`, `hosp/bench`, `hosp/keyboard`). Same folder layout as under `assets/models/`; their rows are at the end of ASSETS.md | 2026-09-18 | Nothing (unused) |
| `prototype-web/` | The original TypeScript / Three.js / Electron prototype of the game | 2026-09-18 | The Godot game |
