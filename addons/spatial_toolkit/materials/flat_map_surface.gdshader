shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_burley, specular_disabled;

uniform vec4 surface_color : source_color = vec4(0.47, 0.52, 0.40, 1.0);

uniform bool baked_vertex_color = false;
varying vec4 baked_surface_color;

void vertex() {
	baked_surface_color = CUSTOM0;
}

// Source-color uniforms stay in sRGB in Compatibility; float bake attributes
// store linear RGB so the same scene remains portable to Forward+/Mobile.
vec3 baked_linear_to_srgb(vec3 color) {
	vec3 high = 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - vec3(0.055);
	return mix(high, color * 12.92, lessThanEqual(color, vec3(0.0031308)));
}

void fragment() {
	// Flat imported layers have upward normals. Keep depth testing so opaque
	// buildings occlude these surfaces; their material priorities order painting.
	vec3 active_color = baked_vertex_color ? baked_surface_color.rgb : surface_color.rgb;
	if (baked_vertex_color && OUTPUT_IS_SRGB) {
		active_color = baked_linear_to_srgb(active_color);
	}
	ALBEDO = active_color;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	// Explicit ALPHA selects the transparent pass even at full opacity.
	// No flat layer writes depth, avoiding coplanar map-layer depth conflicts.
	ALPHA = 1.0;
}
