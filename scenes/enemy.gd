extends Combatant

class_name Enemy

@export var definition: EnemyDefinition
@onready var player_detector: CollisionShape3D = $PlayerDetector/CollisionShape3D
var move_target: Vector3
var is_moving := false
var _move_time_left := 0.0
signal move_finished

func _ready() -> void:
	max_hp = definition.max_hp
	attack_range = definition.attack_range
	(player_detector.shape as SphereShape3D).radius = definition.detection_radius
	super()

func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	CombatManager.handle_contact(body as Player, self)

func move_to(dest: Vector3):
	move_target = dest
	is_moving = true
	_move_time_left = global_position.distance_to(dest) / move_speed + 1.0

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	
	var finished := false
	if is_moving:
		var to_target := move_target - global_position
		to_target.y = 0.0
		var step := move_speed * delta
		if to_target.length() <= step:
			velocity.x = to_target.x / delta
			velocity.z = to_target.z / delta
			finished = true
		else:
			var dir := to_target.normalized()
			velocity.x = dir.x * move_speed
			velocity.z = dir.z * move_speed
		_move_time_left -= delta
		if _move_time_left <= 0.0:
			finished = true
	
	move_and_slide()
	if finished:
		is_moving = false
		velocity.x = 0.0
		velocity.z = 0.0
		move_finished.emit()
