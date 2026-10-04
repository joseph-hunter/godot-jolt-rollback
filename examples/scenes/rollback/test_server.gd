extends Node

const MAX_BUFFER_FRAMES := 512
@export_range(1, 60, 1) var buffer_target: int = 4
var players: Array[RigidBody3D] = []
var input_buffers: Dictionary = {}
var physics_tick: int = 0


func setup(first: RigidBody3D) -> void:
	var positions := [Vector3(-1.5, 0.5, -1.5), Vector3(1.5, 0.5, -1.5),
		Vector3(-1.5, 0.5, 1.5), Vector3(1.5, 0.5, 1.5)]
	for index in range(4):
		var player := first if index == 0 else first.duplicate() as RigidBody3D
		player.position = positions[index]
		if index > 0:
			player.name = "Player%d" % (index + 1)
			first.get_parent().add_child(player)
			input_buffers[index] = {
				"frames": [], "started": false, "last_received": 0,
				"last_consumed": 0, "direction": Vector3.ZERO,
				"underflows": 0, "overflows": 0, "expired": 0,
				"consume_credit": 0.0, "consume_rate": 1.0, "average_depth": 0.0,
			}
		players.append(player)


func set_host_input(direction: Vector3, jump: bool) -> void:
	players[0].set_controls(direction, jump)


func receive_client_input(packet: Dictionary) -> void:
	var buffer: Dictionary = input_buffers[packet.player_id]
	# A prolonged outage may exhaust the client's bounded resend history.
	# Explicitly record the unrecoverable gap instead of blocking forever.
	var first_available: int = packet.get("first_available_tick", buffer.last_received + 1)
	if first_available > buffer.last_received + 1:
		buffer.expired += first_available - buffer.last_received - 1
		buffer.last_received = first_available - 1
	for frame in packet.frames:
		if frame.tick <= buffer.last_received:
			continue
		# Do not ACK past a missing frame: a later retry must still be accepted.
		if frame.tick != buffer.last_received + 1:
			break
		if buffer.frames.size() >= MAX_BUFFER_FRAMES:
			buffer.overflows += 1
			break
		buffer.frames.append(frame)
		buffer.last_received = frame.tick


func consume_inputs() -> void:
	physics_tick += 1
	for player_id in input_buffers:
		var buffer: Dictionary = input_buffers[player_id]
		if not buffer.started:
			if buffer.frames.size() < buffer_target:
				players[player_id].set_controls(Vector3.ZERO, false)
				continue
			buffer.started = true
			buffer.average_depth = float(buffer_target)

		# Downstream regulation: physics stays fixed-rate; consume 0/1/2
		# input frames occasionally to hold the queue near its target.
		# Measure after the usual one-frame consumption and smooth packet bursts.
		var depth := maxf(0.0, float(buffer.frames.size() - 1))
		var blend := 1.0 - exp(-1.0 / (0.25 * Engine.physics_ticks_per_second))
		buffer.average_depth = lerpf(buffer.average_depth, depth, blend)
		var error: float = buffer.average_depth - float(buffer_target)
		buffer.consume_rate = 1.0
		if absf(error) > 1.0:
			buffer.consume_rate = clampf(1.0 + error * 0.01, 0.95, 1.05)
		if buffer.frames.is_empty():
			buffer.underflows += 1
			buffer.consume_credit = 0.0
			players[player_id].set_controls(buffer.direction, false)
			continue

		buffer.consume_credit += buffer.consume_rate
		var count := mini(int(buffer.consume_credit), 2)
		buffer.consume_credit -= count
		var jump := false
		for index in range(count):
			if buffer.frames.is_empty():
				break
			var frame: Dictionary = buffer.frames.pop_front()
			buffer.direction = frame.direction
			buffer.last_consumed = frame.tick
			# Preserve an edge when two frames are combined; never repeat it on holds.
			jump = jump or frame.jump
		players[player_id].set_controls(buffer.direction, jump)


func set_buffer_target(value: int) -> void:
	buffer_target = clampi(value, 1, 60)

func capture_snapshot() -> Dictionary:
	# Called before consume_inputs: these IDs describe the completed physics step.
	var snapshot := {"physics_tick": physics_tick, "input_ticks": {}, "received_input_ticks": {},
		"transforms": [], "linear_velocities": [], "angular_velocities": []}
	for player in players:
		snapshot.transforms.append(player.global_transform)
		snapshot.linear_velocities.append(player.linear_velocity)
		snapshot.angular_velocities.append(player.angular_velocity)
	for player_id in input_buffers:
		snapshot.input_ticks[player_id] = input_buffers[player_id].last_consumed
		snapshot.received_input_ticks[player_id] = input_buffers[player_id].last_received
	return snapshot
