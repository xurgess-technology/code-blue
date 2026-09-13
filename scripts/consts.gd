class_name C
extends RefCounted
## Shared constants. Everything in the project reads its scale numbers from here.

## One map tile in metres. Corridors are 2 tiles, so 3 m wide: hospital-sized.
const TILE := 1.5
const WALL_H := 3.0
const EYE_H := 1.7
const PLAYER_RADIUS := 0.4
const PLAYER_HEIGHT := 1.8

const WALK_SPEED := 3.4
const SPRINT_SPEED := 5.6
## Hand slots (inventory worker, sweep 2): bulky loot takes two of them.
const CARRY_CAP := 4
const SURGERY_TABLE_RANGE := 3.2
const INTERACT_RANGE := 2.2
const SHOVE_RANGE := 2.6
const SHOVE_COOLDOWN := 1.5

## Flashlight
const CONE_RANGE := 14.0
const CONE_DEG := 26.0

## Shift pacing
const PUNCH_SECONDS := 2.0
const POD_SECONDS := 5.0
const END_SCREEN_SECONDS := 7.0
## Seconds for a patient to bleed out from 100 on shift 1, before step bonuses.
const VITALS_DRAIN_SECONDS := 840.0

## Physics layers (1-indexed in the editor, bit masks here)
const L_WORLD := 1
const L_PLAYER := 2
const L_MONSTER := 4
const L_PICKUP := 8
const L_INTERACT := 16

const PLAYER_COLORS: Array[Color] = [
	Color("3d8f80"), Color("8f3d6e"), Color("8f7a3d"), Color("3d5f8f"),
	Color("6e8f3d"), Color("8f4a3d"),
]

## Multiplayer
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 8

static func tile_to_world(tx: float, ty: float, y: float = 0.0) -> Vector3:
	return Vector3((tx + 0.5) * TILE, y, (ty + 0.5) * TILE)

static func world_to_tile(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / TILE)), int(floor(p.z / TILE)))
