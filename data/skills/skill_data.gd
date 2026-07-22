extends RefCounted
class_name SkillData
## Static skill / upgrade definitions for the incremental progression tree.
##
## This stays the single source of truth for cost/effect/prerequisites.
## scenes/skill_tree/skill_tree.gd builds a live Yggdrasil node tree from these
## defs (Builder, no Registry/Loader — the tree is constructed in code every
## time the scene loads) purely for the visual graph; buying still goes
## through GameState.buy_upgrade() below.

# effect:
#   "score_mult" -> +per_level to Beats multiplier per note hit
#   "idle"       -> +per_level passive Beats/sec (the incremental engine)
#   "window"     -> +per_level ms added to every hit window (easier timing)
const DEFS := {
	&"multiplier_1": {
		"name": "Groove Amp I",
		"desc": "+0.25x Beats per note hit.",
		"effect": "score_mult", "per_level": 0.25, "max_level": 5,
		"base_cost": 50, "cost_growth": 1.8,
		"requires": [],
	},
	&"idle_1": {
		"name": "Auto-Sampler",
		"desc": "Passively generate +0.5 Beats/sec.",
		"effect": "idle", "per_level": 0.5, "max_level": 10,
		"base_cost": 100, "cost_growth": 1.6,
		"requires": [&"multiplier_1"],
	},
	&"window_1": {
		"name": "Steady Hands",
		"desc": "+8ms to every hit window.",
		"effect": "window", "per_level": 8.0, "max_level": 3,
		"base_cost": 150, "cost_growth": 2.2,
		"requires": [&"multiplier_1"],
	},
	&"multiplier_2": {
		"name": "Groove Amp II",
		"desc": "+0.5x Beats per note hit.",
		"effect": "score_mult", "per_level": 0.5, "max_level": 5,
		"base_cost": 600, "cost_growth": 2.0,
		"requires": [&"idle_1", &"window_1"],
	},
}


static func get_def(id: StringName) -> Dictionary:
	return DEFS.get(id, {})


static func ids() -> Array:
	return DEFS.keys()


static func cost_for_level(id: StringName, level: int) -> int:
	var def: Dictionary = DEFS.get(id, {})
	if def.is_empty():
		return 0
	return int(round(float(def["base_cost"]) * pow(float(def["cost_growth"]), level)))


## A node is unlockable once every prerequisite has at least one level.
static func is_unlocked(id: StringName, levels: Dictionary) -> bool:
	var def: Dictionary = DEFS.get(id, {})
	if def.is_empty():
		return false
	for req in def["requires"]:
		if int(levels.get(req, 0)) <= 0:
			return false
	return true
