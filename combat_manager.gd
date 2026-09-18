extends Node

enum Action {
	READY,
	JOIN_COMBAT,
	END_TURN,
	ATTACK_WEAPON,
}
enum CombatState {PREP, ONGOING, END}

var currents: Dictionary[int, Combat] = {}
var current_turn_combatant: Dictionary[int, Combatant] = {}
var _next_combat_id := 0

signal new_turn_received(combat_id: int)
signal join_rejected
signal combat_started
signal combat_ended
signal new_combat_available(combat_id: int)

func _ready() -> void:
	NetworkManager.client_connected.connect(get_states)

# Only ran by server
func handle_contact(player: Player, enemy: Enemy):
	# Player can't join 2 combats
	if player.current_combat_id != -1:
		return
	
	var combat: Combat
	if enemy.current_combat_id != -1:
		combat = get_combat(enemy.current_combat_id)
		if combat.phase != CombatState.PREP:
			return
		combat.add_combatant(player)
	else:
		combat = Combat.new()
		combat.turn_changed.connect(_on_turn_changed)
		combat.combat_end.connect(_on_combat_ended)
		combat.combat_id = _next_combat_id
		_next_combat_id+=1
		combat.add_combatant(enemy)
		combat.add_combatant(player)
		currents.set(combat.combat_id, combat)
		_start_combat_timer(combat)
	
	_notify_joined(player, combat.combat_id, combat.phase)

func _start_combat_timer(combat: Combat):
	await get_tree().create_timer(30.0).timeout
	if combat.phase == CombatState.PREP:
		combat.start()

func _on_turn_changed(combat: Combat, combatant: Combatant):
	_start_turn_timer(combat)
	if combatant is Enemy:
		_handle_enemy_turn(combat, combatant)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path())

func _on_combat_ended(combat: Combat):
	for combatant in combat.turn_order:
		if combatant is Player:
			rpc(
				"notify_combat_id_changed",
				combatant.get_meta("player_id")
			)
			combatant.current_hp = combatant.max_hp
			rpc(
				"notify_health_changed",
				combatant.get_path(),
				combatant.current_hp
			)
		else:
			combatant.current_combat_id = -1
	currents.erase(combat.combat_id)


func _start_turn_timer(combat: Combat):
	var saved_turn:= combat.turn_number
	await get_tree().create_timer(15.0).timeout
	if combat.turn_number == saved_turn:
		combat.next_turn()

func _handle_enemy_turn(combat: Combat, enemy: Enemy):
	await get_tree().create_timer(1.0).timeout
	var players := combat.get_targets_in_range(enemy)
	if players.size() > 0:
		var attack_action := CombatAction.attack(players[0], -2)
		_resolve_action(attack_action)
	combat.next_turn()

@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	print_debug("Turn changed !")
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	current_turn_combatant[combat_id] = combatant
	combatant.reset_move()
	new_turn_received.emit(combat_id)

@rpc("authority", "call_local")
func notify_health_changed(path_to_node: NodePath, new_health: int):
	var combatant = get_node(path_to_node)
	if combatant is not Combatant:
		return
	combatant.current_hp = new_health

@rpc("authority", "call_local")
func notify_combat_id_changed(
	player_id: int,
	combat_id: int = -1,
	combat_phase: CombatState = CombatState.PREP
):
	var player := Player.get_by_id(player_id)
	if not player:
		return
	var was_in_combat := player.current_combat_id != -1
	player.current_combat_id = combat_id
	if combat_id != -1 and combat_phase == CombatState.PREP:
		new_combat_available.emit(combat_id)
	if player_id == multiplayer.get_unique_id():
		if combat_id != -1 and not was_in_combat:
			combat_started.emit()
			player.reset_move()
		elif combat_id == -1 and was_in_combat:
			combat_ended.emit()

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
	if combat.phase != CombatState.PREP:
		rpc_id(remote_id, "notify_join_rejected")
		return
	var player := Player.get_by_id(remote_id)
	if not player or player.current_combat_id != -1:
		return
	var join_pos := combat.get_join_position()
	combat.add_combatant(player)
	player.rpc_id(remote_id, "force_position", join_pos)
	_notify_joined(player, combat_id, combat.phase)

func _handle_ready(combat: Combat, combat_id: int, remote_id: int):
	if combat.phase != CombatState.PREP:
		return
	var player := Player.get_by_id(remote_id)
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
	if combat.phase != CombatState.ONGOING:
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
			var attack_action := CombatAction.attack(enemies[0], -5)
			_resolve_action(attack_action)
			combatant.action_used = true

func get_combat(combat_id: int) -> Combat:
	return currents[combat_id]

func is_combat_turn(player: Player) -> bool:
	return current_turn_combatant.get(player.current_combat_id) == player

func can_move(player: Player) -> bool:
	if player.current_combat_id == -1:
		return true
	if not current_turn_combatant.has(player.current_combat_id):
		return true
	return is_combat_turn(player)

func _notify_joined(player: Player, combat_id: int, combat_phase: CombatState) -> void:
	rpc(
		"notify_combat_id_changed",
		player.get_meta("player_id"),
		combat_id,
		combat_phase
	)

@rpc("authority", "call_local")
func notify_action_rejected():
	get_tree().call_group("cost_an_action", "set_disabled", false)

@rpc("authority", "call_local")
func notify_join_rejected():
	join_rejected.emit()
	
func get_states(client_id: int):
	var players = get_tree().current_scene.get_node("Players").get_children()
	for player:Player in players:
		var combat_phase := CombatState.PREP
		if player.current_combat_id != -1:
			var combat: Combat = currents.get(player.current_combat_id)
			if combat:
				combat_phase = combat.phase
				if combat.phase == CombatState.ONGOING:
					rpc_id(
						client_id,
						"notify_turn_changed",
						combat.combat_id,
						combat.get_current_combatant().get_path()
					)
		rpc_id(
			client_id,
			"notify_combat_id_changed",
			player.get_meta("player_id"),
			player.current_combat_id,
			combat_phase
		)

func _resolve_action(action: CombatAction) -> void:
	match action.kind:
		CombatAction.Kind.ATTACK:
			action.target.change_hp(action.hp_amount)
			rpc(
				"notify_health_changed",
				action.target.get_path(),
				action.target.current_hp
			)
			pass
		CombatAction.Kind.DEFEND:
			pass
		CombatAction.Kind.HEAL:
			pass
		CombatAction.Kind.NONE:
			pass
