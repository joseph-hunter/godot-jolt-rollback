extends Node3D

const Manager = preload("res://rollback/rollback_manager.gd")

class Probe extends RigidBody3D:
	var owner_test
	var index := 0
	var reference := false
	var memory := {"drive": [0.0], "samples": PackedFloat32Array([0]), "ticks": 0}
	func rollback_save() -> Dictionary:
		if owner_test.scenario == "snapshot_object" and memory.ticks == 10 and not reference:
			return {"node": self}
		return memory
	func rollback_restore(state: Dictionary) -> bool:
		memory = state
		if index == 0:
			owner_test.trace.clear()
		return owner_test.scenario != "restore_failure"
	func rollback_simulate(input: Vector3, _delta: float) -> bool:
		if owner_test.scenario == "gameplay_failure" and memory.ticks == 10 and not reference:
			return false
		memory.drive[0] = memory.drive[0] * 0.9 + input.x
		memory.samples[0] += input.x
		memory.ticks += 1
		constant_force = Vector3(0, 0, memory.drive[0] * 0.01)
		var tick: int = owner_test.manager.current_tick
		if owner_test.scenario == "sleeping":
			if tick == 25:
				sleeping = true
			if tick == 40:
				sleeping = false
		if not reference:
			owner_test.manager.present(StringName(str(index)), tick)
			if owner_test.manager.replaying and index == 1:
				owner_test.check(owner_test.trace == owner_test.trace_history[tick], "Historical integration order/eligibility differs at %d" % tick)
				for i in 2:
					owner_test.check(owner_test.bodies[i].memory == owner_test.game_history[tick][i], "Historical gameplay differs at %d: %s vs %s" % [tick, owner_test.bodies[i].memory, owner_test.game_history[tick][i]])
				owner_test.trace.clear()
		return true
	func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
		if owner_test.detaching:
			return
		var tick: int = owner_test.manager.current_tick
		var input: Vector3 = owner_test.authoritative(tick, index) if reference else owner_test.manager.input_for(StringName(str(index)))
		var trace: Array = owner_test.reference_trace if reference else owner_test.trace
		trace.append(index)
		state.apply_central_force(input + Vector3(0, 0, memory.drive[0] * 0.01))
		state.apply_torque(Vector3(0, memory.drive[0] * 0.002, 0))
	func _physics_process(delta: float) -> void:
		if owner_test.detaching:
			return
		rollback_simulate(owner_test.authoritative(owner_test.manager.current_tick, index), delta)

var manager
var server = PhysicsServer3D
var bodies: Array = []
var references: Array = []
var trace: Array = []
var reference_trace: Array = []
var trace_history: Dictionary = {}
var game_history: Dictionary = {}
var scenario := "corrected"
var origin := 0
var correction_tick := 20
var end_tick := 70
var corrected_count := 0
var provider_calls := 0
var events := 0
var bad := false
var stop_checks := 0
var stopped_ticks := -1
var stopped_steps := -1
var detaching := false

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			scenario = arg.trim_prefix("--scenario=")
	if scenario == "full_window":
		correction_tick = 0
		end_tick = 240
	if scenario == "wrap":
		correction_tick = 270
		end_tick = 320
	if scenario == "stale":
		end_tick = 250
	if scenario == "offset":
		origin = 1000
		correction_tick += origin
		end_tick += origin
	if scenario == "sleeping":
		correction_tick = 44
	Engine.physics_ticks_per_second = 120
	Engine.time_scale = 1.0
	process_physics_priority = 100
	manager = Manager.new()
	add_child(manager)
	var world := make_world()
	bodies = make_bodies(world, false)
	references = make_bodies(make_world(), true)
	for i in [1, 0]:
		check(manager.add_participant(StringName(str(i)), bodies[i]), "Participant setup failed")
	check(not manager.add_participant(&"0", bodies[0]), "Duplicate ID accepted")
	check(not manager.add_participant(&"other", bodies[0]), "Duplicate node accepted")
	manager.corrected.connect(func(begin, end):
		corrected_count += 1
		check(begin == correction_tick and end == end_tick, "Wrong coalesced range")
		if scenario == "repeated" and corrected_count == 1:
			correction_tick = 80
			end_tick = 110
		trace.clear())
	manager.presentation_event.connect(func(_id, _event): events += 1)
	check(manager.start(world.world_3d.space, provide, origin), "Manager start failed")
	if scenario == "future":
		for tick in range(correction_tick, correction_tick + 9):
			check(manager.submit_input(tick, frame(tick)), "Future input rejected")

func make_world() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	add_child(viewport)
	return viewport

func make_bodies(parent: Node, reference: bool) -> Array:
	var result := []
	for i in 2:
		var body := Probe.new()
		body.owner_test = self
		body.index = i
		body.reference = reference
		body.gravity_scale = 0.0
		body.position.x = -0.55 if i == 0 else 0.55
		var shape := CollisionShape3D.new()
		shape.shape = SphereShape3D.new()
		body.add_child(shape)
		parent.add_child(body)
		result.append(body)
	return result

func authoritative(tick: int, index: int) -> Vector3:
	var sign_value := 1.0 if index == 0 else -1.0
	if scenario == "sleeping" and tick < 40:
		return Vector3.ZERO
	if tick >= correction_tick and tick < correction_tick + 9:
		return Vector3(sign_value * 12, 0, sign_value * 2)
	return Vector3(sign_value * 6, 0, 0) if tick - origin < 40 else Vector3.ZERO

func frame(tick: int) -> Dictionary:
	return {&"0": authoritative(tick, 0), &"1": authoritative(tick, 1)}

func provide(tick: int) -> Variant:
	provider_calls += 1
	trace.clear()
	reference_trace.clear()
	if matches_reference(tick):
		check(states(bodies) == states(references), "Boundary differs from reference at %d" % tick)
	if scenario == "missing" and tick == 10:
		return {}
	if scenario == "object" and tick == 10:
		return {&"0": self, &"1": Vector3.ZERO}
	var result := frame(tick)
	if tick >= correction_tick and tick < correction_tick + 9 and scenario not in ["unchanged", "detach"]:
		result = {&"0": Vector3.ZERO, &"1": Vector3.ZERO}
	return result

func states(actors: Array) -> Array:
	var result := []
	for body in actors:
		var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
		result.append([state.transform, state.linear_velocity, state.angular_velocity, state.sleeping, Manager._copy(body.memory), body.constant_force])
	return result

func matches_reference(tick: int) -> bool:
	if scenario == "repeated" and corrected_count == 1 and tick >= 80:
		return false
	return corrected_count > 0 or scenario in ["future", "unchanged", "detach"]

func _physics_process(_delta: float) -> void:
	if bad:
		return
	if detaching:
		return
	var tick: int = manager.current_tick
	var status: Dictionary = server.rollback_get_world_status(manager._space)
	if manager.failed:
		check(scenario in ["stale", "missing", "object", "backend_failure", "snapshot_object", "restore_failure", "gameplay_failure"], "Unexpected manager failure: " + manager.failure_reason)
		if stopped_ticks < 0:
			stopped_ticks = bodies[0].memory.ticks
			stopped_steps = status.completed_steps
		check(bodies[0].memory.ticks == stopped_ticks and status.completed_steps == stopped_steps, "Failed simulation advanced")
		stop_checks += 1
		if stop_checks == 10:
			check(references[0].memory.ticks > stopped_ticks, "Reference stopped with failed manager")
			passed()
		return
	trace_history[tick] = reference_trace.duplicate()
	game_history[tick] = [Manager._copy(references[0].memory), Manager._copy(references[1].memory)]
	if matches_reference(tick):
		check(trace == reference_trace, "Final/normal integration order differs")
		check(states(bodies) == states(references), "Gameplay differs after correction")
	check(events == 2 * (tick - origin + 1), "Historical presentation duplicated or normal event lost")
	if scenario == "backend_failure" and tick == 10:
		server.rollback_fail_world(manager._space, "Injected backend failure")
	if scenario == "detach" and tick == 10:
		detaching = true
		check(await manager.detach(), "Idle detach failed")
		check(not server.rollback_get_world_status(manager._space).registered, "Detach retained registration")
		manager.queue_free()
		await get_tree().process_frame
		check(not server.rollback_get_world_status(bodies[0].get_world_3d().space).failed, "Detached callback owner failed the ordinary world")
		passed()
		return
	if tick == end_tick - 1 and scenario not in ["future", "missing", "object", "backend_failure", "snapshot_object", "gameplay_failure"]:
		if scenario == "stale":
			check(not manager.submit_input(0, frame(0)), "Stale correction accepted")
		else:
			# Reordered corrections must result in one earliest-start session.
			for t in range(correction_tick + 8, correction_tick - 1, -1):
				var input := frame(t)
				check(manager.submit_input(t, input), "Correction rejected")
				input[&"0"] = Vector3(999, 999, 999)
	if tick == end_tick + 8:
		var expected_sessions := 0 if scenario in ["future", "unchanged"] else (2 if scenario == "repeated" else 1)
		var expected_steps := 0 if scenario in ["future", "unchanged"] else (80 if scenario == "repeated" else end_tick - correction_tick)
		check(corrected_count == expected_sessions, "Session count wrong")
		check(status.replay_steps == expected_steps, "Replay step count wrong")
		check(status.completed_steps == tick - origin, "Upcoming automatic tick advanced more than once")
		check(provider_calls == tick - origin + 1 - (9 if scenario == "future" else 0), "Live provider ran in replay")
		passed()

func check(condition: bool, message: String) -> void:
	if not condition and not bad:
		bad = true
		push_error("MANAGER TEST FAIL [%s]: %s" % [scenario, message])
		get_tree().quit(1)

func passed() -> void:
	if not bad:
		print("MANAGER TEST PASS [%s]" % scenario)
		get_tree().quit(0)
