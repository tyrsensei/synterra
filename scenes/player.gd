extends CharacterBody3D

class_name Player

func _enter_tree() -> void:
	var multiplayer_id:= int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	
	# 1. Récupérer l'input (direction souhaitée)
	var direction_input:= Input.get_vector("ui_up", "ui_down", "ui_left", "ui_right")
	# 2. Appliquer la gravité si besoin (CharacterBody3D)
	# 3. Définir self.velocity en fonction de l'input
	
	move_and_slide()
