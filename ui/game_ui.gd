extends Control

@onready var combat_bar: HBoxContainer = $"VBoxContainer/Combat Bar"

var pending_combat_id := -1
var local_player: Player
var attack_used_this_turn := false

func _ready() -> void:
	StateManager.combat_started.connect(_on_combat_started)
	StateManager.combat_ended.connect(_on_combat_ended)
	StateManager.new_combat_available.connect(_on_new_combat)
	CombatManager.new_turn_received.connect(_on_new_turn)

func _process(_delta: float) -> void:
	var player := _get_player()
	if not player or player.current_combat_id == -1 or not CombatManager.is_player_turn(player):
		return
	get_tree().call_group(
		"cost_an_action", "set_disabled",
		attack_used_this_turn or not player.has_enemy_in_range()
	)

	
func _get_player() -> Player:
	if not local_player:
		local_player = StateManager.get_player_from_id(multiplayer.get_unique_id())
	return local_player

func _on_combat_started():
	var tree := get_tree()
	tree.call_group("combat_ui", "set_disabled", true)
	tree.call_group("combat_ui", "show")
	tree.call_group("combat_join_ui", "hide")
	tree.call_group("combat_prep_ui", "show")

func _on_combat_ended():
	var tree := get_tree()
	tree.call_group("combat_ui", "hide")
	tree.call_group("combat_ui", "set_disabled", true)
	tree.call_group("combat_join_ui", "hide")
	tree.call_group("combat_prep_ui", "hide")
	pending_combat_id = -1

func _on_new_turn():
	print_debug("UI new turn")
	attack_used_this_turn = false
	var player := _get_player()
	if not player:
		return
	var is_my_turn:= CombatManager.is_player_turn(player)
	var tree := get_tree()
	tree.call_group("combat_ui", "set_disabled", !is_my_turn)
	tree.call_group("combat_prep_ui", "hide")
	
func _on_new_combat(combat_id: int):
	print_debug("New combat received: ", combat_id)
	var player := _get_player()
	if not player or player.current_combat_id != -1:
		return
	if pending_combat_id != -1 and pending_combat_id != combat_id:
		return
	pending_combat_id = combat_id
	get_tree().call_group("combat_join_ui", "show")

func _on_end_turn_button_button_up() -> void:
	print_debug("end turn clicked")
	var player := _get_player()
	CombatManager.rpc_id(
		1,
		"request_action",
		player.current_combat_id,
		CombatManager.Action.END_TURN
	)


func _on_attack_button_button_up() -> void:
	print_debug("attack clicked")
	get_tree().call_group("cost_an_action", "set_disabled", true)
	var player := _get_player()
	player.set_available_move()
	attack_used_this_turn = true
	CombatManager.rpc_id(
		1,
		"request_action",
		player.current_combat_id,
		CombatManager.Action.ATTACK_WEAPON
	)


func _on_join_combat_button_button_up() -> void:
	print_debug("join clicked")
	CombatManager.rpc_id(
		1,
		"request_action",
		pending_combat_id,
		CombatManager.Action.JOIN_COMBAT
	)


func _on_ready_button_button_up() -> void:
	print_debug("ready clicked")
	var player := _get_player()
	CombatManager.rpc_id(
		1,
		"request_action",
		player.current_combat_id,
		CombatManager.Action.READY
	)
