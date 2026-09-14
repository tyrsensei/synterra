# Exists only on server and is not replicated
extends RefCounted

class_name Combat

const JOIN_MARGIN := 2.0
var combat_id: int
var current_turn := -1
var turn_number := 0
var turn_order: Array[Combatant] = []
var ready_players: Array[Player] = []
var phase: CombatManager.CombatState = CombatManager.CombatState.PREP

signal combat_end
signal turn_changed(combatant: Combatant)

func is_everyone_ready():
	for combatant in turn_order:
		if combatant is Player and combatant not in ready_players:
			return false
	
	return true

func add_combatant(combatant: Combatant):
	turn_order.append(combatant)
	if combatant is not Player:
		combatant.current_combat_id = self.combat_id
	combatant.died.connect(_check_combat_end)

func start():
	turn_order.sort_custom(
		func(a: Combatant, b: Combatant):
			return a.initiative > b.initiative
	)
	for combatant in turn_order:
		print_debug("Initiative: ", combatant.name, " -> ", combatant.initiative)
	phase = CombatManager.CombatState.ONGOING
	next_turn()

func end():
	for combatant in turn_order:
		combatant.died.disconnect(_check_combat_end)
	phase = CombatManager.CombatState.END
	combat_end.emit()

func get_current_combatant() -> Combatant:
	return turn_order[current_turn]

func next_turn():
	if phase != CombatManager.CombatState.ONGOING:
		return
	turn_number += 1
	current_turn = (current_turn + 1) % turn_order.size()
	while turn_order[current_turn].current_hp == 0:
		current_turn = (current_turn + 1) % turn_order.size()
	turn_order[current_turn].action_used = false
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

func get_targets_in_range(attacker: Combatant) -> Array[Combatant]:
	var candidates: Array[Combatant] = []
	for combatant in turn_order:
		var is_opponent := (
			(attacker is Player and combatant is Enemy)
			or (attacker is Enemy and combatant is Player)
		)
		if not is_opponent or combatant.current_hp <= 0:
			continue
		if attacker.global_position.distance_to(combatant.global_position) <= attacker.attack_range:
			candidates.append(combatant)
	candidates.sort_custom(func(a, b):
		return (
			attacker.global_position.distance_to(a.global_position)
			< attacker.global_position.distance_to(b.global_position)
		)
	)
	return candidates

func _check_combat_end():
	print_debug("Check combat end on combat_id=", combat_id, " self=", self)
	var enemies_alive := 0
	var players_alive := 0
	for combatant in turn_order:
		if combatant.current_hp > 0:
			if combatant is Enemy:
				enemies_alive += 1
			elif combatant is Player :
				players_alive +=1
	if enemies_alive == 0 or players_alive == 0:
		end()
