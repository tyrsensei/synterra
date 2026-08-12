extends Node

var players: Dictionary[int, Dictionary]= {}
var server_password:= ""
signal server_disconnected

var player_info = {"name": "Name"}

var player_scene: PackedScene = preload("res://scenes/player.tscn")

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func create_server(nickname: String, password: String):
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(7000)
	if err:
		print_debug(err)
		return err
	self.server_password = password
	multiplayer.multiplayer_peer = peer
	print_debug("host: ", peer)
	player_info["name"] = nickname
	get_tree().change_scene_to_file("res://levels/game.tscn")
	await get_tree().scene_changed
	add_player(1, player_info)

func join_server(nickname: String, password: String, address: String = "127.0.0.1", port: int = 7000):
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err:
		print_debug(err)
		return err
	multiplayer.multiplayer_peer = peer
	print_debug("client: ", peer)
	player_info["name"] = nickname
	server_password = password

func add_player(player_id: int, peer_player_info: Dictionary) -> void:
	players[player_id] = peer_player_info
	print_debug(players)
	var players_container:= get_tree().current_scene.get_node("Players") as Node3D
	var player:= player_scene.instantiate()
	player.name = str("Player-", player_id)
	player.set_multiplayer_authority(player_id)
	players_container.add_child(player)

func remove_multiplayer_peer():
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()

func _on_peer_connected(id: int):
	print_debug("peer connected: ", id)
	
func _on_peer_disconnected(id: int):
	print_debug("peer disconnected: ", id)
	

func _on_connected_ok():
	print_debug("on_connected_ok: ", player_info, " (", server_password, ")")
	rpc_id(1, "update_player_info", player_info, server_password)


func _on_connected_fail():
	remove_multiplayer_peer()


func _on_server_disconnected():
	remove_multiplayer_peer()
	players.clear()
	server_disconnected.emit()
	
@rpc("any_peer", "call_remote")
func update_player_info(peer_player_info: Dictionary, password: String):
	print_debug("peer_player_info: ", peer_player_info, ", password: ", password)
	if password != server_password:
		print_debug("Password error")
		return
	add_player(multiplayer.get_remote_sender_id(), peer_player_info)
	update_players.rpc(players)

@rpc("authority", "call_remote")
func update_players(new_players: Dictionary):
	print_debug("update_players: ", new_players)
	players = new_players
	get_tree().change_scene_to_file("res://levels/game.tscn")
	await get_tree().scene_changed
