#pragma once

#include <Jolt/Physics/StateRecorderImpl.h>

#include <memory>
#include <array>
#include <chrono>

// Opt-in, bounded diagnostic counters. Durations are monotonic wall nanoseconds.
struct JoltRollbackTimings {
	enum Stage {
		RESTORE_VALIDATION, RESTORE_BACKEND, RESTORE_WRAPPERS, RESTORE_NODES,
		CAPTURE_METADATA, CAPTURE_BACKEND, CAPTURE_ACCOUNTING, CAPTURE_COMPATIBILITY,
		STEP_JOB_PREPARE, STEP_WRAPPER_PRE, STEP_JOLT_UPDATE, STEP_WRAPPER_POST,
		STEP_JOB_CLEANUP, COUNT
	};
	std::array<uint64_t, COUNT> elapsed{};
	std::array<uint64_t, COUNT> calls{};
	int64_t session = 0;
	bool active = false;
	void reset() {
		elapsed.fill(0);
		calls.fill(0);
		++session;
		active = true;
	}
};

class JoltRollbackScope {
	JoltRollbackTimings* timings;
	JoltRollbackTimings::Stage stage;
	std::chrono::steady_clock::time_point started;
public:
	JoltRollbackScope(JoltRollbackTimings* p_timings, JoltRollbackTimings::Stage p_stage)
		: timings(p_timings), stage(p_stage) {
		if (timings != nullptr) {
			started = std::chrono::steady_clock::now();
			++timings->calls[stage];
		}
	}
	void finish() {
		if (timings != nullptr) {
			timings->elapsed[stage] += (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
				std::chrono::steady_clock::now() - started).count();
			timings = nullptr;
		}
	}
	~JoltRollbackScope() { finish(); }
};

// Internal owned state. Scripts receive non-reusable, world-scoped handles.
struct JoltRollbackSnapshot {
	struct Body {
		JPH::BodyID id;
		RID rid;
		JPH::ShapeRefC shape;
		Dictionary configuration;
		Dictionary state;
	};

	int64_t handle = 0;
	int64_t tick = -1;
	size_t accounted_bytes = 0;
	uint64_t generation = 0;
	float last_step = 0.0f;
	bool has_stepped = false;
	int32_t optimization_count = 0;
	Dictionary environment;
	std::string settings;
	std::vector<Body> bodies;
	JPH::StateRecorderImpl recorder;
};
