extends Node

var currents: Dictionary[int, Combat] = {}
var _next_combat_id := 0

func handle_contact(player: Player, enemy: Enemy):
	print_debug("Contact between ", player, " and ", enemy)
	# Player can't join 2 combats
	if player.current_combat:
		return
	
	if enemy.current_combat:
		if enemy.current_combat.phase != StateManager.CombatState.PREP:
			return
		enemy.current_combat.add_participant(player)
	else:
		var combat = Combat.new()
		combat.turn_changed.connect(_on_turn_changed.bind(combat))
		combat.combat_id = _next_combat_id
		_next_combat_id+=1
		combat.add_enemy(enemy)
		combat.add_participant(player)
		currents.set(combat.combat_id, combat)
		_start_combat_timer(combat)
	
	StateManager.rpc(
		"notify_state_changed",
		player.get_meta("player_id"),
		StateManager.PlayerState.FIGHT
	)

func _start_combat_timer(combat: Combat):
	await get_tree().create_timer(5.0).timeout
	if combat.phase == StateManager.CombatState.PREP:
		combat.start()

func _on_turn_changed(combatant: Combatant, combat: Combat):
	_start_turn_timer(combat)
	if (
		combatant is Player
		and not combatant.last_position.is_equal_approx(combatant.global_position)
	):
		combatant.rpc_id(
			combatant.get_meta("player_id"),
			"force_position",
			combatant.last_position
		)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path(), combatant.last_position)

func _start_turn_timer(combat: Combat):
	var saved_turn:= combat.current_turn
	await get_tree().create_timer(5.0).timeout
	if combat.current_turn == saved_turn:
		_end_current_turn(combat)

@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath, pos: Vector3):
	print_debug("Turn changed !")
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	combatant.reset_move(pos)
	

@rpc("any_peer")
func request_end_turn(combat_id: int):
	if not multiplayer.is_server():
		return
	var remote_id:= multiplayer.get_remote_sender_id()
	var combat: Combat = currents.get(combat_id)
	var combatant = combat.get_current_combatant()
	if combatant.get_meta("player_id") != remote_id:
		return
	
	_end_current_turn(combat)

func _end_current_turn(combat: Combat) -> void:
	var combatant := combat.get_current_combatant()
	var clamped := combatant.clamp_position(combatant.global_position)
	if combatant.global_position != clamped:
		combatant.rpc_id(combatant.get_meta("player_id"), "force_position", clamped)
	combatant.last_position = clamped
	combat.next_turn()
