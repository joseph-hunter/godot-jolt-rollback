extends SceneTree

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func make_scene():
	var scene = load("res://scenes/rollback/multiplayer-test.tscn").instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	return scene

func advance(scene, ticks: int) -> void:
	for tick in range(ticks):
		scene._advance_simulation(1.0 / 120.0, Vector3.ZERO, false)

func run() -> void:
	Engine.physics_ticks_per_second = 120
	root.size = Vector2i(1600, 900)
	var scene = make_scene()
	var client = scene._clients[0]
	var server = scene._server
	for tick in range(4):
		client.sample_input(Vector3.RIGHT, tick == 1)
	var packet: Dictionary = client.create_input_packet()
	check(client.create_input_packet().frames.size() == 4, "Lost packet must be retransmitted")
	server.receive_client_input(packet)
	server.receive_client_input(packet)
	check(server.input_buffers[1].frames.size() == 4, "Duplicate frames queued")
	client.receive_snapshot(server.capture_snapshot())
	check(client._pending_frames.is_empty(), "Receipt ACK failed to prune history")
	check(packet.frames.size() == 4, "ACK mutated in-flight packet")
	check(client.acknowledged_input_tick == 0, "Receipt ACK confused with consumption ACK")
	for tick in range(1, 5):
		server.players[1]._jump_pending = false
		server.consume_inputs()
		check(server.input_buffers[1].last_consumed == tick, "Changed FIFO order")
		check(server.players[1]._jump_pending == (tick == 2), "Jump lost or repeated")
	server.players[1]._jump_pending = false
	server.consume_inputs()
	check(not server.players[1]._jump_pending, "Empty buffer repeated jump")
	# A gap must not advance the cumulative ACK.
	server.receive_client_input({"player_id": 1, "frames": [{"tick": 6, "direction": Vector3.ZERO, "jump": false}]})
	check(server.input_buffers[1].last_received == 4, "ACK skipped missing tick")
	server.receive_client_input({"player_id": 1, "frames": [
		{"tick": 5, "direction": Vector3.ZERO, "jump": false},
		{"tick": 6, "direction": Vector3.ZERO, "jump": false}]})
	check(server.input_buffers[1].last_received == 6, "Retry failed to repair gap")
	scene.free()

	# Loss must not cause permanent depletion. Controller also tracks target changes.
	for hz in [30, 60]:
		scene = make_scene()
		scene._set_network_tick_rate(hz)
		scene._set_ping(100)
		scene._set_packet_loss(20)
		scene._loss_rng.seed = 123
		scene._server.set_buffer_target(12)
		advance(scene, 3600)
		for id in range(1, 4):
			var buffer: Dictionary = scene._server.input_buffers[id]
			print("Loss test ", hz, "Hz client ", id, " queue=", buffer.frames.size(), " avg=", buffer.average_depth)
			check(buffer.average_depth > 7 and buffer.average_depth < 18, "Queue failed to regulate around 12")
			check(buffer.expired == 0, "Moderate loss exhausted history")
			check(scene._clients[id - 1]._pending_frames.size() < 100, "ACK history grew without bound")
		scene._set_packet_loss(0)
		scene._server.set_buffer_target(4)
		advance(scene, 3600)
		for buffer in scene._server.input_buffers.values():
			check(buffer.average_depth < 7, "Overfull queue failed to drain toward lower target")
		scene._server.set_buffer_target(12)
		advance(scene, 3600)
		for buffer in scene._server.input_buffers.values():
			check(buffer.average_depth > 9, "Queue failed to refill toward raised target")
		scene.free()

	# Long total outage: bounded memory, explicit expiry, then recover on reconnect.
	scene = make_scene()
	scene._set_packet_loss(100)
	advance(scene, 1300)
	for peer in scene._clients:
		check(peer._pending_frames.size() == 1024, "Resend history not bounded")
		check(peer.expired_inputs == 276, "History expiration not accounted for")
	scene._set_packet_loss(0)
	advance(scene, 2400)
	for id in range(1, 4):
		check(scene._server.input_buffers[id].expired >= 276, "Server failed to report expired gap")
		check(scene._clients[id - 1]._pending_frames.size() < 1024, "Reconnect stuck on expired input")
		check(scene._server.input_buffers[id].last_consumed > 1300, "Server failed to resume")
	print("Input recovery and regulation checks: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
