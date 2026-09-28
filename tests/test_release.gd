extends SceneTree

var state
var scene
var checks := 0
var failures := 0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)

func _initialize() -> void:
	call_deferred("run_checks")

func fresh() -> void:
	paused = false
	if is_instance_valid(scene):
		scene.free()
	state.pending_load = {}
	state.board_size = 0
	state.map_type = "none"
	state.unlimited_money = false
	state.unlimited_lives = false
	state.free_walls = false
	state.bonus_lives_per_wave = true
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	scene.simulation.set_process(false)
	scene.wave_manager.auto_advance = false
	scene.wave_manager.rng.seed = 12345
	state.stock = {"wall": 0, "tower": 0}
	state.gold = 100000

func enemy_at(at: Vector2i, hp: float = 1000.0):
	var enemy = load("res://scripts/enemy.gd").new()
	scene.level.enemies.add_child(enemy)
	enemy.setup(scene.level, hp, 60.0, 5, Color.WHITE, 11.0)
	enemy.cell = at
	enemy.position = scene.level.cell_center(at)
	enemy._path = scene.level.bfs_path(at, scene.level.base_cell)
	if not enemy._path.is_empty():
		enemy._path.remove_at(0)
	return enemy

func reject(snapshot: Dictionary, field: String, value: Variant) -> void:
	var changed := snapshot.duplicate(true)
	changed[field] = value
	check(not SaveSchema.validate(changed).is_empty(), "Invalid save field accepted: " + field)

func run_checks() -> void:
	state = root.get_node("GameState")
	fresh()
	var snapshot: Dictionary = scene.level.serialize_run()
	check(SaveSchema.validate(snapshot).is_empty(), "New run failed validation")
	check(SaveSchema.validate(JSON.parse_string(JSON.stringify(snapshot))).is_empty(), "JSON run failed validation")
	check(not SaveSchema.validate({"v": 2, "spawn": []}).is_empty(), "Incomplete save accepted")
	for field in ["v", "board_size", "spawn", "base", "gold", "lives", "wave", "score", "stock", "pieces", "wave_state", "enemies", "bullets"]:
		for invalid in [null, "invalid", true]:
			reject(snapshot, field, invalid)
	reject(snapshot, "spawn", [])
	reject(snapshot, "base", [99, 99])
	reject(snapshot, "gold", INF)
	reject(snapshot, "score", NAN)
	reject(snapshot, "wave", -1)
	reject(snapshot, "board_size", 0.5)
	reject(snapshot, "pieces", [{"t": "wall", "x": 2, "y": 2, "lvl": -1}])
	reject(snapshot, "pieces", [{"t": "unknown", "x": 2, "y": 2}])
	reject(snapshot, "pieces", [{"t": "wall", "x": 2, "y": 2}, {"t": "wall", "x": 2, "y": 2}])
	reject(snapshot, "wave_state", {"started": 1, "jobs": []})
	var original_scene = current_scene
	scene.hud._load_data({"v": 2, "spawn": []})
	check(current_scene == original_scene and state.pending_load.is_empty(), "Invalid load replaced the active scene")
	state.board_size = 2
	check(scene.level.serialize_run()["board_size"] == 0, "Next-board preference leaked into current save")
	state.apply_run_state(snapshot)
	check(state.run_board_size == 0 and state.board_size == 2, "Loading overwrote the next-board preference")
	# Settings accept only correctly typed, bounded values.
	var config := ConfigFile.new()
	config.set_value("options", "board_size", 99)
	config.set_value("options", "map_type", "custom:../outside")
	config.set_value("options", "unlimited_money", "true")
	config.set_value("stats", "best_score", -10)
	config.save("user://settings.cfg")
	state.best_score = 17
	state.load_settings()
	check(state.board_size == 0 and state.map_type == "none", "Bad settings were not defaulted")
	check(not state.unlimited_money and state.best_score == 17, "Invalid settings changed typed state")
	# Paid investment, including upgrades and undo, is independent of cheats.
	fresh()
	state.free_walls = true
	var balance: int = state.gold
	scene.level._try_place(Vector2i(2, 2), "wall")
	var wall = scene.level._pieces[Vector2i(2, 2)]
	check(wall.gold_invested == 0 and wall.sell_refund() == 0, "Free wall gained resale value")
	scene.level._remove_structure(wall)
	check(state.gold == balance, "Selling a free wall minted gold")
	state.free_walls = false
	scene.level._try_place(Vector2i(3, 2), "wall")
	scene.level._try_place(Vector2i(3, 2), "tower")
	var tower = scene.level._pieces[Vector2i(3, 2)]
	var investment: int = tower.gold_invested
	state.unlimited_money = true
	scene.level._select_structure(tower)
	scene.level.upgrade_selected()
	check(tower.level == 2 and tower.gold_invested == investment, "Free upgrade gained resale value")
	check(scene.level.undo() and tower.level == 1 and tower.gold_invested == investment, "Free upgrade undo changed paid investment")
	state.unlimited_money = false
	scene.level.upgrade_selected()
	check(tower.gold_invested > investment, "Paid upgrade did not retain investment")
	tower._cooldown = 0.25
	var enemy = enemy_at(Vector2i(2, 7))
	scene.level._rebuild_enemy_buckets()
	tower._fire(enemy)
	var shot = scene.level.bullets.get_child(0)
	shot.position += Vector2(2, 1)
	var saved: Dictionary = scene.level.serialize_run()
	check(SaveSchema.validate(saved).is_empty(), "Live run failed validation: " + SaveSchema.validate(saved))
	# Mutation fuzzing: every nested field must reject or validate cleanly,
	# without a cast, index error or exception escaping into the loader.
	for section in ["pieces", "enemies", "bullets"]:
		for field in saved[section][0]:
			for value in [null, true, false, "invalid", [], {}, -1, 0.5, INF]:
				var changed := saved.duplicate(true)
				changed[section][0][field] = value
				var result: Variant = SaveSchema.validate(changed)
				check(result is String, "Nested save validation crashed: " + section + "/" + field)
	var bad_enemy := saved.duplicate(true)
	bad_enemy["enemies"][0]["color"] = [1]
	check(not SaveSchema.validate(bad_enemy).is_empty(), "Short enemy color accepted")
	bad_enemy = saved.duplicate(true)
	bad_enemy["enemies"][0]["path"] = [[31, 14]]
	check(not SaveSchema.validate(bad_enemy).is_empty(), "Disconnected enemy route accepted")
	var bad_shot := saved.duplicate(true)
	bad_shot["bullets"][0]["target"] = 999
	check(not SaveSchema.validate(bad_shot).is_empty(), "Invalid projectile target accepted")
	state.pending_load = JSON.parse_string(JSON.stringify(saved))
	state.apply_run_state(state.pending_load)
	var restored = load("res://scripts/level.gd").new()
	root.add_child(restored)
	state.pending_load = {}
	var under = restored._under_walls[Vector2i(3, 2)]
	check(under.gold_invested == 10 and not under.from_stock, "Underlying wall ownership changed on load")
	check(is_equal_approx(restored._pieces[Vector2i(3, 2)]._cooldown, 0.25), "Tower cooldown was lost")
	check(restored.bullets.get_child_count() == 1 and restored.bullets.get_child(0).position == shot.position, "In-flight projectile was lost")
	check(restored.bullets.get_child(0).target == restored.enemies.get_child(0), "Projectile target was not restored")
	restored.free()
	var legacy := saved.duplicate(true)
	legacy.erase("bullets")
	legacy.erase("run_options")
	for piece in legacy["pieces"]:
		piece.erase("under_wall")
		piece.erase("cooldown")
		piece.erase("visual_cd")
	legacy["wave_state"].erase("queue_interval")
	legacy["wave_state"].erase("rng_state")
	check(SaveSchema.validate(legacy).is_empty(), "Legacy v2 save was rejected")
	# Queue cadence and random sequence survive round trips.
	var waves = scene.wave_manager
	waves.send_waves(100, 0.0)
	var wave_data: Dictionary = waves.serialize()
	var loaded_waves = load("res://scripts/wave_manager.gd").new()
	loaded_waves.restore(JSON.parse_string(JSON.stringify(wave_data)))
	check(loaded_waves._queue_interval == 0.0 and loaded_waves._queued_sends == 99, "Queue pacing changed on load")
	check(loaded_waves.rng.randi() == waves.rng.randi(), "Wave randomness changed on load")
	var invalid_rng: Dictionary = scene.level.serialize_run()
	invalid_rng["wave_state"]["rng_state"] = "99999999999999999999"
	check(not SaveSchema.validate(invalid_rng).is_empty(), "Out-of-range RNG state accepted")
	loaded_waves.free()
	# Auto resumes after an expired timer was temporarily unable to start.
	waves._queued_sends = 0
	waves._countdown = 0.0
	waves.auto_advance = true
	var started: int = waves.waves_started()
	waves._tick_countdown(0.01, false)
	check(waves.waves_started() == started + 1, "Expired auto timer never resumed")
	waves.auto_advance = false
	check(LicenseNotices.text().contains("Godot Engine") and LicenseNotices.text().contains("Permission is hereby granted"), "Engine notices were incomplete")
	scene.hud._show_licenses()
	check(scene.hud._has_modal(), "License overlay did not block shortcuts")
	scene.hud._close_modal()
	check(not scene.hud._map_display_name("custom:[b]name[/b]").contains("[b]"), "Map name injected rich-text markup")
	# Duration-limited effects integrate only their remaining active interval.
	enemy._dots.clear()
	enemy.health = 1000.0
	enemy.base_speed = 0.0
	enemy.apply_dot(10.0, 0.1, "poison")
	enemy.simulate_step(1.0)
	check(is_equal_approx(enemy.health, 999.0), "Expired DoT applied a whole frame of damage")
	enemy.health = 1000.0
	enemy.apply_dot(10.0, 1.0, "poison")
	enemy.apply_vuln(1.0, 0.1)
	enemy.simulate_step(1.0)
	check(is_equal_approx(enemy.health, 989.0), "Expired vulnerability multiplied the whole frame")
	# Real play time is independent of simulated delta and pause mode.
	state.total_play_seconds = 0.0
	var now := Time.get_ticks_usec()
	var elapsed_usec := mini(100000, now / 2)
	state._last_stats_tick = now - elapsed_usec
	state._process(1000.0)
	check(absf(state.total_play_seconds - elapsed_usec / 1000000.0) < 0.1, "Play time used simulated delta")
	paused = true
	check(state.can_process(), "Statistics stop while paused")
	state.score = 123456
	state.wave = 123
	state.total_kills = 99
	state.flush_statistics()
	var written := ConfigFile.new()
	written.load("user://settings.cfg")
	check(written.get_value("stats", "best_score") >= 123456 and written.get_value("stats", "total_kills") == 99, "Statistics checkpoint lost recent values")
	paused = false
	# Modals consume gameplay shortcuts and do not let Space unpause them.
	scene.hud._set_options_visible(true)
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_SPACE
	scene.hud._unhandled_key_input(key)
	check(paused, "Space unpaused behind options")
	var gold_before: int = state.gold
	key.keycode = KEY_E
	scene.hud._unhandled_key_input(key)
	check(state.gold == gold_before, "Upgrade shortcut changed the hidden board")
	scene.hud._show_save_popup()
	var name_input = scene.hud._save_popup_root.find_children("*", "LineEdit", true, false)[0]
	var letter := InputEventKey.new()
	letter.pressed = true
	letter.keycode = KEY_A
	letter.physical_keycode = KEY_A
	letter.unicode = 97
	root.push_input(letter)
	await process_frame
	check(name_input.text == "a", "Focused modal text input swallowed a character")
	scene.hud._close_save_popup()
	scene.hud._set_options_visible(false)
	check(not paused, "Closing options did not restore pause state")
	# A failed undo is all-or-nothing and stays available for later.
	fresh()
	scene.level._try_place(Vector2i(3, 7), "wall")
	scene.level._remove_structure(scene.level._pieces[Vector2i(3, 7)])
	var occupant = enemy_at(Vector2i(3, 7))
	var undo_count: int = scene.level._undo_stack.size()
	balance = state.gold
	check(not scene.level.undo(), "Undo restored a wall inside an enemy")
	check(state.gold == balance and scene.level._undo_stack.size() == undo_count, "Rejected undo changed economy/history")
	occupant._dead = true
	check(scene.level.undo(), "Safe retry of undo failed")
	# Save in the same frame as a path edit must contain recomputed routes.
	fresh()
	var rerouted = enemy_at(Vector2i(1, 7))
	scene.level._try_place(Vector2i(5, 7), "wall")
	var edited: Dictionary = scene.level.serialize_run()
	check(not rerouted._path.has(Vector2i(5, 7)), "Immediate save retained a blocked route")
	check(SaveSchema.validate(edited).is_empty(), "Immediate path-edit save was invalid")
	var score_before: int = state.score
	rerouted.take_damage(1000000.0)
	check(scene.hud._score_label.text.contains(state.abbrev(score_before + 5)), "HUD score lagged behind the last kill")
	# Custom maps preserve off-center endpoints; legacy plain maps remain valid.
	var grid := ["0000", "0110", "0000"]
	check(state.save_map("endpoints", grid, Vector2i(0, 0), Vector2i(3, 2)), "Versioned map save failed")
	var map_data: Dictionary = state.load_map_data("endpoints")
	check(map_data["spawn"] == [0.0, 0.0] and map_data["base"] == [3.0, 2.0], "Map endpoints did not round-trip")
	var old_map := FileAccess.open("user://maps/legacy.txt", FileAccess.WRITE)
	old_map.store_string("0000\n0110\n0000\n")
	old_map.close()
	check(not state.load_map_data("legacy").is_empty(), "Legacy map was rejected")
	check(SaveSchema.map_data({"v": 2, "grid": ["000", "0"], "spawn": [0, 0], "base": [2, 0]}).is_empty(), "Ragged map accepted")
	# Numerical limits remain finite at and beyond the supported range.
	for type in ["tower", "sniper", "missile", "cannon", "laser", "ice", "gold", "amplifier"]:
		var stats := PieceData.tower_stats(type, 9223372036854775807)
		check(is_finite(stats["damage"]) and is_finite(stats["fire_rate"]) and stats["fire_rate"] <= GameRules.MAX_FIRE_RATE, "Non-finite tower stats: " + type)
		check(PieceData.upgrade_cost(type, 9223372036854775807) >= 0, "Upgrade price overflow: " + type)
	check(not state.spend(-1), "Negative cost minted currency")
	state.gold = GameRules.MAX_CURRENCY - 1
	state.add_gold(10)
	check(state.gold == GameRules.MAX_CURRENCY, "Currency overflowed its exact JSON range")
	fresh()
	scene.level._try_place(Vector2i(3, 6), "tower")
	var bounded_tower = scene.level._pieces[Vector2i(3, 6)]
	var bounded_enemy = enemy_at(Vector2i(3, 7))
	scene.level.active_projectiles = GameRules.MAX_BULLETS
	bounded_tower._fire(bounded_enemy)
	check(scene.level.bullets.get_child_count() == 0, "Projectile population exceeded its bound")
	scene.level.active_projectiles = 0
	bounded_tower._fire(bounded_enemy)
	var bounded_shot = scene.level.bullets.get_child(0)
	check(scene.level.active_projectiles == 1, "Projectile capacity was not registered")
	bounded_shot._hit()
	check(scene.level.active_projectiles == 0, "Projectile capacity waited for a render frame to release")
	bounded_shot._retire()
	check(scene.level.active_projectiles == 0, "Projectile capacity was released twice")
	fresh()
	for column in range(1, 23):
		scene.level._try_place(Vector2i(column, 0), "gold")
		scene.level._pieces[Vector2i(column, 0)].level = GameRules.MAX_LEVEL
	var rich_enemy = enemy_at(Vector2i(3, 7), 1.0)
	rich_enemy.reward = GameRules.MAX_CURRENCY
	rich_enemy.take_damage(10.0)
	check(state.gold == GameRules.MAX_CURRENCY, "Boosted reward overflowed before currency saturation")
	await check_simulation()
	print("Release regressions: %d passed, %d failed" % [checks - failures, failures])
	if is_instance_valid(scene):
		scene.free()
	quit(1 if failures else 0)

func simulation_result(frames: int, real_delta: float, speed: float) -> Dictionary:
	fresh()
	state.unlimited_lives = true
	scene.level._try_place(Vector2i(3, 6), "tower")
	scene.level._try_place(Vector2i(5, 7), "spike_trap")
	scene.wave_manager.start_next_wave()
	state.game_speed = speed
	for frame in range(frames):
		scene.simulation.advance(real_delta, false)
	var data: Dictionary = scene.level.serialize_run()
	# Cosmetic visibility is deliberately different at reduced-graphics speeds.
	for shot in data["bullets"]:
		shot.erase("visible")
	return data

func check_simulation() -> void:
	var slow := simulation_result(120, 1.0 / 60.0, 1.0)
	var fast := simulation_result(30, 1.0 / 60.0, 4.0)
	check(slow == fast, "Combat changed when only the requested speed changed")
	var higher_fps := simulation_result(240, 1.0 / 120.0, 1.0)
	check(slow == higher_fps, "Combat changed when only render-frame frequency changed")
	fresh()
	state.game_speed = 1000.0
	var steps: int = scene.simulation.advance(1.0 / 60.0, false)
	check(steps <= GameRules.MAX_STEPS_PER_FRAME, "High-speed step budget was unbounded")
	check(scene.simulation.accumulator <= GameRules.STEP * GameRules.MAX_STEPS_PER_FRAME + 0.000001, "High-speed backlog grew without a bound")
	# Run the actual scene briefly through the normal headless main loop.
	scene.simulation.set_process(true)
	state.game_speed = 1.0
	scene.wave_manager.start_next_wave()
	for frame in range(4):
		await process_frame
	scene.simulation.set_process(false)
	check(scene.wave_manager.waves_started() == 1, "Normal scene smoke did not start its wave")
