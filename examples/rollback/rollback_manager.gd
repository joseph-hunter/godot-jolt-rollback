extends Node
## One manager per fixed-topology physics space. See docs/rollback-manager.md.
## Participants implement rollback_save(), rollback_restore(state), and
## rollback_simulate(input, delta). Only this node dispatches their gameplay.

signal simulation_failed(message: String)
signal corrected(start_tick: int, end_tick: int)
signal presentation_event(participant_id: StringName, event: Variant)

const INPUT_CAPACITY := 240
const BOUNDARY_CAPACITY := 241
const FIXED_DELTA := 1.0 / 120.0

var current_tick := -1
var replaying := false
var failed := false
var failure_reason := ""
var running := false
var _server = PhysicsServer3D
var _space: RID
var _origin := 0
var _provider: Callable
var _participants: Dictionary = {}
var _ids: Array[StringName] = []
var _input_tags: Array[int] = []
var _inputs: Array = []
var _boundary_tags: Array[int] = []
var _handles: Array[int] = []
var _gameplay: Array = []
var _future: Dictionary = {}
var _selected: Dictionary = {}
var _pending_start := -1
var _request_id := 0
var _armed := false
var _coordinating := false
var _detaching := false

func add_participant(id: StringName, node: Node) -> bool:
	if running or id == &"" or _participants.has(id) or not is_instance_valid(node):
		return false
	for existing in _participants.values():
		if existing == node:
			return false
	for method in [&"rollback_save", &"rollback_restore", &"rollback_simulate"]:
		if not node.has_method(method):
			return false
	_participants[id] = node
	_ids.append(id)
	_ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return true

## provider(tick) returns a complete Dictionary keyed by participant StringNames.
## Sample live input or predict here; this callable is never invoked in replay.
func start(space: RID, provider: Callable, first_tick: int = 0) -> bool:
	if running or failed or _detaching or not is_inside_tree() or not space.is_valid() or not provider.is_valid() or first_tick < 0 or _ids.is_empty():
		return false
	if not _server.has_method("rollback_begin_replay"):
		return false
	if Engine.physics_ticks_per_second != 120 or Engine.time_scale != 1.0:
		return false
	_space = space
	_provider = provider
	_origin = first_tick
	_future.clear()
	_selected.clear()
	_pending_start = -1
	_armed = false
	current_tick = first_tick - 1
	_input_tags.resize(INPUT_CAPACITY)
	_input_tags.fill(-1)
	_inputs.resize(INPUT_CAPACITY)
	_boundary_tags.resize(BOUNDARY_CAPACITY)
	_boundary_tags.fill(-1)
	_handles.resize(BOUNDARY_CAPACITY)
	_gameplay.resize(BOUNDARY_CAPACITY)
	if not _server.rollback_register_world(space, _boundary):
		return false
	running = true
	for id in _ids:
		var node: Node = _participants[id]
		if not _server.rollback_register_participant(space, node):
			return _fail("Participant registration failed: %s" % id)
		# SceneTree must not also dispatch participant gameplay.
		node.set_physics_process(false)
	return true

## Complete authoritative frame. Past changes coalesce to the earliest tick.
## Future frames are bounded to 240 ticks ahead and override provider results.
func submit_input(tick: int, frame: Dictionary) -> bool:
	if not running or failed or _detaching or _coordinating:
		return false
	if not _valid_frame(frame):
		return _fail("Authoritative input must contain value data for every participant.")
	if tick < _origin or tick > current_tick + INPUT_CAPACITY:
		return _fail("Input tick is outside the supported history/future window: %d" % tick)
	if tick > current_tick:
		_future[tick] = _copy(frame)
		return true
	var slot := tick % INPUT_CAPACITY
	if _input_tags[slot] != tick or _boundary_tags[tick % BOUNDARY_CAPACITY] != tick:
		return _fail("Correction history is unavailable for tick %d" % tick)
	if _inputs[slot] == frame:
		return true
	_inputs[slot] = _copy(frame)
	_pending_start = tick if _pending_start < 0 else mini(tick, _pending_start)
	_request_id += 1
	if not _server.rollback_request_correction(_space, _request_id):
		return _fail("Correction submission failed.")
	return true

## Returns an owned copy, so callback mutation cannot corrupt retained input.
func input_for(id: StringName) -> Variant:
	if failed or not _selected.has(id):
		_fail("No selected input for participant %s" % id)
		return null
	return _copy(_selected[id])

func present(id: StringName, event: Variant) -> void:
	if running and not failed and not replaying:
		presentation_event.emit(id, event)

## Await before freeing the manager or space. Physics resumes ordinary stepping;
## participant physics processing remains disabled until the caller enables it.
func detach() -> bool:
	if not running or _detaching or _coordinating:
		return false
	_detaching = true
	# Deferred calls can still occur inside sync/end_sync. process_frame is idle.
	await get_tree().process_frame
	var ok: bool = _server.rollback_unregister_world(_space)
	if ok:
		running = false
		_armed = false
		_future.clear()
		_selected.clear()
		_inputs.clear()
		_gameplay.clear()
		_handles.clear()
		_boundary_tags.clear()
		_input_tags.clear()
	_detaching = false
	return ok

func _boundary(context: Dictionary) -> bool:
	if failed:
		return false
	_coordinating = true
	var ok: bool
	if Engine.physics_ticks_per_second != 120 or Engine.time_scale != 1.0:
		ok = _fail("Rollback requires 120 Hz and time scale 1.0.")
	elif context.kind == "correction_pending":
		ok = _replay(int(context.tick))
	else:
		current_tick = int(context.tick) if int(context.tick) >= 0 else _origin + int(context.completed_steps)
		ok = _capture(current_tick)
		if ok:
			var frame: Variant = _future.get(current_tick) if _future.has(current_tick) else _provider.call(current_tick)
			_future.erase(current_tick)
			if not _valid_frame(frame):
				ok = _fail("Input provider omitted or returned unsupported input at tick %d" % current_tick)
			else:
				_selected = _copy(frame)
				_input_tags[current_tick % INPUT_CAPACITY] = current_tick
				_inputs[current_tick % INPUT_CAPACITY] = _copy(_selected)
				_armed = true
	_coordinating = false
	return ok and not failed

func _capture(tick: int) -> bool:
	var states: Dictionary = {}
	for id in _ids:
		if not is_instance_valid(_participants[id]):
			return _fail("Participant was destroyed: %s" % id)
		var state: Variant = _participants[id].rollback_save()
		if not _value_data(state):
			return _fail("Gameplay snapshot contains an Object or unsupported container: %s" % id)
		states[id] = _copy(state)
	var handle: int = _server.rollback_capture_physics(_space, tick)
	if handle <= 0:
		return _fail("Physics boundary capture failed at tick %d" % tick)
	var slot := tick % BOUNDARY_CAPACITY
	_boundary_tags[slot] = tick
	_handles[slot] = handle
	_gameplay[slot] = states
	return true

func _replay(end: int) -> bool:
	var begin := _pending_start
	if begin < 0 or end <= begin or end - begin > INPUT_CAPACITY or _boundary_tags[begin % BOUNDARY_CAPACITY] != begin:
		return _fail("Correction has no retained starting boundary.")
	for tick in range(begin, end):
		if _input_tags[tick % INPUT_CAPACITY] != tick:
			return _fail("Required replay input is missing at tick %d" % tick)
	if not _server.rollback_begin_replay(_space, _handles[begin % BOUNDARY_CAPACITY], begin, end):
		return _fail("Physics replay restoration failed.")
	replaying = true
	current_tick = begin
	for id in _ids:
		if not is_instance_valid(_participants[id]):
			return _fail("Participant was destroyed: %s" % id)
		var restored: Variant = _participants[id].rollback_restore(_copy(_gameplay[begin % BOUNDARY_CAPACITY][id]))
		if not restored is bool or not restored:
			return _fail("Gameplay restoration failed: %s" % id)
	for tick in range(begin, end):
		current_tick = tick
		_selected = _copy(_inputs[tick % INPUT_CAPACITY])
		if not _server.rollback_flush_replay_callbacks(_space, tick) or not _simulate():
			return _fail("Replay callback/gameplay delivery failed at tick %d" % tick)
		if not _server.rollback_step_manual(_space, tick, FIXED_DELTA) or not _capture(tick + 1):
			return _fail("Replay step/capture failed at tick %d" % tick)
	if not _server.rollback_finish_replay(_space, end):
		return _fail("Replay did not finish at the current boundary.")
	current_tick = end
	replaying = false
	_pending_start = -1
	for id in _ids:
		_participants[id].reset_physics_interpolation()
	corrected.emit(begin, end)
	return not failed

func _physics_process(_delta: float) -> void:
	if not running or failed or not _healthy() or not _armed:
		return
	_armed = false
	_simulate()

func _process(_delta: float) -> void:
	if running and not failed:
		_healthy()

func _simulate() -> bool:
	for id in _ids:
		if not _healthy():
			return false
		if not is_instance_valid(_participants[id]):
			return _fail("Participant was destroyed: %s" % id)
		var simulated: Variant = _participants[id].rollback_simulate(input_for(id), FIXED_DELTA)
		if not simulated is bool or not simulated:
			return _fail("Gameplay simulation failed: %s" % id)
	return _healthy()

func _healthy() -> bool:
	if failed:
		return false
	var status: Dictionary = _server.rollback_get_world_status(_space)
	if not status.get("registered", false):
		return _fail("Rollback world registration was lost.")
	if status.get("failed", false):
		return _fail(str(status.error))
	return true

func _fail(message: String) -> bool:
	if not failed:
		failed = true
		failure_reason = message
		_armed = false
		replaying = false
		if running:
			var status: Dictionary = _server.rollback_get_world_status(_space)
			if status.get("failed", false):
				failure_reason = str(status.error)
			elif status.get("registered", false):
				_server.rollback_fail_world(_space, message)
		simulation_failed.emit(failure_reason)
	return false

func _valid_frame(frame: Variant) -> bool:
	if not frame is Dictionary or frame.size() != _ids.size() or not _value_data(frame):
		return false
	for id in _ids:
		if not frame.has(id):
			return false
	return true

static func _copy(value: Variant) -> Variant:
	if value is Array:
		var result: Array = value.duplicate()
		for i in result.size():
			result[i] = _copy(value[i])
		return result
	if value is Dictionary:
		var result: Dictionary = value.duplicate()
		for key in result:
			result[key] = _copy(value[key])
		return result
	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
		return value.duplicate()
	return value

## A depth limit also rejects cyclic containers without recursing indefinitely.
static func _value_data(value: Variant, depth: int = 0) -> bool:
	if depth > 32 or value is Object or value is Callable or value is Signal or value is RID:
		return false
	if value is Array or value is Dictionary:
		for item in value:
			if not _value_data(item, depth + 1):
				return false
			if value is Dictionary and not _value_data(value[item], depth + 1):
				return false
			if value is Dictionary and (item is Array or item is Dictionary or typeof(item) >= TYPE_PACKED_BYTE_ARRAY):
				return false
	return true
