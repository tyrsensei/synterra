extends CharacterBody3D

class_name Enemy


func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	
	if body is Player:
		States.rpc(
			"notify_state_changed",
			body.get_meta("player_id"),
			States.PlayerState.FIGHT
		)
