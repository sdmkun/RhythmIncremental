class_name SongData
extends RefCounted
## The song the rhythm scene plays, defined as a set of layers.
##
## This is the first concrete instance of the layer/slot model in
## docs/audio-design.md: a base drum pulse that is always there, plus optional
## layers that skills switch on. Layers do NOT have to share the song's tempo —
## PDJE's MusPanel time-stretches each one to the song BPM in realtime
## (see PdjeSong), so a 120 BPM bass loop sits happily under a 125 BPM track.
##
## The chart is the pulse itself — four-on-the-floor, one note per beat.

const BPM := 125.0
const BARS := 8
const BEATS_PER_BAR := 4
const LANE_COUNT := 4
const TITLE := "Four On The Floor"

## The base layer is generated: a kick one-shot placed on every beat. The baked
## loop is written to user:// so PDJE can register it like any other music file.
const KICK_PATH := "res://audio/sfx/SSTN_DrumOneshots_Kick3.wav"
## Peak the baked pulse is normalised to. Deliberately not near full scale:
## PDJE mixes this with the other layers, and a loop that already peaks at 0.97
## leaves nothing for them to sum into.
const PULSE_PEAK := 0.7
## Bumped whenever the bake changes, so a stale cache is not reused.
const PULSE_BAKE_VERSION := 2
const PULSE_CACHE := "user://cache/audio/kick_pulse_%dbpm_%dbars_v%d.wav"

## Skill-gated overlays. `source_bpm` is the tempo the file was authored at;
## anything other than BPM gets ChangeBpm()'d on the way in.
const LAYERS := {
	&"bass": {
		"skill": &"layer_bass",
		"path": "res://audio/loops/SSTN_120_G#_BassLoops_FunkySlapBassLayered.wav",
		"source_bpm": 120.0,
	},
}


static func beats_per_loop() -> int:
	return BARS * BEATS_PER_BAR


static func beat_seconds() -> float:
	return 60.0 / BPM


static func loop_seconds() -> float:
	return beats_per_loop() * beat_seconds()


## Layer table for PdjeSong.start(): { name: { path, source_bpm, on } }.
## The kick is always on; everything else follows the player's skills.
static func layer_table(levels: Dictionary) -> Dictionary:
	var out := {}
	var pulse := kick_pulse_path()
	if not pulse.is_empty():
		out[&"kick"] = {"path": pulse, "source_bpm": BPM, "on": true}
	for name in LAYERS.keys():
		var layer: Dictionary = LAYERS[name]
		out[name] = {
			"path": layer["path"],
			"source_bpm": float(layer["source_bpm"]),
			"on": int(levels.get(layer["skill"], 0)) > 0,
		}
	return out


## Which layer a skill switches on, or &"" if it is not an audio skill.
static func layer_for_skill(id: StringName) -> StringName:
	for name in LAYERS.keys():
		if LAYERS[name]["skill"] == id:
			return name
	return &""


## Four-on-the-floor: a note on every beat, i.e. every 4th 16th-note step.
static func chart() -> Array:
	var steps := PackedInt32Array()
	for b in beats_per_loop():
		steps.append(b * BeatGrid.STEPS_PER_BEAT)
	var lanes := BeatGrid.assign_lanes(steps, TITLE, LANE_COUNT)
	var notes: Array = []
	var beat := beat_seconds()
	for i in steps.size():
		notes.append({"time": i * beat, "lane": lanes[i], "step": steps[i]})
	return notes


## Bake (once) the kick pulse loop and return its path, or "" if the kick
## sample is unreadable. Cached on disk — the content only depends on the
## sample, the tempo and the bar count.
static func kick_pulse_path() -> String:
	var out := PULSE_CACHE % [int(BPM), BARS, PULSE_BAKE_VERSION]
	if FileAccess.file_exists(out):
		return out
	var kick := WavPCM.parse(KICK_PATH)
	if not kick.ok:
		push_warning("SongData: kick unavailable (%s): %s" % [KICK_PATH, kick.error])
		return ""
	var sr := kick.sample_rate
	var beat_frames := int(round(beat_seconds() * sr))
	var pulse := AudioBake.silence(beat_frames * beats_per_loop(), maxi(kick.channels, 2), sr)
	for b in beats_per_loop():
		AudioBake.overlay(pulse, kick, b * beat_frames)
	AudioBake.limit(pulse, PULSE_PEAK)
	if not pulse.save_wav16(out):
		return ""
	return out
