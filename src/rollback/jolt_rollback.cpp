#include "jolt_rollback.hpp"

#include "servers/jolt_physics_server_3d.hpp"
#include "spaces/jolt_space_3d.hpp"

bool JoltPhysicsServer3DExtension::_rollback_access_valid() const {
	const OS* os = OS::get_singleton();
	return os->get_thread_caller_id() == os->get_main_thread_id();
}

bool JoltPhysicsServer3DExtension::_rollback_configuration_valid() const {
	Engine* engine = Engine::get_singleton();
	return engine->get_physics_ticks_per_second() == 120 && engine->get_time_scale() == 1.0;
}

bool JoltPhysicsServer3DExtension::rollback_register_world(
	const RID& p_space,
	const Callable& p_callback
) {
	ERR_FAIL_COND_V_MSG(!_rollback_access_valid(), false, "Rollback APIs require the main thread.");
	ERR_FAIL_COND_V_MSG(
		coordinating_rollback || flushing_queries || stepping || sync_open,
		false,
		"World registration requires an idle server boundary."
	);
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	ERR_FAIL_NULL_V(space, false);
	ERR_FAIL_COND_V_MSG(
		space->is_rollback_failed(),
		false,
		"A failed world requires destruction and a known-good reset before registration."
	);
	ERR_FAIL_COND_V_MSG(
		rollback_worlds.has(p_space),
		false,
		"World already has a rollback manager."
	);
	ERR_FAIL_COND_V_MSG(!p_callback.is_valid(), false, "Rollback manager callback is invalid.");
	ERR_FAIL_COND_V_MSG(
		!_rollback_configuration_valid(),
		false,
		"Rollback requires 120 Hz and time scale 1.0."
	);
#ifndef JPH_CROSS_PLATFORM_DETERMINISTIC
	ERR_FAIL_V_MSG(
		false,
		"Rebuild with GDJ_CROSS_PLATFORM_DETERMINISTIC=ON to register rollback worlds."
	);
#endif
	RollbackWorld world;
	world.callback = p_callback;
	rollback_worlds.insert(p_space, world);
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_request_correction(
	const RID& p_space,
	int64_t p_request_id
) {
	ERR_FAIL_COND_V_MSG(!_rollback_access_valid(), false, "Rollback APIs require the main thread.");
	ERR_FAIL_COND_V_MSG(
		coordinating_rollback || flushing_queries || stepping,
		false,
		"Queue corrections outside boundary and physics callback dispatch."
	);
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	ERR_FAIL_NULL_V(space, false);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, false);
	ERR_FAIL_COND_V_MSG(space->is_rollback_failed(), false, "Rollback world is stopped.");
	ERR_FAIL_COND_V_MSG(p_request_id < 0, false, "Correction request IDs must be nonnegative.");
	// Only notification metadata crosses this boundary. The manager owns corrected inputs,
	// their earliest affected tick, and coalescing of the actual corrections.
	world->request_id = p_request_id;
	++world->request_count;
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_unregister_world(const RID& p_space) {
	ERR_FAIL_COND_V_MSG(!_rollback_access_valid(), false, "Rollback APIs require the main thread.");
	ERR_FAIL_COND_V_MSG(
		coordinating_rollback || flushing_queries || stepping || sync_open,
		false,
		"World unregistration requires an idle server boundary."
	);
	return rollback_worlds.erase(p_space);
}

void JoltPhysicsServer3DExtension::rollback_fail_world(const RID& p_space, const String& p_error) {
	ERR_FAIL_COND_MSG(!_rollback_access_valid(), "Rollback APIs require the main thread.");
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	ERR_FAIL_NULL(space);
	ERR_FAIL_COND_MSG(!rollback_worlds.has(p_space), "World has no rollback manager.");
	space->fail_rollback(p_error);
}

Dictionary JoltPhysicsServer3DExtension::rollback_get_world_status(const RID& p_space) const {
	Dictionary status;
	ERR_FAIL_COND_V_MSG(
		!_rollback_access_valid(),
		status,
		"Rollback APIs require the main thread."
	);
	const JoltSpace3D* space = space_owner.get_or_null(p_space);
	ERR_FAIL_NULL_V(space, status);
	const RollbackWorld* world = rollback_worlds.getptr(p_space);
	status["registered"] = world != nullptr;
	status["failed"] = space->is_rollback_failed();
	status["error"] = space->get_rollback_error();
	status["active"] = space->is_active();
	if (world != nullptr) {
		status["completed_steps"] = world->completed_steps;
		status["pending_request_count"] = world->request_count;
		status["latest_request_id"] = world->request_id;
		status["replay_steps"] = world->replay_steps;
		status["replay_active"] = world->replay_active;
		status["replay_tick"] = world->replay_tick;
		status["replay_end"] = world->replay_end;
		status["logical_tick"] = world->logical_tick >= 0 ? world->logical_tick + world->completed_steps - world->logical_auto_steps : -1;
		int64_t count = 0;
		int64_t bytes = 0;
		int64_t oldest_tick = INT64_MAX;
		int64_t newest_tick = -1;
		for (const auto& snapshot : world->snapshots) {
			if (snapshot) {
				++count;
				bytes += (int64_t)snapshot->accounted_bytes;
				oldest_tick = MIN(oldest_tick, snapshot->tick);
				newest_tick = MAX(newest_tick, snapshot->tick);
			}
		}
		status["snapshot_count"] = count;
		status["snapshot_bytes"] = bytes;
		status["oldest_snapshot_tick"] = count != 0 ? oldest_tick : -1;
		status["newest_snapshot_tick"] = newest_tick;
	}
	return status;
}

void JoltPhysicsServer3DExtension::_fail_reentrant_rollback_operation(const String& p_operation) {
	const String error = vformat("Reentrant physics operation '%s' is forbidden.", p_operation);
	if (JoltSpace3D* space = space_owner.get_or_null(notifying_rollback_space)) {
		space->fail_rollback(error);
	} else {
		// There is no selected world during the ordinary server-wide query flush/step.
		for (const auto& entry : rollback_worlds) {
			if (JoltSpace3D* affected_space = space_owner.get_or_null(entry.first)) {
				affected_space->fail_rollback(error);
			}
		}
	}
	ERR_PRINT(error);
}

bool JoltPhysicsServer3DExtension::_notify_rollback_world(const RID& p_space, bool p_correction) {
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (space == nullptr || world == nullptr || space->is_rollback_failed()) {
		return false;
	}
	if (!world->callback.is_valid()) {
		space->fail_rollback("Rollback manager callback is no longer valid.");
		return false;
	}
	Dictionary context;
	context["kind"] = p_correction ? "correction_pending" : "normal_boundary";
	context["space"] = p_space;
	context["completed_steps"] = world->completed_steps;
	context["delta"] = 1.0 / 120.0;
	context["request_id"] = world->request_id;
	context["request_count"] = world->request_count;
	context["replay_available"] = true;
	context["restoration_available"] = true;
	context["tick"] = world->logical_tick >= 0 ? world->logical_tick + world->completed_steps - world->logical_auto_steps : -1;
	const Callable callback = world->callback;
	world->request_count = 0;
	Array arguments;
	arguments.push_back(context);
	notifying_rollback_space = p_space;
	correction_callback = p_correction;
	if (p_correction) {
		world->correction_completed = false;
	}
	const Variant result = callback.callv(arguments);
	correction_callback = false;
	notifying_rollback_space = RID();

	// Gameplay may destroy the space or callback owner. Never retain a map entry or
	// space pointer across the GDScript call.
	space = space_owner.get_or_null(p_space);
	if (space == nullptr || !rollback_worlds.has(p_space)) {
		return false;
	}
	if (result.get_type() != Variant::BOOL || !bool(result)) {
		space->fail_rollback(
			"Rollback manager must return true after successful boundary preparation."
		);
	}
	world = rollback_worlds.getptr(p_space);
	if (world->replay_active || (p_correction && !world->correction_completed)) {
		space->fail_rollback("Correction callback did not finish its replay session at the current boundary.");
	}
	return !space->is_rollback_failed();
}

void JoltPhysicsServer3DExtension::_sync() {
	if (coordinating_rollback || flushing_queries || stepping || sync_open) {
		_fail_reentrant_rollback_operation("sync");
		return;
	}
	sync_open = true;
	if (!active) {
		return;
	}
	coordinating_rollback = true;
	// Copy identifiers because user callbacks can destroy worlds. Registration and
	// explicit unregistration are guarded; destruction removes ownership immediately.
	LocalVector<RID> spaces;
	for (const auto& entry : rollback_worlds) {
		spaces.push_back(entry.first);
	}
	for (const RID& space_rid : spaces) {
		JoltSpace3D* space = space_owner.get_or_null(space_rid);
		const RollbackWorld* world = rollback_worlds.getptr(space_rid);
		if (space == nullptr || world == nullptr || !space->is_active() ||
			space->is_rollback_failed())
		{
			continue;
		}
		if (!_rollback_configuration_valid()) {
			space->fail_rollback("Rollback requires 120 Hz and time scale 1.0.");
			continue;
		}
		const bool correction_pending = world->request_count != 0;
		if (_notify_rollback_world(space_rid, correction_pending) && correction_pending) {
			// Select the upcoming live input after the historical session. Its callbacks
			// belong exclusively to the following ordinary flush, never to replay.
			_notify_rollback_world(space_rid, false);
		}
	}
	coordinating_rollback = false;
}

void JoltPhysicsServer3DExtension::_end_sync() {
	if (coordinating_rollback || flushing_queries || stepping) {
		_fail_reentrant_rollback_operation("end_sync");
		return;
	}
	sync_open = false;
}
