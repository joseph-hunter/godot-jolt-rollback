#pragma once

void jolt_initialize();

void jolt_deinitialize();

// Scope the pinned PhysicsSystem::Update error assertion to its recoverable
// return path. Other assertions keep the backend's existing fatal behavior.
bool jolt_set_update_error_return(bool p_enabled);
