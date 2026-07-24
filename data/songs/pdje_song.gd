class_name PdjeSong
extends Node
## Plays the song through PDJE's MusPanel: one music per layer, toggled and
## tempo-matched in realtime.
##
## This is the first use of PDJE's *audio* half in the game proper (docs/
## decisions.md D-4). What it buys over mixing the layers ourselves:
##
##   - `ChangeBpm(title, target, origin)` time-stretches a layer to the song's
##     tempo without transposing it, so a 120 BPM bass loop can sit under a
##     125 BPM track. No offline stretch, no resampling-induced detune.
##   - `SetMusic(title, on/off)` switches a layer mid-song, which is what the
##     genre-shift pillar ultimately needs.
##
## Verified working by scenes/tools/pdje_audio_check.tscn: InitPlayer /
## Activate / LoadMusic / SetMusic / ChangeBpm / CueMusic all return true, and
## GetConsumedFrames() tracks wall-clock at a ratio of 1.000 with a constant
## ~0.11 s startup offset.
##
## Windows only (PDJE is a Windows GDExtension); every PDJE class is reached
## through ClassDB so this file stays loadable without the addon.

const DB_PATH := "user://pdje/rootdb"
const EDITOR_PATH := "user://pdje/editor"
const COMPOSER := "rhythmincremental"
## PDJE's root DB is keyed by title, and the dev tools under scenes/tools/
## register the same .wav files under their own composer. Without a namespace
## the two collide and LoadMusic() answers -2 for the loser.
const TITLE_PREFIX := "ri_"
const FULL_MANUAL_RENDER_FALLBACK := 2
const FRAME_RATE := 48000.0     # GetConsumedFrames() is documented as /48000

## GetConsumedFrames() counts frames the engine has *generated*, which is a
## fixed prebuffer ahead of what has reached the speakers. Measured in
## scenes/tools/pdje_audio_check.tscn: the counter sits exactly 5328 frames
## (0.111 s) above wall-clock, constant across 23 s and across runs. That is
## 23% of a beat at 125 BPM, so uncorrected it makes every note read as landing
## before its kick.
##
## Not auto-measured: the counter does not advance linearly between Activate()
## and the first frame, because registration and ChangeBpm() block. It is a
## property of the frame buffer size handed to InitPlayer(), so it only needs
## revisiting if that changes. Tune by ear if notes feel early (raise) or late
## (lower).
const ENGINE_PREBUFFER_FRAMES := 5328.0

## MusPanel does NOT loop: a music plays once and then stays silent. So we have
## to rewind each layer ourselves at the loop point.
##
## The cue has to be timed against the RAW counter, not the latency-compensated
## position. A cue affects audio the engine is generating *now*, and generation
## runs ENGINE_PREBUFFER_FRAMES ahead of the speakers. Issue it when the raw
## counter completes the loop and generation continues seamlessly into the next
## lap; issue it when the *audible* position completes the loop and it is a
## whole prebuffer late, leaving a gap.
const MANUAL_LOOP := true

var ready_to_play: bool = false
var log_lines: Array[String] = []
## Print every loop cue — used by rhythm_game's --selftest.
var _log_cues: bool = OS.get_cmdline_user_args().has("--selftest")

var _engine: Node = null
var _player: Object = null
var _panel: Object = null
var _titles: Dictionary = {}     # layer name (StringName) -> PDJE music title
var _on: Dictionary = {}         # layer name -> bool
var _frames_at_start := 0.0
var _clock_latched := false
var _loop_length := 0.0
var _laps_cued := 0


static func available() -> bool:
	return ClassDB.class_exists("PDJE_Wrapper")


## Register + load every layer and start the engine. `layers` is
## { name: { path, source_bpm, on } }. Returns false if PDJE is unusable.
func start(layers: Dictionary, song_bpm: float, loop_length: float) -> bool:
	_loop_length = loop_length
	if not available():
		_note("PDJE_Wrapper not available (%s)" % OS.get_name())
		return false

	DirAccess.make_dir_recursive_absolute("user://pdje")
	_engine = ClassDB.instantiate("PDJE_Wrapper") as Node
	if _engine == null:
		_note("PDJE_Wrapper could not be instantiated")
		return false
	add_child(_engine)
	if not _engine.InitEngine(DB_PATH):
		_note("InitEngine(%s) failed" % DB_PATH)
		return false

	for name in layers.keys():
		var layer: Dictionary = layers[name]
		var title: String = TITLE_PREFIX + String(layer["path"]).get_file().get_basename()
		if not _register(title, layer["path"], float(layer["source_bpm"])):
			continue
		_titles[name] = title

	if _titles.is_empty():
		_note("no layer could be registered")
		return false

	var mode := ClassDB.class_get_integer_constant("PDJE_Wrapper", "FULL_MANUAL_RENDER")
	if mode == 0:
		mode = FULL_MANUAL_RENDER_FALLBACK
	if not _engine.InitPlayer(mode, "void", 48):
		_note("InitPlayer failed")
		return false
	_player = _engine.GetPlayer()
	if _player == null or not _player.Activate():
		_note("player could not be activated")
		return false
	_panel = _player.GetMusicControlPanel()
	if _panel == null:
		_note("GetMusicControlPanel() returned null (manual panels unavailable)")
		return false

	for name in _titles.keys():
		var loaded: Variant = _panel.LoadMusic(_titles[name], COMPOSER, float(layers[name]["source_bpm"]))
		_note("LoadMusic(%s, %s) -> %s" % [_titles[name], COMPOSER, loaded])
	_note("loaded list = %s" % str(_panel.GetLoadedMusicList()))

	# ChangeBpm only takes on music that is switched ON — called on an inactive
	# title it just returns false. So every layer goes on, gets stretched, and
	# only then is switched back off if the player has not unlocked it. This all
	# happens in one frame, well inside the engine's ~0.11 s output latency, so
	# nothing leaks out of the speakers.
	for name in _titles.keys():
		_panel.SetMusic(_titles[name], true)
	for name in _titles.keys():
		var src_bpm := float(layers[name]["source_bpm"])
		if is_equal_approx(src_bpm, song_bpm):
			continue
		# The whole point: fit the layer to the song without transposing it.
		var ok: bool = _panel.ChangeBpm(_titles[name], song_bpm, src_bpm)
		_note("%s: ChangeBpm %.0f -> %.0f BPM = %s" % [name, src_bpm, song_bpm, ok])

	for name in _titles.keys():
		set_layer(name, bool(layers[name]["on"]))

	ready_to_play = true
	_note("playing: %s" % ", ".join(active_layers()))
	return true


## Switch a layer on or off. Safe to call mid-song — that is the point.
func set_layer(name: StringName, on: bool) -> void:
	if _panel == null or not _titles.has(name):
		return
	_panel.SetMusic(_titles[name], on)
	_on[name] = on


func active_layers() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _on.keys():
		if _on[name]:
			out.append(String(name))
	return out


## Seconds of *audible* song, i.e. already latency-compensated. Monotonic — it
## keeps rising across laps, so it drops straight into Conductor.song_position.
##
## Two corrections are folded in here:
##
##   - The zero point is latched on the first call rather than at the end of
##     start(), with every layer rewound at that same instant. Registering and
##     loading takes a variable ~0.9 s, and measuring before the first frame
##     leaves the chart that far behind the audio.
##   - ENGINE_PREBUFFER_FRAMES is subtracted, so what comes back is where the
##     song is in the speakers rather than in the engine's buffer.
func position() -> float:
	if _player == null:
		return 0.0
	if not _clock_latched:
		_clock_latched = true
		for name in _titles.keys():
			_panel.CueMusic(_titles[name], "0")
		_frames_at_start = _consumed_frames()
	return _raw_position() - ENGINE_PREBUFFER_FRAMES / FRAME_RATE


## Where the engine's generator is, as opposed to where the speakers are.
## Loop cues are timed against this; note timing is not.
func _raw_position() -> float:
	if _player == null or not _clock_latched:
		return 0.0
	return (_consumed_frames() - _frames_at_start) / FRAME_RATE


## Call every frame with the frame delta: rewinds the layers at each loop point.
##
## The cue can only be issued on a frame boundary, so it will never land exactly
## on the loop point, and whatever it misses by is heard — cue late and the
## engine emits that much silence before the next lap; cue early and it clips
## the tail of the current one. Firing on whichever frame is *nearest* the
## boundary rather than the first one past it halves the worst case to about
## half a frame (~8 ms at 60 fps). The error does not accumulate: each lap is
## cued against an absolute multiple of the loop length.
func pump(delta: float) -> void:
	if not MANUAL_LOOP or _panel == null or _loop_length <= 0.0 or not _clock_latched:
		return
	var raw := _raw_position()
	var next_lap := _laps_cued + 1
	var boundary := next_lap * _loop_length
	if raw + delta * 0.5 < boundary:
		return
	_laps_cued = next_lap
	for name in _titles.keys():
		_panel.CueMusic(_titles[name], "0")
	if _log_cues:
		print("[song] lap %d cued at raw %.4f s (target %.4f, %+.1f ms)" % [
			next_lap, raw, boundary, (raw - boundary) * 1000.0])


func stop() -> void:
	ready_to_play = false
	if _player != null:
		_player.Deactivate()


## The wrapper hands this back as a String, not an int.
func _consumed_frames() -> float:
	return float(str(_player.GetConsumedFrames()))


## PDJE can only play music that lives in its own DB, so each layer's .wav has
## to be registered once. The DB goes under user:// — res:// is read-only after
## export, and the shipped examples write there.
func _register(title: String, path: String, bpm: float) -> bool:
	if not FileAccess.file_exists(path):
		_note("layer file missing: %s" % path)
		return false
	if not _engine.SearchMusic(title, COMPOSER).is_empty():
		return true
	# One editor project per music. There is a single editor per engine, and it
	# keeps the rows from the previous registration: pushing a second music
	# through the same project makes render() choke ("failed to convert bpm to
	# double / invalid stod argument"), which the shipped one-music examples
	# never hit. A separate project path per title keeps them isolated.
	_engine.InitEditor(COMPOSER, "none", "%s/%s" % [EDITOR_PATH, title])
	var editor: Object = _engine.GetEditor()
	if editor == null:
		_note("GetEditor() null — cannot register %s" % title)
		return false
	editor.ConfigNewMusic(title, COMPOSER, path)
	# One PDJE_EDITOR_ARG per row: the carrier is single-use.
	var arg: Object = ClassDB.instantiate("PDJE_EDITOR_ARG")
	if arg == null:
		_note("PDJE_EDITOR_ARG could not be instantiated")
		return false
	arg.InitMusicArg(title, str(int(bpm)), 0, 0, 4)
	editor.AddLine(arg)
	var render: Variant = editor.render("%s_track" % title)
	if String(render) != "RENDER COMPLETE":
		_note("render(%s) -> %s" % [title, render])
		return false
	var pushed: Variant = editor.pushToRootDB(title, COMPOSER)
	_note("registered %s @%.0f BPM (pushToRootDB -> %s)" % [title, bpm, pushed])
	return true


func _note(text: String) -> void:
	log_lines.append(text)
