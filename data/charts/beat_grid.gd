class_name BeatGrid
extends RefCounted
## Turns raw Beat This output into a musically usable grid.
##
## Beat This alone is not accurate enough to build a chart from (its timestamps
## are quantised to a 0.02 s hop, which is ±2% of a beat at 175 BPM — see
## docs/audio-design.md). Two pieces of outside knowledge fix that:
##
##   1. The BPM is written in the sample-pack file name ("..._175_...").
##      When the name holds several numbers, the detected BPM picks which one.
##   2. The loop is a power-of-two number of bars.
##
## Together those give an EXACT bar-aligned BPM: `bars * 240 / loop_length`.
## Detection is then only used for *where the notes are*, snapped to 16ths.

const MIN_BPM := 60.0
const MAX_BPM := 250.0
const BEATS_PER_BAR := 4
const STEPS_PER_BEAT := 4       # snap resolution: 16th notes
const MAX_BARS_EXP := 10        # up to 1024 bars
const BAR_FIT_TOLERANCE := 0.08 # relative error still accepted as "2^n bars"


## Every plausible BPM written into a file name, in order of appearance.
static func filename_bpm_candidates(file_name: String) -> Array[float]:
	var out: Array[float] = []
	var re := RegEx.new()
	re.compile("\\d+")
	for m in re.search_all(file_name.get_basename()):
		var v := float(m.get_string())
		if v >= MIN_BPM and v <= MAX_BPM and not out.has(v):
			out.append(v)
	return out


## Resolve the true BPM of a loop.
## Returns { bpm, nominal_bpm, bars, bars_raw, fits_power_of_two, candidates, note }.
static func resolve(file_name: String, loop_length: float, detected_bpm: float) -> Dictionary:
	var candidates := filename_bpm_candidates(file_name)
	var nominal := 0.0
	var note := ""

	if candidates.is_empty():
		nominal = detected_bpm
		note = "no BPM in the file name — falling back to the detected value"
	elif candidates.size() == 1:
		nominal = candidates[0]
		note = "file name"
	else:
		# Several numbers in the name: keep the one closest to what was
		# detected, tolerating half/double-time confusion in the detector.
		var best := INF
		for c in candidates:
			var d := _octave_distance(c, detected_bpm)
			if d < best:
				best = d
				nominal = c
		note = "file name (%s -> %.0f, closest to detected %.2f)" % [
			str(candidates), nominal, detected_bpm]

	if nominal <= 0.0:
		nominal = 120.0
		note = "nothing usable — defaulted to 120"

	var bars_raw := 0.0
	if loop_length > 0.0:
		bars_raw = loop_length * nominal / float(60 * BEATS_PER_BAR)
	var bars := nearest_power_of_two(bars_raw)
	var fits := bars > 0 and absf(bars_raw - float(bars)) / float(bars) <= BAR_FIT_TOLERANCE

	var bpm := nominal
	if fits and loop_length > 0.0:
		# The exact grid: a 2^n-bar loop pins the BPM far tighter than either
		# the rounded file name or the 0.02 s detection hop can.
		bpm = float(bars) * float(60 * BEATS_PER_BAR) / loop_length
	elif loop_length > 0.0:
		note += " / WARNING: %.2f bars is not a power of two — using the nominal BPM" % bars_raw

	return {
		"bpm": bpm,
		"nominal_bpm": nominal,
		"bars": bars,
		"bars_raw": bars_raw,
		"fits_power_of_two": fits,
		"candidates": candidates,
		"note": note,
	}


static func nearest_power_of_two(x: float) -> int:
	if x <= 0.0:
		return 0
	var e := clampi(int(round(log(x) / log(2.0))), 0, MAX_BARS_EXP)
	return 1 << e


## Distance between a candidate BPM and a detected one, forgiving the
## half-time / double-time errors beat trackers routinely make.
static func _octave_distance(candidate: float, detected: float) -> float:
	if detected <= 0.0:
		return 0.0
	var best := INF
	for k in [0.25, 0.5, 1.0, 2.0, 4.0]:
		best = minf(best, absf(candidate - detected * k) / candidate)
	return best


## Median inter-beat interval -> BPM. Robust against the odd dropped beat.
static func estimate_bpm(beats: PackedFloat64Array) -> float:
	if beats.size() < 2:
		return 0.0
	var diffs: Array[float] = []
	for i in range(1, beats.size()):
		diffs.append(float(beats[i] - beats[i - 1]))
	diffs.sort()
	var mid := diffs.size() / 2
	var median := diffs[mid] if diffs.size() % 2 == 1 else (diffs[mid - 1] + diffs[mid]) * 0.5
	if median <= 0.0:
		return 0.0
	return 60.0 / median


## Seconds per 16th note.
static func step_seconds(bpm: float) -> float:
	if bpm <= 0.0:
		return 0.0
	return 60.0 / bpm / float(STEPS_PER_BEAT)


## Snap detected beat times onto the 16th-note grid of a loop.
## Returns the step INDEX of each note (0 .. steps_per_loop-1), deduplicated and
## sorted. Indices survive a BPM change; convert with `step_seconds()`.
static func snap_to_steps(beats: PackedFloat64Array, bpm: float, loop_length: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var step := step_seconds(bpm)
	if step <= 0.0 or loop_length <= 0.0:
		return out
	var steps_per_loop := maxi(int(round(loop_length / step)), 1)
	var seen := {}
	for t in beats:
		# A beat sitting on the loop point belongs to step 0 of the next lap.
		var idx := posmod(int(round(float(t) / step)), steps_per_loop)
		if not seen.has(idx):
			seen[idx] = true
			out.append(idx)
	out.sort()
	return out


## Lay the snapped steps out across the lanes.
## Deterministic (seeded by the loop name) so a chart never changes between
## runs, and never repeats the lane the previous note used.
static func assign_lanes(steps: PackedInt32Array, seed_text: String, lane_count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var previous := -1
	for i in steps.size():
		var lane := rng.randi_range(0, lane_count - 1)
		if lane == previous:
			lane = (lane + 1 + rng.randi_range(0, lane_count - 2)) % lane_count
		out.append(lane)
		previous = lane
	return out
