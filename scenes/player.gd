extends Combatant

class_name Player

@export var speed:= 5
@export var camera_speed:= 0.005
@export var camera_pivot_min = -PI/4
@export var camera_pivot_max = PI/4

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera_3d: Camera3D = $CameraPivot/SpringArm3D/Camera3D

var mouse_move := Vector2.ZERO
var state: StateManager.PlayerState = StateManager.PlayerState.EXPLORATION

func _enter_tree() -> void:
	var multiplayer_id:= int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)

func _ready() -> void:
	super()
	if is_multiplayer_authority():
		camera_3d.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_move += event.relative

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	
	camera_pivot.rotate_x(-mouse_move.y * camera_speed)
	rotate_y(-mouse_move.x * camera_speed)
	if camera_pivot.rotation.x > camera_pivot_max or camera_pivot.rotation.x < camera_pivot_min:
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, camera_pivot_min, camera_pivot_max)
	mouse_move = Vector2.ZERO
	
	# Don't move if in combat and not my turn
	if not is_my_turn():
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
	
	# Limit if in combat
	if current_combat:
		var next_pos := global_position + Vector3(velocity.x, 0, velocity.z) * delta
		var outward := circle_overflow_direction(next_pos)
		if outward != Vector2.ZERO:
			var flat_velocity := Vector2(velocity.x, velocity.z).slide(outward)
			velocity.x = flat_velocity.x
			velocity.z = flat_velocity.y
	
	move_and_slide()

func is_my_turn() -> bool:
	if not current_combat:
		return true
	return (
		current_combat.phase == StateManager.CombatState.ONGOING
		and current_combat.get_current_combatant() == self
	)
