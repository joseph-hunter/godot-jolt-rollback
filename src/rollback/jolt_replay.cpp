#include "jolt_rollback.hpp"
#include "servers/jolt_physics_server_3d.hpp"
#include "spaces/jolt_job_system.hpp"
#include "spaces/jolt_space_3d.hpp"

#include <cmath>

bool JoltPhysicsServer3DExtension::_step_space(
	JoltSpace3D* p_space,
	float p_delta,
	bool p_rollback,
	JoltRollbackTimings* p_profile
) {
	JoltRollbackScope prepare_timer(p_profile, JoltRollbackTimings::STEP_JOB_PREPARE);
	job_system->pre_step();
	prepare_timer.finish();
	const JPH::EPhysicsUpdateError error = p_space->step(p_delta, p_rollback, p_profile);
	JoltRollbackScope cleanup_timer(p_profile, JoltRollbackTimings::STEP_JOB_CLEANUP);
	job_system->post_step();
	cleanup_timer.finish();
	if (p_rollback && error != JPH::EPhysicsUpdateError::None) {
		p_space->fail_rollback(vformat("Jolt update failed with error flags %d.", (int)error));
	}
	return !p_space->is_rollback_failed();
}

bool JoltPhysicsServer3DExtension::_rollback_replay_access(const RID& p_space) {
	if (!_rollback_snapshot_access(p_space)) {
		return false;
	}
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (!correction_callback || !world->replay_active || !active ||
		!space_owner.get_or_null(p_space)->is_active())
	{
		space_owner.get_or_null(p_space)->fail_rollback(
			"Replay operations require an active correction session."
		);
		return false;
	}
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_begin_replay(
	const RID& p_space,
	int64_t p_handle,
	int64_t p_start,
	int64_t p_end
) {
	if (!_rollback_snapshot_access(p_space)) {
		return false;
	}
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	const int64_t current = world->logical_tick >= 0
		? world->logical_tick + world->completed_steps - world->logical_auto_steps
		: -1;
	if (!correction_callback || world->replay_active || world->correction_completed ||
		p_start < 0 || p_end < p_start || p_end - p_start > 240 || p_end != current)
	{
		space->fail_rollback(
			"Replay requires a pending correction and a retained range ending at the current "
			"boundary (maximum 240 ticks)."
		);
		return false;
	}
	if (!rollback_restore_physics(p_space, p_handle, p_start)) {
		return false;
	}
	world->replay_active = true;
	world->replay_tick = p_start;
	world->replay_end = p_end;
	world->callbacks_flushed = false;
	world->boundary_captured = true;
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_flush_replay_callbacks(
	const RID& p_space,
	int64_t p_tick
) {
	if (!_rollback_replay_access(p_space)) {
		return false;
	}
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	if (p_tick != world->replay_tick || p_tick >= world->replay_end || world->callbacks_flushed ||
		!world->boundary_captured)
	{
		space->fail_rollback(
			"Replay callbacks must be delivered once per historical tick, before the exclusive "
			"ending boundary."
		);
		return false;
	}
	world->callbacks_flushed = true;
	flushing_queries = true;
	space->call_queries();
	flushing_queries = false;
	return !space->is_rollback_failed();
}

bool JoltPhysicsServer3DExtension::rollback_step_manual(
	const RID& p_space,
	int64_t p_tick,
	double p_delta
) {
	if (!_rollback_replay_access(p_space)) {
		return false;
	}
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	if (p_tick != world->replay_tick || p_tick >= world->replay_end || !world->callbacks_flushed ||
		!std::isfinite(p_delta) || ABS(p_delta - 1.0 / 120.0) > 0.000000001)
	{
		space->fail_rollback(
			"Manual replay step requires the selected historical tick, delivered callbacks and "
			"fixed delta 1/120."
		);
		return false;
	}
	stepping = true;
	const auto profile = world->profile;
	const bool success = _step_space(space, (float)p_delta, true, profile && profile->active ? profile.get() : nullptr);
	stepping = false;
	if (!success) {
		return false;
	}
	++world->replay_steps;
	++world->replay_tick;
	world->callbacks_flushed = false;
	world->boundary_captured = false;
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_finish_replay(const RID& p_space, int64_t p_tick) {
	if (!_rollback_replay_access(p_space)) {
		return false;
	}
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (p_tick != world->replay_tick || p_tick != world->replay_end || world->callbacks_flushed ||
		!world->boundary_captured)
	{
		space_owner.get_or_null(p_space)->fail_rollback(
			"Replay must finish at its captured ending boundary with callbacks still pending."
		);
		return false;
	}
	const auto& final_snapshot = world->snapshots[(size_t)(p_tick % 241)];
	if (!final_snapshot || final_snapshot->tick != p_tick) {
		space_owner.get_or_null(p_space)->fail_rollback("Replay final boundary snapshot is no longer retained.");
		return false;
	}
	world->logical_tick = p_tick;
	world->logical_auto_steps = world->completed_steps;
	world->replay_active = false;
	world->correction_completed = true;
	if (world->profile) {
		world->profile->active = false;
	}
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_set_profiling(const RID& p_space, bool p_enabled) {
	ERR_FAIL_COND_V(!_rollback_access_valid(), false);
	ERR_FAIL_COND_V(coordinating_rollback || sync_open || stepping || flushing_queries, false);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, false);
	world->profile = p_enabled ? std::make_shared<JoltRollbackTimings>() : nullptr;
	return true;
}

bool JoltPhysicsServer3DExtension::rollback_reset_profile(const RID& p_space) {
	ERR_FAIL_COND_V(!_rollback_access_valid(), false);
	ERR_FAIL_COND_V(!coordinating_rollback || !correction_callback || notifying_rollback_space != p_space || flushing_queries || stepping, false);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, false);
	ERR_FAIL_COND_V(!world->profile || world->replay_active, false);
	world->profile->reset();
	return true;
}

Dictionary JoltPhysicsServer3DExtension::rollback_get_profile(const RID& p_space) const {
	Dictionary result;
	ERR_FAIL_COND_V(!_rollback_access_valid(), result);
	const RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, result);
	if (!world->profile) {
		return result;
	}
	static const char* names[JoltRollbackTimings::COUNT] = {
		"restore_validation", "restore_backend", "restore_wrappers", "restore_nodes",
		"capture_metadata", "capture_backend", "capture_accounting", "capture_compatibility",
		"step_job_prepare", "step_wrapper_pre", "step_jolt_update", "step_wrapper_post", "step_job_cleanup"
	};
	Dictionary elapsed;
	Dictionary calls;
	for (size_t i = 0; i < JoltRollbackTimings::COUNT; ++i) {
		elapsed[names[i]] = (int64_t)world->profile->elapsed[i];
		calls[names[i]] = (int64_t)world->profile->calls[i];
	}
	result["schema_version"] = 1;
	result["session"] = world->profile->session;
	result["world"] = (int64_t)p_space.get_id();
	result["elapsed_ns"] = elapsed;
	result["calls"] = calls;
	return result;
}
