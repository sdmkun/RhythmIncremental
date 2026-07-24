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
	_say("InitPlayer(FULL_MANUAL_RENDER=%d, \"void\", 48) -> %s" % [
		mode, _engine.InitPlayer(mode, "void", 48)])
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
	# ChangeBpm returns false when called right after LoadMusic but true when
	# called seconds later, so something has to settle first. Bisect what:
	# is it "the music must be ON", or simply elapsed time?
	_say("ChangeBpm straight after LoadMusic (music still OFF) -> %s"
		% _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))
	_panel.SetMusic(bass_title, true)
	_say("ChangeBpm same frame as SetMusic(on) -> %s"
		% _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))
	await get_tree().process_frame
	_say("ChangeBpm one frame later -> %s"
		% _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))

	_steps = [
		{"at": 0.5, "what": "ChangeBpm @0.5s", "do": func(): _say("  -> %s" % _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))},
		{"at": 1.0, "what": "ChangeBpm @1.0s", "do": func(): _say("  -> %s" % _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))},
		{"at": 2.0, "what": "ChangeBpm @2.0s", "do": func(): _say("  -> %s" % _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))},
		{"at": 4.0, "what": "ChangeBpm @4.0s", "do": func(): _say("  -> %s" % _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))},
		{"at": 6.0, "what": "ChangeBpm @6.0s", "do": func(): _say("  -> %s" % _panel.ChangeBpm(bass_title, TARGET_BPM, BASS_BPM))},
		{"at": 8.0, "what": "kick ON too (two layers)", "do": func(): _say("  SetMusic(kick,true) -> %s" % _panel.SetMusic(kick_title, true))},
		{"at": 10.0, "what": "done", "do": func(): _finish(0)},
	]
	_t0 = Time.get_ticks_msec() / 1000.0
	_say("\n--- timeline (watch whether consumed frames advance) ---")
	set_process(true)


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
