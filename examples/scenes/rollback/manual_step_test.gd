extends Node3D

# Single-world baseline. Physics runs normally until manual stepping is added.
@onready var player: RigidBody3D = $RigidBody3D
var _jump_held: bool = false


func _physics_process(_delta: float) -> void:
	var direction := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		0.0,
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	).normalized()
	var held := Input.is_physical_key_pressed(KEY_SPACE)
	var jump := held and not _jump_held
	_jump_held = held
	if not get_window().has_focus():
		direction = Vector3.ZERO
		jump = false
	player.set_controls(direction, jump)
