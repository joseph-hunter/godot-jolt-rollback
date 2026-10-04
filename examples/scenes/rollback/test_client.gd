extends Node

const MAX_INPUT_HISTORY := 1024
const MAX_PACKET_FRAMES := 256
var player_id: int = 1
var replicas: Array[RigidBody3D] = []
var input_tick: int = 0
var last_server_tick: int = -1
var acknowledged_input_tick: int = 0
var received_input_tick: int = 0
var expired_inputs: int = 0
var _pending_frames: Array[Dictionary] = []


func setup(viewport: SubViewport, players: Array[RigidBody3D], id: int) -> void:
	player_id = id
	for index in range(players.size()):
		var replica := players[index].duplicate() as RigidBody3D
		if index != player_id:
			replica.set_script(null)
			replica.freeze = true
		viewport.add_child(replica)
		replicas.append(replica)


func sample_input(direction: Vector3, jump: bool) -> void:
	input_tick += 1
	replicas[player_id].set_controls(direction, jump)
	_pending_frames.append({"tick": input_tick, "direction": direction, "jump": jump})
	if _pending_frames.size() > MAX_INPUT_HISTORY:
		_pending_frames.pop_front()
		expired_inputs += 1


func create_input_packet() -> Dictionary:
	# Resend oldest unacknowledged frames first. Copy the array so later ACKs
	# cannot mutate packets already in flight. Frame dictionaries are immutable.
	return {"player_id": player_id,
		"first_available_tick": _pending_frames[0].tick if not _pending_frames.is_empty() else input_tick + 1,
		"frames": _pending_frames.slice(0, MAX_PACKET_FRAMES)}


func receive_snapshot(snapshot: Dictionary) -> void:
	if snapshot.physics_tick <= last_server_tick:
		return
	last_server_tick = snapshot.physics_tick
	acknowledged_input_tick = snapshot.input_ticks[player_id]
	# Receipt ACKs release transport history; consumption ACKs identify physics state.
	received_input_tick = maxi(received_input_tick, snapshot.received_input_ticks[player_id])
	while not _pending_frames.is_empty() and _pending_frames[0].tick <= received_input_tick:
		_pending_frames.pop_front()
	for index in range(replicas.size()):
		# Still hard corrections: rollback history/replay is a separate next step.
		replicas[index].global_transform = snapshot.transforms[index]
		replicas[index].linear_velocity = snapshot.linear_velocities[index]
		replicas[index].angular_velocity = snapshot.angular_velocities[index]
