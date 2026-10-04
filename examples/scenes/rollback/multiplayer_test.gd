extends Node3D

@export_range(1, 240, 1) var network_tick_rate: int = 60

@onready var _server: Node = $Server
@onready var _clients: Array[Node] = [$Client, $Client2, $Client3]
var _labels: Array[Label] = []
var _ping_label: Label
var _selected: int = 0
var _ping_ms: float = 0.0
var _network_time: float = 0.0
var _input_queue: Array[Dictionary] = []
var _snapshot_queue: Array[Dictionary] = []
var _jump_held: bool = false
var _network_accumulator: float = 0.0
var _buffer_labels: Array[Label] = []
var _buffer_bars: Array[ProgressBar] = []
var _loss_labels: Array[Label] = []
var _packet_loss_percent: float = 0.0
var _loss_rng := RandomNumberGenerator.new()
var _dropped_inputs: Array[int] = [0, 0, 0]
var _dropped_snapshots: Array[int] = [0, 0, 0]


func _ready() -> void:
	_loss_rng.randomize()
	_server.setup($RigidBody3D)

	var template: Camera3D = $Camera3D
	template.current = false
	var colors := [Color("ffb454"), Color("8bd5ff"), Color("a6e3a1"), Color("f5a9d0")]
	for index in range(4):
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[index]
		_server.players[index].get_node("MeshInstance3D").material_override = material

	var layer := CanvasLayer.new()
	add_child(layer)
	var layout := VBoxContainer.new()
	layer.add_child(layout)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_ping_label = Label.new()
	layout.add_child(_ping_label)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 300
	slider.step = 10
	slider.focus_mode = Control.FOCUS_NONE
	slider.custom_minimum_size.y = 28
	slider.value_changed.connect(_set_ping)
	layout.add_child(slider)
	_set_ping(0.0)

	var rate_row := HBoxContainer.new()
	layout.add_child(rate_row)
	var rate_label := Label.new()
	rate_label.text = "Network Hz (physics: %d Hz):" % Engine.physics_ticks_per_second
	rate_row.add_child(rate_label)
	var rate := SpinBox.new()
	rate.min_value = 1
	rate.max_value = Engine.physics_ticks_per_second
	rate.step = 1
	network_tick_rate = clampi(network_tick_rate, 1, Engine.physics_ticks_per_second)
	rate.value = network_tick_rate
	rate.value_changed.connect(_set_network_tick_rate)
	rate_row.add_child(rate)

	var buffer_caption := Label.new()
	buffer_caption.text = "Server buffer target (physics frames):"
	rate_row.add_child(buffer_caption)
	var buffer_setting := SpinBox.new()
	buffer_setting.min_value = 1
	buffer_setting.max_value = 60
	buffer_setting.value = _server.buffer_target
	buffer_setting.tooltip_text = "Server input consumption adjusts gradually to maintain this target."
	buffer_setting.value_changed.connect(func(value: float): _server.set_buffer_target(int(value)))
	rate_row.add_child(buffer_setting)

	var loss_row := HBoxContainer.new()
	layout.add_child(loss_row)
	var loss_caption := Label.new()
	loss_caption.text = "Packet loss % (each direction, independently per client):"
	loss_row.add_child(loss_caption)
	var loss_setting := SpinBox.new()
	loss_setting.min_value = 0
	loss_setting.max_value = 100
	loss_setting.step = 1
	loss_setting.value_changed.connect(_set_packet_loss)
	loss_row.add_child(loss_setting)
	var loss_note := Label.new()
	loss_note.text = "Input retries + automatic buffer regulation"
	loss_row.add_child(loss_note)

	var split := VBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 4)
	layout.add_child(split)

	var row: HBoxContainer
	for index in range(4):
		if index % 2 == 0:
			row = HBoxContainer.new()
			row.size_flags_vertical = Control.SIZE_EXPAND_FILL
			row.add_theme_constant_override("separation", 4)
			split.add_child(row)
		var container := SubViewportContainer.new()
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.stretch = true
		row.add_child(container)
		container.gui_input.connect(_on_view_input.bind(index))

		var viewport := SubViewport.new()
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		if index == 0:
			viewport.world_3d = get_world_3d()
		else:
			viewport.own_world_3d = true
		container.add_child(viewport)
		if index > 0:
			# The client predicts its own sphere in a separate physics world.
			for node_name in ["Ground", "DirectionalLight3D", "WorldEnvironment"]:
				viewport.add_child(get_node(node_name).duplicate())
			_clients[index - 1].setup(viewport, _server.players, index)

		var camera := template.duplicate() as Camera3D
		viewport.add_child(camera)
		camera.global_transform = template.global_transform
		camera.current = true

		var label := Label.new()
		label.position = Vector2(16, 16)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_color_override("font_color", colors[index])
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		container.add_child(label)
		_labels.append(label)
		if index > 0:
			var status := Label.new()
			status.position = Vector2(16, 42)
			status.mouse_filter = Control.MOUSE_FILTER_IGNORE
			status.add_theme_font_size_override("font_size", 14)
			container.add_child(status)
			_buffer_labels.append(status)
			var bar := ProgressBar.new()
			bar.position = Vector2(16, 68)
			bar.size = Vector2(240, 12)
			bar.show_percentage = false
			bar.tooltip_text = "Received physics-frame inputs waiting on the server. Red means empty."
			bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			container.add_child(bar)
			_buffer_bars.append(bar)
			var loss_status := Label.new()
			loss_status.position = Vector2(16, 84)
			loss_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
			loss_status.add_theme_font_size_override("font_size", 14)
			container.add_child(loss_status)
			_loss_labels.append(loss_status)

	template.queue_free()
	_select_player(0)
	_update_buffer_display()


func _physics_process(delta: float) -> void:
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
	_advance_simulation(delta, direction, jump)


func _advance_simulation(delta: float, direction: Vector3, jump: bool) -> void:
	_network_time += delta
	# Local controls and delivery run at physics rate, independently of sending.
	_server.set_host_input(
		direction if _selected == 0 else Vector3.ZERO, jump and _selected == 0
	)
	for client in _clients:
		client.sample_input(
			direction if _selected == client.player_id else Vector3.ZERO,
			jump and _selected == client.player_id
		)
	var hz := clampi(network_tick_rate, 1, Engine.physics_ticks_per_second)
	var interval := 1.0 / float(hz)
	_network_accumulator += delta
	if _network_accumulator + 0.000000001 >= interval:
		_network_accumulator = maxf(0.0, _network_accumulator - interval)
		_step_network()

	_deliver_packets()
	_server.consume_inputs()
	_update_buffer_display()


func _step_network() -> void:
	var snapshot: Dictionary = _server.capture_snapshot()
	for client in _clients:
		var index: int = client.player_id - 1
		# Unacknowledged frames remain available for the next send if this packet is lost.
		var packet: Dictionary = client.create_input_packet()
		if _should_drop_packet():
			_dropped_inputs[index] += 1
		else:
			_enqueue(_input_queue, packet)
		if _should_drop_packet():
			_dropped_snapshots[index] += 1
		else:
			_enqueue(_snapshot_queue, {"client_index": index, "snapshot": snapshot})


func _deliver_packets() -> void:
	while not _input_queue.is_empty() and _input_queue[0].due <= _network_time:
		_server.receive_client_input(_input_queue.pop_front())
	while not _snapshot_queue.is_empty() and _snapshot_queue[0].due <= _network_time:
		var packet: Dictionary = _snapshot_queue.pop_front()
		_clients[packet.client_index].receive_snapshot(packet.snapshot)


func _set_packet_loss(value: float) -> void:
	_packet_loss_percent = clampf(value, 0.0, 100.0)


func _should_drop_packet() -> bool:
	return _loss_rng.randf() < _packet_loss_percent / 100.0


func _set_network_tick_rate(value: float) -> void:
	network_tick_rate = clampi(int(value), 1, Engine.physics_ticks_per_second)
	_network_accumulator = 0.0


func _enqueue(queue: Array[Dictionary], packet: Dictionary) -> void:
	var due := _network_time + _ping_ms / 2000.0
	# Preserve message order when the slider changes with packets in flight.
	if not queue.is_empty():
		due = maxf(due, queue.back().due)
	packet["due"] = due
	queue.append(packet)


func _set_ping(value: float) -> void:
	_ping_ms = value
	_ping_label.text = (
		"Simulated ping: %d ms RTT (%d ms each way) | Prediction + snap correction | WASD + Space"
		% [int(value), int(value / 2.0)]
	)


func _on_view_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_player(index)


func _select_player(selected: int) -> void:
	_selected = selected
	for index in range(_labels.size()):
		var role := "HOST - Player 1" if index == 0 else "CLIENT %d - Player %d" % [index, index + 1]
		var hint := "ACTIVE" if index == selected else "Click to control"
		_labels[index].text = "%s | %s" % [role, hint]


func _update_buffer_display() -> void:
	for index in range(_clients.size()):
		var buffer: Dictionary = _server.input_buffers[index + 1]
		var count: int = buffer.frames.size()
		var status := "RUNNING" if buffer.started else "FILLING"
		if buffer.started and count == 0:
			status = "EMPTY"
		_buffer_labels[index].text = "Server queue: %d / target %d | %s | underruns: %d" % [
			count, _server.buffer_target, status, buffer.underflows]
		_buffer_bars[index].max_value = maxf(float(_server.buffer_target * 2), float(count))
		_buffer_bars[index].value = count
		_buffer_bars[index].modulate = Color("f38ba8") if count == 0 else Color("a6e3a1")
		_loss_labels[index].text = "Dropped: input %d / state %d" % [
			_dropped_inputs[index], _dropped_snapshots[index]]
		_loss_labels[index].text += "\nUnacked: %d | consume: %.0f%% | expired: %d" % [
			_clients[index]._pending_frames.size(), buffer.consume_rate * 100.0, buffer.expired]
