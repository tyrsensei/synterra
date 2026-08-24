extends CharacterBody3D

class_name Combatant

var initiative: int = 0
var current_combat: Combat = null
var move_center: Vector3
var move_radius: float
var move_max_distance: float = 5.0
var last_position: Vector3

func _ready() -> void:
	initiative = randi_range(0, 10)
	reset_move(global_position)

func reset_move(pos: Vector3):
	last_position = pos
	move_center = pos
	move_radius = move_max_distance

func circle_overflow_direction(pos: Vector3) -> Vector2:
	var flat_pos := Vector2(pos.x, pos.z)
	var flat_center := Vector2(move_center.x, move_center.z)
	var offset := flat_pos - flat_center
	if offset.length() <= move_radius:
		return Vector2.ZERO
	return offset.normalized()

func clamp_position(pos: Vector3) -> Vector3:
	print_debug("clamp_position: ", pos)
	var outward := circle_overflow_direction(pos)
	if outward == Vector2.ZERO:
		return pos
	var flat_center := Vector2(move_center.x, move_center.z)
	var clamped_flat := flat_center + outward * move_radius
	return Vector3(clamped_flat.x, pos.y, clamped_flat.y)

@rpc("any_peer")
func force_position(pos: Vector3):
	if multiplayer.get_remote_sender_id() == 1:
		print_debug("force_position: ", pos)
		global_position = pos
