class_name GameSimulation
extends Node
## All gameplay advances through the same bounded fixed timestep. When the
## requested speed exceeds the budget, simulated time slows for every system.

var level: Level
var waves: WaveManager
var accumulator := 0.0
var _sample_real := 0.0
var _sample_simulated := 0.0

func _process(delta: float) -> void:
	advance(delta)

func advance(real_delta: float, enforce_budget: bool = true) -> int:
	if GameState.game_over or level == null or waves == null:
		return 0
	var requested := clampf(real_delta, 0.0, 0.25) * GameState.game_speed
	accumulator = minf(accumulator + requested, GameRules.STEP * GameRules.MAX_STEPS_PER_FRAME * 2)
	var start := Time.get_ticks_usec()
	var steps := 0
	while accumulator + 0.000000001 >= GameRules.STEP and steps < GameRules.MAX_STEPS_PER_FRAME:
		if enforce_budget and steps > 0 and Time.get_ticks_usec() - start >= GameRules.FRAME_BUDGET_USEC:
			break
		step()
		accumulator = maxf(0.0, accumulator - GameRules.STEP)
		steps += 1
		if GameState.game_over:
			break
	_sample_real += real_delta
	_sample_simulated += steps * GameRules.STEP
	if _sample_real >= 0.5:
		GameState.effective_speed = _sample_simulated / _sample_real
		GameState.simulation_limited = GameState.effective_speed < GameState.game_speed * 0.9
		_sample_real = 0.0
		_sample_simulated = 0.0
	return steps

func step() -> void:
	if level._paths_dirty:
		level._paths_dirty = false
		level._recompute_paths_now()
		level._update_preview()
	for enemy in level.enemies.get_children():
		if not enemy.is_queued_for_deletion():
			enemy.simulate_step(GameRules.STEP)
		if GameState.game_over:
			return
	level._rebuild_enemy_buckets()
	for container in [level.traps, level.towers, level.bullets]:
		for piece in container.get_children():
			if not piece.is_queued_for_deletion():
				piece.simulate_step(GameRules.STEP)
	waves.simulate_step(GameRules.STEP)
