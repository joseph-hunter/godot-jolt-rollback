extends Node3D

class Probe extends RigidBody3D:
	var manager
	var index: int
	var reference := false
	var drive := 0.0
	var gameplay_ticks := 0
	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		var t: int = manager.live_tick if reference else manager.tick
		if reference:
			manager.reference_trace.append(index)
		elif manager.replaying:
			manager.replay_trace.append(index)
			manager.replay_events.append([t, index])
			if manager.scenario == "nested_restore":
				manager.server.rollback_restore_physics(manager.space, manager.handles[manager.start_tick % 241], manager.start_tick)
				return
		else:
			manager.normal_trace.append(index)
		state.apply_central_force(manager.input_for(reference, index) + Vector3(0, 0, drive * 0.01))
		state.apply_torque(Vector3(0, drive * 0.002, 0))
	func _physics_process(delta: float) -> void:
		simulate_tick(delta)
	func simulate_tick(_delta: float) -> void:
		var t: int = manager.live_tick if reference else manager.tick
		drive = drive * 0.9 + manager.input_for(reference, index).x
		gameplay_ticks += 1
		var force := Vector3(0, 0, drive * 0.01)
		if constant_force != force:
			constant_force = force
		if manager.scenario == "sleeping":
			if t == 25:
				sleeping = true
			elif t == 40:
				sleeping = false

var server = PhysicsServer3D
var space: RID
var reference_space: RID
var bodies: Array[Probe] = []
var reference_bodies: Array[Probe] = []
var handles: Array[int] = []
var boundary_tags: Array[int] = []
var gameplay: Array = []
var input_tags: Array[int] = []
var input_history: Array = []
var reference_states: Dictionary = {}
var reference_traces: Dictionary = {}
var tick := 0
var live_tick := 0
var start_tick := 20
var tick_offset := 0
var end_tick := 70
var corrected_start := 20
var selected_inputs: Array = []
var normal_trace: Array[int] = []
var reference_trace: Array[int] = []
var replay_trace: Array[int] = []
var replay_events: Array = []
var replaying := false
var corrected := false
var submitted := false
var corrections := 0
var scenario := "corrected"
var failed := false
var inspections := 0
var stopped_auto := -1
var stopped_replay := -1
var stopped_states: Array = []
var replay_msec := 0.0

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			scenario = arg.trim_prefix("--scenario=")
	if scenario in ["initial", "full_window"]:
		start_tick = 0
		corrected_start = 0
	if scenario == "full_window":
		end_tick = 240
	if scenario == "sleeping":
		start_tick = 30
		corrected_start = 44
	if scenario == "tick_offset":
		tick_offset = 1000
		start_tick += tick_offset
		end_tick += tick_offset
		corrected_start += tick_offset
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 120
	InputMap.add_action("rollback_poc_live_probe")
	Input.action_press("rollback_poc_live_probe")
	handles.resize(241)
	boundary_tags.resize(241)
	boundary_tags.fill(-1)
	gameplay.resize(241)
	input_tags.resize(240)
	input_tags.fill(-1)
	input_history.resize(240)
	var viewport := _make_world()
	space = viewport.world_3d.space
	bodies = _make_bodies(viewport, false)
	var reference := _make_world()
	reference_space = reference.world_3d.space
	reference_bodies = _make_bodies(reference, true)
	_check(server.rollback_register_world(space, _boundary), "Registration failed.")
	for body in bodies:
		_check(server.rollback_register_participant(space, body), "Participant registration failed.")

func _make_world() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	add_child(viewport)
	return viewport

func _make_bodies(parent: Node, reference: bool) -> Array[Probe]:
	var result: Array[Probe] = []
	for i in 2:
		var body := Probe.new()
		body.manager = self
		body.index = i
		body.reference = reference
		body.gravity_scale = 0.0
		body.position = Vector3(-0.55 if i == 0 else 0.55, 0, 0)
		if scenario == "update_error":
			body.position.y = 2.0
		var collision := CollisionShape3D.new()
		collision.shape = SphereShape3D.new()
		body.add_child(collision)
		parent.add_child(body)
		result.append(body)
	if scenario == "update_error" and not reference:
		for i in 3:
			var slab := StaticBody3D.new()
			var collision := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(10, 0.1, 10)
			collision.shape = box
			slab.add_child(collision)
			slab.position.y = float(i) * 0.001
			parent.add_child(slab)
	return result

func _authoritative_input(t: int, i: int) -> Vector3:
	if scenario == "update_error":
		return Vector3(0, -150, 0) if t >= 20 and t <= 50 else Vector3.ZERO
	var direction := 1.0 if i == 0 else -1.0
	if scenario == "sleeping" and t < 40:
		return Vector3.ZERO
	if t >= corrected_start and t < corrected_start + 9:
		return Vector3(direction * 12, 0, direction * 2)
	return Vector3(direction * 6, 0, 0) if t - tick_offset < 40 else Vector3.ZERO

func _predicted_input(t: int, i: int) -> Vector3:
	if scenario == "update_error" and not corrected:
		return Vector3.ZERO
	if not corrected and t >= corrected_start and t < corrected_start + 9:
		return Vector3.ZERO
	return _authoritative_input(t, i)

func input_for(reference: bool, i: int) -> Vector3:
	return _authoritative_input(live_tick, i) if reference else selected_inputs[i]

func _states(actors: Array[Probe]) -> Array:
	var result: Array = []
	for body in actors:
		var state := server.body_get_direct_state(body.get_rid())
		result.append([state.transform, state.linear_velocity, state.angular_velocity,
			state.sleeping, body.constant_force, body.drive, body.gameplay_ticks])
	return result

func _capture(t: int) -> void:
	var slot := t % 241
	handles[slot] = server.rollback_capture_physics(space, t)
	boundary_tags[slot] = t
	gameplay[slot] = [[bodies[0].drive, bodies[0].gameplay_ticks], [bodies[1].drive, bodies[1].gameplay_ticks]]
	_check(handles[slot] > 0, "Boundary capture failed.")

func _boundary(context: Dictionary) -> bool:
	_check(context.replay_available, "Replay capability not advertised.")
	if context.kind == "correction_pending":
		return _correct(context)
	live_tick = context.completed_steps + tick_offset
	tick = live_tick
	_check(context.tick == -1 or context.tick == tick, "Logical and automatic tick mismatch.")
	normal_trace.clear()
	reference_trace.clear()
	selected_inputs = [_predicted_input(tick, 0), _predicted_input(tick, 1)]
	input_tags[tick % 240] = tick
	input_history[tick % 240] = selected_inputs.duplicate()
	reference_states[tick] = _states(reference_bodies)
	_capture(tick)
	if scenario == "manual_outside" and tick == 10:
		_check(not server.rollback_step_manual(space, tick, 1.0 / 120.0), "Uncontrolled manual step accepted.")
	if corrected:
		_check(_states(bodies) == reference_states[tick], "Corrected boundary diverged at tick %d." % tick)
	return not failed

func _correct(context: Dictionary) -> bool:
	var started := Time.get_ticks_usec()
	corrections += 1
	_check(context.completed_steps == end_tick - tick_offset and context.tick == end_tick, "Correction entered at wrong current boundary.")
	reference_states[end_tick] = _states(reference_bodies)
	_check(_states(bodies) != reference_states[end_tick], "Test did not introduce a divergent predicted timeline.")
	var requested_end := end_tick - 1 if scenario == "wrong_end" else end_tick
	var ok: bool = server.rollback_begin_replay(space, handles[start_tick % 241], start_tick, requested_end)
	if scenario == "wrong_end":
		_check(not ok, "Replay with a wrong ending boundary was accepted.")
		return true
	_check(ok and boundary_tags[start_tick % 241] == start_tick, "Replay begin/starting boundary failed.")
	if scenario == "duplicate_begin":
		_check(not server.rollback_begin_replay(space, handles[start_tick % 241], start_tick, end_tick), "Nested replay session accepted.")
		return true
	var restored_game: Array = gameplay[start_tick % 241]
	for i in 2:
		bodies[i].drive = restored_game[i][0]
		bodies[i].gameplay_ticks = restored_game[i][1]
	corrected = true
	replaying = true
	if scenario == "missing_input":
		input_tags[start_tick % 240] = -1
	for t in range(start_tick, end_tick):
		tick = t
		if input_tags[t % 240] != t:
			server.rollback_fail_world(space, "Required retained replay input is missing.")
			return false
		# Replace wrong predictions in retained history, not the global live Input state.
		input_history[t % 240] = [_authoritative_input(t, 0), _authoritative_input(t, 1)]
		selected_inputs = input_history[t % 240]
		replay_trace.clear()
		if scenario == "step_without_flush":
			_check(not server.rollback_step_manual(space, t, 1.0 / 120.0), "Step preceding callback delivery accepted.")
			return true
		ok = server.rollback_flush_replay_callbacks(space, t)
		if scenario == "nested_restore":
			_check(not ok, "Nested restore inside integration was accepted.")
			return true
		_check(ok, "Replay callback flush failed.")
		if scenario == "capture_after_flush":
			_check(server.rollback_capture_physics(space, t) == 0, "Post-callback snapshot accepted as a boundary.")
			return true
		_check(replay_trace == reference_traces[t], "Historical callback eligibility/order mismatch at tick %d." % t)
		if scenario == "duplicate_flush":
			_check(not server.rollback_flush_replay_callbacks(space, t), "Duplicate callback flush accepted.")
			return true
		for body in bodies:
			body.simulate_tick(1.0 / 120.0)
		var delta := 1.0 / 60.0 if scenario == "wrong_delta" else 1.0 / 120.0
		ok = server.rollback_step_manual(space, t, delta)
		if scenario == "update_error" and not ok:
			_check(server.rollback_get_world_status(space).error.begins_with("Jolt update failed with error flags"), "Manual update error was not propagated.")
			return true
		if scenario == "wrong_delta":
			_check(not ok, "Wrong replay delta accepted.")
			return true
		_check(ok, "Complete replay step failed.")
		_check(_states(bodies) == reference_states[t + 1], "Corrected replay diverged at boundary %d." % (t + 1))
		if scenario == "double_step":
			_check(not server.rollback_step_manual(space, t, delta), "Repeated historical step accepted.")
			return true
		if scenario == "unfinished":
			return true
		if scenario == "missing_intermediate_capture":
			_check(not server.rollback_flush_replay_callbacks(space, t + 1), "Replay advanced without replacing an intermediate snapshot.")
			return true
		if scenario != "missing_final_capture" or t + 1 != end_tick:
			_capture(t + 1)
		if scenario == "release_current_capture" and t + 1 == end_tick:
			_check(not server.rollback_release_snapshot(space, handles[end_tick % 241]), "Current corrected ending snapshot was released during replay.")
			return true
	if scenario == "update_error":
		_fail("Replay did not exceed the configured contact capacity.")
		return false
	if scenario == "final_flush":
		_check(not server.rollback_flush_replay_callbacks(space, end_tick), "Final boundary callbacks consumed during replay.")
		return true
	ok = server.rollback_finish_replay(space, end_tick)
	if scenario == "missing_final_capture":
		_check(not ok, "Replay finished without a corrected final snapshot.")
		return true
	_check(ok, "Replay finish failed.")
	var status: Dictionary = server.rollback_get_world_status(space)
	_check(status.completed_steps == end_tick - tick_offset, "Replay altered the automatic step counter.")
	_check(status.replay_steps == end_tick - start_tick and not status.replay_active, "Missing/duplicate historical steps.")
	for event in replay_events:
		_check(event[0] < end_tick, "Final boundary integration ran during replay.")
	_check(Input.is_action_pressed("rollback_poc_live_probe"), "Replay changed global live input state.")
	replaying = false
	replay_msec = float(Time.get_ticks_usec() - started) / 1000.0
	tick = end_tick
	return not failed

func _physics_process(_delta: float) -> void:
	if failed:
		return
	var status: Dictionary = server.rollback_get_world_status(space)
	if status.failed:
		_verify_stopped(status)
		return
	reference_traces[live_tick] = reference_trace.duplicate()
	if corrected:
		_check(normal_trace == reference_trace, "Final/live boundary callbacks were missed or duplicated.")
		_check(status.completed_steps == live_tick - tick_offset, "Upcoming normal tick stepped early or twice.")
		_check(status.replay_steps == end_tick - start_tick, "Unexpected later manual advancement.")
		_check(_states(bodies) == _states(reference_bodies), "Normal continuation differs from authoritative reference.")
		for body in bodies:
			_check(body.global_transform.is_equal_approx(server.body_get_direct_state(body.get_rid()).transform), "Normal flush exposed stale node state.")
		if live_tick == end_tick + 8:
			_check(corrections == 1, "Correction session was duplicated.")
			_pass()
	if live_tick == end_tick - 1 and not submitted:
		submitted = true
		_check(server.rollback_request_correction(space, 1), "Correction request rejected.")
	if live_tick > end_tick + 20:
		_fail("Scenario timed out.")

func _verify_stopped(status: Dictionary) -> void:
	_check(scenario not in ["corrected", "initial", "sleeping", "full_window", "tick_offset"], "Unexpected failure: %s" % status.error)
	if stopped_auto < 0:
		stopped_auto = status.completed_steps
		stopped_replay = status.replay_steps
		stopped_states = _states(bodies)
	_check(status.completed_steps == stopped_auto and status.replay_steps == stopped_replay, "Failed world advanced.")
	_check(_states(bodies) == stopped_states, "Failed physics/gameplay state changed.")
	for body in bodies:
		_check(not body.is_physics_processing(), "Failed participant kept processing.")
	inspections += 1
	if inspections == 10:
		_check(reference_bodies[0].gameplay_ticks > bodies[0].gameplay_ticks, "Unaffected world/gameplay stopped.")
		_pass()

func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	push_error("REPLAY TEST FAIL [%s]: %s" % [scenario, message])
	get_tree().quit(1)

func _pass() -> void:
	if not failed:
		Input.action_release("rollback_poc_live_probe")
		print("REPLAY TEST PASS [%s]: %d historical ticks, final boundary %d, replay %.2f ms" % [scenario, server.rollback_get_world_status(space).replay_steps, end_tick, replay_msec])
		get_tree().quit(0)
