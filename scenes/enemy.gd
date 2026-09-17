extends Combatant

class_name Enemy

@export var definition: EnemyDefinition
@onready var player_detector: CollisionShape3D = $PlayerDetector/CollisionShape3D

func _ready() -> void:
	max_hp = definition.max_hp
	attack_range = definition.attack_range
	(player_detector.shape as SphereShape3D).radius = definition.detection_radius
	super()

func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	
	CombatManager.handle_contact(body as Player, self)

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	
	move_and_slide()
