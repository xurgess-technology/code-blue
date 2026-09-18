# Changelog

Everything that changes in **Malpractice**, newest first. One minor version per day of work, one
patch per thing we did that day. How to add to it: [RULES.md](RULES.md#changelog).

**2026-09-18 (0.6.x)**

- **0.6.10**: Eyeball Extraction 👁️
    - Added: Take a strapped Hive's eye out with a scalpel and an eye spoon: trace the cut and watch it open on the skin, circle the socket with the spoon, lift the eye on its nerve and slice it.
    - Added: Specimen vats on the lab wall. Put an eye in one to keep it from spoiling, carry it, set it on a lab bench. Eyes spoil outside a vat and sell at the furnace.
    - Added: The scalpel and eye spoon in the OR storage, and jars of heads on the lab wall.
- **0.6.9**: Lie down, doc
    - Added: Hold E at an OR table to strap yourself down, face up and awake. Let go and hold E again to get up.
    - Changed: A strapped-down body lies along the table for everyone, with no torch or other light on it.
- **0.6.8**: A new way of working 🧑‍⚕️🧑‍⚕️🧑‍⚕️
    - Added: One orchestrator agent hands work to subagents in four reusable work slots; see [RULES.md](RULES.md#workflow).
    - Added: Review windows: a game window from a slot, titled with what to go look at. It waits in the taskbar instead of popping up in your face.
    - Changed: Play it first, test it hard later; big test sweeps get batched.
- **0.6.7**: Spring cleaning 🧹
    - Removed: The first Night Nurse, unused models and the old web prototype (moved to `deprecated/`).
    - Removed: Sounds nothing played, and about 320 MB of old screenshots, logs and caches.
- **0.6.6**: Paperwork
    - Added: This changelog, and [RULES.md](RULES.md) for how we work.
    - Added: The art style for characters and models, written down in DESIGN.md.
- **0.6.5**: The Hive gets a glow-up 🍄
    - Changed: A new Hive: charcoal skin, and a shelf fungus growing out of its broken-open skull.
    - Added: Its own shamble and lunge, and eyes that flood orange once it's seen you.
    - Changed: There's no brain to take out of it for now; that part is being rethought.
- **0.6.4**: THE NIGHT NURSE HAS YOU BY THE THROAT 🫲🫲🫲
    - Changed: She grabs you and drops you downed instead of taking hearts.
    - Changed: A new look in the game's art style.
- **0.6.3**: Cameras
    - Added: F5 cycles first person, over the shoulder, and a view facing you.
    - Fixed: Your flashlight no longer shines on the back of your own head.
- **0.6.2**: ROCKET BOOTS 🚀🚀🚀 THE SHOP SELLS A REAL THING 🚀🚀🚀
    - Added: Rocket boots at the pharmacy: fly on a fuel bar, faceplant into walls.
- **0.6.1**: The hub fills in
    - Added: A personnel room with working mirrors, and the OR's lab wall, storage and janitor's closet.
    - Changed: Surgical tools work straight from your hands, and the dive flies flat out.
- **0.6.0**: Code Blue is dead, long live Malpractice
    - Changed: The project is renamed everywhere.

**2026-09-17 (0.5.x)**

- **0.5.4**: Polish
    - Changed: The Walk-In is now the Hive.
    - Changed: Faxes move faster and get rubber stamps; a shift assignment fax starts every session.
    - Changed: The carry camera sits over your right shoulder; throws have a wind-up.
    - Changed: The saw follows a skin-marker line instead of a glowing guide.
    - Fixed: The paramedics' gurney no longer shoves you out of an operation.
- **0.5.3**: The outside world
    - Added: The hospital's exterior, and you arrive by walking out of the fog.
    - Changed: Wander too deep into the fog and you get lost instead of steered back.
- **0.5.2**: A NEW DOCTOR IN THE HOUSE 🩺 (THE STYLIZED SURGEON)
    - Added: The players' new body, built from Python in Blender.
- **0.5.1**: WE ARE NOW MALPRACTICE!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    - Changed: The game is **Malpractice**, and the hospital is **St. Doe's General**. RIP Code Blue.
- **0.5.0**: The wall terminal
    - Added: A shared projector screen in the break room: sign in with your scan laser, everyone sees everyone's.
    - Changed: The database is a slide projector with a lock screen.

**2026-09-16 (0.4.x)**

- **0.4.5**: Polish
    - Added: Dead patients go to the furnace; the saved walk out.
    - Changed: Surgery can use supplies from your hands, and the ability hotbar is round.
    - Changed: The default camera went over the shoulder and back again by the afternoon.
    - Fixed: Spoiled brains no longer sell at full price. Nice try.
- **0.4.4**: The wall terminal, part one
    - Added: A projector screen, a scan laser, and a database per player.
- **0.4.3**: THE HUB REBUILD 🏥🏥🏥 (FROM ZACH'S ACTUAL FLOORPLAN)
    - Added: Three OR tables, the lobby, a fax pharmacy, a crematorium furnace and a break room.
- **0.4.2**: Faxes everywhere
    - Added: The title menu, the settings screen and first-time tips are all faxes now.
- **0.4.1**: Loading that never freezes
    - Added: A heart monitor loading screen, with levels built in the background.
    - Added: Windows export builds.
- **0.4.0**: Sprint-dive and prone
    - Added: Crouch while sprinting to dive; the crouch key cycles stand, crouch and prone.

**2026-09-15 (0.3.x)**

- **0.3.4**: Polish
    - Changed: Things you can use highlight when you aim at them.
    - Changed: The first call rings as soon as you clock in, and the OR doors open with E.
    - Added: Exit to Main Menu and Exit to Desktop on the pause screen.
- **0.3.3**: The database terminal
    - Added: A terminal that replaces the medical guide.
    - Changed: Hive Eyes and Echo look the part.
- **0.3.2**: GOODBYE GOLD BARS 💸 HELLO PHARMACY
    - Added: The pharmacy (placebo pills, emotionally supportive) and the crematorium furnace for selling loot.
    - Added: Charged throws.
    - Removed: Gold bars and the sell bin.
- **0.3.1**: The fog lot
    - Added: A ring of fog, and an ambulance that drives in for every delivery.
- **0.3.0**: Crouch, jump, abilities, scanner
    - Added: Crouch and jump, ability slots on Alt+1-4, and a scanner for learning about monsters.

**2026-09-14 (0.2.x)**

- **0.2.5**: New faces
    - Added: Blender-built players, paramedics and Bob, the seal patient, and the Night Nurse's model.
- **0.2.4**: Hands
    - Added: First-person arms, items held properly, wind-ups and the carry camera.
- **0.2.3**: Pocket spaces
    - Added: The Factory and the Restaurant, stitched into the hospital through seams.
- **0.2.2**: Doors
    - Added: Room doors and locked wing gates, with the wings rebuilt every shift.
- **0.2.1**: Dissection
    - Added: Monster patients, a skull saw and brain forceps.
- **0.2.0**: Monsters
    - Added: The Walk-In (now the Hive), and a redesigned Discharged.
    - Changed: Monster meshes baked down from ~90 draw calls to ~6 each.

**2026-09-13 (0.1.x)**

- **0.1.7**: Brains and combat
    - Added: Brains that spoil, the blender, and the Echo and Hive Eyes abilities.
    - Added: Saw swings, anesthetic jabs, and dragging sedated monsters to a table.
- **0.1.6**: The shift loop
    - Added: Several patients at once, the phone, paramedics, clocking out and game over.
    - Added: The OR wall monitor.
- **0.1.5**: Downed players
    - Added: 0 HP downs you: crawl, bleed out, get carried to a table and stitched up.
- **0.1.4**: A generated hospital
    - Added: Wings of hallways and rooms, furnished and lit.
- **0.1.3**: Inventory and money
    - Added: Four hand slots, bulky and sellable loot, and money.
- **0.1.2**: Multiplayer
    - Added: Host over Steam or IP and join mid-shift.
    - Changed: Netcode rewritten to send each field on its own, so bad connections catch up.
- **0.1.1**: Surgery that feels right
    - Changed: Every surgery minigame gives feedback in the world instead of gauges.
- **0.1.0**: THE HOSPITAL IS OPEN 🚑🚑🚑 (AGAINST MEDICAL ADVICE)
    - Added: Code Blue, a co-op hospital horror game in Godot, and the web prototype it grew from.
    - Added: Settings, and a secret dev room.
