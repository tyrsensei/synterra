# Exists only on server and is not replicated
extends RefCounted

class_name Combat

const JOIN_MARGIN := 2.0
var combat_id: int
var current_turn := -1
var turn_order: Array[Combatant] = []
var phase: StateManager.CombatState = StateManager.CombatState.PREP

signal combat_end
signal participant_added(player: Player)
signal enemy_added(enemy: Enemy)
signal turn_changed(combatant: Combatant)

func add_participant(player: Player):
	turn_order.append(player)
	participant_added.emit(player)
	player.current_combat_id = self.combat_id

func add_enemy(enemy: Enemy):
	turn_order.append(enemy)
	enemy_added.emit(enemy)
	enemy.current_combat_id = self.combat_id

func start():
	turn_order.sort_custom(
		func(a: Combatant, b: Combatant):
			return a.initiative > b.initiative
	)
	for combatant in turn_order:
		print_debug("Initiative: ", combatant.name, " -> ", combatant.initiative)
	phase = StateManager.CombatState.ONGOING
	next_turn()

func end():
	phase = StateManager.CombatState.END
	combat_end.emit()

func get_current_combatant() -> Combatant:
	return turn_order[current_turn]

func next_turn():
	turn_order[current_turn].action_used = false
	current_turn = (current_turn + 1) % turn_order.size()
	turn_changed.emit(turn_order[current_turn])

func get_join_position() -> Vector3:
	var sum := Vector3.ZERO
	var num_players := 0
	for combatant in turn_order:
		if combatant is not Player:
			continue
		sum += combatant.global_position
		num_players+=1
	var center := sum / num_players
	var angle := randf() * TAU
	return center + Vector3(cos(angle), 0, sin(angle)) * JOIN_MARGIN
