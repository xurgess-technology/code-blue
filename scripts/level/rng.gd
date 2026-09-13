extends RefCounted
## mulberry32, bit for bit the same as the TypeScript prototype's PRNG, so seeds stay stable.

var a: int


func _init(s: int) -> void:
	a = s & 0xFFFFFFFF


## 32-bit multiply (Math.imul), split so the intermediate never overflows int64.
static func imul(x: int, y: int) -> int:
	x &= 0xFFFFFFFF
	y &= 0xFFFFFFFF
	return (((((x >> 16) * y) & 0xFFFF) << 16) + ((x & 0xFFFF) * y)) & 0xFFFFFFFF


func nextf() -> float:
	a = (a + 0x6d2b79f5) & 0xFFFFFFFF
	var t := a
	t = imul(t ^ (t >> 15), t | 1)
	t = ((t + imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF) ^ t
	return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


## Integer in [lo, hi], inclusive.
func rint(lo: int, hi: int) -> int:
	return lo + int(floor(nextf() * float(hi - lo + 1)))


func rangef(lo: float, hi: float) -> float:
	return lo + nextf() * (hi - lo)


func chance(p: float) -> bool:
	return nextf() < p


func pick(arr: Array):
	return arr[int(floor(nextf() * float(arr.size())))]


func shuffle(arr: Array) -> Array:
	for i in range(arr.size() - 1, 0, -1):
		var j := int(floor(nextf() * float(i + 1)))
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr


## Index into `weights` (non-negative floats) chosen with probability proportional to its weight.
func weighted(weights: Array) -> int:
	var total := 0.0
	for x in weights:
		total += float(x)
	if total <= 0.0:
		return -1
	var roll := nextf() * total
	for i in weights.size():
		roll -= float(weights[i])
		if roll < 0.0:
			return i
	return weights.size() - 1
