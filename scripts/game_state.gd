extends Node
## Persistent run state. Autoloaded, so it survives scene reloads on restart.

const STARTING_GOLD := 240
const STARTING_LIVES := 20
const STARTING_WALLS := 30
const STARTING_TOWERS := 0
## Hard mode starting values (used when bonus_lives_per_wave is off). Explicit
## numbers rather than a multiplier so each lever can be tuned independently.
const HARD_STARTING_GOLD := 120
const HARD_STARTING_LIVES := 10
const HARD_STARTING_WALLS := 15
const SETTINGS_PATH := "user://settings.cfg"
## Where custom maps saved from the editor are stored. One .txt per map.
const MAPS_DIR := "user://maps"
const MAX_DATA_FILE_BYTES := 64 * 1024 * 1024

## Names are single portable filenames, never relative paths.
func valid_data_name(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() or value.begins_with("."):
		return false
	if value.to_utf8_buffer().size() > 200 or value.ends_with("."):
		return false
	for ch in value:
		if ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] or ch.unicode_at(0) < 32 or ch.unicode_at(0) == 127:
			return false
	var stem := value.get_slice(".", 0).strip_edges().to_upper()
	if stem in ["CON", "PRN", "AUX", "NUL"]:
		return false
	if stem.length() == 4 and (stem.begins_with("COM") or stem.begins_with("LPT")) and stem[3] in "123456789¹²³":
		return false
	return true

func _safe_data_path(path: String) -> bool:
	if not path.begins_with("user://") or ".." in path.trim_prefix("user://").split("/"):
		return false
	var root := DirAccess.open("user://")
	if root == null:
		return false
	var relative := path.trim_prefix("user://")
	var parent := relative.get_base_dir()
	if not parent.is_empty() and root.is_link(parent):
		return false
	return not root.is_link(relative)

## Write beside the destination, check the flush, then replace it. A failed
## write leaves the previous save intact instead of truncating it first.
func _write_data_text(path: String, text: String) -> bool:
	if not _safe_data_path(path) or text.to_utf8_buffer().size() > MAX_DATA_FILE_BYTES:
		return false
	var temporary := path + ".tmp"
	if not _safe_data_path(temporary):
		return false
	var f := FileAccess.open(temporary, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.flush()
	var ok := f.get_error() == OK
	f.close()
	if ok:
		ok = DirAccess.rename_absolute(temporary, path) == OK
	if not ok:
		DirAccess.remove_absolute(temporary)
	return ok

func _read_data_text(path: String) -> String:
	if not _safe_data_path(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	if f.get_length() > MAX_DATA_FILE_BYTES:
		f.close()
		return ""
	var text := f.get_as_text()
	f.close()
	return text

func _read_data_json(path: String) -> Dictionary:
	var text := _read_data_text(path)
	if text.is_empty():
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {}
	return parser.data if parser.data is Dictionary else {}

## Save / map format versions. Stamped into every save we write; the loader
## refuses files whose version doesn't match. Bump deliberately whenever the
## on-disk schema changes incompatibly (e.g. a renamed/removed field). Don't
## bump for additive changes that read fine with a `.get(key, default)`.
##
## Tracked in CHECKLIST.md under "Save / load". When you bump one of these,
## tick the matching item and add a one-line note to RELEASES so players know
## why their old saves stopped loading.
const SAVE_FORMAT_VERSION := 2
const MAP_FORMAT_VERSION := 2

## Old project name (from before the v49 rename). Used by the one-shot
## startup migration to find user data left behind when Godot's user:// path
## moved with the rename.
const OLD_PROJECT_NAME := "Tower Defense"
const NEW_PROJECT_NAME := "Simple Tower Defense 2D"

## Spendable currency. Goes up on kills (kill reward + Gold Mine bonus),
## down on placement / upgrade. Capped only by signed-int range. The HUD
## shows it abbreviated above ~10K.
var gold := STARTING_GOLD
var lives := STARTING_LIVES
## Current wave NUMBER. Goes up when WaveManager actually launches a wave;
## a "queued" send-N waves doesn't bump it until each fires. Best-wave stat
## compares against this.
var wave := 0
## Cumulative SCORE for the run. NOT the same as gold - score reflects how
## much enemy reward you generated this run regardless of how you spent it,
## so it's the right comparison for the best-score stat. Kill reward adds
## both gold and score, but sell refunds only return gold.
var score := 0
var game_over := false
## Free-piece stock counters. Only "wall" and "tower" (the basic Bullet
## Tower) get stock. Every other tower and every trap is paid from gold
## the moment it's placed - no free first one. Stock counts down on each
## free placement; when it hits 0, the buy button switches from
## "Wall x30" to "Wall $10" and the player starts paying gold.
##
## DO NOT add other types to this dict without also wiring stock_changed
## events and updating the HUD buy-button render in _refresh_buy_buttons.
var stock := {"wall": STARTING_WALLS, "tower": STARTING_TOWERS}

## Set to a save snapshot just before reload_current_scene() to resume a run
## instead of starting fresh; main.gd and Level read it on the fresh scene.
## Empty dictionary == start a normal new game.
var pending_load := {}

## Persistent option (kept across Reset Game): grant lives per wave cleared.
## On by default; Hard mode in the options menu turns it off.
var bonus_lives_per_wave := true
## Persistent option: never run out of gold.
var unlimited_money := false
## Persistent option: enemies that leak don't subtract from lives.
var unlimited_lives := false
## Persistent option: walls are free to place.
var free_walls := false
## Persistent option: hold left-click and drag to draw walls. On by default.
var drag_draw_walls := true
## Persistent option: 30s inter-wave timer; sending a non-boss wave early
## refunds gold for each second left on the countdown. On by default.
var round_timer_bonus := true
## Persistent option: board size for a new game (0 normal, 1 large, 2 huge).
var board_size := 0
var run_board_size := 0
var game_speed := 1.0
var effective_speed := 1.0
var simulation_limited := false
var _last_stats_tick := 0
var _next_stats_flush := 0
## Persistent option: which pre-built map to use for a new game.
## One of: "none" (open field), "spiral", "generate", or "custom:<name>".
var map_type := "none"
## Seed used the last time we built a Generated map. 0 = "no seed stored
## yet; roll a fresh one on the next generation". On New Game with map_type
## "generate" we ask whether to keep the same map (reuse this seed) or roll
## a new one (clear to 0 first).
var generated_seed: int = 0

## Persistent option: borderless fullscreen on (true) vs windowed (false).
## Toggled in-game with F11. Applied at boot from save_settings file so the
## window comes up the way it was left.
var fullscreen: bool = false

## Best-ever wave reached and best-ever score, persisted across sessions.
var best_wave := 0
var best_score := 0
## Lifetime stats persisted across sessions.
var total_kills := 0
var total_games := 0
var total_play_seconds := 0.0
var best_tower_level := 0
var first_played_unix := 0
var last_played_unix := 0

## At or above this game speed, cosmetic effects are skipped to cut visual
## noise and load. Logical projectile timing and combat stay unchanged.
const FAST_GFX_SCALE := 4.0

func reduced_gfx() -> bool:
	return game_speed >= FAST_GFX_SCALE

## Arrow glyph for info/help text: a real arrow on desktop, ASCII "->" on web
## (the web build's fallback font can't render the Unicode arrow).
func arrow() -> String:
	return "->" if OS.has_feature("web") else "→"

const _ABBREV_UNITS := ["K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp"]

## Compact display for large numbers so long runs stay readable:
## 850 -> "850", 12345 -> "12.3K", 4_500_000 -> "4.5M", 1.2e12 -> "1.2T".
## Under 1000 it shows a plain integer; above, 3 significant digits + a suffix.
func abbrev(value: float) -> String:
	var neg := value < 0.0
	var n := absf(value)
	if n < 1000.0:
		return ("-" if neg else "") + str(int(round(n)))
	var mag := 0
	while n >= 1000.0 and mag < _ABBREV_UNITS.size():
		n /= 1000.0
		mag += 1
	var s: String
	if n < 10.0:
		s = "%.2f" % n
	elif n < 100.0:
		s = "%.1f" % n
	else:
		s = "%.0f" % n
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return ("-" if neg else "") + s + _ABBREV_UNITS[mag - 1]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_stats_tick = Time.get_ticks_usec()
	_next_stats_flush = Time.get_ticks_msec() + 30000
	_maybe_migrate_user_data()
	load_settings()
	if first_played_unix == 0:
		first_played_unix = int(Time.get_unix_time_from_system())
		save_settings()

## One-shot user-data migration. The v49 rename to "Simple Tower Defense 2D"
## moved Godot's user:// path (it's derived from project.config/name), which
## stranded every save/map/setting under the OLD "Tower Defense" folder. This
## checks the old folder, and if the new folder hasn't been used yet, copies
## saves, the auto/manual slots, named saves, custom maps and settings over.
## Idempotent: once anything's in the new folder, it does nothing.
func _maybe_migrate_user_data() -> void:
	var new_dir := OS.get_user_data_dir()
	# Only run when this is actually the renamed project (someone forks the
	# code under a different name? leave their data alone).
	if new_dir.get_file() != NEW_PROJECT_NAME:
		return
	var old_dir := new_dir.get_base_dir().path_join(OLD_PROJECT_NAME)
	if old_dir == new_dir or not DirAccess.dir_exists_absolute(old_dir):
		return
	# Refuse if the new dir already has gameplay content - a player who has
	# already played v49 must not have it overwritten by a stale older copy.
	if _user_dir_has_content(new_dir):
		return
	# Copy single-file slots, then walk subdirectories.
	_copy_file(old_dir + "/save_auto.json",   new_dir + "/save_auto.json")
	_copy_file(old_dir + "/save_manual.json", new_dir + "/save_manual.json")
	_copy_file(old_dir + "/settings.cfg",     new_dir + "/settings.cfg")
	_copy_dir(old_dir + "/saves", new_dir + "/saves")
	_copy_dir(old_dir + "/maps",  new_dir + "/maps")
	print("Migrated saves and settings from the previous game name.")

## True if the dir contains any save / map / settings file. Used to gate the
## migration so it never overwrites in-progress v49 data.
func _user_dir_has_content(dir: String) -> bool:
	if FileAccess.file_exists(dir + "/save_auto.json"): return true
	if FileAccess.file_exists(dir + "/save_manual.json"): return true
	if FileAccess.file_exists(dir + "/settings.cfg"): return true
	if _dir_has_files(dir + "/saves"): return true
	if _dir_has_files(dir + "/maps"): return true
	return false

func _dir_has_files(dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(dir):
		return false
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir():
			d.list_dir_end()
			return true
		n = d.get_next()
	d.list_dir_end()
	return false

## Hard cap on files we'll migrate from the old user-data dir. Real saves
## top out around 100 KB; anything bigger is either corrupt or hostile and
## not worth the OOM risk on a low-memory device.
const _MIGRATION_MAX_FILE := 10 * 1024 * 1024  # 10 MiB

func _copy_file(src: String, dst: String) -> void:
	if not FileAccess.file_exists(src):
		return
	var directory := DirAccess.open(src.get_base_dir())
	if directory == null or directory.is_link(src.get_file()):
		return
	var sf := FileAccess.open(src, FileAccess.READ)
	if sf == null:
		return
	var n := sf.get_length()
	if n > _MIGRATION_MAX_FILE:
		sf.close()
		push_warning("Skipped an oversized legacy data file.")
		return
	var data := sf.get_buffer(n)
	sf.close()
	var df := FileAccess.open(dst, FileAccess.WRITE)
	if df == null:
		return
	df.store_buffer(data)
	df.close()

func _copy_dir(src: String, dst: String) -> void:
	if not DirAccess.dir_exists_absolute(src):
		return
	var parent := DirAccess.open(src.get_base_dir())
	if parent == null or parent.is_link(src.get_file()):
		return
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir():
			_copy_file(src + "/" + n, dst + "/" + n)
		n = d.get_next()
	d.list_dir_end()

## True when the snapshot can be loaded by this build. We refuse mismatched
## save versions cleanly (with a toast) instead of crashing on missing fields.
func is_save_compatible(data: Dictionary) -> bool:
	return SaveSchema.validate(data).is_empty()

func _process(_delta: float) -> void:
	_update_play_time()
	if Time.get_ticks_msec() >= _next_stats_flush:
		flush_statistics()

func _update_play_time() -> void:
	var now := Time.get_ticks_usec()
	if _last_stats_tick > 0:
		total_play_seconds += maxf(0.0, (now - _last_stats_tick) / 1000000.0)
	_last_stats_tick = now

func flush_statistics() -> void:
	_update_play_time()
	best_wave = maxi(best_wave, wave)
	best_score = maxi(best_score, score)
	last_played_unix = int(Time.get_unix_time_from_system())
	_next_stats_flush = Time.get_ticks_msec() + 30000
	save_settings()

func request_quit() -> void:
	flush_statistics()
	get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		request_quit()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		flush_statistics()

func reset() -> void:
	# Capture the just-finished run's high before wiping it.
	_check_best()
	# Hard mode (bonus_lives_per_wave off): tighter gold / lives / wall stock.
	var hard := not bonus_lives_per_wave
	gold = HARD_STARTING_GOLD if hard else STARTING_GOLD
	lives = HARD_STARTING_LIVES if hard else STARTING_LIVES
	wave = 0
	score = 0
	game_over = false
	run_board_size = board_size
	game_speed = 1.0
	effective_speed = 1.0
	simulation_limited = false
	stock = {
		"wall": HARD_STARTING_WALLS if hard else STARTING_WALLS,
		"tower": STARTING_TOWERS,
	}
	total_games = GameRules.safe_add(total_games, 1)
	last_played_unix = int(Time.get_unix_time_from_system())
	save_settings()

## Saves persistent options and best stats so they survive a relaunch.
func save_settings() -> void:
	var c := ConfigFile.new()
	c.set_value("options", "bonus_lives_per_wave", bonus_lives_per_wave)
	c.set_value("options", "unlimited_money", unlimited_money)
	c.set_value("options", "unlimited_lives", unlimited_lives)
	c.set_value("options", "free_walls", free_walls)
	c.set_value("options", "drag_draw_walls", drag_draw_walls)
	c.set_value("options", "round_timer_bonus", round_timer_bonus)
	c.set_value("options", "map_type", map_type)
	c.set_value("options", "board_size", board_size)
	c.set_value("options", "generated_seed", generated_seed)
	c.set_value("options", "fullscreen", fullscreen)
	c.set_value("stats", "best_wave", best_wave)
	c.set_value("stats", "best_score", best_score)
	c.set_value("stats", "total_kills", total_kills)
	c.set_value("stats", "total_games", total_games)
	c.set_value("stats", "total_play_seconds", total_play_seconds)
	c.set_value("stats", "best_tower_level", best_tower_level)
	c.set_value("stats", "first_played_unix", first_played_unix)
	c.set_value("stats", "last_played_unix", last_played_unix)
	if not _write_data_text(SETTINGS_PATH, c.encode_to_text()):
		push_warning("Settings could not be saved.")

func load_settings() -> void:
	var c := ConfigFile.new()
	var text := _read_data_text(SETTINGS_PATH)
	if text.is_empty() or c.parse(text) != OK:
		return
	for option in ["bonus_lives_per_wave", "unlimited_money", "unlimited_lives", "free_walls", "drag_draw_walls", "round_timer_bonus", "fullscreen"]:
		var value: Variant = c.get_value("options", option, get(option))
		if value is bool:
			set(option, value)
	var stored: Variant = c.get_value("options", "map_type", "none")
	if stored is String and (stored in ["none", "spiral", "generate"] or (stored.begins_with("custom:") and valid_data_name(stored.substr(7)))):
		map_type = stored
	else:
		map_type = "none"
	var size_value: Variant = c.get_value("options", "board_size", 0)
	board_size = int(size_value) if GameRules.integer(size_value, 0, 2) else 0
	var seed_value: Variant = c.get_value("options", "generated_seed", 0)
	generated_seed = int(seed_value) if GameRules.integer(seed_value, 0, 4294967295) else 0
	for field in ["best_wave", "best_score", "total_kills", "total_games", "best_tower_level", "first_played_unix", "last_played_unix"]:
		var value: Variant = c.get_value("stats", field, get(field))
		if GameRules.integer(value):
			set(field, int(value))
	var play_time: Variant = c.get_value("stats", "total_play_seconds", total_play_seconds)
	if GameRules.number(play_time, 0.0, GameRules.MAX_CURRENCY):
		total_play_seconds = float(play_time)

## Saves a wall grid (one string per row, "0"/"1" per cell) under MAPS_DIR.
func save_map(map_name: String, grid: Array, spawn := Vector2i(-1, -1), base := Vector2i(-1, -1)) -> bool:
	if not valid_data_name(map_name):
		return false
	if grid.is_empty() or not grid[0] is String:
		return false
	if spawn.x < 0:
		spawn = Vector2i(0, grid.size() / 2)
	if base.x < 0:
		base = Vector2i(grid[0].length() - 1, grid.size() / 2)
	var data := {"v": MAP_FORMAT_VERSION, "grid": grid, "spawn": [spawn.x, spawn.y], "base": [base.x, base.y]}
	if SaveSchema.map_data(data).is_empty():
		return false
	_ensure_maps_dir()
	return _write_data_text("%s/%s.txt" % [MAPS_DIR, map_name], JSON.stringify(data))

## Reads a saved map's wall grid as an Array of strings, one per row.
func load_map_grid(map_name: String) -> Array:
	return load_map_data(map_name).get("grid", [])

func load_map_data(map_name: String) -> Dictionary:
	if not valid_data_name(map_name):
		return {}
	var path := "%s/%s.txt" % [MAPS_DIR, map_name]
	var text := _read_data_text(path)
	if text.strip_edges().begins_with("{"):
		var parser := JSON.new()
		if parser.parse(text) != OK:
			return {}
		return SaveSchema.map_data(parser.data)
	var out: Array = []
	for raw_line in text.split("\n"):
		var line: String = raw_line.trim_suffix("\r")
		if line.length() > 0:
			out.append(line)
	if out.is_empty() or out[0].length() < 2:
		return {}
	var middle := out.size() / 2
	# Legacy plain grids used centered entrances; the old loader cleared walls
	# at those two cells. Preserve that behavior without rewriting the file.
	if out[middle].length() == out[0].length():
		out[middle] = "0" + out[middle].substr(1, out[middle].length() - 2) + "0"
	return SaveSchema.map_data({"v": MAP_FORMAT_VERSION, "grid": out, "spawn": [0, middle], "base": [out[0].length() - 1, middle]})

## Names (without `.txt`) of every saved map under MAPS_DIR, sorted.
func list_custom_maps() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not _safe_data_path(MAPS_DIR + "/check.txt"):
		return out
	if not DirAccess.dir_exists_absolute(MAPS_DIR):
		return out
	var d := DirAccess.open(MAPS_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and not d.is_link(n) and n.ends_with(".txt") and valid_data_name(n.trim_suffix(".txt")):
			out.append(n.substr(0, n.length() - 4))
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out

func _ensure_maps_dir() -> void:
	if not DirAccess.dir_exists_absolute(MAPS_DIR):
		DirAccess.make_dir_recursive_absolute(MAPS_DIR)

## --- Save / load a run (JSON snapshot in user://). Two slots: "auto" (written
## each wave clear) and "manual" (the in-game Save Game button). ---
func _save_path(slot: String) -> String:
	if slot not in ["auto", "manual"]:
		return ""
	return "user://save_%s.json" % slot

func has_save(slot: String) -> bool:
	var path := _save_path(slot)
	return _safe_data_path(path) and FileAccess.file_exists(path)

func write_save(slot: String, data: Dictionary) -> bool:
	var saved := _write_data_text(_save_path(slot), JSON.stringify(data))
	if saved:
		flush_statistics()
	return saved

func read_save(slot: String) -> Dictionary:
	if not has_save(slot):
		return {}
	return _read_data_json(_save_path(slot))

## --- Named saves on disk (the Save/Load popup). One JSON per name under
## user://saves/, separate from the "auto" slot at the user:// root. ---
const SAVES_DIR := "user://saves"

func _ensure_saves_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVES_DIR):
		DirAccess.make_dir_recursive_absolute(SAVES_DIR)

func _named_save_path(save_name: String) -> String:
	if not valid_data_name(save_name):
		return ""
	return "%s/%s.json" % [SAVES_DIR, save_name]

## Names (without .json) of saved games, newest first.
func list_saves() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not _safe_data_path(SAVES_DIR + "/check.json"):
		return out
	if not DirAccess.dir_exists_absolute(SAVES_DIR):
		return out
	var d := DirAccess.open(SAVES_DIR)
	if d == null:
		return out
	var named: Array = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and not d.is_link(n) and n.ends_with(".json") and valid_data_name(n.trim_suffix(".json")):
			var base := n.substr(0, n.length() - 5)
			named.append([base, FileAccess.get_modified_time(_named_save_path(base))])
		n = d.get_next()
	d.list_dir_end()
	named.sort_custom(func(a, b): return a[1] > b[1])
	for entry in named:
		out.append(entry[0])
	return out

func write_named_save(save_name: String, data: Dictionary) -> bool:
	if not valid_data_name(save_name):
		return false
	_ensure_saves_dir()
	var saved := _write_data_text(_named_save_path(save_name), JSON.stringify(data))
	if saved:
		flush_statistics()
	return saved

func read_named_save(save_name: String) -> Dictionary:
	return _read_data_json(_named_save_path(save_name))

func delete_named_save(save_name: String) -> bool:
	var path := _named_save_path(save_name)
	if _safe_data_path(path) and FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path) == OK
	return false

## Restore the run-level economy from a save snapshot (board/pieces are rebuilt
## by Level; wave counters by WaveManager). Called by main.gd on a load.
func apply_run_state(data: Dictionary) -> void:
	gold = int(data.get("gold", STARTING_GOLD))
	lives = int(data.get("lives", STARTING_LIVES))
	wave = int(data.get("wave", 0))
	score = int(data.get("score", 0))
	game_over = false
	var st: Dictionary = data.get("stock", {})
	stock = {"wall": int(st.get("wall", 0)), "tower": int(st.get("tower", 0))}
	run_board_size = int(data["board_size"])
	for option in data.get("run_options", {}):
		if option in ["bonus_lives_per_wave", "unlimited_money", "unlimited_lives", "free_walls", "round_timer_bonus"]:
			set(option, data["run_options"][option])

## Wipe the persistent best wave / best score back to zero.
func reset_best() -> void:
	best_wave = 0
	best_score = 0
	total_kills = 0
	total_games = 0
	total_play_seconds = 0.0
	best_tower_level = 0
	first_played_unix = int(Time.get_unix_time_from_system())
	last_played_unix = 0
	save_settings()

func _check_best() -> void:
	var changed := false
	if wave > best_wave:
		best_wave = wave
		changed = true
	if score > best_score:
		best_score = score
		changed = true
	if changed:
		save_settings()

func can_afford(cost: int) -> bool:
	return cost >= 0 and (unlimited_money or gold >= cost)

func spend(cost: int) -> bool:
	if cost < 0:
		return false
	if unlimited_money:
		return true
	if not can_afford(cost):
		return false
	gold -= cost
	Events.gold_changed.emit(gold)
	return true

func add_gold(amount: int) -> void:
	gold = GameRules.safe_add(gold, amount)
	Events.gold_changed.emit(gold)

func add_lives(amount: int) -> void:
	lives = GameRules.safe_add(lives, amount)
	Events.lives_changed.emit(lives)

func stock_of(key: String) -> int:
	return stock.get(key, 0)

func take_stock(key: String) -> bool:
	if stock.get(key, 0) > 0:
		stock[key] -= 1
		Events.stock_changed.emit()
		return true
	return false

func add_stock(key: String, amount: int) -> void:
	if stock.has(key):
		stock[key] = GameRules.safe_add(stock[key], amount)
		Events.stock_changed.emit()

func lose_life(amount: int) -> void:
	if game_over or unlimited_lives:
		return
	lives = maxi(0, lives - amount)
	Events.lives_changed.emit(lives)
	if lives <= 0:
		game_over = true
		_check_best()
		Events.game_over.emit()
