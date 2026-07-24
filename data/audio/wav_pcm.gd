class_name WavPCM
extends RefCounted
## Raw PCM decoded straight from a .wav file on disk.
##
## Godot 4.4+ imports .wav as QOA by default (`compress/mode=2` in the .import),
## so `AudioStreamWAV.data` is NOT raw PCM and cannot be fed to an analyser.
## Reading the RIFF ourselves sidesteps the importer entirely and gives us the
## true sample rate / channel count / frame count from the header.
##
## Caveat: this reads the *source* .wav, which is not shipped inside an exported
## .pck (only the imported .sample is). Dev-time / tooling use only.

var ok: bool = false
var error: String = ""
var pcm: PackedFloat32Array = PackedFloat32Array()  # interleaved, [-1, 1]
var channels: int = 0
var sample_rate: int = 0
var frames: int = 0


func duration() -> float:
	if sample_rate <= 0:
		return 0.0
	return float(frames) / float(sample_rate)


## Minimal RIFF/WAVE reader: PCM 8/16/24/32-bit and IEEE float 32/64-bit,
## including WAVE_FORMAT_EXTENSIBLE (0xFFFE). Never returns null — check `ok`.
static func parse(path: String) -> WavPCM:
	var out := WavPCM.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out.error = "cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())]
		return out

	var size := int(f.get_length())
	if size < 12 or f.get_buffer(4).get_string_from_ascii() != "RIFF":
		out.error = "not a RIFF file"
		return out
	f.get_32()  # RIFF chunk size — unreliable, ignored
	if f.get_buffer(4).get_string_from_ascii() != "WAVE":
		out.error = "not a WAVE file"
		return out

	var audio_format := 0
	var bits := 0
	var data_offset := -1
	var data_size := 0
	while f.get_position() + 8 <= size:
		var chunk_id := f.get_buffer(4).get_string_from_ascii()
		var chunk_size := int(f.get_32())
		var chunk_start := int(f.get_position())
		match chunk_id:
			"fmt ":
				audio_format = f.get_16()
				out.channels = f.get_16()
				out.sample_rate = int(f.get_32())
				f.get_32()  # byte rate
				f.get_16()  # block align
				bits = f.get_16()
				if audio_format == 0xFFFE and chunk_size >= 40:
					f.get_16()  # cbSize
					f.get_16()  # valid bits per sample
					f.get_32()  # channel mask
					audio_format = f.get_16()  # first 2 bytes of the sub-format GUID
			"data":
				data_offset = chunk_start
				data_size = mini(chunk_size, size - chunk_start)
		# Chunks are word-aligned; guard against a bogus size stalling the loop.
		var next := chunk_start + maxi(chunk_size, 0)
		next += next & 1
		f.seek(next)

	if data_offset < 0 or data_size <= 0:
		out.error = "no data chunk"
		return out
	if out.channels <= 0 or out.sample_rate <= 0 or bits <= 0:
		out.error = "no usable fmt chunk"
		return out
	if audio_format != 1 and audio_format != 3:
		out.error = "unsupported WAV codec (format=%d; only PCM and IEEE float)" % audio_format
		return out

	var frame_bytes := (bits / 8) * out.channels
	if frame_bytes <= 0:
		out.error = "bad frame size"
		return out
	out.frames = data_size / frame_bytes
	if out.frames <= 0:
		out.error = "empty data chunk"
		return out

	f.seek(data_offset)
	var raw := f.get_buffer(out.frames * frame_bytes)
	f.close()

	var total := out.frames * out.channels
	out.pcm.resize(total)
	match [audio_format, bits]:
		[1, 8]:
			for i in total:
				out.pcm[i] = (float(raw.decode_u8(i)) - 128.0) / 128.0
		[1, 16]:
			for i in total:
				out.pcm[i] = float(raw.decode_s16(i * 2)) / 32768.0
		[1, 24]:
			for i in total:
				var o := i * 3
				var v := raw.decode_u8(o) | (raw.decode_u8(o + 1) << 8) | (raw.decode_u8(o + 2) << 16)
				if v >= 0x800000:
					v -= 0x1000000
				out.pcm[i] = float(v) / 8388608.0
		[1, 32]:
			for i in total:
				out.pcm[i] = float(raw.decode_s32(i * 4)) / 2147483648.0
		[3, 32]:
			for i in total:
				out.pcm[i] = raw.decode_float(i * 4)
		[3, 64]:
			for i in total:
				out.pcm[i] = float(raw.decode_double(i * 8))
		_:
			out.error = "unsupported sample width (format=%d, %d-bit)" % [audio_format, bits]
			return out

	out.ok = true
	return out


## Write this buffer back out as a 16-bit PCM .wav that `parse()` can reload.
## Used to cache expensive bakes under user:// — see data/songs/song_data.gd.
func save_wav16(path: String) -> bool:
	if not ok:
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("WavPCM: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	var data_bytes := frames * channels * 2
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + data_bytes)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)                          # fmt chunk size
	f.store_16(1)                           # PCM
	f.store_16(channels)
	f.store_32(sample_rate)
	f.store_32(sample_rate * channels * 2)  # byte rate
	f.store_16(channels * 2)                # block align
	f.store_16(16)                          # bits per sample
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data_bytes)
	var buf := PackedByteArray()
	buf.resize(data_bytes)
	for i in mini(pcm.size(), frames * channels):
		buf.encode_s16(i * 2, int(clampf(pcm[i], -1.0, 1.0) * 32767.0))
	f.store_buffer(buf)
	f.close()
	return true


## Rebuild a looping AudioStreamWAV from this exact PCM, so what gets analysed
## and what gets played are guaranteed to be the same audio.
func to_stream(looping: bool = true) -> AudioStreamWAV:
	if not ok:
		return null
	var out_channels := channels if channels <= 2 else 1
	var buf := PackedByteArray()
	buf.resize(frames * out_channels * 2)
	if out_channels == channels:
		for i in pcm.size():
			buf.encode_s16(i * 2, int(clampf(pcm[i], -1.0, 1.0) * 32767.0))
	else:
		for frame in frames:
			var v := 0.0
			for c in channels:
				v += pcm[frame * channels + c]
			buf.encode_s16(frame * 2, int(clampf(v / float(channels), -1.0, 1.0) * 32767.0))

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = out_channels == 2
	stream.data = buf
	if looping:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = frames
	return stream
