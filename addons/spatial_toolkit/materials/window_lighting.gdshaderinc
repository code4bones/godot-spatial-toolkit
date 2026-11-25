// Lighting for procedural facades and older section atlases.
float apartment_hash(uvec3 key) {
	uint value = key.x * 1597334677u ^ key.y * 3812015801u ^ key.z * 2798796415u;
	value = (value ^ (value >> 16u)) * 2246822519u;
	return float((value ^ (value >> 13u)) & 65535u) / 65536.0;
}

vec3 section_emission(vec2 address, float building, float side) {
	uvec3 key = uvec3(uint(address.x) + 1u, uint(address.y), uint(building) * 4u + uint(side));
	if (apartment_hash(key) > 0.51) {
		return vec3(0.0);
	}
	float tone = apartment_hash(key + uvec3(83u, 0u, 0u));
	vec3 color = mix(vec3(1.0, 0.52, 0.24), vec3(0.71, 0.85, 1.0), smoothstep(0.30, 0.85, tone));
	return color * mix(0.45, 0.95, apartment_hash(key + uvec3(241u, 0u, 0u)));
}

vec3 apartment_emission(vec2 cell, float building, float side) {
	if (cell.y < 1.0) {
		return vec3(0.0);
	}
	uint facade = uint(building) * 4u + uint(side);
	uint level = uint(cell.y);
	float offset = floor(apartment_hash(uvec3(17u, level, facade)) * 6.0);
	float column = mod(cell.x, 1024.0) + offset;
	uint group = uint(floor(column / 6.0));
	float occupancy = apartment_hash(uvec3(group + 1u, level, facade));
	float width = 2.0 + floor(apartment_hash(uvec3(group + 179u, level, facade)) * 3.0);
	if (occupancy > 0.55 || mod(column, 6.0) >= (occupancy < 0.045 ? 1.0 : width)) {
		return vec3(0.0);
	}
	float tone = apartment_hash(uvec3(group + 83u, level, facade));
	vec3 color = mix(vec3(1.0, 0.52, 0.24), vec3(0.71, 0.85, 1.0), smoothstep(0.30, 0.85, tone));
	float intensity = mix(0.45, 0.95, apartment_hash(uvec3(group + 241u, level, facade)));
	float variation = mix(0.91, 1.09, apartment_hash(uvec3(uint(column), level, facade)));
	return color * intensity * variation;
}
