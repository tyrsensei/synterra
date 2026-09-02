extends Node

enum PlayerState {EXPLORATION, FIGHT, BUILD}
enum CombatState {PREP, ONGOING, END}

signal combat_started
signal combat_ended
signal new_combat_available(combat_id: int)

func _ready() -> void:
	NetworkManager.client_connected.connect(get_states)
	
@rpc("any_peer")
func request_state_change(new_state: PlayerState, combat_id: int = -1):
	var player_id := multiplayer.get_remote_sender_id()
	rpc("notify_state_changed", player_id, new_state, combat_id)

@rpc("authority", "call_local")
func notify_state_changed(
	player_id: int,
	new_state: PlayerState,
	combat_id: int = -1,
	combat_state: CombatState = CombatState.PREP
):
	var player: Player = get_player_from_id(player_id)
	if player:
		player.state = new_state
		player.current_combat_id = combat_id
		if combat_id != -1 and combat_state == CombatState.PREP:
			new_combat_available.emit(combat_id)
		# we only send signals to player
		if player_id == multiplayer.get_unique_id():
			match new_state:
				PlayerState.FIGHT:
					combat_started.emit()
				PlayerState.EXPLORATION:
					combat_ended.emit()

func get_states(client_id: int):
	var players = get_tree().current_scene.get_node("Players").get_children()
	for player:Player in players:
		var combat_phase := CombatState.PREP
		if player.current_combat_id != -1:
			var combat: Combat = CombatManager.currents.get(player.current_combat_id)
			if combat:
				combat_phase = combat.phase
		rpc_id(
			client_id,
			"notify_state_changed",
			player.get_meta("player_id"),
			player.state,
			player.current_combat_id,
			combat_phase
		)

func get_player_from_id(player_id: int) -> Player:
	return get_tree().current_scene.get_node_or_null(
		str("Players/Player-", player_id)
	)
