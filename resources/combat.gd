extends RefCounted

class_name Combat

var turn_order: Array[Combatant] = []
var phase: StateManager.CombatState = StateManager.CombatState.PREP

signal combat_end
signal participant_added(player: Player)
signal enemy_added(enemy: Enemy)

func add_participant(player: Player):
	turn_order.append(player)
	participant_added.emit(player)
	player.current_combat = self

func add_enemy(enemy: Enemy):
	turn_order.append(enemy)
	enemy_added.emit(enemy)
	enemy.current_combat = self

func start():
	turn_order.sort_custom(
		func(a: Combatant, b: Combatant):
			return a.initiative > b.initiative
	)
	for combatant in turn_order:
		print_debug("Initiative: ", combatant.name, " -> ", combatant.initiative)
	phase = StateManager.CombatState.ONGOING

func end():
	phase = StateManager.CombatState.END
	combat_end.emit()
