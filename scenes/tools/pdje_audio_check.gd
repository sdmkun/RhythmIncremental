extends Control
## PdjeAudioCheck — spike: does PDJE's Core/Player/MusPanel half actually work
## here, and can it time-stretch a layer in realtime?
##
## Only PDJE_AI (Beat This) has been proven in this project so far. Before the
## rhythm scene is rebuilt on PDJE playback, this answers, by running:
##
##   1. Does InitPlayer(FULL_MANUAL_RENDER) + Activate() produce sound?
##   2. Does GetConsumedFrames() advance, and is it really /48000 seconds?
##   3. Does ChangeBpm(title, 125, 120) time-stretch without changing pitch?
##   4. Does SetMusic(title, on/off) toggle a layer in realtime?
##   5. Does music loop on its own, or does it need re-cueing?
##
## Verification tool, not part of the game. Windows only (PDJE is a Windows
## GDExtension); every PDJE class is reached via ClassDB so this stays loadable
## without the addon.
##
## Run: --path . res://scenes/tools/pdje_audio_check.tscn -- --auto

const DB_PATH := "user://pdje/rootdb"
const EDITOR_PATH := "user://pdje/editor"
const COMPOSER := "beatcheck"
const FULL_MANUAL_RENDER_FALLBACK := 2

const KICK_LOOP := "res://audio/loops/TSP_ENEIV2_175_kit_throwback_drum_E.wav"
const BASS_LOOP := "res://audio/loops/SSTN_120_G#_BassLoops_FunkySlapBassLayered.wav"
const BASS_BPM := 120.0
const TARGET_BPM := 125.0

var _engine: Node = null
var _player: Object = null
var _panel: Object = null
var _log: RichTextLabel

var _steps: Array[Dictionary] = []
var _step := 0
var _next_at := 0.0
var _t0 := 0.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#1c1a2e")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_log = RichTextLabel.new()
	_log.set_anchors_preset(Control.PRESET_FULL_RECT)
	_log.offset_left = 24
	_log.offset_top = 24
	_log.offset_right = -24
	_log.offset_bottom = -24
	_log.add_theme_font_size_override("normal_font_size", 15)
	add_child(_log)

	set_process(false)
	_run.call_deferred()


func _say(text: String) -> void:
	print(text)
	if _log != null:
		_log.text += text + "\n"


func _run() -> void:
	_say("########## PDJE audio spike ##########")
	_say("OS=%s  PDJE_Wrapper=%s" % [OS.get_name(), ClassDB.class_exists("PDJE_Wrapper")])
	if not ClassDB.class_exists("PDJE_Wrapper"):
		_say("PDJE not available — nothing to test.")
		_finish(1)
		return

	DirAccess.make_dir_recursive_absolute("user://pdje")
	_engine = ClassDB.instantiate("PDJE_Wrapper") as Node
	add_child(_engine)
	_say("InitEngine -> %s" % _engine.InitEngine(DB_PATH))

	_register(KICK_LOOP, 175.0)
	_register(BASS_LOOP, BASS_BPM)

	var mode := ClassDB.class_get_integer_constant("PDJE_Wrapper", "FULL_MANUAL_RENDER")
	if mode == 0:
		mode = FULL_MANUAL_RENDER_FALLBACK
	# `-- --buffer N`: the shipped examples pass 48 here and the judge docs pass
	# 480, with no explanation of the units. Sweep it to find out what it costs.
	var buffer := 48
	var args := OS.get_cmdline_user_args()
	var bi := args.find("--buffer")
	if bi >= 0 and bi + 1 < args.size():
		buffer = int(args[bi + 1])
	_say("InitPlayer(FULL_MANUAL_RENDER=%d, \"void\", %d) -> %s" % [
		mode, buffer, _engine.InitPlayer(mode, "void", buffer)])
	_player = _engine.GetPlayer()
	if _player == null:
		_say("[color=#ff6b6b]GetPlayer() returned null — manual render path unavailable.[/color]")
		_finish(1)
		return
	_say("player.Activate() -> %s" % _player.Activate())

	_panel = _player.GetMusicControlPanel()
	if _panel == null:
		_say("[color=#ff6b6b]GetMusicControlPanel() returned null.[/color]")
		_finish(1)
		return
	_say("panel OK. loaded list (before) = %s" % str(_panel.GetLoadedMusicList()))

	var kick_title := KICK_LOOP.get_file().get_basename()
	var bass_title := BASS_LOOP.get_file().get_basename()
	_say("LoadMusic(kick) -> %s" % _panel.LoadMusic(kick_title, COMPOSER, 175.0))
	_say("LoadMusic(bass) -> %s" % _panel.LoadMusic(bass_title, COMPOSER, BASS_BPM))
	_say("loaded list (after) = %s" % str(_panel.GetLoadedMusicList()))

	# The timed script below drives the actual questions.
	# --- FX probe: the docs and the shipped example disagree on how to reach the
	# FX enum (EnumWrapper.PDJE_FX_LIST.FILTER vs EnumWrapper.FILTER), and the
	# arg keys are case-sensitive with no authoritative list. Settle both here.
	_probe_fx(bass_title)

	_panel.SetMusic(kick_title, true)
	_panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM)
	_panel.SetMusic(bass_title, true)
	_t0 = Time.get_ticks_msec() / 1000.0

	# Sweep the cutoff down and back up: if a lowpass is really engaged the bass
	# should go muffled and then open up again.
	_steps = [
		{"at": 1.0, "what": "lowpass ON, cutoff 20000 (open)", "do": func(): _set_filter(bass_title, 20000.0)},
		{"at": 3.0, "what": "cutoff 800 (muffled)", "do": func(): _set_filter(bass_title, 800.0)},
		{"at": 6.0, "what": "cutoff 300 (very muffled)", "do": func(): _set_filter(bass_title, 300.0)},
		{"at": 9.0, "what": "cutoff 20000 (open again)", "do": func(): _set_filter(bass_title, 20000.0)},
		{"at": 12.0, "what": "filter OFF", "do": func(): _filter_off(bass_title)},
		{"at": 15.0, "what": "done", "do": func(): _finish(0)},
	]
	set_process(true)
	return
	_t0 = Time.get_ticks_msec() / 1000.0
	_say("\n--- timeline (watch whether consumed frames advance) ---")
	set_process(true)


var _fx: Object = null        # FXWrapper
var _fx_args: Object = null   # FXArgWrapper
var _fx_filter: int = -1      # resolved FILTER enum value


## Work out how to reach the FX enum and what the FILTER arg keys are called.
func _probe_fx(title: String) -> void:
	_say("\n--- FX probe on %s ---" % title)

	# The enum lives on a class we cannot name directly (ClassDB-only access),
	# so try both documented spellings.
	var flat := ClassDB.class_get_integer_constant("EnumWrapper", "FILTER")
	_say("  EnumWrapper.FILTER = %s" % flat)
	var listed := ClassDB.class_get_integer_constant("EnumWrapper", "PDJE_FX_LIST_FILTER")
	_say("  EnumWrapper.PDJE_FX_LIST_FILTER = %s" % listed)
	var names := ClassDB.class_get_integer_constant_list("EnumWrapper", true)
	_say("  EnumWrapper constants (first 24): %s" % str(names.slice(0, 24)))
	_fx_filter = flat

	_fx = _panel.getFXHandle(title)
	if _fx == null:
		_say("  getFXHandle() returned null")
		return
	_say("  getFXHandle OK")
	_fx.FX_ON_OFF(_fx_filter, true)
	_fx_args = _fx.GetArgSetter()
	if _fx_args == null:
		_say("  GetArgSetter() returned null")
		return
	_say("  FILTER arg keys = %s" % str(_fx_args.GetFXArgKeys(_fx_filter)))

	# Is there a native pitch shifter anywhere in the FX set? Dump every FX's
	# arg keys and look for anything pitch/key/semitone shaped — that would beat
	# doing it offline.
	_say("  -- all FX arg keys --")
	for cname in names:
		var v := ClassDB.class_get_integer_constant("EnumWrapper", cname)
		var keys: Variant = _fx_args.GetFXArgKeys(v)
		_say("    %-12s (%2d) %s" % [cname, v, str(keys)])


## HLswitch picks the filter type: the editor mix table lists HIGH(0)/LOW(2),
## so 2 is the lowpass we want for the hold mechanic.
func _set_filter(title: String, freq: float) -> void:
	if _fx_args == null:
		_say("  (no FX handle)")
		return
	_fx.FX_ON_OFF(_fx_filter, true)
	_fx_args.SetFXArg(_fx_filter, "HLswitch", 2)
	_fx_args.SetFXArg(_fx_filter, "Filterfreq", freq)
	_say("  SetFXArg(FILTER, Filterfreq, %.0f)" % freq)


func _filter_off(title: String) -> void:
	if _fx == null:
		return
	_fx.FX_ON_OFF(_fx_filter, false)
	_say("  FX_ON_OFF(FILTER, false)")


## Compare the file as WE read it against the beats PDJE's decoder produces.
## If PDJE is playing at the wrong rate, the beat spacing it reports will be
## off by exactly that ratio, and the true loop length with it.
func _probe_length(path: String, bpm: float) -> void:
	if path.is_empty():
		return
	_say("\n--- %s ---" % path.get_file())
	var wav := WavPCM.parse(path)
	if wav.ok:
		_say("  file: %d Hz, %d ch, %d frames = %.4f s" % [
			wav.sample_rate, wav.channels, wav.frames, wav.duration()])

	var ai := ClassDB.instantiate("PDJE_AI") as Node
	if ai == null:
		return
	add_child(ai)
	var detector: Object = ai.CreateBeatThisDetector(
		"res://addons/Project_DJ_Godot/onnx_models/beat_this_model_final0.onnx")
	if detector == null:
		_say("  (no detector)")
		return
	var title := path.get_file().get_basename()
	_register(path, bpm)
	var res: Object = detector.DetectMusic(_engine, title, COMPOSER, bpm)
	if res == null:
		_say("  DetectMusic returned null")
		return
	var beats: PackedFloat64Array = res.beats
	if beats.size() < 2:
		_say("  only %d beat(s) — inconclusive" % beats.size())
		return
	var spacing := float(beats[beats.size() - 1] - beats[0]) / float(beats.size() - 1)
	_say("  PDJE decode: %d beats, spacing %.4f s -> %.2f BPM, last beat %.4f s" % [
		beats.size(), spacing, 60.0 / spacing, beats[beats.size() - 1]])
	_say("  expected spacing %.4f s at %.0f BPM -> rate ratio %.4f" % [
		60.0 / bpm, bpm, (60.0 / bpm) / spacing])


func _register(path: String, bpm: float) -> void:
	var title := path.get_file().get_basename()
	if not _engine.SearchMusic(title, COMPOSER).is_empty():
		_say("SearchMusic(%s) — already registered." % title)
		return
	_engine.InitEditor(COMPOSER, "none", EDITOR_PATH)
	var editor: Object = _engine.GetEditor()
	if editor == null:
		_say("GetEditor() null — cannot register %s" % title)
		return
	editor.ConfigNewMusic(title, COMPOSER, path)
	var arg: Object = ClassDB.instantiate("PDJE_EDITOR_ARG")
	arg.InitMusicArg(title, str(int(bpm)), 0, 0, 4)
	editor.AddLine(arg)
	editor.render("spike_track")
	editor.pushToRootDB(title, COMPOSER)
	_say("registered %s @%.0f BPM" % [title, bpm])


var _last_report := -1.0

func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0 - _t0
	while _step < _steps.size() and t >= float(_steps[_step]["at"]):
		var s := _steps[_step]
		_say("[%5.1fs] %s" % [t, s["what"]])
		(s["do"] as Callable).call()
		_step += 1
	# GetConsumedFrames() is documented as /48000 seconds — check that against
	# the wall clock, since a stalled counter means playback never started.
	if t - _last_report >= 2.0:
		_last_report = t
		# NOTE: the wrapper returns this as a String, not an int.
		var raw: Variant = _player.GetConsumedFrames()
		var frames := float(str(raw))
		_say("        consumed=%s (%s)  =%.2f s @48k  wall=%.2f s  ratio=%.4f" % [
			str(raw), type_string(typeof(raw)), frames / 48000.0, t,
			(frames / 48000.0) / maxf(t, 0.001)])


func _finish(code: int) -> void:
	set_process(false)
	_say("########## spike done ##########")
	if _player != null:
		_player.Deactivate()
	if OS.get_cmdline_user_args().has("--auto"):
		get_tree().quit(code)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_finish(0)
		get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")
