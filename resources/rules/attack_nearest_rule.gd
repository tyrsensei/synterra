extends CombatRule
class_name AttackNearestRule

func matches(enemy: Enemy, combat: Combat, _value: float) -> bool:
	var target := combat.get_nearest_opponent(enemy)
	if not target:
		return false
	if (
		target.global_position.distance_to(enemy.global_position) > enemy.attack_range
		or enemy.action_used
	):
		return false
	return true
	
func decide(enemy: Enemy, combat: Combat, _value: float) -> CombatAction:
	var target := combat.get_nearest_opponent(enemy)
	if not target:
		return
	return CombatAction.attack(enemy, target, enemy.definition.attack_damage)
