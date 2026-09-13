extends RefCounted
## Shared enums for the monster brains. Kept in lock-step with Monster.State / Monster.Mode
## (scripts/monster.gd); a separate file so the brains need not preload monster.gd, which
## preloads them.

enum State { WANDER, CHASE, STUNNED }
enum Mode { IDLE, WANDER, LISTEN, RUSH, SEARCH, STALK, STUNNED, RETREAT }
