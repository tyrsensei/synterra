extends CombatRule
class_name FleeRule

func matches(enemy: Enemy, _combat: Combat, value: float) -> bool:
	if value and enemy.current_hp > value:
		return false
	return true

func decide(enemy: Enemy, combat: Combat, _value: float) -> CombatAction:
	var nearest_opponent := combat.get_nearest_opponent(enemy)
	if not nearest_opponent:
		return
	var to_target := enemy.global_position - nearest_opponent.global_position
	to_target.y = 0.0
	var destination := enemy.global_position + to_target.normalized() * enemy.move_radius
	return CombatAction.move(enemy, destination)
