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
#   "score_mult"  -> +per_level to Beats multiplier per note hit
#   "idle"        -> +per_level passive Beats/sec (the incremental engine)
#   "window"      -> +per_level ms added to every hit window (easier timing)
#   "audio_layer" -> switches on the SongData layer named by "layer" (pillar 1:
#                    the song itself grows as you spend Beats). No numeric
#                    effect, so it is skipped by GameState._recompute_multipliers.
#   "hold_notes"  -> puts long notes in the chart; holding one runs a lowpass
#                    over a layer (pillar 2: play drives realtime FX). Also
#                    purely a flag, with no numeric effect.
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
	&"layer_bass": {
		"name": "Slap Bass",
		"desc": "Layers a funky slap bass under the kick.",
		"effect": "audio_layer", "layer": &"bass", "per_level": 0.0, "max_level": 1,
		"base_cost": 200, "cost_growth": 1.0,
		"requires": [&"multiplier_1"],
	},
	&"layer_melodic": {
		"name": "Jazz Piano",
		"desc": "Adds a stuttering jazz piano on top.",
		"effect": "audio_layer", "layer": &"melodic", "per_level": 0.0, "max_level": 1,
		"base_cost": 500, "cost_growth": 1.0,
		"requires": [&"layer_bass"],
	},
	&"hold_notes": {
		"name": "Filter Sweep",
		"desc": "Adds long notes. Hold the key to muffle the piano with a lowpass filter.",
		"effect": "hold_notes", "per_level": 0.0, "max_level": 1,
		"base_cost": 800, "cost_growth": 1.0,
		"requires": [&"layer_melodic"],
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


## Owned skills that would be orphaned if `id` dropped to level 0.
## Used to stop a debug refund from stranding its own dependants.
static func dependents_owned(id: StringName, levels: Dictionary) -> Array[StringName]:
	var out: Array[StringName] = []
	for other in DEFS.keys():
		if other == id or int(levels.get(other, 0)) <= 0:
			continue
		if DEFS[other]["requires"].has(id):
			out.append(other)
	return out
