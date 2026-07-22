extends Node
## Conductor — the musical clock / timing source (Autoload).
##
## The rhythm scene reads song_position (seconds into the track) every frame and
## spawns / judges notes against it. This prototype uses a plain
## AudioStreamPlayer plus a latency-compensated clock so it runs with ZERO
## external dependencies.
##
## ── INTEGRATION POINT: Project-DJ-Godot ──────────────────────────────────────
## Replace this timing source with PDJE's Core module for microsecond-accurate,
## OS-level audio timing + its built-in Judge module. Roughly:
##
##   var pdje := PDJE_Wrapper.new()          # provided by the GDExtension
##   pdje.judged.connect(_on_pdje_judged)    # lane/note + timing offset payload
##
## Then feed PDJE's timeline position into song_position instead of the
## AudioStreamPlayer estimate below, and let PDJE emit judgements rather than
## comparing timestamps in GDScript. See addons/Project_DJ_Godot/INSTALL.md.
## ─────────────────────────────────────────────────────────────────────────────

signal song_started
signal song_finished

var playing: bool = false
var song_position: float = 0.0     # seconds since the chart's t=0
var bpm: float = 120.0

# Manual audio-output latency offset in seconds (tune per device / build).
var output_latency: float = 0.0

var _player: AudioStreamPlayer
var _time_began: float = 0.0
var _length: float = 0.0
var _has_stream: bool = false


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.finished.connect(_on_player_finished)
	output_latency = AudioServer.get_output_latency()
	set_process(false)


## Start a song. `stream` may be null — the clock still runs so charts are
## fully playable/testable without any audio file present.
func play_song(stream: AudioStream, start_bpm: float = 120.0) -> void:
	bpm = start_bpm
	song_position = 0.0
	_has_stream = stream != null
	if _has_stream:
		_player.stream = stream
		_length = stream.get_length()
		_player.play()
		_time_began = Time.get_ticks_usec() / 1_000_000.0
	else:
		_length = 0.0
		_time_began = Time.get_ticks_usec() / 1_000_000.0
	playing = true
	set_process(true)
	song_started.emit()


func stop() -> void:
	playing = false
	set_process(false)
	if _player.playing:
		_player.stop()


func _process(_delta: float) -> void:
	if not playing:
		return
	if _has_stream and _player.playing:
		# Prefer the audio driver's own playback position for accuracy.
		song_position = _player.get_playback_position() \
			+ AudioServer.get_time_since_last_mix() \
			- output_latency
	else:
		# No stream (or finished): fall back to a wall-clock estimate.
		song_position = Time.get_ticks_usec() / 1_000_000.0 - _time_began - output_latency


func beat_to_seconds(beat: float) -> float:
	return beat * 60.0 / bpm


func _on_player_finished() -> void:
	_finish()


func _finish() -> void:
	if not playing:
		return
	playing = false
	set_process(false)
	song_finished.emit()
