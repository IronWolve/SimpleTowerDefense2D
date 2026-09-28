class_name SaveSchema
extends RefCounted
## Validate before replacing the current scene. Version 2 stays readable;
## additions have defaults, while malformed nested data is rejected as a unit.

static func _cell(value: Variant, dimensions: Vector2i) -> bool:
	return value is Array and value.size() == 2 and GameRules.integer(value[0], 0, dimensions.x - 1) and GameRules.integer(value[1], 0, dimensions.y - 1)

static func _vector(value: Variant, size: int, low: float, high: float) -> bool:
	if not value is Array or value.size() != size:
		return false
	for item in value:
		if not GameRules.number(item, low, high):
			return false
	return true

static func _numbers(data: Dictionary, names: Array, low: float = 0.0, high: float = 1.0e30) -> bool:
	for name in names:
		if data.has(name) and not GameRules.number(data[name], low, high):
			return false
	return true

static func _integers(data: Dictionary, names: Array, low: int = 0, high: int = GameRules.MAX_CURRENCY) -> bool:
	for name in names:
		if data.has(name) and not GameRules.integer(data[name], low, high):
			return false
	return true

static func _bools(data: Dictionary, names: Array) -> bool:
	for name in names:
		if data.has(name) and not data[name] is bool:
			return false
	return true

static func _signed_integer_text(value: Variant) -> bool:
	if not value is String or not value.is_valid_int() or value.length() > 20:
		return false
	var negative: bool = value.begins_with("-")
	var digits: String = value.trim_prefix("-").trim_prefix("+")
	var maximum := "9223372036854775808" if negative else "9223372036854775807"
	return digits.length() < 19 or (digits.length() == 19 and digits <= maximum)

static func validate(data: Variant) -> String:
	if not data is Dictionary or data.is_empty():
		return "No readable saved game found."
	if not GameRules.integer(data.get("v"), 2, 2):
		return "This save uses an unsupported version."
	if not GameRules.integer(data.get("board_size"), 0, GameRules.BOARD_SIZES.size() - 1):
		return "The save has an invalid board size."
	var dimensions: Vector2i = GameRules.BOARD_SIZES[int(data["board_size"])]
	if not _cell(data.get("spawn"), dimensions) or not _cell(data.get("base"), dimensions) or data["spawn"] == data["base"]:
		return "The save has invalid entrance or exit positions."
	for key in ["gold", "lives", "score", "wave"]:
		if not GameRules.integer(data.get(key)):
			return "The save has invalid run statistics."
	if data["wave"] > GameRules.MAX_WAVE:
		return "The saved wave is outside the supported range."
	if not data.get("stock") is Dictionary or not _integers(data["stock"], ["wall", "tower"]):
		return "The save has invalid piece stock."
	if not data.get("pieces") is Array or data["pieces"].size() > dimensions.x * dimensions.y:
		return "The save has an invalid board."
	var occupied := {}
	var blocked := {}
	for piece in data["pieces"]:
		if not piece is Dictionary or not piece.get("t") is String or not PieceData.TYPES.has(piece["t"]):
			return "The save contains an unknown piece."
		var cell := [piece.get("x"), piece.get("y")]
		if not _cell(cell, dimensions) or cell == data["spawn"] or cell == data["base"]:
			return "The save places a piece outside the board or over an entrance."
		var at := Vector2i(int(cell[0]), int(cell[1]))
		if occupied.has(at):
			return "The save contains overlapping pieces."
		occupied[at] = true
		if PieceData.TYPES[piece["t"]]["blocks"]:
			blocked[at] = true
		if not _integers(piece, ["lvl"], 1, GameRules.MAX_LEVEL) or not _integers(piece, ["inv"]) or not _bools(piece, ["stock", "under"]):
			return "The save has invalid piece upgrades."
		if not _numbers(piece, ["cooldown", "visual_cd", "erupt_timer"], -1.0, 1000000.0):
			return "The save has invalid piece timers."
		if piece.has("under_wall"):
			var under: Variant = piece["under_wall"]
			if not under is Dictionary or not _integers(under, ["inv"]) or not _bools(under, ["stock"]):
				return "The save has invalid underlying walls."
	if not data.get("enemies", []) is Array or data.get("enemies", []).size() > GameRules.MAX_SAVED_ENEMIES:
		return "The save has too many enemies or invalid enemy data."
	for enemy in data.get("enemies", []):
		if not _enemy(enemy, dimensions, blocked, data["base"]):
			return "The save contains invalid enemy state or routes."
	if not _waves(data.get("wave_state"), int(data["wave"])):
		return "The save contains invalid wave progress."
	if not data.get("bullets", []) is Array or data.get("bullets", []).size() > GameRules.MAX_BULLETS:
		return "The save has invalid projectiles."
	for bullet in data.get("bullets", []):
		if not _bullet(bullet, dimensions, data.get("enemies", []).size()):
			return "The save contains an invalid projectile."
	if data.has("run_options"):
		if not data["run_options"] is Dictionary or not _bools(data["run_options"], ["bonus_lives_per_wave", "unlimited_money", "unlimited_lives", "free_walls", "round_timer_bonus"]):
			return "The save contains invalid game options."
	return ""

static func _enemy(enemy: Variant, dimensions: Vector2i, blocked: Dictionary, base: Array) -> bool:
	if not enemy is Dictionary or not _cell(enemy.get("cell"), dimensions):
		return false
	if not _vector(enemy.get("pos"), 2, 0.0, max(dimensions.x, dimensions.y) * 40.0):
		return false
	if enemy["pos"][0] > dimensions.x * 40.0 or enemy["pos"][1] > dimensions.y * 40.0:
		return false
	if not _vector(enemy.get("color", [0.9, 0.35, 0.35, 1.0]), 4, 0.0, 1.0):
		return false
	if not _numbers(enemy, ["base_speed", "speed"], 0.0, 175.0) or not _numbers(enemy, ["health", "max_health"], 0.000001):
		return false
	if not _integers(enemy, ["reward", "leak"]) or not _numbers(enemy, ["radius"], 1.0, 100.0):
		return false
	if not _numbers(enemy, ["slow_t", "vuln_t"], 0.0, 1000000.0) or not _numbers(enemy, ["slow_f"], 0.0, 0.95):
		return false
	if not _numbers(enemy, ["vuln_p"], 0.0, 1000.0) or not _numbers(enemy, ["face"], -TAU, TAU):
		return false
	if not _bools(enemy, ["is_boss"]):
		return false
	for field in ["shape", "boss_kind"]:
		if enemy.has(field) and not enemy[field] is String:
			return false
	if not enemy.get("resist", {}) is Dictionary or enemy.get("resist", {}).size() > 8:
		return false
	for value in enemy.get("resist", {}).values():
		if not GameRules.number(value, 0.0, 10.0):
			return false
	var dots: Variant = enemy.get("dots", {})
	if not dots is Dictionary or dots.size() > 8:
		return false
	for key in dots:
		if not key is String or not dots[key] is Dictionary or not GameRules.number(dots[key].get("dps")) or not GameRules.number(dots[key].get("timer"), 0.0, 1000000.0):
			return false
	var path: Variant = enemy.get("path")
	if not path is Array or path.size() > dimensions.x * dimensions.y:
		return false
	var previous := Vector2i(int(enemy["cell"][0]), int(enemy["cell"][1]))
	var seen := {}
	for cell in path:
		if not _cell(cell, dimensions):
			return false
		var current := Vector2i(int(cell[0]), int(cell[1]))
		if blocked.has(current) or seen.has(current) or absi(current.x - previous.x) + absi(current.y - previous.y) > 1:
			return false
		seen[current] = true
		previous = current
	return previous == Vector2i(int(base[0]), int(base[1])) and not blocked.has(Vector2i(int(enemy["cell"][0]), int(enemy["cell"][1])))

static func _waves(waves: Variant, wave: int) -> bool:
	if not waves is Dictionary or not _integers(waves, ["started", "bonus_through"], 0, GameRules.MAX_WAVE):
		return false
	if int(waves.get("started", 0)) != wave or int(waves.get("bonus_through", 0)) > wave:
		return false
	if not _integers(waves, ["queued"], 0, 1000) or not _bools(waves, ["auto"]):
		return false
	if not _numbers(waves, ["countdown"], -1.0, 30.0) or not _numbers(waves, ["queue_timer", "queue_interval"], 0.0, 30.0):
		return false
	if waves.has("rng_state") and not _signed_integer_text(waves["rng_state"]):
		return false
	var jobs: Variant = waves.get("jobs", [])
	if not jobs is Array or jobs.size() > GameRules.MAX_JOBS:
		return false
	for job in jobs:
		if not job is Dictionary or job.get("kind") not in ["normal", "boss", "turtle"]:
			return false
		if not GameRules.integer(job.get("wave"), 1, wave) or not GameRules.integer(job.get("remaining"), 1, 40):
			return false
		if not GameRules.number(job.get("timer"), -1.0, 30.0):
			return false
	return true

static func _bullet(bullet: Variant, dimensions: Vector2i, count: int) -> bool:
	if not bullet is Dictionary or not _vector(bullet.get("pos"), 2, 0.0, dimensions.x * 40.0) or not _vector(bullet.get("dest"), 2, 0.0, dimensions.x * 40.0):
		return false
	if not _vector(bullet.get("color"), 4, 0.0, 1.0) or not GameRules.integer(bullet.get("target"), -1, count - 1):
		return false
	return _numbers(bullet, ["damage", "slow_time"]) and _numbers(bullet, ["speed"], 0.01, 10000.0) and _numbers(bullet, ["slow"], 0.0, 0.95) and _numbers(bullet, ["aoe"], 0.0, 300.0) and _bools(bullet, ["retarget", "visible"]) and bullet.get("style") in ["bullet", "ball", "missile"]

static func map_data(value: Variant) -> Dictionary:
	if not value is Dictionary or not GameRules.integer(value.get("v"), 2, 2) or not value.get("grid") is Array:
		return {}
	var grid: Array = value["grid"]
	if grid.is_empty() or grid.size() > 30 or not grid[0] is String or grid[0].length() < 2 or grid[0].length() > 64:
		return {}
	var dimensions := Vector2i(grid[0].length(), grid.size())
	for row in grid:
		if not row is String or row.length() != dimensions.x:
			return {}
		for character in row:
			if character not in ["0", "1"]:
				return {}
	if not _cell(value.get("spawn"), dimensions) or not _cell(value.get("base"), dimensions) or value["spawn"] == value["base"]:
		return {}
	for point in [value["spawn"], value["base"]]:
		if grid[int(point[1])][int(point[0])] != "0":
			return {}
	return value
