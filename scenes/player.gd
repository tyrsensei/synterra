extends CharacterBody3D

class_name Player

@export var speed:= 5

func _enter_tree() -> void:
	var multiplayer_id:= int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	
	var direction_input:= Input.get_vector("ui_up", "ui_down", "ui_left", "ui_right") * speed
	if not is_on_floor():
		self.velocity.y += get_gravity().y * delta
	self.velocity.x = direction_input.x
	self.velocity.z = direction_input.y
	
	move_and_slide()
