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
	&"melodic": {
		"skill": &"layer_melodic",
		"path": "res://audio/loops/SSTN_125_D_MelodicLoops_Jazz_Piano_Stutters.wav",
		"source_bpm": 125.0,      # already on tempo — no ChangeBpm needed
	},
}

## The layer a hold note filters. Holds are gated behind the skill that adds
## this layer, so there is always something to filter.
const HOLD_FILTER_LAYER := &"melodic"
## Cutoff applied while a hold note is held down, in Hz. Low enough to be
## obviously muffled without making the layer vanish.
const HOLD_FILTER_HZ := 500.0


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


## Bars (0-based) whose last two beats fuse into one held note, once the player
## owns the hold skill. Spaced half a loop apart so each 8-bar lap has two.
const HOLD_BARS := [3, 7]
const HOLD_BEATS := 2

## Four-on-the-floor: a note on every beat, i.e. every 4th 16th-note step.
## With `holds` enabled, the last two beats of HOLD_BARS fuse into a single
## note carrying a `hold` duration — the tap on the second of those beats is
## absorbed rather than added, so the hand is never asked to do two things.
static func chart(holds: bool = false) -> Array:
	var steps := PackedInt32Array()
	for b in beats_per_loop():
		steps.append(b * BeatGrid.STEPS_PER_BEAT)
	# Lanes are assigned over the full beat grid regardless of holds, so turning
	# the skill on never reshuffles the taps the player already knows.
	var lanes := BeatGrid.assign_lanes(steps, TITLE, LANE_COUNT)

	var hold_start := {}
	var absorbed := {}
	if holds:
		for bar in HOLD_BARS:
			var beat_index: int = bar * BEATS_PER_BAR + (BEATS_PER_BAR - HOLD_BEATS)
			hold_start[beat_index] = true
			for k in range(1, HOLD_BEATS):
				absorbed[beat_index + k] = true

	var notes: Array = []
	var beat := beat_seconds()
	for i in steps.size():
		if absorbed.has(i):
			continue
		var note := {"time": i * beat, "lane": lanes[i], "step": steps[i], "hold": 0.0}
		if hold_start.has(i):
			note["hold"] = HOLD_BEATS * beat
		notes.append(note)
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
