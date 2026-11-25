uniform sampler2D road_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float repeat_size = 2.0;
uniform float macro_scale : hint_range(2.0, 24.0) = 8.0;
uniform float macro_contrast : hint_range(0.0, 0.6) = 0.0;
uniform vec4 surface_tint : source_color = vec4(1.0);
uniform float ground_texture_blend : hint_range(0.0, 1.0) = 0.0;
uniform float ground_tone_variation : hint_range(0.0, 1.0) = 0.0;
uniform float ground_world_scale = 1.0;
uniform vec4 ground_albedo_average : source_color = vec4(0.0);
uniform float ground_roughness_average = 1.0;
#ifdef OPAQUE_TERRAIN
instance uniform vec2 terrain_center;
instance uniform float terrain_radius = 1.0;
#endif

varying vec2 road_position;
varying vec3 surface_normal;

void vertex() {
	vec3 position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	road_position = vec2(position.x, -position.z);
	surface_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float terrain_hash(vec2 cell) {
	vec3 seed = fract(vec3(cell.xyx) * 0.1031);
	seed += dot(seed, seed.yzx + 33.33);
	return fract((seed.x + seed.y) * seed.z);
}

float terrain_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 weight = smoothstep(vec2(0.0), vec2(1.0), fract(position));
	float near_row = mix(terrain_hash(cell), terrain_hash(cell + vec2(1.0, 0.0)), weight.x);
	float far_row = mix(terrain_hash(cell + vec2(0.0, 1.0)),
		terrain_hash(cell + vec2(1.0, 1.0)), weight.x);
	return mix(near_row, far_row, weight.y);
}

void fragment() {
	vec2 tile = road_position / repeat_size;
	vec2 tile_dx = vec2(0.0);
	vec2 tile_dy = vec2(0.0);
	if (ground_texture_blend > 0.0) {
		tile_dx = dFdx(tile);
		tile_dy = dFdy(tile);
	}
#ifdef OPAQUE_TERRAIN
	// Fade the foot into the underlying terrain while keeping the slope opaque.
	float edge = length(road_position - terrain_center) / terrain_radius;
	if (edge > 0.76) {
		float coverage = 1.0 - smoothstep(0.76, 1.0, edge);
		if (coverage < terrain_hash(floor(road_position * 18.0)) || edge >= 1.0) {
			discard;
		}
	}
#endif
	vec3 albedo = texture(road_albedo, tile).rgb;
	vec2 slope = texture(road_normal, tile).rg * 2.0 - 1.0;
	float roughness = texture(road_roughness, tile).r;
	if (ground_texture_blend > 0.0 || ground_tone_variation > 0.0) {
		vec2 source_position = road_position / ground_world_scale;
		if (ground_texture_blend > 0.0) {
			float footprint = max(length(tile_dx), length(tile_dy));
			float fade = smoothstep(0.025, 0.18, footprint);
			if (fade < 1.0) {
				float patch = terrain_noise(source_position / 9.0 + vec2(17.3, -8.1));
				float patch_mix = mix(0.32, 0.58, smoothstep(0.18, 0.82, patch));
				float blend = patch_mix * ground_texture_blend * (1.0 - fade);
				if (blend > 0.0) {
					vec2 shifted = tile + vec2(0.371, 0.619);
					albedo = mix(albedo, textureGrad(road_albedo, shifted, tile_dx, tile_dy).rgb, blend);
					slope = mix(slope, textureGrad(road_normal, shifted, tile_dx, tile_dy).rg * 2.0 - 1.0, blend);
					roughness = mix(roughness, textureGrad(road_roughness, shifted, tile_dx, tile_dy).r, blend);
				}
			}
			float average_weight = fade * ground_texture_blend;
			albedo = mix(albedo, ground_albedo_average.rgb, average_weight * ground_albedo_average.a);
			slope *= 1.0 - average_weight;
			roughness = mix(roughness, ground_roughness_average, average_weight);
		}
		if (ground_tone_variation > 0.0) {
			vec2 field = source_position / 27.0 + vec2(-7.4, 19.2);
			float pattern = mix(terrain_noise(field), terrain_noise(field * 2.4 + vec2(3.3, 8.7)), 0.26);
			albedo *= 1.0 + (pattern * 2.0 - 1.0) * ground_tone_variation;
		}
	}
	ALBEDO = albedo * surface_tint.rgb;
	if (macro_contrast > 0.0) {
		vec2 field = tile / macro_scale;
		float pattern = mix(terrain_noise(field),
			terrain_noise(field * 2.7 + vec2(13.7, 4.3)), 0.28);
		float tone = smoothstep(0.23, 0.77, pattern) * 2.0 - 1.0;
		ALBEDO *= 1.0 + tone * macro_contrast;
	}
	float up = sqrt(max(1.0 - dot(slope, slope), 0.0));
	vec3 normal_world = normalize(surface_normal);
	vec3 tangent = normalize(vec3(1.0, 0.0, 0.0) - normal_world * normal_world.x);
	vec3 bitangent = cross(normal_world, tangent);
	NORMAL = normalize(mat3(VIEW_MATRIX) * (tangent * slope.x + normal_world * up + bitangent * slope.y));
	ROUGHNESS = roughness;
#ifndef OPAQUE_TERRAIN
	// Keep the same ordered, depth-tested pass as the flat road material.
	ALPHA = 1.0;
#endif
}
