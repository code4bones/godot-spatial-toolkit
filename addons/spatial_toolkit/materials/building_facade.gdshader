shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://addons/spatial_toolkit/materials/window_lighting.gdshaderinc"

// Visual facade assumptions only: world positions are projected local metres.
// Geometry, source tags and courtyard openings remain authoritative.
uniform vec4 wall_color : source_color = vec4(0.62, 0.59, 0.52, 1.0);
uniform vec4 roof_color : source_color = vec4(0.23, 0.25, 0.26, 1.0);
uniform sampler2D roof_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_metal_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float roof_repeat_m = 0.0;
uniform float roof_metallic = 0.0;
uniform bool roof_has_normal = false;
uniform bool roof_has_roughness = false;
uniform float roof_texture_blend : hint_range(0.0, 1.0) = 0.0;
uniform vec4 roof_weathering_albedo_average : source_color = vec4(0.645, 0.645, 0.645, 1.0);
uniform vec2 roof_weathering_finish_average = vec2(0.91, 1.0);
uniform vec4 glass_color : source_color = vec4(0.19, 0.27, 0.32, 1.0);
uniform bool match_window_palette = false;
uniform vec4 window_frame_color : source_color = vec4(0.19, 0.23, 0.25, 1.0);
uniform float window_glass_roughness = 0.29;
uniform float floor_height : hint_range(2.0, 6.0) = 3.0;
uniform float building_seed = 0.0;
uniform int facade_style : hint_range(0, 1) = 0;
// Geometry is baked in gameplay metres; facade detail stays in source metres.
uniform float world_scale : hint_range(1.0, 100.0) = 1.0;
uniform bool open_windows = false;
uniform sampler2D finish_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D finish_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D finish_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D finish_metal_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float finish_repeat_m = 0.0;
uniform float finish_metallic = 0.0;
uniform float facade_weathering_strength : hint_range(0.0, 1.0) = 0.0;
uniform float facade_texture_blend : hint_range(0.0, 1.0) = 0.0;
uniform float facade_highlights : hint_range(0.0, 1.0) = 0.0;
uniform vec2 facade_highlight_profile = vec2(0.74, 0.34);
uniform vec4 facade_weathering_albedo_average : source_color = vec4(0.645, 0.645, 0.645, 1.0);
uniform vec2 facade_weathering_finish_average = vec2(1.0);
uniform bool upper_floor_windows_only = false;
uniform vec2 facade_long_axis = vec2(0.0);
uniform bool section_windows = false;
uniform int section_first_level = 1;
uniform int section_wall_count = 0;
uniform int section_light_offset = -1;
uniform vec2 section_window_vertical = vec2(1.525, 0.625);
uniform float section_window_depth_m : hint_range(0.0, 0.35) = 0.0;
uniform sampler2D section_window_atlas : filter_nearest, repeat_disable;
uniform float night_uplight = 0.0;
uniform bool lit_windows = false;
uniform float night_fog_density = 0.0;
// Offline bake stores linear wall RGB/style in float CUSTOM0 and seed/floor in UV.
uniform bool baked_facade_data = false;
varying vec4 baked_wall;
varying vec2 baked_layout;

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 local_source_position;
varying flat vec4 section_wall;
varying flat vec4 section_lookup;

float cell_hash(vec2 cell) {
	float seed = baked_facade_data ? baked_layout.x : building_seed;
	return fract(sin(dot(cell, vec2(127.1, 311.7)) + seed * 0.173) * 43758.5453);
}

float weathering_hash(ivec2 cell, uint seed) {
	uint bits = uint(cell.x) * 1597334677u ^ uint(cell.y) * 3812015801u ^ seed * 2798796415u;
	bits = (bits ^ (bits >> 16u)) * 2246822519u;
	return float((bits ^ (bits >> 13u)) & 65535u) / 65535.0;
}

float weathering_field(vec2 point, uint seed) {
	ivec2 cell = ivec2(floor(point));
	vec2 weight = fract(point);
	weight *= weight * (3.0 - 2.0 * weight);
	float near_row = mix(weathering_hash(cell, seed), weathering_hash(cell + ivec2(1, 0), seed), weight.x);
	float far_row = mix(weathering_hash(cell + ivec2(0, 1), seed), weathering_hash(cell + ivec2(1, 1), seed), weight.x);
	return mix(near_row, far_row, weight.y);
}

// Filter the rectangle edges using their projected pixel footprint.
float rectangle_mask(vec2 point, vec2 half_size, vec2 footprint) {
	vec2 edges = smoothstep(half_size - footprint, half_size + footprint, abs(point));
	return (1.0 - edges.x) * (1.0 - edges.y);
}

float window_light_coverage(vec2 point, vec2 half_size, vec2 footprint) {
	vec2 half_pixel = footprint * 0.5;
	vec2 overlap = min(point + half_pixel, half_size) - max(point - half_pixel, -half_size);
	vec2 coverage = clamp(overlap / footprint, vec2(0.0), vec2(1.0));
	return coverage.x * coverage.y;
}

vec4 section_texel(int index) {
	int width = textureSize(section_window_atlas, 0).x;
	return texelFetch(section_window_atlas, ivec2(index % width, index / width), 0);
}

// The ray starts at the facade plane inside the rectangular opening.
// Return the distance and the inward-facing reveal normal in facade coordinates.
vec3 recess_hit(vec2 point, vec2 half_size, vec2 ray, float back_distance) {
	vec2 direction = sign(ray);
	vec2 sides = (half_size - point * direction) / max(abs(ray), vec2(0.00001));
	if (sides.x < min(sides.y, back_distance)) {
		return vec3(sides.x, -direction.x, 0.0);
	}
	if (sides.y < back_distance) {
		return vec3(sides.y, 0.0, -direction.y);
	}
	return vec3(back_distance, 0.0, 0.0);
}

float industrial_grille(vec2 point, vec2 half_size, vec2 footprint) {
	// Normalized bar centers and widths measured in the industrial GLB.
	const vec2 columns[9] = {
		vec2(0.013, 0.026), vec2(0.140, 0.009), vec2(0.2507, 0.018),
		vec2(0.377, 0.009), vec2(0.497, 0.017), vec2(0.626, 0.008),
		vec2(0.7466, 0.018), vec2(0.875, 0.014), vec2(0.987, 0.026)
	};
	const vec2 rows[4] = {
		vec2(0.013, 0.026), vec2(0.327, 0.026), vec2(0.659, 0.025), vec2(0.979, 0.042)
	};
	vec2 size = 2.0 * half_size;
	vec2 uv = point / size + 0.5;
	vec2 column = columns[int(clamp(round(uv.x * 8.0), 0.0, 8.0))];
	vec2 row = rows[int(clamp(round(uv.y * 3.0), 0.0, 3.0))];
	vec2 spacing = size / vec2(8.0, 3.0);
	vec2 distance_to_bar = abs(uv - vec2(column.x, row.x)) * size;
	vec2 half_width = vec2(column.y, row.y) * half_size;
	vec2 antialias = min(footprint, spacing * 0.5);
	vec2 bars = 1.0 - smoothstep(max(half_width - antialias, vec2(0.0)),
		half_width + antialias, distance_to_bar);
	bars *= 1.0 - smoothstep(half_width * 2.0, spacing * 0.45, footprint);
	return max(bars.x, bars.y);
}

void vertex() {
	baked_wall = CUSTOM0;
	baked_layout = UV;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	local_source_position = VERTEX / max(world_scale, 1.0);
	section_wall = vec4(0.0);
	section_lookup = vec4(0.0);
	if (section_windows && abs(NORMAL.y) < 0.05) {
		for (int index = 0; index < section_wall_count; index++) {
			vec4 wall = section_texel(index * 2);
			vec4 lookup = section_texel(index * 2 + 1);
			vec2 normal = vec2(wall.w, -wall.z) * lookup.w;
			vec2 delta = local_source_position.xz - wall.xy;
			float along = dot(delta, wall.zw);
			if (dot(NORMAL.xz, normal) > 0.995 && abs(dot(delta, normal)) <= 0.025
					&& along >= -0.025 && along <= lookup.x + 0.025) {
				section_wall = wall;
				section_lookup = lookup;
				break;
			}
		}
	}
}

// Source-color uniforms stay in sRGB in Compatibility; float bake attributes
// store linear RGB so the same scene remains portable to Forward+/Mobile.
vec3 baked_linear_to_srgb(vec3 color) {
	vec3 high = 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - vec3(0.055);
	return mix(high, color * 12.92, lessThanEqual(color, vec3(0.0031308)));
}

void fragment() {
	// Ordinary surfaces retain their original depth, including opt-out materials.
	DEPTH = FRAGCOORD.z;
	vec4 active_wall = baked_facade_data ? baked_wall : wall_color;
	if (baked_facade_data && OUTPUT_IS_SRGB) {
		active_wall.rgb = baked_linear_to_srgb(active_wall.rgb);
	}
	float active_floor = baked_facade_data ? baked_layout.y : floor_height;
	float active_seed = baked_facade_data ? baked_layout.x : building_seed;
	int active_style = baked_facade_data ? int(round(baked_wall.a)) : facade_style;
	vec3 surface_normal = normalize(world_normal);
	float roof = smoothstep(0.55, 0.8, abs(surface_normal.y));
	vec3 source_position = world_position / max(world_scale, 1.0);
	// Each planar wall uses its dominant horizontal axis; roofs never receive windows.
	bool along_z = abs(surface_normal.x) > abs(surface_normal.z);
	float wall_u = along_z ? source_position.z : source_position.x;
	float level_height = max(active_floor, 2.0);
	vec2 facade_position = vec2(wall_u, source_position.y);
	vec2 cell_size = vec2(2.7, level_height);
	vec2 grid_position = facade_position / cell_size + vec2(fract(active_seed * 0.037), 0.0);
	vec2 cell = floor(grid_position);
	vec2 within_cell = (fract(grid_position) - vec2(0.5)) * cell_size;
	vec2 footprint = max(fwidth(facade_position), vec2(0.012));
	vec2 half_frame = vec2(0.66, level_height * 0.255);
	vec2 half_glass = vec2(0.54, level_height * 0.215);
	bool blocked = upper_floor_windows_only &&
		(cell.y < 1.0 || abs(dot(surface_normal.xz, facade_long_axis)) > 0.58);
	float side = along_z ? (surface_normal.x >= 0.0 ? 0.0 : 1.0) : (surface_normal.z >= 0.0 ? 2.0 : 3.0);
	vec3 stored_section_light = vec3(0.0);
	if (section_windows) {
		vec2 wall_point = vec2(dot(local_source_position.xz - section_wall.xy, section_wall.zw), local_source_position.y);
		footprint = max(fwidth(wall_point), vec2(0.012));
		cell.y = floor(wall_point.y / level_height);
		blocked = section_lookup.x <= 0.0 || cell.y < float(section_first_level) || cell.y > section_lookup.z
			|| wall_point.x < 0.0 || wall_point.x >= section_lookup.x;
		if (!blocked) {
			int stride = int(ceil(section_lookup.x));
			int offset = int(section_lookup.y) + (int(cell.y) - section_first_level) * stride + int(floor(wall_point.x));
			vec4 pair = section_texel(offset);
			bool use_left = abs(wall_point.x - pair.x) <= abs(wall_point.x - pair.y);
			float center = use_left ? pair.x : pair.y;
			cell.x = use_left ? pair.z : pair.w;
			blocked = center < 0.0;
			if (!blocked && section_light_offset >= 0) {
				vec4 prepared_light = section_texel(section_light_offset + int(cell.x));
				stored_section_light = prepared_light.rgb;
				cell.x = prepared_light.a;
			}
			within_cell = wall_point - vec2(center, cell.y * level_height + section_window_vertical.x);
			vec2 normal = vec2(section_wall.w, -section_wall.z) * section_lookup.w;
			side = abs(normal.x) > abs(normal.y) ? (normal.x >= 0.0 ? 0.0 : 1.0) : (normal.y >= 0.0 ? 2.0 : 3.0);
		}
		half_frame = vec2(0.71, section_window_vertical.y);
		half_glass = half_frame * vec2(0.80, 0.84);
	}
	float distance_to_camera = length(CAMERA_POSITION_WORLD - world_position) / max(world_scale, 1.0);
	float detail_visibility = 1.0 - smoothstep(160.0, 650.0, distance_to_camera);
	detail_visibility *= 1.0 - smoothstep(0.3, 1.2, max(footprint.x, footprint.y));
	bool recessed = section_windows && section_window_depth_m > 0.0;
	vec2 grille_point = within_cell;
	vec2 pane_point = within_cell;
	vec3 reveal_normal = vec3(0.0);
	float reveal_shade = 1.0;
	if (recessed) {
		half_glass = max(half_frame - vec2(0.022, 0.028), vec2(0.0));
		if (!open_windows && !blocked && roof == 0.0 && detail_visibility > 0.0
				&& all(lessThan(abs(within_cell), half_frame))) {
			// Orthographic viewing rays are parallel. VIEW points toward the camera.
			vec3 ray_view = PROJECTION_MATRIX[3][3] > 0.5 ? vec3(0.0, 0.0, -1.0) : -VIEW;
			vec3 ray_world = mat3(INV_VIEW_MATRIX) * ray_view;
			float into_wall = -dot(ray_world, surface_normal);
			if (into_wall > 0.0001) {
				vec3 tangent = normalize(mat3(MODEL_MATRIX) * vec3(section_wall.z, 0.0, section_wall.w));
				vec3 up = normalize(MODEL_MATRIX[1].xyz);
				vec2 wall_ray = vec2(dot(ray_world, tangent), dot(ray_world, up));
				float back_distance = section_window_depth_m / into_wall;
				vec3 hit = recess_hit(within_cell, half_frame, wall_ray, back_distance);
				pane_point += wall_ray * hit.x;
				// Keep painted bars aligned with the middle of the streamed 3D frames.
				grille_point += wall_ray * (back_distance * 0.56);
				reveal_normal = tangent * hit.y + up * hit.z;
				reveal_shade = mix(0.77, 0.53, hit.x / back_distance);
				vec4 clip = PROJECTION_MATRIX * vec4(VERTEX + ray_view * (hit.x * max(world_scale, 1.0)), 1.0);
				// Compatibility uses NDC Z [-1,1], Vulkan renderers use [0,1].
				float inset_depth = (clip.z / clip.w - CLIP_SPACE_FAR) / (1.0 - CLIP_SPACE_FAR);
				DEPTH = min(FRAGCOORD.z, clamp(inset_depth, 0.0, 1.0));
			}
		}
	}
	bool on_reveal = dot(reveal_normal, reveal_normal) > 0.5;

	vec3 plaster = active_wall.rgb;
	// Broad, restrained variation avoids a texture-like noisy surface at overview scale.
	float weathering = sin(wall_u * 0.13 + active_seed) * sin(source_position.y * 0.19);
	plaster *= 0.98 + 0.02 * weathering;
	if (active_style == 1 && finish_repeat_m <= 0.0) {
		float brick_row = floor(source_position.y / 0.25);
		vec2 brick_point = vec2(wall_u + mod(brick_row, 2.0) * 0.26, source_position.y);
		vec2 brick_cell_size = vec2(0.52, 0.25);
		vec2 brick_local = (fract(brick_point / brick_cell_size) - vec2(0.5)) * brick_cell_size;
		float brick = rectangle_mask(brick_local, brick_cell_size * 0.5 - vec2(0.013), footprint);
		float brick_visibility = detail_visibility * (1.0 - smoothstep(30.0, 120.0, distance_to_camera));
		plaster *= mix(1.0, mix(0.76, 1.025, brick), brick_visibility);
	}
	float wall_roughness = 0.86;
	float wall_metallic = 0.0;
	float wall_specular = 0.24;
	float source_pixel_m = 0.0;
	if (facade_weathering_strength > 0.0 || facade_texture_blend > 0.0 || roof_texture_blend > 0.0) {
		source_pixel_m = max(length(dFdx(source_position)), length(dFdy(source_position)));
	}
	vec3 finish_world_normal = surface_normal;
	if (finish_repeat_m > 0.0 && roof < 1.0) {
		vec3 across = normalize(cross(vec3(0.0, 1.0, 0.0), surface_normal));
		vec3 up = cross(surface_normal, across);
		vec2 tile = vec2(dot(source_position, across), -dot(source_position, up)) / finish_repeat_m;
		vec3 finish_color = texture(finish_albedo, tile).rgb;
		wall_roughness = texture(finish_roughness, tile).r;
		wall_metallic = finish_metallic * texture(finish_metal_map, tile).r;
		vec2 slope = texture(finish_normal, tile).rg * 2.0 - 1.0;
		float coarse_repeat = smoothstep(0.15, 0.90, source_pixel_m / finish_repeat_m);
		if (facade_texture_blend > 0.0) {
			// Capture the original gradients before the per-pixel mask and distance tests.
			vec2 tile_dx = dFdx(tile);
			vec2 tile_dy = dFdy(tile);
			if (coarse_repeat < 1.0) {
				uint seed = uint(active_seed) + uint(side) * 997u + 557u;
				vec2 wall_m = tile * finish_repeat_m;
				float patch_m = max(4.0, finish_repeat_m * 2.0);
				float mask = weathering_field(wall_m / (patch_m * vec2(1.0, 1.45)), seed);
				float blend = facade_texture_blend * smoothstep(0.26, 0.74, mask) * (1.0 - coarse_repeat);
				if (blend > 0.0) {
					// Shift along the wall to keep brick courses and cladding rows level.
					float phase = mix(0.32, 0.68, weathering_hash(ivec2(17, 9), seed));
					vec2 shifted = tile + vec2(phase, 0.0);
					finish_color = mix(finish_color, textureGrad(finish_albedo, shifted, tile_dx, tile_dy).rgb, blend);
					wall_roughness = mix(wall_roughness, textureGrad(finish_roughness, shifted, tile_dx, tile_dy).r, blend);
					wall_metallic = mix(wall_metallic, finish_metallic * textureGrad(finish_metal_map, shifted, tile_dx, tile_dy).r, blend);
					slope = mix(slope, textureGrad(finish_normal, shifted, tile_dx, tile_dy).rg * 2.0 - 1.0, blend);
				}
			}
		}
		if (facade_weathering_strength > 0.0) {
			// Blend toward the material's own averages as a repeat approaches a pixel.
			float fade = facade_weathering_strength * coarse_repeat;
			finish_color = mix(finish_color, facade_weathering_albedo_average.rgb, fade);
			wall_roughness = mix(wall_roughness, facade_weathering_finish_average.x, fade);
			wall_metallic = mix(wall_metallic, finish_metallic * facade_weathering_finish_average.y, fade);
			slope *= 1.0 - fade;
		}
		plaster *= mix(vec3(1.0), finish_color * 1.55, 0.80);
		float face = sqrt(max(1.0 - dot(slope, slope), 0.0));
		finish_world_normal = normalize(across * slope.x - up * slope.y + surface_normal * face);
	}
	if (facade_weathering_strength > 0.0 && roof < 1.0) {
		vec3 across = normalize(cross(vec3(0.0, 1.0, 0.0), surface_normal));
		vec2 wall_m = vec2(dot(source_position, across), source_position.y);
		uint seed = uint(active_seed) + uint(side) * 997u;
		float wide = weathering_field(wall_m / 17.0, seed);
		float mids = weathering_field(wall_m / 8.0, seed + 101u);
		float patina = (mix(wide, mids, 0.32) - 0.5) * 2.0;
		float base = 1.0 - smoothstep(0.1, 4.1 + mids * 2.2, wall_m.y);
		float streaks = smoothstep(0.73, 0.95,
			weathering_field(wall_m / vec2(1.35, 10.0), seed + 307u));
		streaks *= (1.0 - smoothstep(0.13, 0.90, source_pixel_m)) * (0.35 + 0.65 * wide);
		float tone = 0.27 * patina - 0.17 * base - 0.15 * streaks;
		plaster *= 1.0 + facade_weathering_strength * tone;
		wall_roughness = clamp(wall_roughness + facade_weathering_strength *
			(-0.15 * patina + 0.05 * base + 0.04 * streaks), 0.0, 1.0);
	}
	// Slim horizontal slab bands and inset dark glazing with a concrete surround.
	// Place the slab at the cell boundary, between successive rows of windows.
	float band = 1.0 - smoothstep(0.055, 0.055 + footprint.y, level_height * 0.5 - abs(within_cell.y));
	if (!section_windows) {
		plaster *= 1.0 - 0.12 * band * detail_visibility;
	}
	float surround = rectangle_mask(within_cell, half_frame, footprint);
	float pane = rectangle_mask(pane_point, half_glass, footprint);
	if (recessed) {
		pane = on_reveal ? 0.0 : pane * surround;
	}
	if (open_windows || blocked) {
		// Actual holes and their reveals are the facade's sole window layout.
		// Painting panes elsewhere would imply sealed or misaligned openings.
		surround = 0.0;
		pane = 0.0;
	}
	if (facade_highlights > 0.0 && roof < 1.0) {
		// Keep the finish's local variation and leave the window surround alone.
		float highlight = facade_highlights * (1.0 - surround * detail_visibility);
		wall_roughness = mix(wall_roughness, facade_highlight_profile.x, highlight * 0.64);
		wall_specular = mix(wall_specular, facade_highlight_profile.y, highlight);
	}
	float mullion = 1.0 - smoothstep(0.025, 0.025 + footprint.x, abs(within_cell.x));
	if (recessed && pane > 0.0) {
		// The GLB's horizontal basis is UP × wall_normal.
		vec2 frame_point = vec2(-section_lookup.w * grille_point.x, grille_point.y);
		mullion = industrial_grille(frame_point, half_frame, footprint);
	}
	float pane_variation = match_window_palette ? 1.0 : mix(0.83, 1.08, cell_hash(cell));
	vec3 glazing = glass_color.rgb * pane_variation;
	vec3 frame_color = match_window_palette ? window_frame_color.rgb : active_wall.rgb * 0.78;
	float grille = mullion * (recessed ? 1.0 : 0.65);
	glazing = mix(glazing, match_window_palette ? window_frame_color.rgb : active_wall.rgb * 0.63,
		grille);
	vec3 facade = mix(plaster, frame_color, surround * detail_visibility);
	facade = mix(facade, glazing, pane * detail_visibility);
	if (on_reveal) {
		facade = mix(facade, plaster * reveal_shade, surround * detail_visibility);
	}

	vec3 roof_finish = roof_color.rgb;
	float roof_rough = 0.91;
	float roof_metal = 0.0;
	vec3 roof_world_normal = surface_normal;
	if (roof_repeat_m > 0.0 && roof > 0.0) {
		vec2 roof_m = vec2(source_position.x, -source_position.z);
		vec2 roof_uv = roof_m / roof_repeat_m;
		roof_finish = texture(roof_albedo, roof_uv).rgb;
		if (roof_has_roughness) {
			roof_rough = texture(roof_roughness, roof_uv).r;
		}
		roof_metal = roof_metallic * texture(roof_metal_map, roof_uv).r;
		vec2 slope = vec2(0.0);
		if (roof_has_normal) {
			slope = texture(roof_normal, roof_uv).rg * 2.0 - 1.0;
		}
		if (roof_texture_blend > 0.0) {
			vec2 roof_dx = dFdx(roof_uv);
			vec2 roof_dy = dFdy(roof_uv);
			uint seed = uint(active_seed) + 823u;
			float coarse_repeat = smoothstep(0.04, 0.24, source_pixel_m / roof_repeat_m);
			float patch_m = max(6.0, roof_repeat_m * 2.5);
			float patch = weathering_field(roof_m / patch_m, seed);
			float patch_mix = mix(0.30, 0.58, smoothstep(0.22, 0.78, patch));
			float blend = roof_texture_blend * patch_mix * (1.0 - coarse_repeat);
			if (blend > 0.0) {
				// Keep the existing orientation of the sheet and its seams.
				vec2 phase = mix(vec2(0.30), vec2(0.70), vec2(
					weathering_hash(ivec2(2, 11), seed), weathering_hash(ivec2(17, 3), seed)));
				vec2 shifted = roof_uv + phase;
				roof_finish = mix(roof_finish, textureGrad(roof_albedo, shifted, roof_dx, roof_dy).rgb, blend);
				if (roof_has_roughness) {
					roof_rough = mix(roof_rough, textureGrad(roof_roughness, shifted, roof_dx, roof_dy).r, blend);
				}
				if (roof_metallic > 0.0) {
					roof_metal = mix(roof_metal, roof_metallic * textureGrad(roof_metal_map, shifted, roof_dx, roof_dy).r, blend);
				}
				if (roof_has_normal) {
					slope = mix(slope, textureGrad(roof_normal, shifted, roof_dx, roof_dy).rg * 2.0 - 1.0, blend);
				}
			}
			float fade = roof_texture_blend * coarse_repeat;
			roof_finish = mix(roof_finish, roof_weathering_albedo_average.rgb, fade);
			if (roof_has_roughness) {
				roof_rough = mix(roof_rough, roof_weathering_finish_average.x, fade);
			}
			roof_metal = mix(roof_metal, roof_metallic * roof_weathering_finish_average.y, fade);
			slope *= 1.0 - fade;
			float broad = weathering_field(roof_m / 16.0, seed + 137u);
			roof_finish *= 1.0 + roof_texture_blend * (broad - 0.5) * 0.20;
		}
		if (roof_has_normal) {
			float up = sqrt(max(1.0 - dot(slope, slope), 0.0));
			vec3 tangent = normalize(vec3(1.0, 0.0, 0.0) - surface_normal * surface_normal.x);
			vec3 bitangent = cross(surface_normal, tangent);
			roof_world_normal = normalize(tangent * slope.x + surface_normal * up + bitangent * slope.y);
		}
	}
	ALBEDO = mix(facade, roof_finish, roof);
	if (night_uplight > 0.0 && roof < 1.0) {
		float height = max(0.0, source_position.y);
		float phase = active_seed * 0.149;
		float lateral = abs(fract(wall_u / 8.0 + phase) - 0.5) * 8.0;
		float beam = 1.0 - smoothstep(0.15 + height * 0.24, 1.15 + height * 0.40, lateral);
		float falloff = exp(-height * 0.22) * (1.0 - smoothstep(8.0, 14.0, height));
		float range = 1.0 - smoothstep(95.0, 235.0, distance_to_camera);
		vec3 light_color = mix(vec3(1.0, 0.56, 0.25), vec3(0.29, 0.68, 1.0),
			step(0.6, fract(active_seed * 0.317)));
		EMISSION = light_color * mix(vec3(0.32), facade, 0.55)
			* (1.0 - roof) * beam * falloff * range * night_uplight * 1.7;
	}
	if (lit_windows && !open_windows && !blocked && roof < 1.0) {
		bool prepared = section_windows && section_light_offset >= 0;
		float distant = smoothstep(120.0, 350.0, distance_to_camera);
		float fog_boost = exp(min(night_fog_density * distance_to_camera * 0.82, 2.6));
		float coverage;
		if (prepared) {
			// An illuminated opening also lights its recess. Sample that glow
			// on the facade plane so a grazing ray cannot switch it off.
			coverage = window_light_coverage(within_cell, half_glass, footprint);
			if (recessed && coverage > 0.0) {
				vec2 frame_point = vec2(-section_lookup.w * within_cell.x, within_cell.y);
				coverage *= 1.0 - industrial_grille(frame_point, half_frame, footprint);
			}
			coverage *= mix(1.0, fog_boost, distant);
		} else {
			float glass = pane * (1.0 - grille);
			// Preserve the center of a legacy window as a subpixel dot.
			vec2 radius = min(max(vec2(0.45, 0.48), footprint * 0.62), cell_size * 0.37);
			float point = 1.0 - smoothstep(0.2, 1.0, length(within_cell / radius));
			vec2 cell_footprint = footprint / cell_size;
			float resolved = 1.0 - smoothstep(0.55, 1.10, max(cell_footprint.x, cell_footprint.y));
			float range = 1.0 - smoothstep(850.0, 1350.0, distance_to_camera);
			coverage = mix(glass, point * resolved * range * fog_boost, distant);
		}
		if (coverage > 0.0) {
			vec3 light = prepared ? stored_section_light :
				(section_windows ? section_emission(cell, active_seed, side) : apartment_emission(cell, active_seed, side));
			EMISSION += light * coverage * (1.0 - roof);
		}
	}
	ROUGHNESS = mix(mix(wall_roughness, window_glass_roughness, pane * detail_visibility), roof_rough, roof);
	SPECULAR = mix(mix(wall_specular, 0.32, pane * detail_visibility), 0.2, roof);
	float finish_mask = (1.0 - roof) * (1.0 - surround * detail_visibility);
	METALLIC = wall_metallic * finish_mask + roof_metal * roof;
	if (finish_repeat_m > 0.0 || roof_has_normal) {
		vec3 shaded_normal = mix(surface_normal, finish_world_normal, finish_mask * detail_visibility);
		shaded_normal = mix(shaded_normal, roof_world_normal, roof * detail_visibility);
		NORMAL = normalize(mat3(VIEW_MATRIX) * shaded_normal);
	}
	if (on_reveal) {
		NORMAL = normalize(mat3(VIEW_MATRIX) * reveal_normal);
	}
}
