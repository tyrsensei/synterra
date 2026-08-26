extends Node

enum Action {
	END_TURN,
	ATTACK_WEAPON,
}
var currents: Dictionary[int, Combat] = {}
var current_turn_combatant: Dictionary[int, Combatant] = {}
var _next_combat_id := 0

# Only ran by server
func handle_contact(player: Player, enemy: Enemy):
	# Player can't join 2 combats
	if player.current_combat_id != -1:
		return
	
	if enemy.current_combat_id != -1:
		var enemy_combat = get_combat(enemy.current_combat_id)
		if enemy_combat.phase != StateManager.CombatState.PREP:
			return
		enemy_combat.add_participant(player)
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
		StateManager.PlayerState.FIGHT,
		player.current_combat_id
	)

func _start_combat_timer(combat: Combat):
	await get_tree().create_timer(5.0).timeout
	if combat.phase == StateManager.CombatState.PREP:
		combat.start()

func _on_turn_changed(combatant: Combatant, combat: Combat):
	_start_turn_timer(combat)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path())

func _start_turn_timer(combat: Combat):
	var saved_turn:= combat.current_turn
	await get_tree().create_timer(15.0).timeout
	if combat.current_turn == saved_turn:
		combat.next_turn()

@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	print_debug("Turn changed !")
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	current_turn_combatant[combat_id] = combatant
	combatant.reset_move()
	

@rpc("any_peer", "call_local")
func request_action(combat_id: int, action: Action):
	if not multiplayer.is_server():
		return
	var remote_id:= multiplayer.get_remote_sender_id()
	var combat: Combat = currents.get(combat_id)
	var combatant := combat.get_current_combatant()
	if combatant.get_meta("player_id") != remote_id:
		return
	
	match action:
		Action.END_TURN:
			print_debug("end turn requested")
			combat.next_turn()
		Action.ATTACK_WEAPON:
			if combatant.action_used:
				return
			#TODO attack action
			combatant.action_used = true
			# Set new available distance
			combatant.set_available_move()

func get_combat(combat_id: int) -> Combat:
	return currents[combat_id]
