extends Node3D

class Probe extends RigidBody3D:
	var manager
	var index: int
	var observed := false
	var integrations := 0 # Instrumentation, not simulation state.
	var gameplay_value := 0
	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		integrations += 1
		if observed:
			manager.trace.append(index)
		state.apply_central_force(manager.inputs[index] + Vector3(0, float(gameplay_value % 3) * 0.01, 0))
	func _physics_process(_delta: float) -> void:
		gameplay_value += 1

var server = PhysicsServer3D
var space: RID
var other_space: RID
var bodies: Array[Probe] = []
var other_bodies: Array[Probe] = []
var inputs: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var trace: Array[int] = []
var expected: Dictionary = {}
var expected_traces: Dictionary = {}
var handle := 0
var saved_tick := 20
var tick := -1
var steps := 0
var restored := false
var saved_gameplay: Array[int] = []
var scenario := "restore_active"
var failed := false
var stopped_at := -1
var stopped_states: Array = []
var stopped_gameplay: Array[int] = []
var stopped_integrations: Array[int] = []
var inspections := 0

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			scenario = arg.trim_prefix("--scenario=")
	Engine.physics_ticks_per_second = 120
	Engine.time_scale = 1.0
	if scenario == "restore_initial":
		saved_tick = 0
	elif scenario == "restore_sleeping":
		saved_tick = 45
	elif scenario == "ring_wrap":
		saved_tick = 0
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	add_child(viewport)
	space = viewport.world_3d.space
	bodies = _make_bodies(viewport, true)
	if scenario == "update_error":
		# Three overlapping static slabs produce six sphere/slab pairs, exceeding
		# the smallest supported cache size of four without invalid Jolt settings.
		for i in 3:
			var floor_body := StaticBody3D.new()
			var collision := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(10, 0.1, 10)
			collision.shape = box
			floor_body.add_child(collision)
			floor_body.position.y = -0.5 + float(i) * 0.001
			viewport.add_child(floor_body)
	var reference := SubViewport.new()
	reference.world_3d = World3D.new()
	add_child(reference)
	other_space = reference.world_3d.space
	other_bodies = _make_bodies(reference, false)
	_check(server.rollback_register_world(space, _boundary), "Registration failed.")
	for body in bodies:
		_check(server.rollback_register_participant(space, body), "Participant registration failed.")

func _make_bodies(parent: Node, observed: bool) -> Array[Probe]:
	var result: Array[Probe] = []
	for i in 2:
		var body := Probe.new()
		body.manager = self
		body.index = i
		body.observed = observed
		body.gravity_scale = 0.0
		body.position = Vector3(-0.55 if i == 0 else 0.55, 0, 0)
		var shape := CollisionShape3D.new()
		shape.shape = SphereShape3D.new()
		body.add_child(shape)
		parent.add_child(body)
		result.append(body)
	return result

func _states() -> Array:
	var result: Array = []
	for body in bodies:
		var state := server.body_get_direct_state(body.get_rid())
		result.append([state.transform, state.linear_velocity, state.angular_velocity, state.sleeping,
			body.constant_force, body.constant_torque, state.total_gravity, state.total_linear_damp, state.total_angular_damp, body.can_sleep])
	return result

func _boundary(context: Dictionary) -> bool:
	steps = context.completed_steps
	_check(context.restoration_available and context.replay_available, "Wrong milestone capabilities.")
	trace.clear()
	tick = saved_tick + steps - 70 if restored else steps
	if scenario == "restore_sleeping_pending" and tick == saved_tick and not restored:
		# The preceding active step queued a callback. Sleeping now must not
		# erase that pending eligibility from the captured boundary.
		for body in bodies:
			body.sleeping = true
	if not restored:
		expected[tick] = _states()
	if tick == saved_tick and not restored:
		for body in bodies:
			saved_gameplay.append(body.gameplay_value)
		handle = server.rollback_capture_physics(space, tick)
		_check(handle > 0, "Capture failed.")
	if scenario == "ring_wrap" and steps <= 241:
		var current_handle: int = server.rollback_capture_physics(space, steps)
		if steps == 0:
			handle = current_handle
		if steps == 240:
			var status: Dictionary = server.rollback_get_world_status(space)
			_check(status.snapshot_count == 241 and status.oldest_snapshot_tick == 0, "Starting boundary was lost before all 240 input ticks could be retained.")
		if steps == 241:
			_check(server.rollback_get_world_status(space).oldest_snapshot_tick == 1, "Ring overwrite did not advance exact tick tags.")
	if (steps == 70 and scenario != "ring_wrap") or (scenario == "ring_wrap" and steps == 242):
		var before_states := _states()
		var before_integrations := [bodies[0].integrations, bodies[1].integrations]
		var target_space := other_space if scenario == "wrong_world" else space
		var target_tick := saved_tick + 1 if scenario == "wrong_tick" else saved_tick
		var ok: bool = server.rollback_restore_physics(target_space, handle, target_tick)
		if scenario in ["stale_handle", "wrong_tick", "wrong_world", "incompatible_mass", "incompatible_shape", "ring_wrap", "unsupported_area", "changed_environment"]:
			_check(not ok, "Invalid restoration was accepted.")
			_check(_states() == before_states, "Rejected restore partially mutated physics.")
			# Wrong-world access is rejected before touching either world; stop the selected world.
			if scenario == "wrong_world":
				server.rollback_fail_world(space, "Wrong-world restore was rejected.")
			return true
		_check(ok, "Restoration failed.")
		_check(_states() == expected[saved_tick], "Physical/wrapper boundary state was not restored exactly.")
		# Read again from the same owned recorder to exercise repeated restore/rewind.
		_check(server.rollback_restore_physics(space, handle, saved_tick), "Second restore failed.")
		for i in 2:
			_check(bodies[i].integrations == before_integrations[i], "Restoration invented force integration.")
			_check(bodies[i].global_transform.is_equal_approx(expected[saved_tick][i][0]), "Restored node pose is stale.")
			_check(bodies[i].linear_velocity == expected[saved_tick][i][1], "Restored node velocity is stale.")
			_check(bodies[i].sleeping == expected[saved_tick][i][3], "Restored node sleeping state is stale.")
			_check(bodies[i].can_sleep == expected[saved_tick][i][9], "Restored node allow-sleep state is stale.")
			bodies[i].gameplay_value = saved_gameplay[i]
		restored = true
		tick = saved_tick
	if restored:
		_check(_states() == expected[tick], "Restored continuation diverged at boundary %d." % tick)
	inputs[0] = Vector3(6, 0, 0) if tick < 30 else Vector3.ZERO
	inputs[1] = Vector3(-6, 0, 0) if tick < 30 else Vector3.ZERO
	return not failed

func _physics_process(_delta: float) -> void:
	if failed:
		return
	var status: Dictionary = server.rollback_get_world_status(space)
	if status.failed:
		_verify_stopped(status)
		return
	if restored:
		_check(trace == expected_traces[tick], "Restored callback eligibility/order differed at tick %d." % tick)
	else:
		expected_traces[tick] = trace.duplicate()
	if scenario == "restore_sleeping" and tick == 40:
		for body in bodies:
			body.sleeping = true
	if tick == 50 and not restored:
		for body in bodies:
			body.global_position += Vector3(0, 3, 0)
			body.sleeping = false
			body.can_sleep = false
			body.constant_force = Vector3(0, 0, 2)
			body.constant_torque = Vector3(0, 1, 0)
	if tick == 55 and not restored:
		if scenario == "unsafe_capture":
			_check(server.rollback_capture_physics(space, tick) == 0, "Capture outside the manager boundary was accepted.")
			return
		if scenario == "stale_handle":
			_check(server.rollback_release_snapshot(space, handle), "Release failed.")
		elif scenario == "incompatible_mass":
			bodies[0].mass = 2.0
		elif scenario == "incompatible_shape":
			bodies[0].get_child(0).shape.radius = 0.9
		elif scenario == "changed_environment":
			server.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, 5.0)
		elif scenario == "unsupported_area":
			var area := Area3D.new()
			var shape := CollisionShape3D.new()
			shape.shape = BoxShape3D.new()
			area.add_child(shape)
			bodies[0].get_parent().add_child(area)
	if restored and tick == 49:
		_pass()
	if steps > 260:
		_fail("Scenario timed out.")

func _verify_stopped(status: Dictionary) -> void:
	if scenario == "update_error":
		_check(status.error.begins_with("Jolt update failed with error flags"), "Expected a propagated Jolt update error.")
	if stopped_at < 0:
		stopped_at = status.completed_steps
		stopped_states = _states()
		for body in bodies:
			stopped_gameplay.append(body.gameplay_value)
			stopped_integrations.append(body.integrations)
	_check(status.completed_steps == stopped_at and _states() == stopped_states, "Failed physics advanced.")
	for i in 2:
		_check(bodies[i].gameplay_value == stopped_gameplay[i], "Failed participant gameplay advanced.")
		_check(bodies[i].integrations == stopped_integrations[i], "Failed world delivered integration.")
		_check(not bodies[i].is_physics_processing(), "Participant physics processing remained enabled.")
	inspections += 1
	if inspections == 10:
		_check(other_bodies[0].gameplay_value > bodies[0].gameplay_value, "Unaffected gameplay stopped.")
		_pass()

func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	failed = true
	push_error("SNAPSHOT TEST FAIL [%s]: %s" % [scenario, message])
	get_tree().quit(1)

func _pass() -> void:
	if not failed:
		print("SNAPSHOT TEST PASS [%s]" % scenario)
		get_tree().quit(0)
