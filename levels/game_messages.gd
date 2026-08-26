extends CanvasLayer

@onready var loading: Label = $Loading

func _ready() -> void:
	SceneManager.loaded_complete.connect(_on_loaded_complete)
	
func _on_loaded_complete():
	loading.hide()
