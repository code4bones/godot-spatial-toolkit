shader_type sky;

uniform vec3 moon_direction = vec3(0.32, 0.31, 0.895);

float star_hash(vec2 p) {
	vec3 value = fract(vec3(p.xyx) * 0.1031);
	value += dot(value, value.yzx + 33.33);
	return fract((value.x + value.y) * value.z);
}

void sky() {
	float altitude = max(EYEDIR.y, 0.0);
	vec3 night = mix(vec3(0.047, 0.065, 0.105), vec3(0.006, 0.012, 0.031),
		smoothstep(0.0, 0.65, altitude));
	vec2 grid = SKY_COORDS * vec2(768.0, 384.0);
	vec2 cell = floor(grid);
	float seed = star_hash(cell);
	vec2 offset = vec2(star_hash(cell + 3.4), star_hash(cell + 28.1)) * 0.56 + 0.22;
	float star = 1.0 - smoothstep(0.045, 0.19, length(fract(grid) - offset));
	float stars = star * step(0.982, seed) * smoothstep(0.025, 0.25, altitude);
	night += vec3(0.55, 0.70, 1.0) * stars * mix(0.3, 1.9, star_hash(cell + 67.5));

	vec3 direction = normalize(moon_direction);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), direction));
	vec3 up = cross(direction, right);
	float facing = max(dot(EYEDIR, direction), 0.0);
	vec2 moon = vec2(dot(EYEDIR, right), dot(EYEDIR, up)) / 0.032;
	float edge = length(moon);
	float disk = (1.0 - smoothstep(0.97, 1.02, edge)) * step(0.5, facing);
	float dome = sqrt(max(1.0 - dot(moon, moon), 0.0));
	float phase = smoothstep(-0.06, 0.23, dot(vec3(moon, dome), vec3(-0.66, 0.3, 0.68)));
	float surface = 0.87 + 0.08 * sin(moon.x * 20.0 + moon.y * 8.0) * sin(moon.y * 26.0);
	night += pow(facing, 350.0) * vec3(0.20, 0.27, 0.40);
	COLOR = mix(night, vec3(0.68, 0.79, 0.95) * surface * (0.10 + 1.60 * phase), disk);
}
