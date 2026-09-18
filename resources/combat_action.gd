extends RefCounted
class_name CombatAction

enum Kind { NONE, ATTACK, DEFEND, HEAL }
enum Effect { NONE, SLOW, STUN, BURN, POISON }

var kind: Kind = Kind.NONE
var effect: Effect = Effect.NONE
var effect_nb_turn: int = 0
var target: Combatant = null
var hp_amount: int = 0

static func attack(target: Combatant, hp_amount: int) -> CombatAction:
	var action := CombatAction.new()
	action.kind = Kind.ATTACK
	action.target = target
	action.hp_amount = hp_amount
	return action
