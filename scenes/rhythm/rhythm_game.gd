extends Node2D
## RhythmGame — a minimal 4-lane falling-note rhythm prototype.
##
## Self-contained: reads a JSON chart, moves notes with the Conductor clock,
## judges key presses in GDScript, and pays out Beats to GameState. When you
## install Project-DJ-Godot, swap the timing + judgement here for PDJE's Core /
## Judge modules (see conductor.gd and addons/Project_DJ_Godot/INSTALL.md).
##
## The default chart is generated from a real loop: PDJE's Beat This detects the
## beats, they get snapped to 16th notes on a bar-exact grid, and the loop plays
## forever with the same pattern re-issued every lap. Regenerate it from
## scenes/tools/beat_check.tscn ("Export chart"). Falls back to the hand-written
## demo chart if the generated one is missing, so the scene never hard-depends
## on the addon.

const CHART_PATH := "res://data/charts/TSP_ENEIV2_175_kit_throwback_drum_E.json"
const FALLBACK_CHART_PATH := "res://data/charts/demo_chart.json"
const LANE_COUNT := 4
const LANE_WIDTH := 110.0
const HIT_Y := 620.0
const SPAWN_Y := -60.0
const APPROACH_TIME := 1.4          # seconds a note is visible before the hit line
const NOTE_HEIGHT := 26.0

const LANE_KEYS := ["D", "F", "J", "K"]
const LANE_COLORS := [
	Color("#ff4fa3"), Color("#4fd0ff"), Color("#ffd24f"), Color("#7bff8a"),
]

# Base hit windows (seconds). GameState.judge_window_bonus_ms widens them.
const WIN_PERFECT := 0.045
const WIN_GREAT := 0.090
const WIN_GOOD := 0.130
const BEATS_PERFECT := 10
const BEATS_GREAT := 6
const BEATS_GOOD := 3

var _pattern: Array = []             # one lap of the chart: [{time, lane}]
var _pending: Array = []             # upcoming notes, time-ordered
var _active: Array = []              # spawned, not yet resolved
var _laps_generated := 0
var _playfield_x := 0.0
var _finished := false

var _looping := false
var _loop_length := 0.0
var _chart_title := ""

var score := 0
var combo := 0
var max_combo := 0
var beats_this_run := 0
var notes_seen := 0
var misses := 0

## `-- --selftest [seconds]`: log the endless loop's bookkeeping and quit.
## Observation only — it never presses anything.
var _selftest_until := 0.0
var _selftest_lap := -1

var _hud: CanvasLayer
var _score_label: Label
var _combo_label: Label
var _judge_label: Label
var _beats_label: Label
var _song_label: Label
var _summary: Panel


func _ready() -> void:
	_playfield_x = (1280.0 - LANE_COUNT * LANE_WIDTH) / 2.0
	_build_playfield()
	_build_hud()
	var stream := _load_song()
	_ensure_generated(APPROACH_TIME + 4.0)
	Conductor.song_finished.connect(_on_song_finished)
	if _song != null and _song.ready_to_play:
		# PDJE owns playback, so it owns the clock too.
		Conductor.play_external(_song.position, _chart_bpm, _loop_length)
	else:
		# With no stream the Conductor still runs a clock, so the scene stays
		# playable (silently) even if the audio is unavailable.
		Conductor.play_song(stream, _chart_bpm, _loop_length if _looping else 0.0)
	_setup_selftest(stream)
	set_process(true)


func _setup_selftest(stream: AudioStream) -> void:
	var args := OS.get_cmdline_user_args()
	var idx := args.find("--selftest")
	if idx < 0:
		return
	_selftest_until = float(args[idx + 1]) if idx + 1 < args.size() else 50.0
	print("\n########## RhythmGame selftest (%.0f s) ##########" % _selftest_until)
	print("chart=%s bpm=%.3f loop=%s loop_length=%.4f notes/lap=%d layers=[%s] audio=%s" % [
		_chart_title, _chart_bpm, _looping, _loop_length, _pattern.size(),
		", ".join(_layers),
		"PDJE" if _song != null else (
			"none" if stream == null else "%s %.4f s" % [
				stream.get_class(), stream.get_length()])])


# --- Setup -------------------------------------------------------------------
var _chart_bpm := 120.0
var _layers: PackedStringArray = PackedStringArray()
var _song: PdjeSong = null


## Start the song: SongData defines the layers, PdjeSong plays them through
## PDJE's MusPanel (which time-stretches off-tempo layers in realtime). Falls
## back to the generated JSON chart if PDJE cannot start, so the scene is never
## dead — the fallback plays silently, since fitting a 120 BPM layer to a
## 125 BPM track is exactly what we are relying on PDJE for.
func _load_song() -> AudioStream:
	var layers := SongData.layer_table(GameState.upgrade_levels)
	if layers.is_empty():
		push_warning("SongData has no layers — falling back to the JSON chart.")
		return _load_chart()

	_chart_bpm = SongData.BPM
	_chart_title = SongData.TITLE
	_loop_length = SongData.loop_seconds()
	_looping = true
	_pattern = SongData.chart()

	_song = PdjeSong.new()
	_song.name = "PdjeSong"
	add_child(_song)
	var started := _song.start(layers, SongData.BPM, _loop_length)
	for line in _song.log_lines:
		print("[song] %s" % line)
	if not started:
		push_warning("PDJE could not start — the chart plays, but silently.")
		_song.queue_free()
		_song = null
		return null
	_layers = _song.active_layers()
	return null


## Reads a generated chart JSON and returns the AudioStream to play with it.
func _load_chart() -> AudioStream:
	var path := CHART_PATH
	if not FileAccess.file_exists(path):
		push_warning("Chart %s not found — falling back to %s" % [path, FALLBACK_CHART_PATH])
		path = FALLBACK_CHART_PATH
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Chart not found: %s" % path)
		return null
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Chart is not a JSON object: %s" % path)
		return null

	_chart_bpm = float(data.get("bpm", 120))
	_chart_title = str(data.get("title", path.get_file().get_basename()))
	_loop_length = float(data.get("loop_length", 0.0))
	_looping = bool(data.get("loop", false)) and _loop_length > 0.0

	for n in data.get("notes", []):
		_pattern.append({"time": float(n["time"]), "lane": int(n["lane"]) % LANE_COUNT})
	_pattern.sort_custom(func(a, b): return a["time"] < b["time"])

	return _load_stream(data)


## The loop is played from the imported (QOA) resource — but with the loop point
## taken from the chart's frame count, which came from the original PCM. That
## keeps the audio loop and the note grid on exactly the same period.
func _load_stream(data: Dictionary) -> AudioStream:
	var audio_path := str(data.get("audio", ""))
	if audio_path.is_empty() or not ResourceLoader.exists(audio_path):
		if not audio_path.is_empty():
			push_warning("Chart audio missing: %s — playing silently." % audio_path)
		return null
	var src := load(audio_path)
	if src is not AudioStreamWAV:
		return src as AudioStream
	var stream: AudioStreamWAV = (src as AudioStreamWAV).duplicate()
	var loop_frames := int(data.get("loop_frames", 0))
	if _looping and loop_frames > 0:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = loop_frames
	return stream


## Endless play: hand out another lap of the pattern whenever the timeline runs
## dry. Note times are absolute, so lap N is just the pattern + N * loop_length.
func _ensure_generated(until: float) -> void:
	if _pattern.is_empty():
		return
	if not _looping:
		if _laps_generated == 0:
			_append_lap(0)
		return
	while _laps_generated * _loop_length < until:
		_append_lap(_laps_generated)


func _append_lap(lap: int) -> void:
	var offset := lap * _loop_length
	for n in _pattern:
		_pending.append({
			"time": n["time"] + offset,
			"lane": n["lane"],
			"node": null,
			"hit": false,
		})
	_laps_generated = lap + 1


func _build_playfield() -> void:
	for i in range(LANE_COUNT):
		var lane := ColorRect.new()
		lane.color = Color(0.10, 0.09, 0.16, 1.0) if i % 2 == 0 else Color(0.13, 0.12, 0.20, 1.0)
		lane.position = Vector2(_playfield_x + i * LANE_WIDTH, 0)
		lane.size = Vector2(LANE_WIDTH, 720)
		add_child(lane)
		# Key hint at the bottom of each lane.
		var key := Label.new()
		key.text = LANE_KEYS[i]
		key.add_theme_font_size_override("font_size", 28)
		key.position = Vector2(_playfield_x + i * LANE_WIDTH + LANE_WIDTH / 2 - 10, HIT_Y + 30)
		add_child(key)
	# Hit line.
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.85)
	line.position = Vector2(_playfield_x, HIT_Y)
	line.size = Vector2(LANE_COUNT * LANE_WIDTH, 4)
	add_child(line)


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)

	_score_label = _make_label(Vector2(30, 24), 28)
	_combo_label = _make_label(Vector2(30, 64), 22)
	_beats_label = _make_label(Vector2(30, 100), 20)
	_song_label = _make_label(Vector2(30, 132), 16)
	_judge_label = _make_label(Vector2(1280 / 2 - 80, 420), 40)
	_judge_label.size = Vector2(160, 60)
	_judge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var back := Button.new()
	back.text = "Finish (Esc)"
	back.position = Vector2(1110, 24)
	back.pressed.connect(_end_run)
	_hud.add_child(back)

	_refresh_hud()


func _make_label(pos: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	_hud.add_child(l)
	return l


# --- Main loop ---------------------------------------------------------------
func _process(_delta: float) -> void:
	if _finished:
		return
	if _song != null:
		_song.pump()      # rewinds the PDJE layers at each loop point
	var t: float = Conductor.song_position
	var px_per_sec := (HIT_Y - SPAWN_Y) / APPROACH_TIME

	_ensure_generated(t + APPROACH_TIME + 4.0)

	# Spawn note visuals as they enter the approach window.
	while not _pending.is_empty() and _pending[0]["time"] - t <= APPROACH_TIME:
		var note = _pending.pop_front()
		_spawn_note(note)
		_active.append(note)

	# Move active notes; auto-miss notes that fall past the window. Iterating
	# backwards so resolved notes can be dropped in place — _active must stay
	# bounded, the timeline never ends.
	var window_good := WIN_GOOD + GameState.judge_window_bonus_ms / 1000.0
	for i in range(_active.size() - 1, -1, -1):
		var note = _active[i]
		if not note["hit"]:
			note["node"].position.y = \
				HIT_Y - (float(note["time"]) - t) * px_per_sec - NOTE_HEIGHT / 2.0
			if t - note["time"] > window_good:
				_register_miss(note)
		if note["hit"]:
			_active.remove_at(i)

	if not _looping and not _finished and _pending.is_empty() and _active.is_empty():
		_end_run()
	elif _looping:
		_refresh_lap()

	if _selftest_until > 0.0:
		_tick_selftest(t)


func _tick_selftest(t: float) -> void:
	if Conductor.loops_completed != _selftest_lap:
		_selftest_lap = Conductor.loops_completed
		print("lap %-2d  t=%8.3f  expected=%8.3f  pending=%-4d active=%-3d seen=%-4d missed=%d" % [
			_selftest_lap + 1, t, _selftest_lap * _loop_length,
			_pending.size(), _active.size(), notes_seen, misses])
	if t >= _selftest_until:
		_finish_selftest("time limit")


func _finish_selftest(reason: String) -> void:
	if _selftest_until <= 0.0:
		return
	_selftest_until = 0.0
	print("laps=%d  notes seen=%d (%d expected)  missed=%d  pending=%d  active=%d" % [
		Conductor.loops_completed + 1, notes_seen,
		_pattern.size() * (Conductor.loops_completed + 1), misses,
		_pending.size(), _active.size()])
	print("########## RhythmGame selftest done (%s) ##########" % reason)
	# Tear down before quitting: queue_free() never runs if we quit mid-frame.
	for note in _active:
		if note["node"]:
			note["node"].free()
			note["node"] = null
	_active.clear()
	_pending.clear()
	Conductor.stop()
	get_tree().quit(0)


func _spawn_note(note: Dictionary) -> void:
	notes_seen += 1
	var rect := ColorRect.new()
	rect.color = LANE_COLORS[note["lane"]]
	rect.size = Vector2(LANE_WIDTH - 16, NOTE_HEIGHT)
	rect.position = Vector2(_playfield_x + note["lane"] * LANE_WIDTH + 8, SPAWN_Y)
	add_child(rect)
	note["node"] = rect


# --- Input & judgement -------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# The loop never ends on its own, so Esc banks the run; Esc again leaves.
		if _finished:
			_back_to_menu()
		else:
			_end_run()
		return
	if _finished:
		return
	for lane in range(LANE_COUNT):
		if event.is_action_pressed("lane_%d" % lane):
			_judge_lane(lane)


func _judge_lane(lane: int) -> void:
	var t: float = Conductor.song_position
	var bonus := GameState.judge_window_bonus_ms / 1000.0
	var best = null
	var best_dt := 1000.0
	for note in _active:
		if note["hit"] or note["lane"] != lane:
			continue
		var dt: float = abs(note["time"] - t)
		if dt < best_dt:
			best_dt = dt
			best = note
	if best == null or best_dt > WIN_GOOD + bonus:
		return
	var beats := 0
	var label := ""
	var col := Color.WHITE
	if best_dt <= WIN_PERFECT + bonus:
		beats = BEATS_PERFECT; label = "PERFECT"; col = Color("#ffd24f")
	elif best_dt <= WIN_GREAT + bonus:
		beats = BEATS_GREAT; label = "GREAT"; col = Color("#7bff8a")
	else:
		beats = BEATS_GOOD; label = "GOOD"; col = Color("#4fd0ff")
	_register_hit(best, beats, label, col)


func _register_hit(note, base_beats: int, label: String, col: Color) -> void:
	note["hit"] = true
	if note["node"]:
		note["node"].queue_free()
		note["node"] = null
	combo += 1
	max_combo = max(max_combo, combo)
	var earned := int(base_beats * GameState.score_multiplier)
	score += earned * 10
	beats_this_run += earned
	GameState.add_beats(earned)
	_flash_judge(label, col)
	_refresh_hud()


func _register_miss(note) -> void:
	note["hit"] = true
	if note["node"]:
		note["node"].queue_free()
		note["node"] = null
	combo = 0
	misses += 1
	_flash_judge("MISS", Color("#ff5964"))
	_refresh_hud()


func _flash_judge(text: String, col: Color) -> void:
	_judge_label.text = text
	_judge_label.add_theme_color_override("font_color", col)


func _refresh_hud() -> void:
	_score_label.text = "Score: %d" % score
	_combo_label.text = "Combo: %d" % combo
	_beats_label.text = "Beats +%d  (total %d)" % [beats_this_run, GameState.beats]
	_refresh_lap()


func _refresh_lap() -> void:
	if not _looping:
		_song_label.text = "%s  —  %.0f BPM" % [_chart_title, _chart_bpm]
		return
	var layers := "kick" if _layers.is_empty() else "kick + " + ", ".join(_layers)
	_song_label.text = "%s  —  %.2f BPM  /  loop %d  /  layers: %s  (endless — Esc to finish)" % [
		_chart_title, _chart_bpm, Conductor.loops_completed + 1, layers]


# --- End of run --------------------------------------------------------------
func _on_song_finished() -> void:
	pass  # Notes may still be resolving; _end_run() fires from _process.


func _end_run() -> void:
	if _finished:
		return
	_finished = true
	Conductor.stop()
	if _song != null:
		_song.stop()
	for note in _active:
		if note["node"]:
			note["node"].queue_free()
	_active.clear()
	_pending.clear()
	GameState.save_game()
	_show_summary()
	_finish_selftest("chart ended")


func _show_summary() -> void:
	_summary = Panel.new()
	_summary.size = Vector2(520, 300)
	_summary.position = Vector2(1280 / 2 - 260, 720 / 2 - 150)
	_hud.add_child(_summary)

	var vb := VBoxContainer.new()
	vb.position = Vector2(30, 24)
	vb.custom_minimum_size = Vector2(460, 0)
	vb.add_theme_constant_override("separation", 14)
	_summary.add_child(vb)

	var title := Label.new()
	title.text = "Run Complete!" if _looping else "Song Complete!"
	title.add_theme_font_size_override("font_size", 32)
	vb.add_child(title)

	var stats := Label.new()
	stats.text = "Score: %d\nMax Combo: %d\nBeats earned: %d\nNotes: %d  (missed %d)\nLoops played: %d" % [
		score, max_combo, beats_this_run, notes_seen, misses, Conductor.loops_completed + 1]
	stats.add_theme_font_size_override("font_size", 20)
	vb.add_child(stats)

	var tree_btn := Button.new()
	tree_btn.text = "Spend Beats in Skill Tree"
	tree_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/skill_tree/skill_tree.tscn"))
	vb.add_child(tree_btn)

	var retry := Button.new()
	retry.text = "Retry Song"
	retry.pressed.connect(func(): get_tree().reload_current_scene())
	vb.add_child(retry)

	var menu := Button.new()
	menu.text = "Main Menu"
	menu.pressed.connect(_back_to_menu)
	vb.add_child(menu)


func _back_to_menu() -> void:
	Conductor.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")
