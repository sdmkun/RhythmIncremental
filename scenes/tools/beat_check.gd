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
## It is also the chart authoring step: "Export chart" resolves the true BPM
## (BeatGrid), snaps the detected beats to 16th notes and writes a looping
## chart JSON into res://data/charts/ for scenes/rhythm/rhythm_game.gd.
##
## Headless: run with `--headless` (or pass `--auto` after `--`) and the scene
## detects with both APIs, prints beat count / estimated BPM / first 8 beats,
## then quits. That covers acceptance criterion 3 without audio output.
## Pass `--autoplay` instead to detect one loop, play it on the real audio
## device and log the drift of every click, then quit — the trigger timing can
## be checked from stdout rather than by ear.
## Pass `--export-chart` to detect every loop and write its chart JSON.

const MODEL_PATH := "res://addons/Project_DJ_Godot/onnx_models/beat_this_model_final0.onnx"
const LOOP_DIR := "res://audio/loops"
const SFX_DIR := "res://audio/sfx"
const CHART_DIR := "res://data/charts"
const LANE_COUNT := 4

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
var _grid: Dictionary = {}                       # BeatGrid.resolve() result
var _steps: PackedInt32Array = PackedInt32Array() # 16th-note indices of the chart
var _source_path: String = ""

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
var _export_button: Button
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

	_export_button = Button.new()
	_export_button.text = "Export chart"
	_export_button.custom_minimum_size = Vector2(170, 40)
	_export_button.disabled = true
	_export_button.pressed.connect(_on_export_pressed)
	buttons.add_child(_export_button)

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
	_steps = PackedInt32Array()
	_grid = {}
	_source_path = path
	_play_button.disabled = true
	_export_button.disabled = true

	# 1. Decode the WAV ourselves (needed for playback on both routes).
	_wav = WavPCM.parse(path)
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

	_music.stream = _wav.to_stream()

	# 2. Model.
	if not _pdje_available():
		var reason := _pdje_unavailable_reason()
		print(reason)
		return "\n".join(lines) + "\n" + reason
	if _detector == null and not _create_detector():
		return "\n".join(lines) + "\n[color=#ff6b6b]Detector could not be created (model not loaded).[/color]"
	lines.append("[color=#4ee1a0]detector OK[/color] (%s)" % MODEL_PATH.get_file())

	# 3. Detect.
	var candidates := BeatGrid.filename_bpm_candidates(path.get_file())
	var hint_bpm := candidates[0] if not candidates.is_empty() else 0.0
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

	var est := BeatGrid.estimate_bpm(_beats)
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

	# 4. Resolve the real BPM and snap the beats onto the 16th grid.
	_grid = BeatGrid.resolve(path.get_file(), _loop_length, est)
	_steps = BeatGrid.snap_to_steps(_beats, _grid["bpm"], _loop_length)
	var step := BeatGrid.step_seconds(_grid["bpm"])
	print("grid: BPM=%.3f (nominal %.0f, %s), bars=%d (raw %.3f), 1/16 = %.4f s, notes=%d" % [
		_grid["bpm"], _grid["nominal_bpm"], _grid["note"],
		_grid["bars"], _grid["bars_raw"], step, _steps.size()])
	print("snapped drift: max %.1f ms, mean %.1f ms" % _snap_drift(step))
	lines.append("[color=#4ee1a0]grid[/color] — BPM [b]%.3f[/b] (nominal %.0f) / [b]%d[/b] bars / 1-16th = %.4f s" % [
		_grid["bpm"], _grid["nominal_bpm"], _grid["bars"], step])
	lines.append("BPM source: %s" % _grid["note"])
	lines.append("chart: [b]%d[/b] notes snapped to 16ths (drift max %.1f ms, mean %.1f ms)" % [
		_steps.size(), _snap_drift(step)[0], _snap_drift(step)[1]])
	lines.append("Press Play — a click should land on every beat. Export chart writes the JSON.")
	_play_button.disabled = _music.stream == null
	_export_button.disabled = _steps.is_empty()
	return "\n".join(lines)


## How far each detected beat had to move to reach its 16th slot — a sanity
## check that the resolved BPM actually describes this loop.
func _snap_drift(step: float) -> Array:
	if step <= 0.0 or _beats.is_empty():
		return [0.0, 0.0]
	var worst := 0.0
	var total := 0.0
	for t in _beats:
		var d: float = absf(float(t) - round(float(t) / step) * step) * 1000.0
		worst = maxf(worst, d)
		total += d
	return [worst, total / float(_beats.size())]


func _on_export_pressed() -> void:
	_status(_export_chart())


## Write the snapped grid out as a looping chart JSON for the rhythm scene.
## Times stay in seconds (rhythm_game.gd's existing format) but the step index
## and the exact grid metadata ride along so the chart can be rebuilt.
func _export_chart() -> String:
	if _steps.is_empty() or _wav == null or not _wav.ok:
		return "[color=#ff6b6b]Nothing to export — run Detect first.[/color]"
	var step := BeatGrid.step_seconds(_grid["bpm"])
	var lanes := BeatGrid.assign_lanes(_steps, _source_path.get_file(), LANE_COUNT)
	var notes: Array = []
	for i in _steps.size():
		notes.append({
			"time": snappedf(_steps[i] * step, 0.000001),
			"lane": lanes[i],
			"step": _steps[i],
		})

	var chart := {
		"title": _source_path.get_file().get_basename(),
		"audio": _source_path,
		"bpm": snappedf(_grid["bpm"], 0.001),
		"nominal_bpm": _grid["nominal_bpm"],
		"bars": _grid["bars"],
		"loop": true,
		"loop_length": snappedf(_loop_length, 0.000001),
		"loop_frames": _wav.frames,
		"sample_rate": _wav.sample_rate,
		"steps_per_loop": _grid["bars"] * BeatGrid.BEATS_PER_BAR * BeatGrid.STEPS_PER_BEAT,
		"_comment": "Generated by scenes/tools/beat_check.tscn: PDJE Beat This detection snapped to 16th notes. BPM resolved from the file name + the power-of-two bar count, not from detection. Regenerate with --export-chart.",
		"notes": notes,
	}

	var out_path := "%s/%s.json" % [CHART_DIR, _source_path.get_file().get_basename()]
	DirAccess.make_dir_recursive_absolute(CHART_DIR)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		var msg := "Cannot write %s (%s)" % [out_path, error_string(FileAccess.get_open_error())]
		push_warning(msg)
		print(msg)
		return "[color=#ff6b6b]%s[/color]" % msg
	f.store_string(JSON.stringify(chart, "  "))
	f.close()
	var ok_msg := "Wrote %s — %d notes, %.3f BPM, %d bars, loop %.4f s" % [
		out_path, notes.size(), chart["bpm"], chart["bars"], _loop_length]
	print(ok_msg)
	return "[color=#4ee1a0]%s[/color]" % ok_msg


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
	var args := OS.get_cmdline_user_args()
	return args.has("--auto") or args.has("--export-chart")


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
	var export_charts := OS.get_cmdline_user_args().has("--export-chart")
	var summary: Array[String] = []
	var ok_count := 0
	var runs := 0
	for path in _loops:
		runs += 1
		_detect(path, API_PCM)
		if not _beats.is_empty():
			ok_count += 1
		summary.append("  PCM   %-56s beats=%-3d -> %-3d notes  detected=%-7.2f grid=%.3f (%d bars)" % [
			path.get_file(), _beats.size(), _steps.size(), BeatGrid.estimate_bpm(_beats),
			_grid.get("bpm", 0.0), _grid.get("bars", 0)])
		if export_charts and not _steps.is_empty():
			print(_export_chart())
		# Yield so PDJE's own logging flushes between runs.
		await get_tree().process_frame

	runs += 1
	_detect(_loops[0], API_MUSIC)
	if not _beats.is_empty():
		ok_count += 1
	summary.append("  MUSIC %-56s beats=%-3d -> %-3d notes  detected=%-7.2f grid=%.3f (%d bars)" % [
		_loops[0].get_file(), _beats.size(), _steps.size(), BeatGrid.estimate_bpm(_beats),
		_grid.get("bpm", 0.0), _grid.get("bars", 0)])

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


func _format_times(times: PackedFloat64Array, count: int) -> String:
	if times.is_empty():
		return "(none)"
	var parts: Array[String] = []
	for i in mini(count, times.size()):
		parts.append("%.3f" % times[i])
	return "[%s]%s" % [", ".join(parts), " ..." if times.size() > count else ""]
