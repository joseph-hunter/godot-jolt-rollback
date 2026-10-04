extends RigidBody3D

@export var move_speed: float = 5.0
@export var jump_speed: float = 6.0

var _direction: Vector3 = Vector3.ZERO
var _jump_pending: bool = false


func _ready() -> void:
	lock_rotation = true
	can_sleep = false
	max_contacts_reported = 4


func set_controls(direction: Vector3, jump: bool) -> void:
	_direction = direction
	# Keep a jump edge even if multiple messages arrive before a physics step.
	_jump_pending = _jump_pending or jump


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var velocity := state.linear_velocity
	velocity.x = _direction.x * move_speed
	velocity.z = _direction.z * move_speed

	var grounded := false
	for contact in range(state.get_contact_count()):
		if state.get_contact_local_normal(contact).dot(Vector3.UP) > 0.7:
			grounded = true
			break

	if _jump_pending and grounded:
		velocity.y = jump_speed
	_jump_pending = false
	state.linear_velocity = velocity
