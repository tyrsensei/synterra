extends Node

enum PlayerState {EXPLORATION, FIGHT, BUILD}

@rpc("any_peer")
func request_state_change(new_state: PlayerState):
	var player_id := multiplayer.get_remote_sender_id()
	rpc("notify_state_changed", player_id, new_state)

@rpc("authority", "call_local")
func notify_state_changed(player_id: int, new_state: PlayerState):
	var player: Player = get_tree().current_scene.get_node_or_null(
		str("Players/Player-", player_id)
	)
	if player:
		player.state = new_state
