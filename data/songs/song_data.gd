class_name SongData
extends RefCounted
## The song the rhythm scene plays, assembled from layers at load time.
##
## This is the first concrete instance of the layer/slot model in
## docs/audio-design.md: a base drum pulse that is always there, plus optional
## layers that skills switch on. Every layer must line up on the same BPM and
## the same power-of-two bar count, so a layer authored at a different tempo is
## time-stretched (pitch preserved) into the song's grid rather than resampled.
##
## The chart is the pulse itself — four-on-the-floor, one note per beat.

const BPM := 125.0
const BARS := 8
const BEATS_PER_BAR := 4
const LANE_COUNT := 4
const TITLE := "Four On The Floor"

const KICK_PATH := "res://audio/sfx/SSTN_DrumOneshots_Kick3.wav"
const KICK_GAIN_DB := -1.0

## Skill-gated overlays. `source_bpm` is the tempo the file was authored at;
## anything other than BPM gets time-stretched on the way in.
const LAYERS := {
	&"bass": {
		"skill": &"layer_bass",
		"path": "res://audio/loops/SSTN_120_G#_BassLoops_FunkySlapBassLayered.wav",
		"source_bpm": 120.0,
		"gain_db": -4.0,
	},
}

const CACHE_DIR := "user://cache/audio"


static func beats_per_loop() -> int:
	return BARS * BEATS_PER_BAR


static func beat_seconds() -> float:
	return 60.0 / BPM


static func loop_seconds() -> float:
	return beats_per_loop() * beat_seconds()


## Build the song for the currently-owned skills.
## Returns { ok, stream, bpm, loop_length, loop_frames, notes, title, layers, log }.
## `notes` is one lap of the chart: [{ time, lane, step }].
static func build(levels: Dictionary) -> Dictionary:
	var log_lines: Array[String] = []
	var out := {
		"ok": false, "stream": null, "bpm": BPM, "title": TITLE,
		"loop_length": loop_seconds(), "loop_frames": 0,
		"notes": [], "layers": PackedStringArray(), "log": log_lines,
	}

	var kick := WavPCM.parse(KICK_PATH)
	if not kick.ok:
		log_lines.append("kick unavailable (%s): %s" % [KICK_PATH, kick.error])
		return out

	var sr := kick.sample_rate
	var beat_frames := int(round(beat_seconds() * sr))
	var loop_frames := beat_frames * beats_per_loop()
	log_lines.append("kick: %d Hz, %d ch, %.3f s" % [sr, kick.channels, kick.duration()])
	log_lines.append("song: %.1f BPM, %d bars, %d beats, loop %d frames (%.4f s)" % [
		BPM, BARS, beats_per_loop(), loop_frames, float(loop_frames) / float(sr)])

	# Base layer: the four-on-the-floor pulse, one kick per beat.
	var mix := AudioBake.silence(loop_frames, maxi(kick.channels, 2), sr)
	var kick_gain := AudioBake.db_to_linear(KICK_GAIN_DB)
	for b in beats_per_loop():
		AudioBake.overlay(mix, kick, b * beat_frames, kick_gain)

	# Skill-gated layers on top.
	var active := PackedStringArray()
	for name in LAYERS.keys():
		var layer: Dictionary = LAYERS[name]
		if int(levels.get(layer["skill"], 0)) <= 0:
			continue
		var buf := _load_layer(layer, loop_frames, beat_frames, sr, log_lines)
		if buf == null:
			continue
		AudioBake.overlay(mix, buf, 0, AudioBake.db_to_linear(float(layer["gain_db"])))
		active.append(String(name))

	var trim := AudioBake.limit(mix)
	if trim < 1.0:
		log_lines.append("mix limited by %.2f dB to stop it clipping" % (20.0 * log(trim) / log(10.0)))

	out["ok"] = true
	out["stream"] = mix.to_stream(true)
	out["loop_frames"] = loop_frames
	out["loop_length"] = float(loop_frames) / float(sr)
	out["layers"] = active
	out["notes"] = _build_chart()
	log_lines.append("layers active: %s" % ("none" if active.is_empty() else ", ".join(active)))
	return out


## Four-on-the-floor: a note on every beat, i.e. every 4th 16th-note step.
static func _build_chart() -> Array:
	var steps := PackedInt32Array()
	for b in beats_per_loop():
		steps.append(b * BeatGrid.STEPS_PER_BEAT)
	var lanes := BeatGrid.assign_lanes(steps, TITLE, LANE_COUNT)
	var notes: Array = []
	var beat := beat_seconds()
	for i in steps.size():
		notes.append({"time": i * beat, "lane": lanes[i], "step": steps[i]})
	return notes


## Decode a layer and fit it to the song grid, stretching if its tempo differs.
## The stretch is cached on disk — it costs a second or two, and the result only
## changes when the source file or the target tempo does.
static func _load_layer(layer: Dictionary, loop_frames: int, beat_frames: int,
		sr: int, log_lines: Array[String]) -> WavPCM:
	var path: String = layer["path"]
	var src_bpm := float(layer["source_bpm"])
	if not FileAccess.file_exists(path):
		log_lines.append("layer %s missing: %s" % [layer["skill"], path])
		return null

	if is_equal_approx(src_bpm, BPM):
		var direct := WavPCM.parse(path)
		if not direct.ok:
			log_lines.append("layer %s: %s" % [layer["skill"], direct.error])
			return null
		return direct

	var cache := "%s/%s_%.0fto%.0f_%d.wav" % [
		CACHE_DIR, path.get_file().get_basename(), src_bpm, BPM,
		FileAccess.get_modified_time(path)]
	if FileAccess.file_exists(cache):
		var hit := WavPCM.parse(cache)
		if hit.ok and hit.frames == loop_frames:
			log_lines.append("layer %s: stretched %.0f->%.0f BPM (cached)" % [
				layer["skill"], src_bpm, BPM])
			return hit

	var raw := WavPCM.parse(path)
	if not raw.ok:
		log_lines.append("layer %s: %s" % [layer["skill"], raw.error])
		return null

	# How many of the song's loops the source covers, at its own tempo.
	var src_loops := maxf(round(raw.duration() * src_bpm / 60.0 / float(beats_per_loop())), 1.0)
	var target := int(round(loop_frames * src_loops))
	var t0 := Time.get_ticks_msec()
	var stretched := AudioBake.time_stretch(raw, target, beat_frames)
	if not stretched.ok:
		log_lines.append("layer %s: stretch failed (%s)" % [layer["skill"], stretched.error])
		return null
	log_lines.append("layer %s: %.3f s @%.0f -> %.3f s @%.0f BPM (%d laps, %d ms)" % [
		layer["skill"], raw.duration(), src_bpm, stretched.duration(), BPM,
		int(src_loops), Time.get_ticks_msec() - t0])
	stretched.save_wav16(cache)
	return stretched
