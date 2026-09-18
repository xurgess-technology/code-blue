# Changelog

Everything that changes in **Malpractice**, newest first. St. Doe's General is under constant renovation;
this is the paperwork.

The layout follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). We're pre-1.0, so the rules are loose: every chunk of
work bumps the minor version (0.**x**.0), fixes on top of it bump the patch (0.x.**y**), and 1.0.0
is the day it's a game you'd charge money for. The current version also lives in `project.godot`
(`config/version`).

New work goes under **Unreleased** as it lands. When we call a version done, that section gets a
number and a date, and a fresh empty **Unreleased** goes on top.

Versions 0.1.0 to 0.5.0 were written after the fact from the git history, one per day of work,
so they're summaries rather than a line per commit.

## [Unreleased]

### Added
- **The Night Nurse's grab.** She no longer takes hearts. If she gets a hand on you, she has you by the
  throat with both hands in a snap and straightens to her full height, holding you up to her face
  with your legs kicking and your arms hanging. Your view is locked on her face, straight on, until
  her head snaps over to one side with a crack, cocked, considering you. Then she drops you, downed,
  and she's gone: somewhere far off, out of everyone's light. About two seconds, and nothing anyone
  can do. Watching her doesn't stop it once she has you, and nothing else can touch you meanwhile.
- **A camera that faces you.** F5 now cycles three views: first person, over the shoulder, and a new
  one out in front looking back at your surgeon, centred. The camera swings round you to get there
  instead of cutting. Facing you there's no crosshair (it would be pointing at your face), and you
  aim where your head looks. It's in Settings -> Controls -> Camera as FRONT too.

### Changed
- **A new Night Nurse**, rebuilt in the game's art style: a soft figurine face under the mask with big
  black eyes, long chunky black hair down her back and over her chest instead of the cap and bun,
  stiff chunky clothes, and all the old grime and blood kept as detailed paint. Same height, same
  wrong walk. The first model is kept in `deprecated/`.
- The art style's hair rule: hair is fine where a character calls for it, as long as it's built
  chunky (surgeons stay bald).

### Fixed
- The Night Nurse's legs no longer poke out through the front of her skirt on a long stride.
- Sprinting in the shoulder view put a shiny white patch on the back of your head: your own
  flashlight, which lives in your head, was lighting your skull as you leaned into the run. Your
  torch no longer lights your own body.

## [0.6.0] - 2026-09-18

The shop finally sells something that does something.

### Added
- **Rocket boots**, the pharmacy's first real item: $100 a pair on the lobby fax. Taking a pair puts
  them on (your hands stay free), one pair each, and they stay on through death until a new run.
  Hold crouch through a sprint-dive and they light: you fly straight ahead, level and fast, burning
  a new **fuel** bar under stamina (about 1.5 s of flight, ~18 m, refilling on the ground). Let go
  and you drop into the normal dive landing.
- **Faceplants**: flying head first into a wall or furniture stops the burn, bounces you back and
  costs a heart. Glancing off a wall at an angle is free. Teammates see heel thrusters, flames, a
  glow on the walls, and they hear you coming.
- **Over-the-shoulder camera**, as an option: Settings -> Controls -> Camera (FIRST / SHOULDER), or
  **F5** anywhere. First person stays the default. You see your own surgeon, the item in their hand,
  and the crosshair still aims. The game takes you back to first person while you're operating, in
  Hive Eyes, downed, being carried or dead.
- A **personnel** room with real, working mirrors, a rebuilt crematorium, desks, and a softer aim
  highlight in the hub.
- The OR's **lab wall** round the corner, storage shelves and a janitor's closet; surgical tools can
  now be used straight from your hands.
- A written **art style** for characters and models in DESIGN.md ("an exaggerated person, never
  chibi, never a doll").
- Tests: rocket boots and the shoulder camera in `controlstest`, a `rocket_boots` multiplayer
  scenario, and a `bootsshot` screenshot tool.

### Changed
- The dive now flies flat out instead of hopping upright.
- Surgeon polish: no belly poking through the scrubs, no glowing face on a charged shove.
- The old realistic `surgeon_a` model (no longer a player body) is unmasked, with no gash and a
  fuller build.
- The project is renamed from Code Blue to Malpractice, everywhere.

## [0.5.0] - 2026-09-17

The hospital gets a name, a face and a new doctor.

### Added
- The game is now **Malpractice**, and the hospital is **St. Doe's General** ("Doe General" on the
  faxes).
- **The outside of the hospital**: upper storeys, signs and planters. You also now arrive by walking
  out of the fog onto a brighter parking lot, instead of spawning inside.
- **Fog you can get lost in**: an oval clearing ringed by a 60 m tall fog belt. Wander in too deep
  and you come out somewhere else instead of being politely steered back.
- **The stylized surgeon**, the players' new body, built in Python in Blender.
- **The wall terminal**: a shared projector screen. Hold your scan laser on it to sign in, drill
  into cards, and everyone sees everyone's laser dot. The database became a slide projector, with a
  lock screen that signs you out when you walk away or go idle.
- A **throw wind-up**: your arm draws back (or both arms go overhead for big things) while you charge.
- Starting a session from the menu now rolls into a shift assignment fax.
- Dev panel: a free camera (P swaps between flying it and walking), and a button to put a
  flatlined patient on the table.
- `docs/FAILING_TESTS.md` and `CLAUDE.md`, so nobody panics about the tests that were already red.

### Changed
- The **Walk-In is now the Hive**, everywhere.
- The **carry camera** sits over your right shoulder, framed like a proper third-person game; the
  body you carry rides your left shoulder. It lingers a moment after you throw a body in the furnace.
- **Fax polish**: every fax screen moves the same way, faster, and gets hand-pressed rubber stamps.
- The **pharmacy** front is a wall with a barred counter window instead of a whole wall of bars.
- Surgery looks: the saw now follows a pre-op skin-marker line instead of a glowing guide; Bob's
  gown pulls back round the forceps' patch; a teammate's flashlight lights the wound; the infection
  on Bob's arm has one consistent look.

### Fixed
- The operator stays rooted at the table (the paramedics' gurney used to shove them out of the
  operation).
- Carried bodies can't be confused with a player's network id; Hive Eyes snaps back if its Hive is gone.
- The exterior's upper storeys no longer z-fight and flicker over the lobby ceiling.

## [0.4.0] - 2026-09-16

Moving day: the hub gets rebuilt from a real floorplan.

### Added
- **The hub rebuild**, from Zach's floorplan: three OR tables, the lobby, a fax-ordering pharmacy,
  the crematorium furnace built into the wall, and a break room with a printer and computer.
- **Sprint-dive and prone**: crouch while sprinting to dive and land prone with a thud; the crouch key
  now steps through stand, crouch and prone.
- **A loading screen** that's a sweeping, beeping heart monitor, a launch printout, and levels built
  in the background so loading never freezes.
- **A fax-style title menu**: the sign-in sheet feeds in after the launch printout. Settings became
  a fax too.
- **The tip fax**: first-time tutorials in a small corner fax. Health moved to the top left.
- **Export builds**: `build.bat` and a Windows preset with the shader baker.
- **Patient exits**: bodies go to the furnace; the saved walk out on their own.
- **Dev mode** as a secret pharmacy order: the dev panel works anywhere, with a hidden room past
  the lot.
- Terminal 3D models, scanner feedback, a per-player database, and circular icon slots for the
  ability hotbar.

### Changed
- Surgery can use a step's supply from the shelf or straight from your hands.
- Toggle sprint, a grace window and no cooldown on the dive, after playtesting.
- The default camera went over the shoulder in the morning and back to first person by the
  afternoon. (See 0.6.0 for how that story ends.)

### Fixed
- Spoiled brains no longer sell at full price. Nice try.
- Three tests broken by the rebuilt rooms, a furnace-throw flake in devtest, and the bot getting
  stuck on things that aren't items in looptest.

## [0.3.0] - 2026-09-15

Sweep 4A: the hub starts to feel like a place.

### Added
- **Crouch, jump, ability slots** (Alt+1-4) with their own cooldowns, and **the scanner** (hold R on
  a monster to learn about it).
- **The fog lot**: the parking lot stripped bare, a ring of fog, an ambulance that drives in for
  every delivery, and spawns moved indoors.
- **The pharmacy and the crematorium**: order placebo pills, sell loot by throwing it through the
  furnace grate. **Charged throws**, and **placebo pills**: $15 a bottle, mechanically useless,
  emotionally supportive.
- **The database terminal** replaces the medical guide. Hive Eyes gets a fly-through and glazed eyes
  your teammates can see; Echo gets a pulse.
- **Exit to Main Menu / Exit to Desktop** on the pause screen.
- An **aim highlight** on things you can use, instead of floating labels everywhere.

### Changed
- The first call rings as soon as you clock in (no grace period).
- The fog is a hard opaque wall your flashlight can't cut through.
- The OR doors are manual double doors (E to open).
- The bone saw's swing lost its velocity pop and gained some camera feedback.
- The patient's twitching under sedation is toned down.

### Removed
- Gold bars, the sell bin and the gold pile.

## [0.2.0] - 2026-09-14

Sweep 3: things that fight back, and things you can do to them.

### Added
- **Combat**: bone saw swings (the saw can break), anesthetic jabs, shoves, and dragging sedated
  monsters and strapping them to a table.
- **Monsters**: the Walk-In (now the Hive) and a redesigned Discharged, with health, sedation and
  lying down.
- **Brains**: brain loot that spoils and rots, the blender, and the abilities you get from drinking
  one: **Echo** and **Hive Eyes**.
- **Dissection**: monster patients, a skull saw and brain forceps, re-dosing while you work.
- **The Night Nurse**'s Blender model in the game, with a dev panel section.
- **Doors**: room doors, locked wing gates, and the wings rebuilt every shift.
- **Pocket spaces**: the Factory and the Restaurant, other places stitched into the hospital through
  seams, with mirrors that show who's inside.
- **Hands**: first-person arms, held items gripped properly, body poses, wind-ups, and the carry
  camera.
- **Human models**: players, paramedics and Bob as Blender-built humans, and the **seal** as a
  patient.

### Changed
- Strapped monsters wear their walking rig, thrashing on the table.
- Wing rebuilds are measured and faster.

## [0.1.0] - 2026-09-13

Day one. The hospital opens its doors, against medical advice.

### Added
- **The game**: a Godot 4.7 co-op hospital horror (then called Code Blue), plus the web prototype
  it grew from.
- **Surgery minigames**: saw, anesthetic, tourniquet, forceps and gauze, each giving feedback in the
  world instead of gauges.
- **The shift loop**: several patients at once, the phone, paramedics, clocking out and game over.
- **Downed players**: 0 HP downs you; crawl, bleed out, get carried to the player table and stitched
  up with a suture kit.
- **A generated hospital**: wings split into hallways and rows of rooms, Kenney and Poly Haven assets,
  and a lit area outside.
- **Inventory**: four hand slots, bulky loot, sellable loot, colour coding and money.
- **The OR wall monitor** and a minimal HUD.
- **Multiplayer**: hosting over Steam or IP, joining mid-shift, and per-field replication built to
  survive bad connections, with a multi-process test harness.
- **Settings** (audio, display, controls), and a secret **dev room** with a dev gun, bots and a panel.
