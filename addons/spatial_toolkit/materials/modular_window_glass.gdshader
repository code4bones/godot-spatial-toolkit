shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 glass_color : source_color;
uniform float glass_roughness;
uniform float glass_specular;
uniform bool lit_windows = false;

varying flat vec3 window_emission;

void vertex() {
	window_emission = INSTANCE_CUSTOM.rgb;
}

void fragment() {
	ALBEDO = glass_color.rgb;
	ROUGHNESS = glass_roughness;
	SPECULAR = glass_specular;
	if (lit_windows) {
		EMISSION = window_emission;
	}
}
