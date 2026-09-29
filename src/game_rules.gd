class_name GameRules
extends RefCounted

const VERSION := "v59"
const BOARD_SIZES: Array[Vector2i] = [Vector2i(32, 15), Vector2i(46, 22), Vector2i(64, 30)]
const MAX_LEVEL := 10000
const MAX_FIRE_RATE := 600.0
const MAX_WAVE := 1000000
const MAX_CURRENCY := 9000000000000000
const MAX_ENEMIES := 2048
const MAX_SAVED_ENEMIES := 8192
const MAX_JOBS := 2048
const MAX_BULLETS := 16384
const STEP := 1.0 / 120.0
const MAX_STEPS_PER_FRAME := 120
const FRAME_BUDGET_USEC := 8000

static func number(value: Variant, low: float = 0.0, high: float = 1.0e30) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= low and value <= high

static func integer(value: Variant, low: int = 0, high: int = MAX_CURRENCY) -> bool:
	return number(value, low, high) and float(value) == floor(float(value))

static func safe_add(a: int, b: int) -> int:
	return a + clampi(b, -a, MAX_CURRENCY - a)
