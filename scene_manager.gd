extends Node

var scene_to_load: PackedScene
var skip_scene_loading: bool = false

signal error(reason: String)
signal loaded_complete

func _ready() -> void:
	NetworkManager.server_ready.connect(_on_server_ready)
	NetworkManager.connection_error.connect(_on_connection_error)
	NetworkManager.client_ready.connect(func (): loaded_complete.emit())
	
func _on_server_ready() -> void:
	if not skip_scene_loading:
		await change_scene()
	if multiplayer.is_server():
		NetworkManager.on_scene_loaded_on_server()
	loaded_complete.emit()

func _on_connection_error(reason: String):
	print_debug("SceneManager:_on_connection_error: ", reason)
	scene_to_load = preload("res://ui/main_menu.tscn")
	await change_scene()
	error.emit(reason)

func join_server(nickname: String, password: String):
	await change_scene()
	NetworkManager.join_server(nickname, password)
	
	
func change_scene():
	get_tree().change_scene_to_packed(scene_to_load)
	await get_tree().scene_changed
	
func set_scene_to_load(scene: PackedScene):
	scene_to_load = scene

func set_skip_scene_loading(skip: bool):
	skip_scene_loading = skip
