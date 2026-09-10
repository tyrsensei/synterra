extends Node

enum Action {
	READY,
	JOIN_COMBAT,
	END_TURN,
	ATTACK_WEAPON,
}
var currents: Dictionary[int, Combat] = {}
var current_turn_combatant: Dictionary[int, Combatant] = {}
var _next_combat_id := 0

signal new_turn_received

# Only ran by server
func handle_contact(player: Player, enemy: Enemy):
	# Player can't join 2 combats
	if player.current_combat_id != -1:
		return
	
	var combat: Combat
	if enemy.current_combat_id != -1:
		combat = get_combat(enemy.current_combat_id)
		if combat.phase != StateManager.CombatState.PREP:
			return
		combat.add_participant(player)
	else:
		combat = Combat.new()
		combat.turn_changed.connect(_on_turn_changed.bind(combat))
		combat.combat_end.connect(_on_combat_ended.bind(combat))
		combat.combat_id = _next_combat_id
		_next_combat_id+=1
		combat.add_enemy(enemy)
		combat.add_participant(player)
		currents.set(combat.combat_id, combat)
		_start_combat_timer(combat)
	
	_notify_joined(player, player.current_combat_id, combat.phase)

func _start_combat_timer(combat: Combat):
	await get_tree().create_timer(30.0).timeout
	if combat.phase == StateManager.CombatState.PREP:
		combat.start()

func _on_turn_changed(combatant: Combatant, combat: Combat):
	_start_turn_timer(combat)
	if combatant is Enemy:
		_handle_enemy_turn(combat, combatant)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path())

func _on_combat_ended(combat: Combat):
	for combatant in combat.turn_order:
		if combatant is Player:
			StateManager.rpc(
				"notify_state_changed",
				combatant.get_meta("player_id"),
				StateManager.PlayerState.EXPLORATION
			)
	currents.erase(combat.combat_id)

func _start_turn_timer(combat: Combat):
	var saved_turn:= combat.current_turn
	await get_tree().create_timer(15.0).timeout
	if combat.current_turn == saved_turn:
		combat.next_turn()

func _handle_enemy_turn(combat: Combat, enemy: Enemy):
	await get_tree().create_timer(1.0).timeout
	var players := combat.get_targets_in_range(enemy)
	if players.size() == 0:
		players[0].change_hp(-2)
		rpc(
			"notify_health_changed",
			players[0].get_path(),
			players[0].current_hp
		)
	combat.next_turn()

@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	print_debug("Turn changed !")
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	current_turn_combatant[combat_id] = combatant
	combatant.reset_move()
	new_turn_received.emit()

@rpc("authority", "call_local")
func notify_health_changed(path_to_node: NodePath, new_health: int):
	var combatant = get_node(path_to_node)
	if combatant is not Combatant:
		return
	combatant.current_hp = new_health

@rpc("any_peer", "call_local")
func request_action(combat_id: int, action: Action):
	if not multiplayer.is_server():
		return
	var remote_id:= multiplayer.get_remote_sender_id()
	var combat: Combat = currents.get(combat_id)
	if not combat:
		return

	match action:
		Action.JOIN_COMBAT:
			_handle_join(combat, combat_id, remote_id)
		Action.READY:
			_handle_ready(combat, combat_id, remote_id)
		Action.END_TURN, Action.ATTACK_WEAPON:
			_handle_combat_action(combat, remote_id, action)

func _handle_join(combat: Combat, combat_id: int, remote_id: int):
	print_debug("join combat requested")
	if combat.phase != StateManager.CombatState.PREP:
		return
	var player := StateManager.get_player_from_id(remote_id)
	if not player or player.current_combat_id != -1:
		return
	var join_pos := combat.get_join_position()
	combat.add_participant(player)
	player.rpc_id(remote_id, "force_position", join_pos)
	_notify_joined(player, combat_id, combat.phase)

func _handle_ready(combat: Combat, combat_id: int, remote_id: int):
	if combat.phase != StateManager.CombatState.PREP:
		return
	var player := StateManager.get_player_from_id(remote_id)
	if (
		not player
		or player in combat.ready_players
		or player.current_combat_id != combat_id
	):
		return
	combat.ready_players.append(player)
	if combat.is_everyone_ready():
		combat.start()

func _handle_combat_action(combat: Combat, remote_id: int, action: Action):
	if combat.phase != StateManager.CombatState.ONGOING:
		return
	var combatant := combat.get_current_combatant()
	if combatant is not Player or combatant.get_meta("player_id") != remote_id:
		return

	match action:
		Action.END_TURN:
			print_debug("end turn requested")
			combat.next_turn()
		Action.ATTACK_WEAPON:
			if combatant.action_used:
				return
			var enemies := combat.get_targets_in_range(combatant)
			if enemies.size() == 0:
				rpc_id(remote_id, "notify_action_rejected")
				return
			enemies[0].change_hp(-5)
			rpc("notify_health_changed", enemies[0].get_path(), enemies[0].current_hp)
			combatant.action_used = true

func get_combat(combat_id: int) -> Combat:
	return currents[combat_id]

func is_player_turn(player: Player) -> bool:
	if player.current_combat_id == -1:
		return true
	
	return (
		current_turn_combatant.get(player.current_combat_id) == player
	)

func _notify_joined(player: Player, combat_id: int, combat_phase: StateManager.CombatState) -> void:
	StateManager.rpc(
		"notify_state_changed",
		player.get_meta("player_id"),
		StateManager.PlayerState.FIGHT,
		combat_id,
		combat_phase
	)

@rpc("authority", "call_remote")
func notify_action_rejected():
	get_tree().call_group("cost_an_action", "set_disabled", false)
