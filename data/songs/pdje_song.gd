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

## Frame buffer handed to InitPlayer(). The shipped config_and_play.gd example
## passes 48 and the judge docs pass 480; neither says what it costs. Measured
## with two layers playing and one being time-stretched, it sets how far the
## engine runs ahead of the speakers: 48 -> ~0.10 s, 480 -> ~0.14 s,
## 2048 -> ~0.22 s. 48 frames is 1 ms of work per callback, which is tight
## enough to underrun and click under load, so this trades 40 ms of latency for
## headroom. Sync does not depend on it — CueMusic takes hold of the output
## immediately, so position() is measured from the cue, not from the buffer.
const PLAYER_FRAME_BUFFER := 480
const FRAME_RATE := 48000.0     # GetConsumedFrames() is documented as /48000

## GetConsumedFrames() sits a fixed prebuffer above wall-clock — measured at
## 5328 frames (0.111 s) in scenes/tools/pdje_audio_check.tscn, constant across
## runs. It is NOT subtracted anywhere, and that is deliberate: CueMusic takes
## hold of the output immediately, so the song's first sample is heard at the
## moment of the latch cue, which makes elapsed-time-since-latch already equal
## to position-in-the-song. Subtracting the prebuffer on top pushed the loop
## cue a prebuffer late and opened a gap at the first seam.
##
## Kept as documentation of the engine's buffer depth.
const ENGINE_PREBUFFER_FRAMES := 5328.0

## MusPanel does NOT loop: a music plays once and then stays silent. So we have
## to rewind each layer ourselves at the loop point.
const MANUAL_LOOP := true

## Realtime FX. The enum lives on EnumWrapper as a FLAT constant — the
## `EnumWrapper.PDJE_FX_LIST.FILTER` spelling in the agent docs does not exist,
## and this enum is NOT the one in the editor's mix-args table (which numbers
## FILTER as 0). Probed values: COMPRESSOR DISTORTION ECHO EQ FILTER FLANGER
## OCSFILTER PANNER PHASER ROBOT ROLL TRANCE VOL, with FILTER = 4.
## Resolved through ClassDB at runtime, with the probed value as the fallback.
const FX_FILTER_FALLBACK := 4
## FILTER takes exactly two args (confirmed via GetFXArgKeys): the type switch
## and the cutoff. The editor mix table documents the type as HIGH(0)/LOW(2),
## and the shipped example comments `HLswitch, 0` as "highpass" — so 2 is the
## lowpass. Flip this if it turns out to sound like a highpass.
const FILTER_LOWPASS := 2
const FILTER_KEY_TYPE := "HLswitch"
const FILTER_KEY_FREQ := "Filterfreq"
## Cutoff in Hz with the filter disengaged. Well above hearing, so "off" and
## "wide open" sound the same and the transition is inaudible.
const FILTER_OPEN_HZ := 20000.0

## Trim on the loop rewind, in frames. Raise it if the next lap arrives early,
## lower it (negative is fine) if a gap opens at the seam. 48 frames = 1 ms.
##
## Note that seams 2..N are self-correcting whatever this is set to — each cue
## defines both the end of one lap and the start of the next, so a constant
## offset cancels. Only the *first* seam is pinned independently, by the latch,
## so a gap or overlap that appears there and nowhere else means the clock's
## zero point disagrees with the cue, not that this value is wrong.
const CUE_TRIM_FRAMES := 0.0

var ready_to_play: bool = false
var log_lines: Array[String] = []
## Print every loop cue — used by rhythm_game's --selftest.
var _log_cues: bool = OS.get_cmdline_user_args().has("--selftest")

var _engine: Node = null
var _player: Object = null
var _panel: Object = null
var _titles: Dictionary = {}     # layer name (StringName) -> PDJE music title
var _on: Dictionary = {}         # layer name -> currently audible?
var _wanted: Dictionary = {}     # layer name -> should be on once the clock starts
var _fx: Dictionary = {}         # layer name -> FXWrapper
var _fx_args: Dictionary = {}    # layer name -> FXArgWrapper
var _filtered: Dictionary = {}   # layer name -> filter currently engaged?
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
	if not _engine.InitPlayer(mode, "void", PLAYER_FRAME_BUFFER):
		# Almost always the output device, not PDJE. Both PDJE and Godot's own
		# WASAPI backend fail the same way when something else holds the default
		# device in exclusive mode (0x8889000A AUDCLNT_E_DEVICE_IN_USE) — a
		# virtual mixer like Voicemeeter, or a DAW with an ASIO driver.
		_note("InitPlayer failed — no usable output device.")
		_note("  Check logs/pdjeLog.txt. If Godot also reports 'WASAPI: Initialize")
		_note("  failed', the device is taken: close the app holding it, or turn off")
		_note("  'Give exclusive mode applications priority' for the default device.")
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

	for name in _titles.keys():
		var src_bpm := float(layers[name]["source_bpm"])
		if is_equal_approx(src_bpm, song_bpm):
			continue
		# The whole point: fit the layer to the song without transposing it.
		var ok: bool = _panel.ChangeBpm(_titles[name], song_bpm, src_bpm)
		_note("%s: ChangeBpm %.0f -> %.0f BPM = %s" % [name, src_bpm, song_bpm, ok])

	# Everything stays SILENT until the clock is latched. LoadMusic leaves a
	# title playable, and registration plus loading takes ~0.9 s of wall time —
	# long enough for two beats of the loop to be heard before the clock starts.
	# Those beats used to leak out and then get cut off by the latch's rewind,
	# which sounded like a stumble right at the top of the first lap.
	for name in _titles.keys():
		_panel.SetMusic(_titles[name], false)
		_on[name] = false
		_wanted[name] = bool(layers[name]["on"])

	ready_to_play = true
	var wanted := PackedStringArray()
	for name in _wanted.keys():
		if _wanted[name]:
			wanted.append(String(name))
	_note("armed (silent until the clock starts): %s" % ", ".join(wanted))
	return true


## Switch a layer on or off. Safe to call mid-song — that is the point.
## Before the clock is latched this only records the intent, so that arming the
## song cannot make it audible early.
func set_layer(name: StringName, on: bool) -> void:
	if _panel == null or not _titles.has(name):
		return
	_wanted[name] = on
	if not _clock_latched:
		return
	_panel.SetMusic(_titles[name], on)
	_on[name] = on


## Sweep a lowpass onto one layer, or open it back up. `cutoff` is in Hz;
## anything at or above FILTER_OPEN_HZ disengages the filter entirely.
##
## The FX handle is fetched lazily and cached: getFXHandle() only works once the
## music is loaded, and re-fetching it per frame would be wasteful for something
## a hold note hits every frame it is held.
func set_layer_filter(name: StringName, cutoff: float) -> void:
	if _panel == null or not _titles.has(name):
		return
	var engage := cutoff < FILTER_OPEN_HZ
	if not _fx.has(name):
		var handle: Object = _panel.getFXHandle(_titles[name])
		if handle == null:
			_note("getFXHandle(%s) returned null — no filter on this layer" % name)
			_fx[name] = null
			return
		_fx[name] = handle
		_fx_args[name] = handle.GetArgSetter()
	var handle: Object = _fx[name]
	var args: Object = _fx_args.get(name)
	if handle == null or args == null:
		return

	if engage != bool(_filtered.get(name, false)):
		handle.FX_ON_OFF(_fx_filter(), engage)
		_filtered[name] = engage
	if engage:
		args.SetFXArg(_fx_filter(), FILTER_KEY_TYPE, FILTER_LOWPASS)
		args.SetFXArg(_fx_filter(), FILTER_KEY_FREQ, cutoff)


func _fx_filter() -> int:
	var v := ClassDB.class_get_integer_constant("EnumWrapper", "FILTER")
	return v if v != 0 else FX_FILTER_FALLBACK


## The layers the song is playing (or is armed to play).
func active_layers() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _wanted.keys():
		if _wanted[name]:
			out.append(String(name))
	return out


## Seconds into the song. Monotonic — it keeps rising across laps, so it drops
## straight into Conductor.song_position.
##
## The zero point is latched on the first call rather than at the end of
## start(), with every layer rewound and unmuted at that same instant.
## Registering and loading takes a variable ~0.9 s, and measuring before the
## first frame leaves the chart that far behind the audio. Because the cue takes
## hold of the output there and then, elapsed time from the latch IS position in
## the song; see ENGINE_PREBUFFER_FRAMES for why nothing is subtracted.
func position() -> float:
	if _player == null:
		return 0.0
	if not _clock_latched:
		_clock_latched = true
		# Rewind to the top and unmute in the same instant, so the song's first
		# sample and the chart's t=0 are the same moment.
		for name in _titles.keys():
			_panel.CueMusic(_titles[name], "0")
		_frames_at_start = _consumed_frames()
		for name in _titles.keys():
			var on := bool(_wanted.get(name, false))
			_panel.SetMusic(_titles[name], on)
			_on[name] = on
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
	var now := position()
	var next_lap := _laps_cued + 1
	var boundary := next_lap * _loop_length + CUE_TRIM_FRAMES / FRAME_RATE
	if now + delta * 0.5 < boundary:
		return
	_laps_cued = next_lap
	for name in _titles.keys():
		_panel.CueMusic(_titles[name], "0")
	if _log_cues:
		print("[song] lap %d cued at %.4f s (target %.4f, %+.1f ms)" % [
			next_lap, now, boundary, (now - boundary) * 1000.0])


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
