extends Node

var scene_to_load: PackedScene
var skip_scene_loading: bool = false

func _ready() -> void:
	NetworkManager.server_ready.connect(_on_server_ready)
	
func _on_server_ready() -> void:
	if not skip_scene_loading:
		get_tree().change_scene_to_packed(scene_to_load)
		await get_tree().scene_changed
	if multiplayer.is_server():
		NetworkManager.on_scene_loaded_on_server()

func set_scene_to_load(scene: PackedScene):
	scene_to_load = scene

func set_skip_scene_loading(skip: bool):
	skip_scene_loading = skip
