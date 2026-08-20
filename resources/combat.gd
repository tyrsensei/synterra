extends RefCounted

class_name Combat

var participants: Array[Player] = []
var phase: States.CombatState = States.CombatState.PREP

signal combat_end
signal participant_added(player: Player)

func add_participant(player: Player):
	participants.append(player)
	participant_added.emit(player)

func start():
	phase = States.CombatState.ONGOING

func end():
	phase = States.CombatState.END
	combat_end.emit()
