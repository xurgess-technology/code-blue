# Pocket Spaces

## Goal
Sometimes, when you turn a corner in a wing, the hallway opens into a place that can't exist
inside a hospital. These places are uncanny and liminal, and they are never explained.
This sweep adds the system and two spaces: **the Factory** and **the Restaurant**.

## How it works
- A pocket space is a hand-built scene placed far from the hospital in world space.
  It has its own tile grid, so monster pathing, line of sight, lights and spawns keep working.
- Entrances are **L-bend hallway stubs** that `wing_gen` adds to wing hallways. Past the bend,
  out of the player's view, a hidden seam moves the player to the matching spot inside the
  pocket. Both sides of the seam look identical, so the move can't be seen. Don't use
  render-to-texture portals, because they cost too much performance.
- **A pocket has 2–3 entrances**, and each one connects to a different hallway. At least two of
  them should lead to different wings, so the pocket also works as a shortcut.
- A shift rolls **0–1 pocket spaces**, with higher odds in deeper wings. Pockets never connect
  to the entrance building or the neutral area.

## The two spaces
**The Factory**: a huge, empty industrial hall with a ceiling that is far too high (around 25–30 m).
It has rows of identical columns, dead machinery, conveyor lines, catwalks and stairs, dim
high-bay lights, and fog that hides the far walls. It should feel too big and too quiet.

**The Restaurant**: a complete Mexican restaurant, with a host stand, booths, tables, a bar and
a kitchen out back. It has no windows, and the room is slightly larger than it should be.
Everything is set as if customers are about to arrive, but no one ever does.

The room mechanics discussed earlier are out of scope for this sweep. Neither space has
special monster rules, working machinery or music.

## Rules
- Loot, supply containers and tool spawns follow normal wing rules, scaled by the
  connected wing's depth.
- Monsters can **spawn inside** a pocket and can **follow players through** a seam.
  Sound also carries through seams.
- Multiplayer: the seam snaps the player's own position and replicates it. Carried players,
  carried bodies and held items move through with the player.

## Constraints
- Hold 60 fps with 1% lows above 50 on the Radeon 890M (medium preset). Check with
  `tools/perfprobe`. For the Factory, rely on fog, occlusion and few shadowed lights.
- Register new content in `scripts/warmup.gd`. Use CC0 assets only, look them up through
  `Assets`, and record them in `ASSETS.md`.
- Update `docs/CONTRACTS.md` ("Hospital") with the pocket and seam data.

## Done when
- `tools/mapcheck.gd` validates pockets on many seeds: every entrance links, everything is
  reachable, and seams line up.
- A headless test walks a bot through every entrance of both spaces.
- A monster follows a player through a seam (`monster_lab` or nettest).
- A nettest scenario passes a client, a carried player and an item through a seam
  under lag.
- `tools/gameshot` has screenshots of both spaces and of each seam from the hallway side.
