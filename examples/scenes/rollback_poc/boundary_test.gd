extends Node3D
## Phase 2 integration test. No restore/replay is claimed by this scene.

class ProbeBody extends RigidBody3D:
	var coordinator
	var participant_id: int
	var integration_count := 0
	var last_integration_tick := -1

	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		integration_count += 1
		last_integration_tick = coordinator.tick
		coordinator.events.append("integrate:%d" % participant_id)
		state.apply_central_force(coordinator.tick_inputs[participant_id])

class CallbackOwner extends RefCounted:
	func prepare(_context: Dictionary) -> bool:
		return true

var server = PhysicsServer3D
var space: RID
var reference_space: RID
var tick := -1
var tick_inputs: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var events: Array[String] = []
var bodies: Array[ProbeBody] = []
var reference_bodies: Array[ProbeBody] = []
var scenario := "normal"
var physics_count := 0
var boundary_count := 0
var correction_count := 0
var failed := false
var stopped_at := -1
var stopped_transforms: Array[Transform3D] = []
var stopped_integrations: Array[int] = []
var sleeping_integrations: Array[int] = []
var request_submitted := false
var callback_owner: CallbackOwner

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scenario="):
			scenario = argument.trim_prefix("--scenario=")
	if not server.has_method("rollback_register_world"):
		_fail("Rebuild and install the rollback extension before running this test.")
		return
	if Engine.get_version_info().major != 4 or Engine.get_version_info().minor != 6:
		_fail("This test must run on Godot 4.6.")
		return
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 120
	var registered_world := _create_world()
	space = registered_world.world_3d.space
	bodies = _create_bodies(registered_world)
	var reference_world := _create_world()
	reference_space = reference_world.world_3d.space
	reference_bodies = _create_bodies(reference_world)
	_check(server.rollback_register_world(space, _boundary), "World registration failed.")
	_check(server.rollback_get_world_status(space).registered, "Missing registration status.")
	if scenario == "duplicate":
		_check(not server.rollback_register_world(space, _boundary), "Duplicate registration accepted.")
	elif scenario == "invalid_return":
		_check(server.rollback_unregister_world(space), "Cannot detach initial manager.")
		_check(server.rollback_register_world(space, _invalid_boundary), "Invalid-return manager registration failed.")
	elif scenario == "destroyed_space":
		var temporary_space: RID = server.space_create()
		server.space_set_active(temporary_space, true)
		_check(server.rollback_register_world(temporary_space, _boundary), "Temporary world registration failed.")
		server.free_rid(temporary_space) # Its manager must never be invoked.
	elif scenario == "owner_destroyed":
		_check(server.rollback_unregister_world(space), "Cannot detach initial manager.")
		callback_owner = CallbackOwner.new()
		_check(server.rollback_register_world(space, callback_owner.prepare), "Owner registration failed.")
		callback_owner = null
	elif scenario == "inactive":
		server.space_set_active(space, false)
		server.space_set_active(reference_space, false)

func _create_world() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	add_child(viewport)
	return viewport

func _create_bodies(parent: Node) -> Array[ProbeBody]:
	var result: Array[ProbeBody] = []
	for index in 2:
		var body := ProbeBody.new()
		body.coordinator = self
		body.participant_id = index
		body.gravity_scale = 0.0
		body.linear_damp = 0.0
		body.angular_damp = 0.0
		body.position = Vector3(-0.55 if index == 0 else 0.55, 0, 0)
		var collision := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 0.5
		collision.shape = shape
		body.add_child(collision)
		parent.add_child(body)
		result.append(body)
	return result

func _boundary(context: Dictionary) -> bool:
	_check(context.space == space, "Callback selected the wrong world.")
	_check(is_equal_approx(context.delta, 1.0 / 120.0), "Incorrect boundary delta.")
	_check(context.replay_available, "Phase 4 replay capability is missing.")
	if context.kind == "correction_pending":
		correction_count += 1
		_check(context.request_count == 2, "Correction requests were not coalesced.")
		_check(context.request_id == 22, "Wrong latest correction request ID.")
		return true # Backend must stop: this callback never completes a replay session.
	_check(context.kind == "normal_boundary", "Unexpected callback kind.")
	boundary_count += 1
	_check(context.completed_steps == tick + 1, "Missing or duplicate automatic step.")
	tick = context.completed_steps
	events.clear()
	events.append("boundary")
	# Both worlds use the same selected input, including during callback flushing.
	tick_inputs[0] = Vector3(6, 0, 0) if tick < 30 else Vector3.ZERO
	tick_inputs[1] = Vector3(-6, 0, 0) if tick < 30 else Vector3.ZERO
	if tick == 10:
		if scenario in ["callback_failure", "unregister_failed"]:
			return false
		if scenario == "explicit_failure":
			server.rollback_fail_world(space, "Injected manager failure.")
		if scenario == "reentrant_request":
			_check(not server.rollback_request_correction(space, 33), "Reentrant request accepted.")
	return true

func _invalid_boundary(context: Dictionary) -> Variant:
	_boundary(context)
	return null if context.completed_steps == 10 else true

func _physics_process(_delta: float) -> void:
	if failed:
		return
	physics_count += 1
	var status: Dictionary = server.rollback_get_world_status(space)
	if scenario == "inactive":
		if physics_count == 5:
			_check(boundary_count == 0 and status.completed_steps == 0, "Inactive world advanced.")
			_activate_worlds()
		if tick < 0:
			return
	if status.failed:
		_verify_stopped(status)
		return
	_check(tick >= 0 and boundary_count > 0, "Physics processing preceded boundary notification.")
	_check(events[0] == "boundary", "Force integration preceded tick input selection.")
	for index in 2:
		var body := bodies[index]
		var reference := reference_bodies[index]
		_check(body.integration_count == reference.integration_count, "Changed normal callback eligibility.")
		_check(body.global_transform.is_equal_approx(reference.global_transform), "Opt-in changed physics state.")
		_check(body.linear_velocity.is_equal_approx(reference.linear_velocity), "Opt-in changed velocity.")
		var direct := server.body_get_direct_state(body.get_rid())
		_check(body.global_transform.is_equal_approx(direct.transform), "Node state is not synchronized before gameplay.")
		if events.has("integrate:%d" % index):
			_check(body.last_integration_tick == tick, "Integration callback used stale tick input.")
	if scenario == "sleep_wake":
		if tick == 120:
			for index in 2:
				bodies[index].sleeping = true
				reference_bodies[index].sleeping = true
				sleeping_integrations.append(bodies[index].integration_count)
		if tick > 121 and tick <= 140:
			for index in 2:
				_check(bodies[index].integration_count == sleeping_integrations[index], "Sleeping body received extra integration callbacks.")
		if tick == 140:
			for index in 2:
				bodies[index].sleeping = false
				reference_bodies[index].sleeping = false
		if tick == 142:
			for index in 2:
				_check(bodies[index].integration_count > sleeping_integrations[index], "Waking did not restore callback eligibility.")
	if tick == 12 and not request_submitted:
		request_submitted = true
		if scenario == "correction":
			_check(server.rollback_request_correction(space, 11), "First correction request rejected.")
			_check(server.rollback_request_correction(space, 22), "Second correction request rejected.")
			_check(correction_count == 0, "Correction was dispatched immediately.")
		elif scenario == "configuration":
			Engine.time_scale = 0.5
	if tick >= (145 if scenario == "sleep_wake" else 90):
		_check(bodies[0].global_position.x < bodies[1].global_position.x, "Interacting spheres passed through each other.")
		_finish()
	if physics_count > 180:
		_fail("Test timed out without the expected outcome.")

func _verify_stopped(status: Dictionary) -> void:
	_check(scenario in ["correction", "callback_failure", "explicit_failure", "owner_destroyed", "configuration", "invalid_return", "unregister_failed"],
		"Unexpected stopped world: %s" % status.error)
	_check(not status.error.is_empty(), "Stopped world has no error.")
	if stopped_at < 0:
		stopped_at = status.completed_steps
		for body in bodies:
			stopped_transforms.append(server.body_get_direct_state(body.get_rid()).transform)
			stopped_integrations.append(body.integration_count)
		if scenario == "unregister_failed":
			_detach_failed_manager()
	if status.registered:
		_check(status.completed_steps == stopped_at, "Failed world advanced automatically.")
	for index in 2:
		_check(server.body_get_direct_state(bodies[index].get_rid()).transform.is_equal_approx(stopped_transforms[index]),
			"Failed world transform changed.")
		_check(bodies[index].integration_count == stopped_integrations[index], "Failed world delivered callbacks.")
	if physics_count >= 35:
		_check(reference_bodies[0].integration_count > bodies[0].integration_count, "Unaffected world stopped too.")
		if scenario == "correction":
			_check(correction_count == 1, "Correction notification was duplicated.")
		_finish()

func _detach_failed_manager() -> void:
	await get_tree().process_frame
	_check(server.rollback_unregister_world(space), "Failed manager could not be detached.")
	_check(server.rollback_get_world_status(space).failed, "Detaching a manager cleared its failure.")
	_check(not server.rollback_register_world(space, _boundary), "Failed world was registered without a reset.")

func _activate_worlds() -> void:
	await get_tree().process_frame
	server.space_set_active(space, true)
	server.space_set_active(reference_space, true)

func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	push_error("BOUNDARY TEST FAIL [%s]: %s" % [scenario, message])
	get_tree().quit(1)

func _finish() -> void:
	if failed:
		return
	Engine.time_scale = 1.0
	print("BOUNDARY TEST PASS [%s]: %d boundaries, %d physics callbacks" % [scenario, boundary_count, bodies[0].integration_count])
	get_tree().quit(0)
