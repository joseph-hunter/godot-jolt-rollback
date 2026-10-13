#include "jolt_rollback.hpp"
#include "objects/jolt_area_impl_3d.hpp"
#include "objects/jolt_body_impl_3d.hpp"
#include "servers/jolt_physics_server_3d.hpp"
#include "spaces/jolt_contact_listener_3d.hpp"
#include "spaces/jolt_space_3d.hpp"

#include <godot_cpp/classes/rigid_body3d.hpp>

bool JoltBodyImpl3D::supports_rollback_snapshot() const {
	const RigidBody3D* node = Object::cast_to<RigidBody3D>(get_instance_wrapped());
	if (node != nullptr && node->is_contact_monitor_enabled()) {
		return false;
	}
	return (is_static() || is_rigid() || is_rigid_linear()) && !reports_contacts() &&
		areas.is_empty() && joints.is_empty() &&
		custom_integration_userdata.get_type() == Variant::NIL;
}

Dictionary JoltBodyImpl3D::capture_rollback_state() const {
	Dictionary state;
	state["sync_state"] = sync_state;
	state["constant_force"] = constant_force;
	state["constant_torque"] = constant_torque;
	state["gravity"] = gravity;
	state["total_linear_damp"] = total_linear_damp;
	state["total_angular_damp"] = total_angular_damp;
	state["kinematic_transform"] = kinematic_transform;
	state["linear_surface_velocity"] = linear_surface_velocity;
	state["angular_surface_velocity"] = angular_surface_velocity;
	return state;
}

void JoltBodyImpl3D::restore_rollback_state(const Dictionary& p_state) {
	sync_state = p_state["sync_state"];
	constant_force = p_state["constant_force"];
	constant_torque = p_state["constant_torque"];
	gravity = p_state["gravity"];
	total_linear_damp = p_state["total_linear_damp"];
	total_angular_damp = p_state["total_angular_damp"];
	kinematic_transform = p_state["kinematic_transform"];
	linear_surface_velocity = p_state["linear_surface_velocity"];
	angular_surface_velocity = p_state["angular_surface_velocity"];
	contact_count = 0;
}

Dictionary JoltBodyImpl3D::rollback_configuration(const JPH::Body& p_body) const {
	JPH::BodyCreationSettings settings = p_body.GetBodyCreationSettings();
	// Static geometry cannot move within a history window. Dynamic poses/velocities
	// and allow-sleep state are in the recorder, not the compatibility signature.
	if (!is_static()) {
		settings.mPosition = JPH::RVec3::sZero();
		settings.mRotation = JPH::Quat::sIdentity();
	}
	settings.mLinearVelocity = JPH::Vec3::sZero();
	settings.mAngularVelocity = JPH::Vec3::sZero();
	settings.mAllowSleeping = true;
	JPH::StateRecorderImpl stream;
	settings.SaveBinaryState(stream);
	const std::string bytes = stream.GetData();
	PackedByteArray binary;
	binary.resize((int64_t)bytes.size());
	memcpy(binary.ptrw(), bytes.data(), bytes.size());
	Dictionary configuration;
	configuration["backend"] = binary;
	configuration["mode"] = (int)mode;
	configuration["mass"] = mass;
	configuration["inertia"] = inertia;
	configuration["scale"] = scale;
	configuration["center_of_mass"] = center_of_mass_custom;
	configuration["custom_center_of_mass"] = custom_center_of_mass;
	configuration["linear_damp"] = linear_damp;
	configuration["angular_damp"] = angular_damp;
	configuration["linear_damp_mode"] = (int)linear_damp_mode;
	configuration["angular_damp_mode"] = (int)angular_damp_mode;
	configuration["gravity_scale"] = gravity_scale;
	configuration["collision_priority"] = collision_priority;
	configuration["locked_axes"] = (int64_t)locked_axes;
	configuration["custom_integrator"] = custom_integrator;
	configuration["exceptions"] = get_collision_exceptions();
	configuration["integration_callback"] = custom_integration_callback;
	configuration["sync_callback"] = state_sync_callback;
	return configuration;
}

namespace {
bool configurations_match(const JoltRollbackSnapshot& a, const JoltRollbackSnapshot& b) {
	if (a.generation != b.generation || a.bodies.size() != b.bodies.size() ||
		a.environment != b.environment || a.settings != b.settings)
	{
		return false;
	}
	for (size_t i = 0; i < a.bodies.size(); ++i) {
		const auto& first = a.bodies[i];
		const auto& second = b.bodies[i];
		if (first.id != second.id || first.rid != second.rid || first.shape != second.shape ||
			first.configuration != second.configuration)
		{
			return false;
		}
	}
	return true;
}

Dictionary environment_configuration(const JoltAreaImpl3D* p_area) {
	Dictionary result;
	for (int i = 0; i <= (int)PhysicsServer3D::AREA_PARAM_PRIORITY; ++i) {
		result[i] = p_area->get_param((PhysicsServer3D::AreaParameter)i);
	}
	return result;
}

std::string physics_configuration(const JPH::PhysicsSystem& p_system) {
	// Internal equality guard only; never expose or accept these bytes as a wire format.
	const JPH::PhysicsSettings& settings = p_system.GetPhysicsSettings();
	return std::string(reinterpret_cast<const char*>(&settings), sizeof(settings));
}
} // namespace

bool JoltSpace3D::capture_rollback_snapshot(JoltRollbackSnapshot& p_snapshot) {
	if (!contact_listener->supports_rollback_snapshot()) {
		fail_rollback(
			"Snapshot proof of concept does not support contact/area notification history."
		);
		return false;
	}
	if (!physics_system->GetConstraints().empty()) {
		fail_rollback("Snapshot proof of concept does not support joints.");
		return false;
	}
	body_accessor.acquire_all();
	for (int32_t i = 0; i < body_accessor.get_count(); ++i) {
		JPH::Body* jolt_body = body_accessor.try_get(i);
		if (jolt_body != nullptr && jolt_body->IsSensor() &&
			jolt_body->GetUserData() == reinterpret_cast<JPH::uint64>(default_area))
		{
			// The backend always owns an empty default-area sensor. Its global
			// parameters are validated separately and its Jolt state is recorded.
			continue;
		}
		if (jolt_body == nullptr || jolt_body->IsSensor() || jolt_body->IsSoftBody()) {
			body_accessor.release();
			fail_rollback(
				"Snapshot proof of concept requires rigid bodies and unchanged static geometry; "
				"areas and soft bodies are unsupported."
			);
			return false;
		}
		auto* body = reinterpret_cast<JoltBodyImpl3D*>(jolt_body->GetUserData());
		if (!body->supports_rollback_snapshot()) {
			body_accessor.release();
			fail_rollback(
				"Unsupported snapshot configuration: kinematic bodies, contacts, areas, joints or "
				"integration userdata."
			);
			return false;
		}
		JoltRollbackSnapshot::Body saved;
		saved.id = jolt_body->GetID();
		saved.rid = body->get_rid();
		saved.shape = jolt_body->GetShape();
		saved.configuration = body->rollback_configuration(*jolt_body);
		saved.state = body->capture_rollback_state();
		p_snapshot.bodies.push_back(std::move(saved));
	}
	body_accessor.release();
	p_snapshot.generation = configuration_generation;
	p_snapshot.last_step = last_step;
	p_snapshot.has_stepped = has_stepped;
	p_snapshot.optimization_count = bodies_added_since_optimizing;
	p_snapshot.environment = environment_configuration(default_area);
	p_snapshot.settings = physics_configuration(*physics_system);
	physics_system->SaveState(p_snapshot.recorder);
	if (p_snapshot.recorder.IsFailed()) {
		fail_rollback("Jolt snapshot capture failed.");
		return false;
	}
	// Conservative metadata charge includes dictionaries and keys, callback handles,
	// body entries and exception arrays; shape resources are shared, not copied.
	p_snapshot.accounted_bytes = sizeof(p_snapshot) + p_snapshot.recorder.GetDataSize() +
		p_snapshot.settings.size();
	for (const auto& body : p_snapshot.bodies) {
		const PackedByteArray binary = body.configuration["backend"];
		const Array exceptions = body.configuration["exceptions"];
		p_snapshot.accounted_bytes += sizeof(body) + 8192 + (size_t)binary.size() +
			(size_t)exceptions.size() * 32;
	}
	return true;
}

bool JoltSpace3D::restore_rollback_snapshot(JoltRollbackSnapshot& p_snapshot) {
	// Validate *every* immutable item before the recorder can partially mutate state.
	JoltRollbackSnapshot current;
	if (!capture_rollback_snapshot(current)) {
		return false;
	}
	if (!configurations_match(current, p_snapshot)) {
		fail_rollback("Snapshot topology or immutable configuration is incompatible.");
		return false;
	}
	p_snapshot.recorder.Rewind();
	if (!physics_system->RestoreState(p_snapshot.recorder) || p_snapshot.recorder.IsFailed()) {
		fail_rollback("Jolt restoration failed after possible partial mutation; reset the world.");
		return false;
	}
	last_step = p_snapshot.last_step;
	has_stepped = p_snapshot.has_stepped;
	bodies_added_since_optimizing = p_snapshot.optimization_count;
	contact_listener->reset_rollback_debug_state();
	for (const auto& saved : p_snapshot.bodies) {
		const JoltWritableBody3D jolt_body = write_body(saved.id);
		auto* body = reinterpret_cast<JoltBodyImpl3D*>(jolt_body->GetUserData());
		body->restore_rollback_state(saved.state);
	}
	return true;
}

void JoltSpace3D::synchronize_rollback_nodes() {
	body_accessor.acquire_all();
	for (int32_t i = 0; i < body_accessor.get_count() && !is_rollback_failed(); ++i) {
		JPH::Body* jolt_body = body_accessor.try_get(i);
		if (jolt_body == nullptr || jolt_body->IsSensor()) {
			continue;
		}
		auto* body = reinterpret_cast<JoltBodyImpl3D*>(jolt_body->GetUserData());
		// Native RigidBody3D state synchronization invokes its script integration
		// virtual too. Use public cache setters instead; server writeback is guarded.
		Node3D* node = Object::cast_to<Node3D>(body->get_instance_wrapped());
		if (node == nullptr) {
			continue;
		}
		node->set_ignore_transform_notification(true);
		node->set_global_transform(body->get_transform_scaled());
		node->set_ignore_transform_notification(false);
		if (RigidBody3D* rigid = Object::cast_to<RigidBody3D>(node)) {
			rigid->set_linear_velocity(body->get_linear_velocity());
			rigid->set_angular_velocity(body->get_angular_velocity());
			rigid->set_sleeping(body->is_sleeping());
			rigid->set_can_sleep(body->can_sleep());
		}
	}
	body_accessor.release();
}

bool JoltPhysicsServer3DExtension::_rollback_snapshot_access(const RID& p_space) {
	ERR_FAIL_COND_V_MSG(!_rollback_access_valid(), false, "Rollback APIs require the main thread.");
	if (coordinating_rollback && notifying_rollback_space.is_valid() &&
		p_space != notifying_rollback_space)
	{
		JoltSpace3D* selected = space_owner.get_or_null(notifying_rollback_space);
		if (selected != nullptr) {
			selected->fail_rollback(
				"Snapshot operation targeted a world other than the selected manager's world."
			);
		}
		return false;
	}
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	ERR_FAIL_NULL_V(space, false);
	if (!rollback_worlds.has(p_space)) {
		ERR_PRINT("World has no rollback manager.");
		return false;
	}
	if (!coordinating_rollback || notifying_rollback_space != p_space || flushing_queries ||
		stepping || snapshot_operation)
	{
		space->fail_rollback(
			"Snapshot operations require the selected manager's sync callback and cannot be "
			"reentrant."
		);
		return false;
	}
	if (!_rollback_configuration_valid()) {
		space->fail_rollback("Rollback requires 120 Hz and time scale 1.0.");
	}
	return !space->is_rollback_failed();
}

int64_t JoltPhysicsServer3DExtension::rollback_capture_physics(const RID& p_space, int64_t p_tick) {
	if (!_rollback_snapshot_access(p_space)) {
		return 0;
	}
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	if (p_tick < 0) {
		space->fail_rollback("Snapshot tick must be nonnegative.");
		return 0;
	}
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (world->replay_active && (p_tick != world->replay_tick || world->callbacks_flushed)) {
		space->fail_rollback("Replay capture must name the current pre-callback boundary.");
		return 0;
	}
	snapshot_operation = true;
	auto snapshot = std::make_shared<JoltRollbackSnapshot>();
	const bool captured = space->capture_rollback_snapshot(*snapshot);
	snapshot_operation = false;
	if (!captured) {
		return 0;
	}
	const size_t slot = (size_t)(p_tick % 241);
	size_t bytes = snapshot->accounted_bytes;
	bool configuration_validated = false;
	for (size_t i = 0; i < world->snapshots.size(); ++i) {
		if (world->snapshots[i] && !configuration_validated) {
			// Every retained capture already passed this same immutable-configuration
			// invariant. Validate once, rather than compare all 241 identical signatures.
			if (!configurations_match(*snapshot, *world->snapshots[i])) {
				space->fail_rollback("Immutable configuration changed while snapshot history was retained.");
				return 0;
			}
			configuration_validated = true;
		}
		if (i != slot && world->snapshots[i]) {
			bytes += world->snapshots[i]->accounted_bytes;
		}
	}
	if (bytes > 64 * 1024 * 1024) {
		space->fail_rollback("Snapshot history exceeded the 64 MiB per-world accounting limit.");
		return 0;
	}
	if (next_snapshot_handle == INT64_MAX) {
		space->fail_rollback("Snapshot handle IDs exhausted; restart with a known-good reset.");
		return 0;
	}
	snapshot->handle = next_snapshot_handle++;
	snapshot->tick = p_tick;
	world->snapshots[slot] = snapshot;
	if (world->replay_active) {
		world->boundary_captured = true;
	} else {
		world->logical_tick = p_tick;
		world->logical_auto_steps = world->completed_steps;
	}
	return snapshot->handle;
}

bool JoltPhysicsServer3DExtension::rollback_restore_physics(
	const RID& p_space,
	int64_t p_handle,
	int64_t p_tick
) {
	if (!_rollback_snapshot_access(p_space)) {
		return false;
	}
	JoltSpace3D* space = space_owner.get_or_null(p_space);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (world->replay_active) {
		space->fail_rollback("An active replay must not restore its starting boundary again.");
		return false;
	}
	std::shared_ptr<JoltRollbackSnapshot> snapshot;
	if (p_tick >= 0) {
		snapshot = world->snapshots[(size_t)(p_tick % 241)];
	}
	if (!snapshot || snapshot->handle != p_handle || snapshot->tick != p_tick) {
		space->fail_rollback(
			"Snapshot handle is stale, released, from another world, or has the wrong tick."
		);
		return false;
	}
	snapshot_operation = true;
	bool restored = space->restore_rollback_snapshot(*snapshot);
	if (restored) {
		flushing_queries = true;
		synchronizing_rollback_nodes = true;
		space->synchronize_rollback_nodes();
		synchronizing_rollback_nodes = false;
		flushing_queries = false;
		restored = !space->is_rollback_failed();
	}
	snapshot_operation = false;
	if (restored) {
		world->logical_tick = p_tick;
		world->logical_auto_steps = world->completed_steps;
	}
	return restored;
}

bool JoltPhysicsServer3DExtension::rollback_release_snapshot(const RID& p_space, int64_t p_handle) {
	ERR_FAIL_COND_V(!_rollback_access_valid(), false);
	ERR_FAIL_COND_V(snapshot_operation || flushing_queries || stepping, false);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, false);
	for (auto& snapshot : world->snapshots) {
		if (snapshot && snapshot->handle == p_handle) {
			if (world->replay_active && snapshot->tick == world->replay_tick) {
				space_owner.get_or_null(p_space)->fail_rollback("Cannot release the current replay boundary snapshot.");
				return false;
			}
			snapshot.reset();
			return true;
		}
	}
	return false;
}

bool JoltPhysicsServer3DExtension::rollback_register_participant(const RID& p_space, Node* p_node) {
	ERR_FAIL_COND_V(!_rollback_access_valid(), false);
	ERR_FAIL_COND_V(coordinating_rollback || sync_open || stepping || flushing_queries, false);
	ERR_FAIL_NULL_V(p_node, false);
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	ERR_FAIL_NULL_V(world, false);
	ERR_FAIL_COND_V(space_owner.get_or_null(p_space)->is_rollback_failed(), false);
	const ObjectID id(p_node->get_instance_id());
	for (const auto& entry : rollback_worlds) {
		for (ObjectID participant : entry.second.participants) {
			ERR_FAIL_COND_V_MSG(
				participant == id,
				false,
				"Participant already belongs to a rollback world."
			);
		}
	}
	world->participants.push_back(id);
	return true;
}

void JoltPhysicsServer3DExtension::_stop_rollback_participants(const RID& p_space) {
	RollbackWorld* world = rollback_worlds.getptr(p_space);
	if (world == nullptr) {
		return;
	}
	for (ObjectID id : world->participants) {
		Node* node = Object::cast_to<Node>(ObjectDB::get_instance(id));
		if (node != nullptr) {
			// Process-mode changes on CollisionObject3D can remove bodies from physics.
			// Disable script dispatch directly, preserving the stopped topology.
			node->set_physics_process(false);
			node->set_process(false);
			node->set_process_input(false);
			node->set_process_unhandled_input(false);
			node->set_process_unhandled_key_input(false);
		}
	}
}
