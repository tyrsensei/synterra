extends CharacterBody3D

class_name Combatant

var initiative: int = 0
var current_combat: Combat = null

func _ready() -> void:
	initiative = randi_range(0, 10)
