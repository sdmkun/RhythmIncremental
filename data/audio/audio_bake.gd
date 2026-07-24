class_name AudioBake
extends RefCounted
## Offline PCM assembly: build a song by baking layers into one buffer.
##
## Everything here runs once, at load time, on WavPCM buffers — the result is a
## single AudioStreamWAV. Baking (rather than running one AudioStreamPlayer per
## layer) keeps the layers sample-locked: two players started in the same frame
## can still land a mix buffer apart, which on a bass-under-kick layer is
## audible as flam. The cost is that layers cannot be toggled mid-song; that is
## what PDJE's MusPanel is for later (see docs/audio-design.md).


static func silence(frames: int, channels: int, sample_rate: int) -> WavPCM:
	var out := WavPCM.new()
	out.channels = maxi(channels, 1)
	out.sample_rate = maxi(sample_rate, 1)
	out.frames = maxi(frames, 0)
	out.pcm.resize(out.frames * out.channels)
	out.ok = out.frames > 0
	return out


## Add `src` into `dst` starting at `at_frame`, wrapping past the end of dst.
## Channel counts may differ (mono spreads to every channel, extra source
## channels are downmixed). Wrapping matters: a one-shot landing on the last
## beat of a loop should bleed into the top of the next lap, not get clipped.
static func overlay(dst: WavPCM, src: WavPCM, at_frame: int, gain: float = 1.0) -> void:
	if not dst.ok or not src.ok or dst.frames <= 0:
		return
	for i in src.frames:
		var d := posmod(at_frame + i, dst.frames)
		for c in dst.channels:
			var v := 0.0
			if src.channels == dst.channels:
				v = src.pcm[i * src.channels + c]
			elif src.channels == 1:
				v = src.pcm[i]
			else:
				for sc in src.channels:
					v += src.pcm[i * src.channels + sc]
				v /= float(src.channels)
			dst.pcm[d * dst.channels + c] += v * gain


static func db_to_linear(db: float) -> float:
	return pow(10.0, db / 20.0)


## Peak-normalise in place, but only downward — a bake that never clips without
## quietly turning a well-levelled mix up.
static func limit(buf: WavPCM, ceiling: float = 0.97) -> float:
	var peak := 0.0
	for v in buf.pcm:
		peak = maxf(peak, absf(v))
	if peak <= ceiling or peak <= 0.0:
		return 1.0
	var g := ceiling / peak
	for i in buf.pcm.size():
		buf.pcm[i] *= g
	return g


## WSOLA time stretch: resize `src` to exactly `out_frames` without shifting
## pitch. Resampling would be far simpler but transposes — a 120→125 BPM change
## is +0.71 semitones, which puts a keyed bass loop badly out of tune.
##
## `hop_out` is the synthesis hop; pass one beat's worth of frames so the splice
## points land on beats, where a bass loop's transients hide the edit.
## Reads wrap around the source, so a seamless loop stays seamless.
static func time_stretch(src: WavPCM, out_frames: int, hop_out: int) -> WavPCM:
	var out := silence(out_frames, src.channels, src.sample_rate)
	if not src.ok or out_frames <= 0 or src.frames <= 0:
		out.ok = false
		out.error = "time_stretch: empty input"
		return out
	if out_frames == src.frames:
		out.pcm = src.pcm.duplicate()
		return out

	var ch := src.channels
	var sr := src.sample_rate
	hop_out = clampi(hop_out, sr / 20, out_frames)
	var hop_in := maxi(int(round(float(hop_out) * float(src.frames) / float(out_frames))), 1)
	var overlap := clampi(hop_out / 4, 64, sr / 40)          # <= 25 ms crossfade
	var radius := clampi(hop_in / 2, 0, sr / 20)             # +-50 ms search

	# The alignment search runs on a decimated mono copy: at 8x decimation it is
	# still far finer than the bass periods we need to lock onto, and it turns
	# the search from tens of millions of multiply-adds into a couple of million.
	const DEC := 8
	var mono := PackedFloat32Array()
	mono.resize(maxi(src.frames / DEC, 1))
	for i in mono.size():
		var s := 0.0
		for c in ch:
			s += src.pcm[(i * DEC) * ch + c]
		mono[i] = s
	var mono_n := mono.size()
	var corr_len := maxi(overlap / DEC, 8)

	# Built one crossfade longer than needed, so the tail can be folded back over
	# the head at the end and the loop closes seamlessly.
	var pad := silence(out_frames + overlap, ch, sr)

	var in_pos := 0
	var out_pos := 0
	var m := 0
	_copy_wrapped(src, pad, in_pos, out_pos, hop_out + overlap)
	out_pos += hop_out

	while out_pos < out_frames:
		m += 1
		# The ideal read position is absolute (m * hop_in), not accumulated from
		# the last splice. Letting it accumulate lets the alignment search walk
		# off — 32 splices at +-50 ms each could drift the bass more than a beat
		# away from the grid. Absolute keeps every splice within one search
		# radius of where the music actually belongs.
		var ideal := m * hop_in
		var template := in_pos + hop_out          # natural continuation of what we wrote
		var best_delta := 0
		var best_score := -INF
		var d := -radius
		while d <= radius:
			var score := 0.0
			var a := posmod((ideal + d) / DEC, mono_n)
			var b := posmod(template / DEC, mono_n)
			for k in corr_len:
				score += mono[posmod(a + k, mono_n)] * mono[posmod(b + k, mono_n)]
			if score > best_score:
				best_score = score
				best_delta = d
			d += DEC
		var next_in := ideal + best_delta

		# Crossfade the new segment over the tail the previous frame left here,
		# then copy through PAST the next splice point so that frame has a tail
		# of its own to fade against. WSOLA has aligned the two, so a linear fade
		# holds them in phase (equal-power would bump the level).
		for i in overlap:
			var t := float(i) / float(overlap)
			var o := (out_pos + i) * ch
			var s := posmod(next_in + i, src.frames) * ch
			for c in ch:
				pad.pcm[o + c] = pad.pcm[o + c] * (1.0 - t) + src.pcm[s + c] * t
		_copy_wrapped(src, pad, next_in + overlap, out_pos + overlap, hop_out)

		in_pos = next_in
		out_pos += hop_out

	# Fold the extra tail back over the head: after this, sample out_frames-1
	# flows into sample 0, so the loop can repeat without a click.
	for i in overlap:
		var t := float(i) / float(overlap)
		var h := i * ch
		var tail := (out_frames + i) * ch
		for c in ch:
			pad.pcm[h + c] = pad.pcm[h + c] * t + pad.pcm[tail + c] * (1.0 - t)

	for i in out_frames * ch:
		out.pcm[i] = pad.pcm[i]
	return out


static func _copy_wrapped(src: WavPCM, dst: WavPCM, from: int, to: int, count: int) -> void:
	var ch := dst.channels
	for i in count:
		var s := posmod(from + i, src.frames) * ch
		var d := (to + i) * ch
		if d + ch > dst.pcm.size():
			return
		for c in ch:
			dst.pcm[d + c] = src.pcm[s + c]
