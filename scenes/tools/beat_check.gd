extends Control
## BeatCheck — standalone verification scene for PDJE's "Beat This" detector.
##
## Pick a loop from res://audio/loops/, run Beat This over it (DetectPCM or
## DetectMusic), then play the loop back with a click sound on every detected
## beat. If the clicks sit on the groove, detection works.
##
## This is a verification tool, NOT part of the game. Spec: docs/tasks/beatthis-check.md.
##
## PDJE is a Windows-only GDExtension, so every PDJE class is reached through
## ClassDB (never as a global identifier) — the scene must stay parseable and
## runnable when the addon is missing.
##
## Headless: run with `--headless` (or pass `--auto` after `--`) and the scene
## detects with both APIs, prints beat count / estimated BPM / first 8 beats,
## then quits. That covers acceptance criterion 3 without audio output.
## Pass `--autoplay` instead to detect one loop, play it on the real audio
## device and log the drift of every click, then quit — the trigger timing can
## be checked from stdout rather than by ear.

const MODEL_PATH := "res://addons/Project_DJ_Godot/onnx_models/beat_this_model_final0.onnx"
const LOOP_DIR := "res://audio/loops"
const SFX_DIR := "res://audio/sfx"

# PDJE writes to these — never res://, which is read-only after export.
const PDJE_DB_PATH := "user://pdje/rootdb"
const PDJE_EDITOR_PATH := "user://pdje/editor"
const PDJE_COMPOSER := "beatcheck"
const FULL_MANUAL_RENDER_FALLBACK := 2

const CLICK_VOICES := 8
const API_PCM := 0
const API_MUSIC := 1

const METRO_IDLE := Color("#2b2848")
const METRO_BEAT := Color("#4ee1a0")
const METRO_DOWNBEAT := Color("#ff7ad9")

## Decoded WAV payload — we parse the file ourselves instead of going through
## AudioStreamWAV because Godot 4.4+ imports .wav as QOA by default
## (compress/mode=2), so `AudioStreamWAV.data` is not raw PCM.
class WavPCM:
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


var _loops: PackedStringArray = PackedStringArray()
var _click_stream: AudioStream = null

var _ai: Node = null            # PDJE_AI (Node facade)
var _detector: Object = null    # PDJE_BeatThisDetector
var _engine: Node = null        # PDJE_Wrapper, only for the DetectMusic route
var _player_activated: bool = false

var _wav: WavPCM = null
var _beats: PackedFloat64Array = PackedFloat64Array()
var _downbeats: PackedFloat64Array = PackedFloat64Array()
var _loop_length: float = 0.0

var _music: AudioStreamPlayer
var _clicks: Array[AudioStreamPlayer] = []
var _click_next: int = 0
var _playing: bool = false
var _beat_index: int = 0
var _last_pos: float = 0.0
var _lap: int = 0
var _flash: float = 0.0
var _flash_down: bool = false
var _click_log: bool = false     # --autoplay: print the drift of every click
var _autoplay_until: int = 0     # ms deadline for --autoplay, 0 = off

var _loop_select: OptionButton
var _api_select: OptionButton
var _detect_button: Button
var _play_button: Button
var _stop_button: Button
var _status_label: RichTextLabel
var _metronome: ColorRect
var _beat_label: Label


func _ready() -> void:
	_loops = _list_wavs(LOOP_DIR)
	_click_stream = _load_first_wav(SFX_DIR)
	_build_ui()
	_build_audio()
	set_process(false)

	if OS.get_cmdline_user_args().has("--autoplay"):
		_run_autoplay.call_deferred()
	elif _is_auto_mode():
		# Deferred so the UI exists before the (blocking) detection runs.
		_run_auto.call_deferred()


func _exit_tree() -> void:
	# The detector owns a native ONNX session; drop it before the Node facade.
	_detector = null


# ──────────────────────────────────────────────────────────────── UI ─────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#1c1a2e")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 40
	root.offset_top = 24
	root.offset_right = -40
	root.offset_bottom = -24
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "BEAT CHECK — PDJE / Beat This"
	title.add_theme_font_size_override("font_size", 30)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Detect beats in a loop, then play a click on every beat. Esc = back."
	root.add_child(subtitle)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)

	_loop_select = OptionButton.new()
	_loop_select.custom_minimum_size = Vector2(560, 36)
	for path in _loops:
		_loop_select.add_item(path.get_file())
	if _loops.is_empty():
		_loop_select.add_item("(no .wav in %s)" % LOOP_DIR)
		_loop_select.disabled = true
	row.add_child(_loop_select)

	_api_select = OptionButton.new()
	_api_select.custom_minimum_size = Vector2(180, 36)
	_api_select.add_item("DetectPCM")
	_api_select.add_item("DetectMusic")
	row.add_child(_api_select)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	root.add_child(buttons)

	_detect_button = Button.new()
	_detect_button.text = "Detect"
	_detect_button.custom_minimum_size = Vector2(160, 40)
	_detect_button.pressed.connect(_on_detect_pressed)
	buttons.add_child(_detect_button)

	_play_button = Button.new()
	_play_button.text = "▶  Play"
	_play_button.custom_minimum_size = Vector2(140, 40)
	_play_button.disabled = true
	_play_button.pressed.connect(_on_play_pressed)
	buttons.add_child(_play_button)

	_stop_button = Button.new()
	_stop_button.text = "■  Stop"
	_stop_button.custom_minimum_size = Vector2(140, 40)
	_stop_button.disabled = true
	_stop_button.pressed.connect(_on_stop_pressed)
	buttons.add_child(_stop_button)

	var back := Button.new()
	back.text = "← Menu"
	back.custom_minimum_size = Vector2(120, 40)
	back.pressed.connect(_go_back)
	buttons.add_child(back)

	var meter := HBoxContainer.new()
	meter.add_theme_constant_override("separation", 16)
	root.add_child(meter)

	_metronome = ColorRect.new()
	_metronome.custom_minimum_size = Vector2(110, 110)
	_metronome.color = METRO_IDLE
	meter.add_child(_metronome)

	_beat_label = Label.new()
	_beat_label.add_theme_font_size_override("font_size", 22)
	_beat_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_beat_label.text = "beat —"
	meter.add_child(_beat_label)

	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_font_size_override("normal_font_size", 16)
	root.add_child(_status_label)

	if not _pdje_available():
		_detect_button.disabled = true
		_status(_pdje_unavailable_reason())
	elif _click_stream == null:
		_status("[color=#ffcc66]No click .wav in %s — detection still works, playback is silent.[/color]" % SFX_DIR)
	else:
		_status("Ready. Pick a loop and press Detect.")


func _build_audio() -> void:
	_music = AudioStreamPlayer.new()
	add_child(_music)
	for i in CLICK_VOICES:
		# A pool, because consecutive beats retrigger faster than one voice can
		# finish — a single player would cut the previous click off.
		var p := AudioStreamPlayer.new()
		p.stream = _click_stream
		add_child(p)
		_clicks.append(p)


func _status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_go_back()


func _go_back() -> void:
	_on_stop_pressed()
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")


# ─────────────────────────────────────────────────────────── detection ───────

func _on_detect_pressed() -> void:
	_on_stop_pressed()
	if _loops.is_empty():
		return
	_detect_button.disabled = true
	_status("Detecting on %s … (blocks for a moment)" % _loops[_loop_select.selected].get_file())
	# Let the label paint before the synchronous ONNX run.
	await get_tree().process_frame
	_status(_detect(_loops[_loop_select.selected], _api_select.selected))
	_detect_button.disabled = false


## Runs the whole pipeline for one loop and returns a BBCode report. The same
## facts are printed plainly so a headless run can be verified from stdout.
func _detect(path: String, api: int) -> String:
	var lines: Array[String] = []
	var api_name := "DetectPCM" if api == API_PCM else "DetectMusic"
	print("\n=== BeatCheck: %s / %s ===" % [path.get_file(), api_name])

	_beats = PackedFloat64Array()
	_downbeats = PackedFloat64Array()
	_play_button.disabled = true

	# 1. Decode the WAV ourselves (needed for playback on both routes).
	_wav = _parse_wav(path)
	if not _wav.ok:
		var parse_msg := "WAV parse failed: %s" % _wav.error
		push_warning(parse_msg)
		print(parse_msg)
		return "[color=#ff6b6b]%s[/color]" % parse_msg
	_loop_length = _wav.duration()
	var wav_line := "WAV: %d Hz, %d ch, %d frames, %.3f s" % [
		_wav.sample_rate, _wav.channels, _wav.frames, _loop_length]
	print(wav_line)
	lines.append(wav_line)

	_music.stream = _build_stream(_wav)

	# 2. Model.
	if not _pdje_available():
		var reason := _pdje_unavailable_reason()
		print(reason)
		return "\n".join(lines) + "\n" + reason
	if _detector == null and not _create_detector():
		return "\n".join(lines) + "\n[color=#ff6b6b]Detector could not be created (model not loaded).[/color]"
	lines.append("[color=#4ee1a0]detector OK[/color] (%s)" % MODEL_PATH.get_file())

	# 3. Detect.
	var hint_bpm := _bpm_from_filename(path)
	var result: Object = null
	if api == API_PCM:
		result = _detect_pcm(_wav)
	else:
		var music := _detect_music(path, hint_bpm)
		result = music["result"]
		lines.append_array(music["notes"] as Array[String])

	if result == null:
		var null_msg := "%s returned null — see the PDJE diagnostics in the log above." % api_name
		push_warning(null_msg)
		print(null_msg)
		return "\n".join(lines) + "\n[color=#ff6b6b]%s[/color]" % null_msg

	_beats = result.beats
	_downbeats = result.downbeats
	_beat_index = 0
	_lap = 0
	_last_pos = 0.0

	if _beats.is_empty():
		var empty_msg := "%s returned a result but `beats` is EMPTY." % api_name
		print(empty_msg)
		return "\n".join(lines) + "\n[color=#ff6b6b]%s[/color]" % empty_msg

	var est := _estimate_bpm(_beats)
	var hint_text := "%.0f" % hint_bpm if hint_bpm > 0.0 else "none"
	print("beats=%d  downbeats=%d  estimated BPM=%.2f  (filename hint: %s)" % [
		_beats.size(), _downbeats.size(), est, hint_text])
	print("first 8 beats:     %s" % _format_times(_beats, 8))
	print("first 8 downbeats: %s" % _format_times(_downbeats, 8))

	lines.append("[color=#4ee1a0]%s OK[/color] — beats: [b]%d[/b], downbeats: [b]%d[/b]" % [
		api_name, _beats.size(), _downbeats.size()])
	lines.append("estimated BPM: [b]%.2f[/b]   (filename hint: %s)" % [est, hint_text])
	lines.append("first 8 beats: %s" % _format_times(_beats, 8))
	lines.append("first 8 downbeats: %s" % _format_times(_downbeats, 8))
	lines.append("Press Play — a click should land on every beat.")
	_play_button.disabled = _music.stream == null
	return "\n".join(lines)


func _create_detector() -> bool:
	if not FileAccess.file_exists(MODEL_PATH):
		var missing := "Beat This model missing: %s" % MODEL_PATH
		push_warning(missing)
		print(missing)
		return false
	if _ai == null:
		_ai = ClassDB.instantiate("PDJE_AI") as Node
		if _ai == null:
			print("PDJE_AI could not be instantiated.")
			return false
		add_child(_ai)
	_detector = _ai.CreateBeatThisDetector(MODEL_PATH)
	if _detector == null:
		push_warning("CreateBeatThisDetector returned null (model failed to load).")
		print("CreateBeatThisDetector returned null.")
		return false
	print("CreateBeatThisDetector OK")
	return true


func _detect_pcm(wav: WavPCM) -> Object:
	if wav.pcm.is_empty() or wav.channels <= 0 or wav.sample_rate <= 0:
		print("DetectPCM skipped: invalid PCM payload.")
		return null
	if wav.pcm.size() % wav.channels != 0:
		print("DetectPCM skipped: PCM is not frame-aligned.")
		return null
	return _detector.DetectPCM(wav.pcm, wav.channels, wav.sample_rate)


## DetectMusic needs the loop registered in PDJE's own DB first, and the minimal
## init sequence is undocumented — so try the cheapest one and escalate. The
## strategy that works is reported back (and printed) to settle the question.
func _detect_music(path: String, hint_bpm: float) -> Dictionary:
	var notes: Array[String] = []
	var bpm := hint_bpm if hint_bpm > 0.0 else 120.0
	if not ClassDB.class_exists("PDJE_Wrapper"):
		notes.append("[color=#ff6b6b]PDJE_Wrapper class missing.[/color]")
		return {"result": null, "notes": notes}

	if _engine == null:
		DirAccess.make_dir_recursive_absolute("user://pdje")
		_engine = ClassDB.instantiate("PDJE_Wrapper") as Node
		if _engine == null:
			notes.append("[color=#ff6b6b]PDJE_Wrapper could not be instantiated.[/color]")
			return {"result": null, "notes": notes}
		add_child(_engine)
		var init_ok: Variant = _engine.InitEngine(PDJE_DB_PATH)
		print("InitEngine(%s) -> %s" % [PDJE_DB_PATH, init_ok])
		notes.append("InitEngine(%s) -> %s" % [PDJE_DB_PATH, init_ok])

	var base := path.get_file().get_basename()

	# Strategy A: registration only, res:// path, no player.
	_register_music(base, path, bpm)
	var result: Object = _detector.DetectMusic(_engine, base, PDJE_COMPOSER, bpm)
	if _has_beats(result):
		print("DetectMusic strategy A (register only, res:// path) succeeded.")
		notes.append("[color=#4ee1a0]DetectMusic needs registration only — no InitPlayer.[/color]")
		return {"result": result, "notes": notes}
	print("DetectMusic strategy A (register only, res:// path) failed.")

	# Strategy B: same registration, but bring the player up first (the shipped
	# example does this before touching the music panel).
	if not _player_activated:
		var mode := ClassDB.class_get_integer_constant("PDJE_Wrapper", "FULL_MANUAL_RENDER")
		if mode == 0:
			mode = FULL_MANUAL_RENDER_FALLBACK
		print("InitPlayer(FULL_MANUAL_RENDER=%d, \"void\", 48) -> %s" % [
			mode, _engine.InitPlayer(mode, "void", 48)])
		var player: Object = _engine.GetPlayer()
		if player != null:
			print("player.Activate() -> %s" % player.Activate())
		_player_activated = true
		result = _detector.DetectMusic(_engine, base, PDJE_COMPOSER, bpm)
		if _has_beats(result):
			print("DetectMusic strategy B (after InitPlayer) succeeded.")
			notes.append("[color=#4ee1a0]DetectMusic needed InitPlayer + Activate first.[/color]")
			return {"result": result, "notes": notes}
		print("DetectMusic strategy B (after InitPlayer) failed.")

	# Strategy C: register with an absolute OS path (config_and_play.gd does this).
	var title_abs := base + "__abs"
	_register_music(title_abs, ProjectSettings.globalize_path(path), bpm)
	result = _detector.DetectMusic(_engine, title_abs, PDJE_COMPOSER, bpm)
	if _has_beats(result):
		print("DetectMusic strategy C (absolute OS path) succeeded.")
		notes.append("[color=#4ee1a0]DetectMusic needed an absolute OS path in ConfigNewMusic.[/color]")
		return {"result": result, "notes": notes}

	print("DetectMusic strategy C (absolute OS path) failed — all strategies exhausted.")
	notes.append("[color=#ff6b6b]DetectMusic failed for every init strategy (see log).[/color]")
	return {"result": result, "notes": notes}


func _register_music(title: String, audio_path: String, bpm: float) -> void:
	if not _engine.SearchMusic(title, PDJE_COMPOSER).is_empty():
		print("SearchMusic(%s) — already registered." % title)
		return
	print("InitEditor(%s) -> %s" % [
		PDJE_EDITOR_PATH, _engine.InitEditor(PDJE_COMPOSER, "none", PDJE_EDITOR_PATH)])
	var editor: Object = _engine.GetEditor()
	if editor == null:
		print("GetEditor() returned null — cannot register %s." % title)
		return
	print("ConfigNewMusic(%s, %s) -> %s" % [
		title, audio_path, editor.ConfigNewMusic(title, PDJE_COMPOSER, audio_path)])
	# One PDJE_EDITOR_ARG per row — the carrier is single-use.
	var arg: Object = ClassDB.instantiate("PDJE_EDITOR_ARG")
	if arg == null:
		print("PDJE_EDITOR_ARG could not be instantiated.")
		return
	arg.InitMusicArg(title, str(int(bpm)), 0, 0, 4)
	print("AddLine() -> %s" % editor.AddLine(arg))
	print("render() -> %s" % editor.render("beatcheck_track"))
	print("pushToRootDB() -> %s" % editor.pushToRootDB(title, PDJE_COMPOSER))


func _has_beats(result: Object) -> bool:
	if result == null:
		return false
	var beats: PackedFloat64Array = result.beats
	return not beats.is_empty()


# ──────────────────────────────────────────────────────── WAV decoding ───────

## Minimal RIFF/WAVE reader: PCM 8/16/24/32-bit and IEEE float 32/64-bit.
## Reading the file straight off disk sidesteps Godot's QOA import, and gives us
## the true sample rate / channel count from the header.
func _parse_wav(path: String) -> WavPCM:
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


## Rebuild a looping AudioStreamWAV from the very PCM we detected on, so
## playback and detection are guaranteed to be the same audio.
func _build_stream(wav: WavPCM) -> AudioStreamWAV:
	if not wav.ok:
		return null
	var out_channels := wav.channels if wav.channels <= 2 else 1
	var buf := PackedByteArray()
	buf.resize(wav.frames * out_channels * 2)
	if out_channels == wav.channels:
		for i in wav.pcm.size():
			buf.encode_s16(i * 2, int(clampf(wav.pcm[i], -1.0, 1.0) * 32767.0))
	else:
		for frame in wav.frames:
			var v := 0.0
			for c in wav.channels:
				v += wav.pcm[frame * wav.channels + c]
			buf.encode_s16(frame * 2, int(clampf(v / float(wav.channels), -1.0, 1.0) * 32767.0))

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = wav.sample_rate
	stream.stereo = out_channels == 2
	stream.data = buf
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = wav.frames
	return stream


# ────────────────────────────────────────────────────────────── playback ─────

func _on_play_pressed() -> void:
	if _music.stream == null or _loop_length <= 0.0:
		return
	_beat_index = 0
	_lap = 0
	_last_pos = 0.0
	_flash = 0.0
	_playing = true
	_play_button.disabled = true
	_stop_button.disabled = false
	_music.play()
	set_process(true)


func _on_stop_pressed() -> void:
	_playing = false
	set_process(false)
	if _music != null and _music.playing:
		_music.stop()
	for p in _clicks:
		if p.playing:
			p.stop()
	if _play_button != null:
		_play_button.disabled = _music == null or _music.stream == null
	if _stop_button != null:
		_stop_button.disabled = true
	if _metronome != null:
		_metronome.color = METRO_IDLE


func _process(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta * 6.0)
	_metronome.color = METRO_IDLE.lerp(
		METRO_DOWNBEAT if _flash_down else METRO_BEAT, _flash)
	if not _playing or _loop_length <= 0.0:
		return

	# Same latency-compensated clock as autoload/conductor.gd.
	var pos := _music.get_playback_position() \
		+ AudioServer.get_time_since_last_mix() \
		- Conductor.output_latency
	# get_playback_position() may or may not wrap on loop depending on the
	# backend, so normalise into the loop either way.
	pos = fposmod(maxf(pos, 0.0), _loop_length)

	if pos < _last_pos - _loop_length * 0.5:
		# Wrapped: replay the same beat grid for the next lap.
		_beat_index = 0
		_lap += 1
	_last_pos = pos

	while _beat_index < _beats.size() and pos >= _beats[_beat_index]:
		_fire_click(_beats[_beat_index], pos)
		_beat_index += 1
		_beat_label.text = "beat %d / %d   (lap %d)" % [_beat_index, _beats.size(), _lap + 1]

	if _autoplay_until > 0 and Time.get_ticks_msec() > _autoplay_until:
		print("\n########## BeatCheck autoplay done ##########")
		# Stop first: quitting mid-playback leaks the active stream playbacks.
		_on_stop_pressed()
		get_tree().quit(0)


func _fire_click(beat_time: float, pos: float) -> void:
	_flash = 1.0
	_flash_down = _is_downbeat(beat_time)
	if _click_log:
		# How late the trigger fired relative to the beat it belongs to.
		print("click #%-3d lap %d  beat=%.3f  pos=%.3f  drift=%+.1f ms%s" % [
			_beat_index + 1, _lap + 1, beat_time, pos,
			(pos - beat_time) * 1000.0, "  (downbeat)" if _flash_down else ""])
	if _click_stream == null:
		return
	var p := _clicks[_click_next]
	_click_next = (_click_next + 1) % _clicks.size()
	p.volume_db = 0.0 if _flash_down else -5.0
	p.play()


func _is_downbeat(t: float) -> bool:
	for d in _downbeats:
		if absf(d - t) < 0.005:
			return true
	return false


# ─────────────────────────────────────────────────────────────── headless ────

func _is_auto_mode() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	return OS.get_cmdline_user_args().has("--auto")


## --autoplay: detect one loop, then actually play it and log every click's
## drift for a couple of laps. Needs a real audio device (do not use --headless).
func _run_autoplay() -> void:
	print("\n########## BeatCheck autoplay ##########")
	if _loops.is_empty():
		get_tree().quit(1)
		return
	# Prefer a percussive loop — Beat This needs transients.
	var pick := _loops[0]
	for path in _loops:
		if path.get_file().to_lower().contains("drum"):
			pick = path
			break
	_loop_select.selected = _loops.find(pick)
	_detect(pick, API_PCM)
	if _beats.is_empty():
		print("autoplay: nothing detected, aborting.")
		get_tree().quit(1)
		return
	print("output_latency = %.1f ms" % (Conductor.output_latency * 1000.0))
	_click_log = true
	_on_play_pressed()
	# Two laps plus a little slack.
	_autoplay_until = Time.get_ticks_msec() + int(_loop_length * 2000.0) + 500


func _run_auto() -> void:
	print("\n########## BeatCheck auto run ##########")
	print("OS=%s  display=%s  PDJE_AI=%s" % [
		OS.get_name(), DisplayServer.get_name(), ClassDB.class_exists("PDJE_AI")])
	if _loops.is_empty():
		print("No loops in %s — nothing to check." % LOOP_DIR)
		get_tree().quit(1)
		return

	# DetectPCM over every loop (cheap, no DB), then DetectMusic once to prove
	# the registration route works too.
	var summary: Array[String] = []
	var ok_count := 0
	var runs := 0
	for path in _loops:
		runs += 1
		_detect(path, API_PCM)
		if not _beats.is_empty():
			ok_count += 1
		summary.append("  PCM   %-56s beats=%-4d bpm=%.2f (hint %.0f)" % [
			path.get_file(), _beats.size(), _estimate_bpm(_beats), _bpm_from_filename(path)])
		# Yield so PDJE's own logging flushes between runs.
		await get_tree().process_frame

	runs += 1
	_detect(_loops[0], API_MUSIC)
	if not _beats.is_empty():
		ok_count += 1
	summary.append("  MUSIC %-56s beats=%-4d bpm=%.2f (hint %.0f)" % [
		_loops[0].get_file(), _beats.size(), _estimate_bpm(_beats), _bpm_from_filename(_loops[0])])

	print("\n########## BeatCheck auto run done (%d/%d runs returned beats) ##########" % [ok_count, runs])
	for line in summary:
		print(line)
	get_tree().quit(0 if ok_count == runs else 1)


# ──────────────────────────────────────────────────────────────── helpers ────

func _pdje_available() -> bool:
	return ClassDB.class_exists("PDJE_AI")


func _pdje_unavailable_reason() -> String:
	if OS.get_name() != "Windows":
		return "[color=#ffcc66]PDJE is a Windows-only GDExtension — detection is disabled on %s.[/color]" % OS.get_name()
	return "[color=#ff6b6b]PDJE_AI not found. Is addons/Project_DJ_Godot installed and the editor restarted?[/color]"


func _list_wavs(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("BeatCheck: cannot open %s" % dir_path)
		return out
	for file in dir.get_files():
		# A running project sees both "x.wav" and "x.wav.import".
		var wav_name := file.trim_suffix(".import")
		var full := dir_path.path_join(wav_name)
		if wav_name.get_extension().to_lower() == "wav" and not out.has(full):
			out.append(full)
	out.sort()
	return out


func _load_first_wav(dir_path: String) -> AudioStream:
	var files := _list_wavs(dir_path)
	if files.is_empty():
		return null
	return load(files[0]) as AudioStream


## Sample-pack loops are named like "TSP_HLZ_174_drum_...". Pull the BPM out so
## DetectMusic gets a sane hint and the estimate has something to compare with.
func _bpm_from_filename(path: String) -> float:
	var re := RegEx.new()
	re.compile("(?:^|[_-])(\\d{2,3})(?:[_-])")
	var m := re.search(path.get_file())
	if m == null:
		return 0.0
	var bpm := float(m.get_string(1))
	if bpm < 40.0 or bpm > 250.0:
		return 0.0
	return bpm


func _estimate_bpm(beats: PackedFloat64Array) -> float:
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


func _format_times(times: PackedFloat64Array, count: int) -> String:
	if times.is_empty():
		return "(none)"
	var parts: Array[String] = []
	for i in mini(count, times.size()):
		parts.append("%.3f" % times[i])
	return "[%s]%s" % [", ".join(parts), " ..." if times.size() > count else ""]
