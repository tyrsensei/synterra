extends CharacterBody3D

class_name Player

@export var speed:= 5
@export var camera_speed:= 0.005
@onready var camera_3d: Camera3D = $SpringArm3D/Camera3D

var mouse_move := Vector2.ZERO

func _enter_tree() -> void:
	var multiplayer_id:= int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)

func _ready() -> void:
	if is_multiplayer_authority():
		camera_3d.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_move += event.relative

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	
	var direction_input:= Input.get_vector("ui_left", "ui_right", "ui_down", "ui_up") * speed
	var move_direction:Vector3 = (
		direction_input.x * self.transform.basis.x
	) + (
		-direction_input.y * self.transform.basis.z
	)
	if not is_on_floor():
		self.velocity.y += get_gravity().y * delta
	self.velocity.x = move_direction.x
	self.velocity.z = move_direction.z
	rotate_y(-mouse_move.x * camera_speed)
	mouse_move = Vector2.ZERO
	
	move_and_slide()
