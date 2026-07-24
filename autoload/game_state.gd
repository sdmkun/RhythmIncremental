extends Node
## GameState — global save/economy/progression singleton (Autoload).
##
## Holds the "incremental" side of the game: soft currency (Beats), permanent
## upgrades bought in the skill tree, and the passive idle income loop.
## Rhythm play feeds this via add_beats(); the skill tree spends from it.

signal beats_changed(total: int)
signal upgrade_purchased(id: StringName)
signal upgrade_refunded(id: StringName)

const SAVE_PATH := "user://save.json"

# --- Economy -----------------------------------------------------------------
var beats: int = 0                     # soft currency earned from notes
var lifetime_beats: int = 0            # never spent — used for unlock gating

# --- Purchased upgrades -------------------------------------------------------
# id -> level. Definitions live in res://data/skills/skill_data.gd
var upgrade_levels: Dictionary = {}

# --- Derived multipliers (recomputed whenever an upgrade is bought) -----------
var score_multiplier: float = 1.0      # bonus Beats per note hit
var idle_beats_per_sec: float = 0.0    # passive income (the "incremental" hook)
var judge_window_bonus_ms: float = 0.0 # widens hit windows (accuracy upgrade)

var _idle_accumulator: float = 0.0


func _ready() -> void:
	load_game()
	set_process(true)


func _process(delta: float) -> void:
	# Passive idle income — the incremental loop keeps ticking even off the chart.
	if idle_beats_per_sec > 0.0:
		_idle_accumulator += idle_beats_per_sec * delta
		if _idle_accumulator >= 1.0:
			var gained := int(_idle_accumulator)
			_idle_accumulator -= gained
			add_beats(gained, false)


func add_beats(amount: int, count_lifetime: bool = true) -> void:
	if amount <= 0:
		return
	beats += amount
	if count_lifetime:
		lifetime_beats += amount
	beats_changed.emit(beats)


func spend_beats(amount: int) -> bool:
	if amount <= 0 or beats < amount:
		return false
	beats -= amount
	beats_changed.emit(beats)
	return true


func get_upgrade_level(id: StringName) -> int:
	return int(upgrade_levels.get(id, 0))


func buy_upgrade(id: StringName) -> bool:
	var def := SkillData.get_def(id)
	if def.is_empty():
		return false
	var level := get_upgrade_level(id)
	if level >= int(def["max_level"]):
		return false
	var cost := SkillData.cost_for_level(id, level)
	if not spend_beats(cost):
		return false
	upgrade_levels[id] = level + 1
	_recompute_multipliers()
	upgrade_purchased.emit(id)
	save_game()
	return true


## Give one level back and return what it cost. Debug affordance (right-click in
## the skill tree), not a designed respec — it refunds the full price.
## Refuses to drop a skill to 0 while an owned skill still requires it.
func refund_upgrade(id: StringName) -> bool:
	var level := get_upgrade_level(id)
	if level <= 0:
		return false
	if level == 1 and not SkillData.dependents_owned(id, upgrade_levels).is_empty():
		return false
	var refund := SkillData.cost_for_level(id, level - 1)
	if level > 1:
		upgrade_levels[id] = level - 1
	else:
		upgrade_levels.erase(id)
	beats += refund
	lifetime_beats = maxi(lifetime_beats - refund, 0)
	_recompute_multipliers()
	beats_changed.emit(beats)
	upgrade_refunded.emit(id)
	save_game()
	return true


## Layer names (SongData.LAYERS keys) switched on by the skills owned right now.
func active_audio_layers() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in upgrade_levels.keys():
		var def := SkillData.get_def(id)
		if def.is_empty() or int(upgrade_levels[id]) <= 0:
			continue
		if String(def["effect"]) == "audio_layer":
			out.append(def["layer"])
	return out


func _recompute_multipliers() -> void:
	score_multiplier = 1.0
	idle_beats_per_sec = 0.0
	judge_window_bonus_ms = 0.0
	for id in upgrade_levels.keys():
		var def := SkillData.get_def(id)
		if def.is_empty():
			continue
		var level: int = upgrade_levels[id]
		match String(def["effect"]):
			"score_mult":
				score_multiplier += float(def["per_level"]) * level
			"idle":
				idle_beats_per_sec += float(def["per_level"]) * level
			"window":
				judge_window_bonus_ms += float(def["per_level"]) * level


# --- Persistence -------------------------------------------------------------
func save_game() -> void:
	var data := {
		"beats": beats,
		"lifetime_beats": lifetime_beats,
		"upgrade_levels": upgrade_levels,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	beats = int(parsed.get("beats", 0))
	lifetime_beats = int(parsed.get("lifetime_beats", 0))
	var raw: Dictionary = parsed.get("upgrade_levels", {})
	upgrade_levels.clear()
	for k in raw.keys():
		upgrade_levels[StringName(k)] = int(raw[k])
	_recompute_multipliers()
