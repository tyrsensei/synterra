extends CombatRule
class_name ChaseNearestRule

const RANGE_MARGIN := 0.9

func matches(enemy: Enemy, combat: Combat, _value: float) -> bool:
	var nearest_player := combat.get_nearest_opponent(enemy)
	if not nearest_player:
		return false
	return (
		nearest_player.global_position.distance_to(enemy.global_position) > enemy.attack_range
		and enemy.move_radius > 0
	)

func decide(enemy: Enemy, combat: Combat, _value: float) -> CombatAction:
	var target := combat.get_nearest_opponent(enemy)
	var to_target := target.global_position - enemy.global_position
	to_target.y = 0.0
	var stop_distance := maxf(enemy.attack_range * RANGE_MARGIN, 0.0)
	var travel := to_target.length() - stop_distance
	var destination := enemy.global_position + to_target.normalized() * travel
	return CombatAction.move(enemy, destination)
