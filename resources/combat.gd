# Exists only on server and is not replicated
extends RefCounted

class_name Combat

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
