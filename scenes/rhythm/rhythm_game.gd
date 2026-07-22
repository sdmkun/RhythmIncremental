extends Node2D
## RhythmGame — a minimal 4-lane falling-note rhythm prototype.
##
## Self-contained: reads a JSON chart, moves notes with the Conductor clock,
## judges key presses in GDScript, and pays out Beats to GameState. When you
## install Project-DJ-Godot, swap the timing + judgement here for PDJE's Core /
## Judge modules (see conductor.gd and addons/Project_DJ_Godot/INSTALL.md).

const CHART_PATH := "res://data/charts/demo_chart.json"
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

var _notes: Array = []               # [{time, lane, node, hit}]
var _next_spawn := 0
var _playfield_x := 0.0
var _finished := false

var score := 0
var combo := 0
var max_combo := 0
var beats_this_run := 0

var _hud: CanvasLayer
var _score_label: Label
var _combo_label: Label
var _judge_label: Label
var _beats_label: Label
var _summary: Panel


func _ready() -> void:
	_playfield_x = (1280.0 - LANE_COUNT * LANE_WIDTH) / 2.0
	_build_playfield()
	_build_hud()
	_load_chart()
	Conductor.song_finished.connect(_on_song_finished)
	# No audio file in the demo chart -> Conductor still runs a clock, so this
	# is fully playable. Drop an AudioStream in to hear it.
	Conductor.play_song(null, _chart_bpm)
	set_process(true)


# --- Setup -------------------------------------------------------------------
var _chart_bpm := 120.0

func _load_chart() -> void:
	var f := FileAccess.open(CHART_PATH, FileAccess.READ)
	if f == null:
		push_error("Chart not found: %s" % CHART_PATH)
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	_chart_bpm = float(data.get("bpm", 120))
	var raw: Array = data.get("notes", [])
	for n in raw:
		_notes.append({
			"time": float(n["time"]),
			"lane": int(n["lane"]),
			"node": null,
			"hit": false,
		})
	_notes.sort_custom(func(a, b): return a["time"] < b["time"])


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
	_judge_label = _make_label(Vector2(1280 / 2 - 80, 420), 40)
	_judge_label.size = Vector2(160, 60)
	_judge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var back := Button.new()
	back.text = "Menu (Esc)"
	back.position = Vector2(1130, 24)
	back.pressed.connect(_back_to_menu)
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
	var t: float = Conductor.song_position
	var px_per_sec := (HIT_Y - SPAWN_Y) / APPROACH_TIME

	# Spawn note visuals as they enter the approach window.
	while _next_spawn < _notes.size() and _notes[_next_spawn]["time"] - t <= APPROACH_TIME:
		_spawn_note(_next_spawn)
		_next_spawn += 1

	# Move active notes; auto-miss notes that fall past the window.
	var window_good := WIN_GOOD + GameState.judge_window_bonus_ms / 1000.0
	for note in _notes:
		if note["hit"] or note["node"] == null:
			continue
		var y: float = HIT_Y - (float(note["time"]) - t) * px_per_sec
		note["node"].position.y = y - NOTE_HEIGHT / 2.0
		if t - note["time"] > window_good:
			_register_miss(note)

	if not _finished and _next_spawn >= _notes.size() and _all_resolved():
		_end_run()


func _spawn_note(idx: int) -> void:
	var note = _notes[idx]
	var rect := ColorRect.new()
	rect.color = LANE_COLORS[note["lane"]]
	rect.size = Vector2(LANE_WIDTH - 16, NOTE_HEIGHT)
	rect.position = Vector2(_playfield_x + note["lane"] * LANE_WIDTH + 8, SPAWN_Y)
	add_child(rect)
	note["node"] = rect


# --- Input & judgement -------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_back_to_menu()
		return
	for lane in range(LANE_COUNT):
		if event.is_action_pressed("lane_%d" % lane):
			_judge_lane(lane)


func _judge_lane(lane: int) -> void:
	var t: float = Conductor.song_position
	var bonus := GameState.judge_window_bonus_ms / 1000.0
	var best = null
	var best_dt := 1000.0
	for note in _notes:
		if note["hit"] or note["lane"] != lane or note["node"] == null:
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
	_flash_judge("MISS", Color("#ff5964"))
	_refresh_hud()


func _flash_judge(text: String, col: Color) -> void:
	_judge_label.text = text
	_judge_label.add_theme_color_override("font_color", col)


func _refresh_hud() -> void:
	_score_label.text = "Score: %d" % score
	_combo_label.text = "Combo: %d" % combo
	_beats_label.text = "Beats +%d  (total %d)" % [beats_this_run, GameState.beats]


func _all_resolved() -> bool:
	for note in _notes:
		if not note["hit"]:
			return false
	return true


# --- End of run --------------------------------------------------------------
func _on_song_finished() -> void:
	pass  # Notes may still be resolving; _end_run() fires from _process.


func _end_run() -> void:
	_finished = true
	GameState.save_game()
	_show_summary()


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
	title.text = "Song Complete!"
	title.add_theme_font_size_override("font_size", 32)
	vb.add_child(title)

	var stats := Label.new()
	stats.text = "Score: %d\nMax Combo: %d\nBeats earned: %d" % [score, max_combo, beats_this_run]
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
