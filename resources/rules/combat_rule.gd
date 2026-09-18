extends Resource
class_name CombatRule

func matches(_enemy: Enemy, _combat: Combat, _value: float) -> bool:
	return true

func decide(_enemy: Enemy, _combat: Combat, _value: float) -> CombatAction:
	return CombatAction.new()
