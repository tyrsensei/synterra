extends Control

@onready var combat_bar: HBoxContainer = $"VBoxContainer/Combat Bar"

func _ready() -> void:
	StateManager.combat_started.connect(_on_combat_started)
	StateManager.combat_ended.connect(_on_combat_ended)
	CombatManager.new_turn_received.connect(_on_new_turn)

func _on_combat_started():
	get_tree().call_group("combat_ui", "show")

func _on_combat_ended():
	get_tree().call_group("combat_ui", "hide")
	get_tree().call_group("combat_ui", "set_disabled", true)

func _on_new_turn():
	print_debug("UI new turn")
	var player := StateManager.get_player_from_id(multiplayer.get_unique_id())
	if not player:
		return
	var is_my_turn:= CombatManager.is_player_turn(player)
	get_tree().call_group("combat_ui", "set_disabled", !is_my_turn)

func _on_end_turn_button_button_up() -> void:
	print_debug("end turn clicked")
	var player := StateManager.get_player_from_id(multiplayer.get_unique_id())
	CombatManager.rpc_id(
		1,
		"request_action",
		player.current_combat_id,
		CombatManager.Action.END_TURN
	)


func _on_attack_button_button_up() -> void:
	print_debug("attack clicked")
	var player := StateManager.get_player_from_id(multiplayer.get_unique_id())
	CombatManager.rpc_id(
		1,
		"request_action",
		player.current_combat_id,
		CombatManager.Action.ATTACK_WEAPON
	)
