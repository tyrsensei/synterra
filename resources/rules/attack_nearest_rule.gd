extends CombatRule
class_name AttackNearestRule

func decide(enemy: Enemy, combat: Combat, _value: float) -> CombatAction:
	var target := combat.get_nearest_opponent(enemy)
	return CombatAction.attack(target, enemy.definition.attack_damage)
