extends CharacterBody3D

class_name Combatant

var initiative: int = 0
var current_combat_id: int = -1
var move_center: Vector3
var move_radius: float
var move_max_distance: float = 5.0

func _ready() -> void:
	initiative = randi_range(0, 10)
	reset_move()

func reset_move():
	move_center = global_position
	move_radius = move_max_distance
