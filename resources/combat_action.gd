extends RefCounted
class_name CombatAction

enum Kind { NONE, ATTACK, DEFEND, HEAL, MOVE }
enum Effect { NONE, SLOW, STUN, BURN, POISON }

var kind: Kind = Kind.NONE
var effect: Effect = Effect.NONE
var effect_nb_turn: int = 0
var actor: Combatant = null
var target: Combatant = null
var destination: Vector3
var hp_amount: int = 0

static func attack(actor: Combatant, target: Combatant, hp_amount: int) -> CombatAction:
	var action := CombatAction.new()
	action.kind = Kind.ATTACK
	action.actor = actor
	action.target = target
	action.hp_amount = hp_amount
	return action

static func move(actor: Combatant, destination: Vector3) -> CombatAction:
	var action := CombatAction.new()
	action.actor = actor
	action.kind = Kind.MOVE
	action.destination = destination
	return action
