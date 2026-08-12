extends Control

@onready var nickname: LineEdit = $VBoxContainer/Nickname
@onready var password: LineEdit = $VBoxContainer/Password

func _on_host_button_button_up() -> void:
	NetworkManager.create_server(nickname.text, password.text)


func _on_join_button_button_up() -> void:
	NetworkManager.join_server(nickname.text, password.text)
