extends CharacterBody3D

class_name Combatant

var initiative: int = 0
var current_combat_id: int = -1
var move_center: Vector3
var move_radius: float
var move_max_distance: float = 5.0
var action_used: bool = false
var max_hp := 10
var current_hp: int = 0:
	set(value):
		current_hp = value
		health_bar.set_instance_shader_parameter("health", float(current_hp) / max_hp)
var attack_range: float = 5.0

signal died

var health_bar: MeshInstance3D

func _ready() -> void:
	_setup_health_bar()
	current_hp = max_hp
	initiative = randi_range(0, 10)
	reset_move()
	

func _setup_health_bar():
	health_bar = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 0.15)
	health_bar.mesh = quad
	health_bar.position.y = 2.2
	
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/combatant_health_bar.gdshader")
	health_bar.material_override = material
	
	add_child(health_bar)

func reset_move():
	move_center = global_position
	move_radius = move_max_distance

func set_available_move():
	move_radius -= global_position.distance_to(move_center)
	move_center = global_position

func change_hp(points: int):
	current_hp = clampi(current_hp + points, 0, max_hp)
	if current_hp == 0:
		print_debug("I died ! ", self)
		died.emit()

func has_enemy_in_range() -> bool:
	var node_container = get_node("../Enemies")
	if self is Enemy:
		node_container = get_node("../Players")
	for enemy in node_container.get_children():
		if global_position.distance_to(enemy.global_position) <= attack_range:
			return true
	return false
