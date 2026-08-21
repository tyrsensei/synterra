extends Node

var currents: Array[Combat] = []

func handle_contact(player: Player, enemy: Enemy):
	# Player can't join 2 combats
	if player.current_combat:
		return
	
	if enemy.current_combat:
		if enemy.current_combat.phase != StateManager.CombatState.PREP:
			return
		enemy.current_combat.add_participant(player)
	else:
		var combat = Combat.new()
		combat.add_enemy(enemy)
		combat.add_participant(player)
		currents.append(combat)
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
