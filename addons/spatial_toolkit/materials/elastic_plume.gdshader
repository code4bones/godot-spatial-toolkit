shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_disabled, depth_draw_never;

uniform vec3 bend_middle = vec3(0.0);
uniform vec3 bend_tail = vec3(0.0);
uniform vec3 nozzle_axis = vec3(0.0, 0.0, 1.0);
uniform float plume_length = 1.0;

void vertex() {
	float age = INSTANCE_CUSTOM.y;
	// Bend both the particle centre and its elongated ends along the curve.
	float local_length = dot(VERTEX - MODEL_MATRIX[3].xyz, nozzle_axis);
	float t = clamp(age + local_length / max(plume_length, 0.01), 0.0, 1.0);
	VERTEX += t * t * mix(bend_middle, bend_tail, t);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
