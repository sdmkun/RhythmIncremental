extends Control
## MainMenu — entry scene. Routes to the rhythm game and the skill tree.

var _beats_label: Label


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#1c1a2e")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.position = Vector2(1280 / 2 - 160, 200)
	vb.custom_minimum_size = Vector2(320, 0)
	vb.add_theme_constant_override("separation", 16)
	add_child(vb)

	var title := Label.new()
	title.text = "RHYTHM ✦ INCREMENTAL"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Godot 4.7.1 prototype — D F J K to play"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(subtitle)

	_beats_label = Label.new()
	_beats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_beats_label.add_theme_font_size_override("font_size", 22)
	vb.add_child(_beats_label)

	vb.add_child(_spacer())

	var play := Button.new()
	play.text = "▶  Play Song"
	play.custom_minimum_size = Vector2(0, 44)
	play.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/rhythm/rhythm_game.tscn"))
	vb.add_child(play)

	var tree := Button.new()
	tree.text = "✦  Skill Tree"
	tree.custom_minimum_size = Vector2(0, 44)
	tree.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/skill_tree/skill_tree.tscn"))
	vb.add_child(tree)

	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func(): get_tree().quit())
	vb.add_child(quit)

	GameState.beats_changed.connect(_on_beats_changed)
	_refresh()


func _spacer() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 16)
	return c


func _on_beats_changed(_total: int) -> void:
	_refresh()


func _refresh() -> void:
	_beats_label.text = "Beats: %d   (idle +%.1f/s)" % [GameState.beats, GameState.idle_beats_per_sec]
