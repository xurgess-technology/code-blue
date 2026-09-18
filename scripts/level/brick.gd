extends RefCounted
## Charred brick for the crematorium, made in code (there's no brick texture on disk): colour,
## normal and roughness maps, tileable, drawn once and cached.
##
##   walls    running-bond brick, black with dark dirt-brown bricks among them, grimy mortar
##   floor    bigger pavers, browner and dirtier, filthy joints
##   ceiling  the wall brick again, soot-black
##
## The materials are world triplanar, so anything can wear them whatever its UVs: the level's
## walls, floor and ceiling (hospital_builder.gd) and the furnace's brickwork (economy/furnace.gd).

const SIZE := 256

static var _cache := {}


static func wall_material() -> StandardMaterial3D:
	return _material("wall", 4, 16, Color(0.075, 0.06, 0.05), Color(0.2, 0.125, 0.07), Color(0.15, 0.13, 0.11), 0.35, 1.0)


static func floor_material() -> StandardMaterial3D:
	return _material("floor", 2, 8, Color(0.1, 0.075, 0.055), Color(0.24, 0.155, 0.085), Color(0.12, 0.09, 0.065), 0.6, 1.2)


static func ceiling_material() -> StandardMaterial3D:
	return _material("ceiling", 4, 16, Color(0.045, 0.04, 0.035), Color(0.1, 0.07, 0.05), Color(0.07, 0.06, 0.05), 0.2, 1.0)


## `across` bricks per row and `rows` courses per texture; each brick picks a colour between `dark`
## and `brown` (`brown_share` of them lean brown), mortar is `mortar`; the texture covers
## `metres` of surface.
static func _material(key: String, across: int, rows: int, dark: Color, brown: Color, mortar: Color,
		brown_share: float, metres: float) -> StandardMaterial3D:
	if _cache.has(key):
		return _cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var dirt_noise := FastNoiseLite.new()
	dirt_noise.seed = rng.randi()
	dirt_noise.frequency = 0.02
	dirt_noise.fractal_octaves = 4
	var dirt: Image = dirt_noise.get_seamless_image(SIZE, SIZE)
	var grain_noise := FastNoiseLite.new()
	grain_noise.seed = rng.randi()
	grain_noise.frequency = 0.18
	var grain: Image = grain_noise.get_seamless_image(SIZE, SIZE)

	var bw := SIZE / across
	var bh := SIZE / rows
	var joint := maxi(2, bh / 6)
	# One colour per brick (the pattern wraps, so the texture tiles).
	var brick_col := []
	for r in rows:
		var row := []
		for c in across:
			var t := rng.randf()
			var col := dark.lerp(brown, rng.randf_range(0.55, 1.0) if t < brown_share else rng.randf_range(0.0, 0.35))
			row.append(col)
		brick_col.append(row)

	var albedo := PackedByteArray()
	albedo.resize(SIZE * SIZE * 3)
	var rough := PackedByteArray()
	rough.resize(SIZE * SIZE)
	var height := PackedFloat32Array()
	height.resize(SIZE * SIZE)
	for y in SIZE:
		var r := mini(y / bh, rows - 1)
		var in_row := y % bh
		var shift := (bw / 2) if r % 2 == 1 else 0
		for x in SIZE:
			var sx := (x + shift) % SIZE
			var c := mini(sx / bw, across - 1)
			var in_col := sx % bw
			var edge := mini(mini(in_row, bh - 1 - in_row), mini(in_col, bw - 1 - in_col))
			var i := y * SIZE + x
			var d := dirt.get_pixel(x, y).r
			var g := grain.get_pixel(x, y).r
			var col: Color
			var h := 0.0
			var ro := 1.0
			if edge < joint:
				col = mortar * (0.8 + 0.4 * g)
				h = 0.0
			else:
				col = (brick_col[r][c] as Color) * (0.82 + 0.36 * g)
				# Chipped, rounded edges.
				h = clampf(float(edge - joint + 1) / 3.0, 0.0, 1.0) * (0.85 + 0.15 * g)
				ro = 0.82 + 0.12 * g
			# Dirt and soot in blotches over everything.
			col = col.lerp(Color(0.05, 0.04, 0.03), clampf((d - 0.55) * 1.6, 0.0, 0.7))
			col = col.lerp(Color(0.2, 0.13, 0.07), clampf((0.35 - d) * 1.2, 0.0, 0.35))
			albedo[i * 3] = clampi(int(col.r * 255.0), 0, 255)
			albedo[i * 3 + 1] = clampi(int(col.g * 255.0), 0, 255)
			albedo[i * 3 + 2] = clampi(int(col.b * 255.0), 0, 255)
			rough[i] = clampi(int(ro * 255.0), 0, 255)
			height[i] = h

	# Normals from the height field (OpenGL convention, as Godot expects), wrapping at the edges.
	var normal := PackedByteArray()
	normal.resize(SIZE * SIZE * 3)
	var k := 2.5
	for y in SIZE:
		for x in SIZE:
			var l := height[y * SIZE + (x - 1 + SIZE) % SIZE]
			var rr := height[y * SIZE + (x + 1) % SIZE]
			var u := height[((y - 1 + SIZE) % SIZE) * SIZE + x]
			var dn := height[((y + 1) % SIZE) * SIZE + x]
			var n := Vector3((l - rr) * k, (dn - u) * k, 1.0).normalized()
			var i := (y * SIZE + x) * 3
			normal[i] = int((n.x * 0.5 + 0.5) * 255.0)
			normal[i + 1] = int((n.y * 0.5 + 0.5) * 255.0)
			normal[i + 2] = int((n.z * 0.5 + 0.5) * 255.0)

	var m := StandardMaterial3D.new()
	m.resource_name = "brick_" + key
	m.albedo_texture = _tex(Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGB8, albedo))
	m.normal_enabled = true
	m.normal_texture = _tex(Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGB8, normal))
	m.normal_scale = 1.4
	m.roughness_texture = _tex(Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_L8, rough))
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	var s := 1.0 / metres
	m.uv1_scale = Vector3(s, s, s)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_cache[key] = m
	return m


static func _tex(img: Image) -> ImageTexture:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
