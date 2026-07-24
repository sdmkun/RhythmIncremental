class_name AudioBake
extends RefCounted
## Offline PCM assembly: render one-shots onto a grid to make a loop.
##
## Used to turn a kick one-shot into a four-on-the-floor bar loop, which then
## gets handed to PDJE as an ordinary music layer. Tempo fitting is NOT done
## here — PDJE's MusPanel.ChangeBpm() time-stretches layers in realtime, so
## there is no reason to do it offline (see docs/audio-design.md).


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

