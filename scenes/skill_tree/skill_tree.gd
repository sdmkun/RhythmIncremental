extends Control
## SkillTree — the incremental progression screen.
##
## Renders SkillData as a live Yggdrasil node tree (Registry/Loader are
## skipped — the tree is built directly from SkillData each time this scene
## loads, since SkillData stays the single source of truth for cost/effect/
## prerequisites; Yggdrasil only owns the visual graph + node states).
## GameState.buy_upgrade() remains the only thing that ever spends Beats.

const NODE_SIZE := Vector2(160, 70)
const NODE_LAYOUT := {
	&"multiplier_1": {"pos": Vector2(0, -180), "root": true},
	&"idle_1": {"pos": Vector2(-200, 0), "root": false},
	&"window_1": {"pos": Vector2(200, 0), "root": false},
	&"multiplier_2": {"pos": Vector2(0, 180), "root": false},
}

var _beats_label: Label
var _message_label: Label
var _message_timer: Timer
var _tree_view: YggdrasilTreeView
var _yg_nodes: Dictionary = {}    # StringName id -> YggdrasilNodeButton
var _yg_labels: Dictionary = {}   # StringName id -> Label (name/level overlay)
var _id_to_skill: Dictionary = {} # int (YggdrasilNode.id) -> StringName skill id


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#161327")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var header := Label.new()
	header.text = "SKILL TREE"
	header.add_theme_font_size_override("font_size", 34)
	header.position = Vector2(40, 24)
	add_child(header)

	_beats_label = Label.new()
	_beats_label.add_theme_font_size_override("font_size", 22)
	_beats_label.position = Vector2(40, 72)
	add_child(_beats_label)

	_message_label = Label.new()
	_message_label.add_theme_font_size_override("font_size", 18)
	_message_label.add_theme_color_override("font_color", Color("#ff5964"))
	_message_label.position = Vector2(40, 104)
	_message_label.visible = false
	add_child(_message_label)

	_message_timer = Timer.new()
	_message_timer.wait_time = 1.6
	_message_timer.one_shot = true
	_message_timer.timeout.connect(func(): _message_label.visible = false)
	add_child(_message_timer)

	var back := Button.new()
	back.text = "◀ Back to Menu"
	back.position = Vector2(1130, 24)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn"))
	add_child(back)

	var container := Control.new()
	container.position = Vector2(40, 140)
	container.custom_minimum_size = Vector2(1200, 540)
	container.size = Vector2(1200, 540)
	add_child(container)

	_build_tree(container)

	GameState.beats_changed.connect(func(_t): _refresh_all())
	GameState.upgrade_purchased.connect(func(_id): _refresh_all())
	_refresh_all()


func _build_tree(container: Control) -> void:
	var tree := YggdrasilTree.new()
	tree.name = "Skill Tree"
	tree.id = "skill_tree"
	tree.revealed = true
	tree.allocation = true
	tree.preallocation = false
	tree.multiallocation = true
	tree.size = Vector2(1200, 540)
	tree.bg_color = Color("#161327")
	tree.node_size[YggdrasilNode.NodeType.MEDIUM] = NODE_SIZE

	var nodes_by_id: Dictionary = {}   # StringName -> YggdrasilNode
	for id in SkillData.ids():
		var layout: Dictionary = NODE_LAYOUT[id]
		var def := SkillData.get_def(id)
		var node := YggdrasilNode.new()
		node.id = tree.get_next_id()
		node.name = String(def["name"])
		node.type = YggdrasilNode.NodeType.MEDIUM
		node.position = layout["pos"]
		node.max_allocations = int(def["max_level"])
		node.is_root = layout["root"]
		node.border_normal = _make_square_texture(Color("#3a3550"))
		node.border_intermediate = _make_square_texture(Color("#ffd24f"))
		node.border_active = _make_square_texture(Color("#7bff8a"))
		nodes_by_id[id] = node
		_id_to_skill[node.id] = id
		tree.nodes.append(node)

	for id in SkillData.ids():
		var node: YggdrasilNode = nodes_by_id[id]
		var def := SkillData.get_def(id)
		for req in def["requires"]:
			var req_node: YggdrasilNode = nodes_by_id[req]
			req_node.out_nodes.append(node.id)
			node.in_nodes.append(req_node.id)

	var builder := YggdrasilBuilder.new(tree)
	builder.set_parent(container)
	builder.set_save_path("user://skill_tree_state.dat")
	builder.node_created_callback(_on_yg_node_created)
	_tree_view = builder.build()

	# Yggdrasil's built-in click handler allocates the first level for free and
	# then blocks further clicks (it isn't built for a repeat-buy economy), so
	# we drive purchases ourselves and only borrow its private allocate/visual
	# machinery to keep node borders + connection lines in sync.
	_tree_view.nodes_service.node_pressed.disconnect(_tree_view.allocation_service.on_node_pressed)
	_tree_view.nodes_service.node_pressed.connect(_on_node_pressed)

	# The tree is rebuilt from scratch every time this scene loads, so replay
	# already-owned levels (tracked for real in GameState) to restore the
	# allocated/active visuals and connection-line states.
	for id in SkillData.ids():
		var node: YggdrasilNodeButton = _yg_nodes[id]
		for _lvl in range(GameState.get_upgrade_level(id)):
			_tree_view.allocation_service._allocate_node(node)


func _on_yg_node_created(node: YggdrasilNodeButton) -> void:
	# NodesService._create_node_from_data() overwrites external_id with the
	# display name, so the skill id has to come from our own id->skill map.
	var id: StringName = _id_to_skill[node.id]
	_yg_nodes[id] = node

	var lbl := Label.new()
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", 14)
	node.add_child(lbl)
	_yg_labels[id] = lbl


func _make_square_texture(color: Color, size: int = 96) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func _on_node_pressed(node: YggdrasilNodeButton) -> void:
	var id: StringName = _id_to_skill[node.id]
	if not SkillData.is_unlocked(id, GameState.upgrade_levels):
		_show_message("Locked — unlock prerequisites first.")
		return
	var def := SkillData.get_def(id)
	if GameState.get_upgrade_level(id) >= int(def["max_level"]):
		return
	if not GameState.buy_upgrade(id):
		_show_message("Not enough Beats.")
		return
	_tree_view.allocation_service._allocate_node(node)


func _show_message(text: String) -> void:
	_message_label.text = text
	_message_label.visible = true
	_message_timer.start()


func _refresh_all() -> void:
	_beats_label.text = "Beats: %d" % GameState.beats
	for id in SkillData.ids():
		var def := SkillData.get_def(id)
		var level := GameState.get_upgrade_level(id)
		var max_level := int(def["max_level"])
		var node: YggdrasilNodeButton = _yg_nodes.get(id)
		var lbl: Label = _yg_labels.get(id)
		if lbl == null:
			continue

		var status: String
		if level >= max_level:
			status = "MAX"
		elif not SkillData.is_unlocked(id, GameState.upgrade_levels):
			status = "locked"
		else:
			status = "%d Beats" % SkillData.cost_for_level(id, level)

		lbl.text = "%s\n(%d/%d)\n%s" % [def["name"], level, max_level, status]
		node.description = "%s\n%s" % [def["desc"], status]
