extends Resource
class_name EnemyDefinition

@export var max_hp := 10
@export var attack_range: float
@export var detection_radius: float
@export var attack_damage: int
@export var pack_radius: float
@export var rules: Array[RuleEntry] = []

func decide_action(enemy: Enemy, combat: Combat) -> CombatAction:
	for entry in rules:
		if entry.rule.matches(enemy, combat, entry.value):
			return entry.rule.decide(enemy, combat, entry.value)
	return CombatAction.new()
