extends Node3D

func _ready() -> void:
	SceneManager.set_skip_scene_loading(true)
	NetworkManager.create_server("TyR", "password")
