shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

void fragment() {
	float flange = 1.0 - smoothstep(0.018, 0.040, abs(fract(UV.y / 9.0) - 0.5));
	float signal = (1.0 - smoothstep(0.48, 0.52, abs(fract(UV.y / 9.0) - 0.5) * 7.0))
		* (1.0 - smoothstep(0.02, 0.05, abs(UV.x - 0.26)));
	ALBEDO = mix(vec3(0.17, 0.22, 0.25), vec3(0.30, 0.36, 0.39), flange);
	METALLIC = 0.57;
	ROUGHNESS = mix(0.56, 0.38, flange);
	EMISSION = vec3(0.08, 0.49, 0.54) * signal * 0.65;
}
