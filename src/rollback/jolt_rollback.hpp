#pragma once

#include <Jolt/Physics/StateRecorderImpl.h>

#include <memory>

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
