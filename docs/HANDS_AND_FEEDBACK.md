# Hands, Wind-ups and the Carry Camera

## Goal
Combat and carrying don't read well yet. Held items float near the hands instead of sitting in
them, a shove or jab lands the instant you click, so nobody can see it coming, and a player
carrying a body sees almost nothing of it. This sweep covers three things:

1. **Held items sit in the hands**, in first person and on other players' bodies.
2. **Readable wind-ups** for the shove, the anesthetic jab and the bone saw swing, so the whole
   team can read the fight and knows when to rush in.
3. **An over-the-shoulder camera** while you carry a downed player or drag a monster.

## Where things are today
- First-person "hands" (`player.gd` `_make_hands`) are a flashlight cylinder and one skin sphere
  on the right. The held stack is on `HeldFirstPerson`, a bare node at `(-0.26, -0.3, -0.48)`
  under the camera, and no hand holds it. Bulky loot is placed low in the middle with a
  hand-tuned transform.
- In third person, `HeldThirdPerson` is a fixed node on `body_visual` at chest height. It
  doesn't follow the arm of the Kenney `char/surgeon` rig.
- Swing and jab (`combat.gd` `animate_held` / `anim_pose`) move the held pivot through keyframes
  with no anticipation. `use()` resolves the hit on the host the moment the click arrives.
- The shove (`player.gd` Q → `shove_count` → `game.player_shoved`) resolves instantly: a cone
  check, then `m.shoved()` (2 s stun for the Walk-In and the Discharged). It has no animation.
- A jab only sedates a monster that is already down ("It shrugged off the needle. Shove it
  first."), so **the shove's stun is the jab window**. Right now nobody can see that window.
- Carrying keeps the carrier in first person. The carried player's view already hangs 1 m behind
  (`_update_down_pose`, `head.position.z = 1.0`).

## 1. Held items in the hands
**First person**
- Replace the sphere and cylinder with simple low-poly **forearms and hands**, sleeves in the
  player's scrub colour. The right hand holds the flashlight and the left hand holds the selected
  stack. Bulky loot, a carried guide binder and similar objects use both hands, and the
  flashlight tucks under an arm. Keep the flashlight beam where it is now.
- Add a **grip point per item kind** (the palm position plus the item's forward and up
  directions) next to `ItemModels.footprint`. The model is placed so that grip lands in the palm.
  Every current kind needs a grip, with a sensible default for loot. Consumable batches (vials,
  gauze) are held as a small bundle, not one floating object.
- Add a small amount of life: walk bob and sway that lags behind mouse look, a lower-and-raise
  when you switch slots or pick something up, and a lowered pose while sprinting. Keep the FOV
  setting compensation (`set_fov` moves the placed nodes).
- The hands must not clip into walls. Render them on their own layer, or pull them in near
  geometry.

**Third person (other players)**
- Attach the held stack to the rig's **hand bone** with a `BoneAttachment3D`. Use the right hand,
  or both hands for bulky items. Use the same grip data, scaled for the body.
- Give the arm a holding pose (raised forearm) while something is held, blended over the idle
  and walk animation. Bulky loot uses a two-armed carry pose.
- The placeholder capsule body (no rig) keeps a fixed attach point as a fallback.

## 2. Wind-ups
One shared **wind-up, strike, recover** model for the shove, the jab and the saw. Every machine
sees the same wind-up, and the host resolves the hit **when the strike happens, not on the
click**.

| Action | Input | Wind-up | Strike resolves | Notes |
|---|---|---|---|---|
| Shove (Q, or LMB with nothing usable) | hold to charge, release to shove | min 0.2 s, full charge 0.9 s | on release | Tap = today's shove. Full charge = longer stun (about 3.5 s instead of 2) and more knockback. Charge holds for 1.5 s at most, then fires by itself. |
| Anesthetic jab (LMB) | click | 0.35 s fixed: syringe drawn, thumb on plunger, arm pulled back | end of wind-up | Target is checked at strike time, so a monster that got up in the meantime shrugs it off. |
| Saw swing (LMB) | click | 0.3 s fixed: saw raised high on the right | end of wind-up | Same system for consistency; the existing chop becomes the strike. |

**What players see and hear**
- **First person:** the arm visibly pulls back. A charging shove brings both hands up and in,
  shakes slightly as it builds, and the screen edges tighten (`PostFX` vignette). Add a rising
  charge sound, and a distinct "full" tick when the charge maxes out.
- **Teammates:** the body shows the same pull-back pose (a charging shove leans the body back
  with arms braced). A short, quiet wind-up cue plays at the player so teammates who aren't
  looking can still hear it.
- **The stun window on the monster.** This is the actual "rush in now" signal:
  - It staggers and goes down clearly (existing `stagger` on `rig_shaper`, pushed harder).
  - A dazed loop sound plays while it is down.
  - Just before it recovers, it twitches and starts to rise (about 0.6 s of warning), so players
    can tell the window is closing.
  - No HUD bars or floating icons. The only UI is the existing crosshair prompt, which reads
    "Jab it" while you aim at a jabbable monster.
- Wind-ups and charging make noise (`emit_noise`), so the Discharged can hear a charge.

**Rules**
- While winding up or charging: move at walk speed, no sprinting, and you can't switch slots.
  Getting hit, downed, shoved or stunned cancels the wind-up with no strike, and the cooldown
  still starts.
- Cooldowns start at the strike. Keep the current values unless playtests say otherwise.
- The playtest bot and `combattest` need seams to charge and release (`Player.bot_*` fields).

**Networking**
- The client starts the wind-up visuals locally the moment the input happens.
- It sends a reliable **wind-up start** event (kind, plus charge start time for the shove) and a
  **release** event. The host broadcasts both (extend `cb_swing`), so other machines play the
  pose.
- The host resolves the strike on release for the shove and on its own wind-up timer for the
  jab and saw. Keep the existing `HOST_COOLDOWN_SLACK`-style tolerance. The charge amount is
  capped on the host from the two event times.
- Under `nettest_run.gd --lag=120 --jitter=40 --loss=0.03` the teammate's pose must still show
  before the strike lands.

## 3. Over-the-shoulder carry camera
- **When:** carrying a downed player (`carrying != 0`) or dragging a monster
  (`dragging_monster >= 0`). Not for bulky loot.
- **Camera (2026-09-17, flagship framing):** over the RIGHT shoulder, like The Last of Us Part II,
  the RE4 remake or God of War: the carrier on the left third of the screen, the crosshair at the
  centre clear and aiming along the player's aim. Everything carried rides the LEFT shoulder: a
  teammate (`pinned_pose` -0.55 x), a human body on the mirrored Carried clip
  (`Player.human_carried_pose`), a seal/monster body across the shoulders shifted left
  (`corpses.SHOULDER_AT`), and the carrier's left arm wraps the legs (right arm free). It eases in
  and out over 0.4 s (smootherstep). The rig, in the player's yaw frame: a pivot at the upper back
  (`PIVOT` (0, -0.2, 0.12) from the eye), then the arm (`CARRY_ARM` 0.5 right, 0.34 up, 1.15 back:
  the camera sits 0.5 m right, 0.14 m up, 1.27 m back from the eye at level pitch). The up/back part
  of the arm swings around the pivot by 45% of the look pitch -- looking down lifts the camera a
  little so the floor ahead is in view, looking up lowers it and pulls it in a little (up to 25%)
  -- neither a full orbit nor rigid. Dragging uses the same framing a little higher and further
  back (`DRAG_ARM` 0.58, 0.72, 1.5) with a gentle 0.2 rad downward look; the dragged body lies
  behind the carrier, so it is mostly out of frame. The furnace linger keeps the carry framing.
  Sphere casts along head -> pivot -> shoulder -> camera keep it out of walls; in tight corridors
  it pulls in toward the head (instantly), and eases back out.
- **Show the local body:** the carrier's own `body_visual` (carry pose) and the carried body
  become visible to the local player. First-person hands and the held item are hidden.
- **Aim and interact:** the interact and aim ray still has to work, for example putting a
  player on the OR table or strapping a monster. Cast it from the camera, but ignore hits closer
  than the player's head, and check reach from the head, not the camera.
- **Flashlight:** keep the beam where it is now and pointed where the camera looks.
  `lights_point` and the Night Nurse rules keep using the head.
- **Exit:** ease back to first person when you put the body down, drop it, get shoved off, or
  get knocked out.
- This is local only, with nothing new on the wire. Add a settings toggle "Carry camera:
  shoulder / first person" (default shoulder).

## Constraints
- Hold 60 fps with 1% lows above 50 on the Radeon 890M (medium preset). Check with
  `tools/perfprobe`. Arms and hands should be a few hundred triangles, with no extra shadowed
  lights.
- Register new meshes, materials and shaders in `scripts/warmup.gd`, including the first
  wind-up of each kind, so the first charge doesn't hitch.
- Use CC0 assets only, look them up through `Assets`, and record them in `ASSETS.md`.
- Update `docs/CONTRACTS.md` ("Combat" and "Player") with the grip data, the wind-up states and
  events, and the carry camera.
- Other sessions edit this project too. Check file mtimes on `player.gd`, `combat.gd` and
  `game.gd` before big rewrites.

## Done when
- `tools/gameshot` has shots of: first person holding each item kind; a teammate holding a
  one-handed item and a bulky item; a shove at full charge in first person and from a
  teammate's view; a jab and a saw swing at the wind-up peak; a monster in its stun window; and
  the carry camera for a carried player and a dragged monster, including in a narrow corridor.
- `combattest` covers these cases:
  - a tap shove and a full-charge shove give the right stun lengths
  - a jab resolves at the end of the wind-up, not on the click
  - a jab on a monster that recovered during the wind-up fails
  - taking a hit mid-wind-up cancels it
- A nettest `combat` scenario under lag confirms the client sees the teammate's wind-up
  before the strike, and that the host caps an over-long charge.
- A headless test puts a carried player on the OR table and straps a dragged monster while in
  the carry camera, so the interact ray still works from the shoulder.
- `tools/playtest.tscn` still passes with `--god` on the usual seeds.
