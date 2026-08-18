extends Control

@onready var nickname: LineEdit = $VBoxContainer/Nickname
@onready var password: LineEdit = $VBoxContainer/Password
@onready var error: Label = $VBoxContainer/Error

func _ready() -> void:
	SceneManager.set_scene_to_load(preload("res://levels/game.tscn"))
	SceneManager.error.connect(_on_error)


func _on_host_button_button_up() -> void:
	NetworkManager.create_server(nickname.text, password.text)


func _on_join_button_button_up() -> void:
	SceneManager.join_server(nickname.text, password.text)

func _on_error(message: String) -> void:
	error.text = message
