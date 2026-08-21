extends Combatant

class_name Enemy

func _ready() -> void:
	super()

func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	
	CombatManager.handle_contact(body as Player, self)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	
	move_and_slide()
