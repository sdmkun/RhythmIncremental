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
var song_position: float = 0.0     # seconds since the chart's t=0, always rising
var bpm: float = 120.0

# Manual audio-output latency offset in seconds (tune per device / build).
var output_latency: float = 0.0

## Endless-loop support. When loop_length > 0 the stream is expected to repeat
## forever, and song_position keeps counting past the loop point
## (lap * loop_length + position within the lap) so charts can be laid out on a
## single continuous timeline instead of a sawtooth.
var loop_length: float = 0.0
var loops_completed: int = 0

## When something else owns playback (PDJE's MusPanel — see data/songs/
## pdje_song.gd), it supplies the clock instead of the AudioStreamPlayer.
## The callable must return monotonic seconds since playback started.
var external_clock: Callable = Callable()

var _player: AudioStreamPlayer
var _time_began: float = 0.0
var _length: float = 0.0
var _has_stream: bool = false
var _last_in_loop: float = 0.0


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.finished.connect(_on_player_finished)
	output_latency = AudioServer.get_output_latency()
	set_process(false)


## Start a song. `stream` may be null — the clock still runs so charts are
## fully playable/testable without any audio file present.
## Pass `song_loop_length` (seconds) for a looping stream: song_position then
## keeps rising across laps instead of resetting at the loop point.
func play_song(stream: AudioStream, start_bpm: float = 120.0, song_loop_length: float = 0.0) -> void:
	bpm = start_bpm
	song_position = 0.0
	loop_length = maxf(song_loop_length, 0.0)
	loops_completed = 0
	_last_in_loop = 0.0
	external_clock = Callable()
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


## Run the clock off an external playback engine rather than our own
## AudioStreamPlayer. `clock` returns monotonic seconds since playback started.
func play_external(clock: Callable, start_bpm: float, song_loop_length: float) -> void:
	play_song(null, start_bpm, song_loop_length)
	external_clock = clock


func stop() -> void:
	playing = false
	set_process(false)
	external_clock = Callable()
	if _player.playing:
		_player.stop()


func _process(_delta: float) -> void:
	if not playing:
		return
	if external_clock.is_valid():
		# Monotonic across laps, so it needs no wrap bookkeeping. output_latency
		# is NOT applied: it describes Godot's own audio device, which has
		# nothing to do with an external engine's output path, and the external
		# clock is expected to hand back an already-compensated position.
		song_position = float(external_clock.call())
		if loop_length > 0.0:
			loops_completed = int(maxf(song_position, 0.0) / loop_length)
	elif _has_stream and _player.playing:
		# Prefer the audio driver's own playback position for accuracy.
		var raw := _player.get_playback_position() \
			+ AudioServer.get_time_since_last_mix() \
			- output_latency
		if loop_length > 0.0:
			# get_playback_position() may or may not wrap on loop depending on
			# the backend, so normalise, then count the laps ourselves.
			var in_loop := fposmod(maxf(raw, 0.0), loop_length)
			if in_loop < _last_in_loop - loop_length * 0.5:
				loops_completed += 1
			_last_in_loop = in_loop
			song_position = loops_completed * loop_length + in_loop
		else:
			song_position = raw
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
