shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// Entire source-derived shell, not sparse props: feature-local source metres
// eliminate district-scale precision drift and keep every wall orientation.
uniform float panel_scale_m : hint_range(1.0, 30.0) = 6.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 1.8;
varying vec2 feature_uv;
varying vec2 wall_uv;
varying vec4 technology;
varying vec4 energy_data;
varying vec3 source_facing;

void vertex() {
	feature_uv = UV;
	wall_uv = UV2;
	technology = CUSTOM0; // deterministic seed, archetype, source height, roof flag
	energy_data = CUSTOM1; // linear accent RGB and stable face orientation phase
	source_facing = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float hash_cell(vec2 p, float seed) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 0.173) * 43758.5453);
}

vec3 linear_to_display(vec3 color) {
	vec3 high = 1.055 * pow(max(color, vec3(0.0)), vec3(1.0 / 2.4)) - vec3(0.055);
	return mix(high, color * 12.92, lessThanEqual(color, vec3(0.0031308)));
}

float rect_distance(vec2 p, vec2 half_size) {
	vec2 d = abs(p) - half_size;
	return max(d.x, d.y);
}

float cut_plate_distance(vec2 p, vec2 half_size, float chamfer) {
	vec2 d = abs(p);
	return max(max(d.x - half_size.x, d.y - half_size.y), (d.x + d.y - half_size.x - half_size.y + chamfer) * 0.70710678);
}

float inside_edge(float distance_value, float footprint) {
	return 1.0 - smoothstep(-footprint, footprint, distance_value);
}

float stroke(float distance_value, float thickness, float footprint) {
	return 1.0 - smoothstep(thickness - footprint, thickness + footprint, abs(distance_value));
}

void fragment() {
	float seed = technology.x;
	float archetype = technology.y;
	float roof = technology.w;
	float orientation = energy_data.a;
	vec3 accent = OUTPUT_IS_SRGB ? linear_to_display(energy_data.rgb) : energy_data.rgb;
	// Source-metre module size stays fixed when the whole map is enlarged.
	vec2 uv = feature_uv / max(panel_scale_m, 1.0);
	float face_phase = mod(orientation, 4.0);
	float face_scale = 0.82 + 0.16 * mod(floor(seed * 0.017) + face_phase, 3.0);
	uv *= face_scale;
	uv += vec2(mod(seed * 0.031, 5.0), mod(seed * 0.019, 3.0));
	vec2 footprint = max(fwidth(uv), vec2(0.0004));
	float aa = max(footprint.x, footprint.y);
	float fine_visibility = 1.0 - smoothstep(0.018, 0.095, aa);
	float medium_visibility = 1.0 - smoothstep(0.12, 0.55, aa);
	vec3 dark_hull = vec3(0.075, 0.115, 0.155);
	vec3 bright_hull = vec3(0.46, 0.57, 0.64);
	vec3 steel = mix(dark_hull, bright_hull, 0.48);
	float energy = 0.0;
	float bevel = 0.0;
	float recess = 0.0;
	float vent = 0.0;
	float hatch = 0.0;
	float plate_variation = 0.5;
	vec2 details = vec2(0.0);

	if (archetype < 0.5) {
		// Overlapping chamfered armour with asymmetrical stepped energy inlays.
		vec2 p = uv * vec2(0.92, 0.72);
		aa = max(max(fwidth(p).x, fwidth(p).y), 0.0004);
		float row = floor(p.y);
		p.x += mod(row, 2.0) * 0.37;
		vec2 cell = floor(p);
		vec2 local = fract(p) - 0.5;
		float plate = cut_plate_distance(local, vec2(0.455, 0.435), 0.105);
		float mask = inside_edge(plate, aa);
		plate_variation = hash_cell(cell, seed);
		steel = mix(dark_hull * 0.28, mix(vec3(0.25, 0.35, 0.43), bright_hull, plate_variation), mask);
		bevel = stroke(plate + 0.028, 0.018, aa) * mask;
		recess = 1.0 - mask;
		float diagonal = local.x + local.y * 0.42;
		float conduit = stroke(diagonal - 0.17, 0.026, aa) * inside_edge(abs(local.y) - 0.34, aa);
		energy = conduit * step(0.20, plate_variation);
		float corner_mark = inside_edge(rect_distance(local - vec2(-0.27, 0.25), vec2(0.08, 0.025)), aa);
		energy = max(energy, corner_mark);
		details = local;
	} else if (archetype < 1.5) {
		// Broad vertical spines: no storey stripes, a large industrial machine.
		vec2 p = uv * vec2(0.58, 0.28);
		aa = max(max(fwidth(p).x, fwidth(p).y), 0.0004);
		vec2 cell = floor(p);
		vec2 local = fract(p) - 0.5;
		float spine = 1.0 - smoothstep(0.20 - aa, 0.24 + aa, abs(local.x));
		float rib_edge = stroke(abs(local.x) - 0.215, 0.025, aa);
		float central_channel = 1.0 - smoothstep(0.064 - aa, 0.095 + aa, abs(local.x));
		steel = mix(vec3(0.13, 0.21, 0.28), vec3(0.48, 0.59, 0.66), spine);
		steel = mix(steel, dark_hull * 0.25, central_channel);
		bevel = rib_edge;
		recess = central_channel;
		float interrupts = inside_edge(abs(local.y) - 0.38, aa);
		energy = stroke(local.x, 0.025, aa) * interrupts;
		float braces = stroke(abs(local.y) + abs(local.x) * 0.75 - 0.46, 0.035, aa);
		steel = mix(steel, bright_hull * 1.05, braces * 0.85);
		energy = max(energy, braces * stroke(abs(local.x) - 0.32, 0.065, aa));
		plate_variation = hash_cell(cell, seed);
		details = vec2(local.x * 1.6, local.y);
	} else if (archetype < 2.5) {
		// Staggered cellular reactors recessed into heavy, clipped metal plates.
		vec2 p = uv * vec2(0.65, 0.68);
		aa = max(max(fwidth(p).x, fwidth(p).y), 0.0004);
		p.x += mod(floor(p.y), 2.0) * 0.5;
		vec2 cell = floor(p);
		vec2 local = fract(p) - 0.5;
		float hex_distance = max(abs(local.x) * 0.8660254 + abs(local.y) * 0.5, abs(local.y)) - 0.36;
		float cell_plate = inside_edge(hex_distance, aa);
		float chamber = inside_edge(hex_distance + 0.105, aa);
		steel = mix(vec3(0.11, 0.17, 0.23), vec3(0.53, 0.61, 0.65), cell_plate);
		steel = mix(steel, dark_hull * 0.28, chamber);
		bevel = stroke(hex_distance + 0.045, 0.022, aa);
		recess = chamber;
		energy = stroke(hex_distance + 0.13, 0.025, aa);
		float core = inside_edge(rect_distance(local, vec2(0.075, 0.12)), aa);
		energy = max(energy * 0.9, core);
		plate_variation = hash_cell(cell, seed);
		energy *= mix(0.45, 1.0, step(0.28, plate_variation));
		details = local;
	} else {
		// Huge segmented hull panels, broad service hatches and offset channels.
		vec2 p = uv * vec2(0.31, 0.24);
		aa = max(max(fwidth(p).x, fwidth(p).y), 0.0004);
		p.y += mod(floor(p.x), 2.0) * 0.31;
		vec2 cell = floor(p);
		vec2 local = fract(p) - 0.5;
		float plate = cut_plate_distance(local, vec2(0.47, 0.465), 0.065);
		float mask = inside_edge(plate, aa);
		plate_variation = hash_cell(cell, seed);
		steel = mix(dark_hull * 0.20, mix(vec3(0.27, 0.36, 0.44), vec3(0.63, 0.66, 0.65), plate_variation), mask);
		bevel = stroke(plate + 0.022, 0.013, aa);
		float hatch_distance = cut_plate_distance(local - vec2(0.06, 0.015), vec2(0.25, 0.29), 0.07);
		hatch = stroke(hatch_distance, 0.018, aa);
		steel = mix(steel, dark_hull * 0.50, inside_edge(hatch_distance, aa) * 0.64);
		recess = max(1.0 - mask, hatch);
		float route_x = local.x + 0.36 - clamp(local.y * 0.45, -0.11, 0.11);
		energy = stroke(route_x, 0.014, aa) * inside_edge(abs(local.y) - 0.36, aa);
		energy = max(energy, inside_edge(rect_distance(local - vec2(0.23, -0.25), vec2(0.09, 0.012)), aa));
		details = local;
	}

	// Broad circuitry links modules across multiple plates; this survives the
	// fine-detail fade and keeps far silhouettes recognisably technological.
	vec2 macro_uv = uv * vec2(0.19, 0.095);
	float macro_aa = max(max(fwidth(macro_uv).x, fwidth(macro_uv).y), 0.0004);
	float macro_route = abs(fract(macro_uv.x + floor(macro_uv.y) * 0.23) - 0.5);
	float macro_channel = 1.0 - smoothstep(0.045 - macro_aa, 0.075 + macro_aa, macro_route);
	float macro_core = 1.0 - smoothstep(0.012 - macro_aa, 0.026 + macro_aa, macro_route);
	steel = mix(steel, dark_hull * 0.20, macro_channel * 0.88);
	energy = max(energy * medium_visibility, macro_core * 0.8);

	// Medium-scale service plates fill the interior of large hull modules.
	// Their staggered chamfers and routed circuits do not imply human storeys.
	vec2 service_uv = uv * vec2(0.90, 0.74);
	float service_aa = max(max(fwidth(service_uv).x, fwidth(service_uv).y), 0.0004);
	service_uv.x += floor(service_uv.y) * 0.31;
	vec2 service_local = fract(service_uv) - 0.5;
	float service_plate = cut_plate_distance(service_local, vec2(0.43, 0.39), 0.08);
	float service_seam = stroke(service_plate, 0.014, service_aa);
	float service_edge = stroke(service_plate + 0.036, 0.009, service_aa);
	steel = mix(steel, dark_hull * 0.16, service_seam * medium_visibility * 0.75);
	steel += vec3(0.075, 0.09, 0.10) * service_edge * medium_visibility;
	float short_trace = stroke(service_local.x + 0.21, 0.013, service_aa) * inside_edge(abs(service_local.y + 0.08) - 0.16, service_aa);
	float trace_turn = stroke(service_local.y - 0.08, 0.013, service_aa) * inside_edge(abs(service_local.x + 0.12) - 0.09, service_aa);
	energy = max(energy, max(short_trace, trace_turn) * medium_visibility * 0.78);

	// Guaranteed per-wall technology: even a tiny end face inside one giant
	// hull cell has a structural channel and hatch. UV2 bounds each connected
	// coplanar wall, so separated wings cannot steal each other's features.
	vec2 face_footprint = max(fwidth(wall_uv), vec2(0.0004));
	float face_aa = max(face_footprint.x, face_footprint.y);
	float spine_x = 0.24 + 0.13 * hash_cell(vec2(face_phase, 1.0), seed);
	float face_route = abs(wall_uv.x - spine_x);
	float face_span = smoothstep(0.03, 0.10, wall_uv.y) * (1.0 - smoothstep(0.88, 0.97, wall_uv.y));
	float face_channel = (1.0 - smoothstep(0.048 - face_footprint.x, 0.068 + face_footprint.x, face_route)) * face_span;
	float face_core = (1.0 - smoothstep(0.009 - face_footprint.x, 0.020 + face_footprint.x, face_route)) * face_span;
	steel = mix(steel, dark_hull * 0.15, face_channel * 0.9);
	float face_frame = stroke(face_route - 0.058, 0.009, face_footprint.x) * face_span;
	steel += vec3(0.18, 0.22, 0.25) * face_frame;
	energy = max(energy, face_core);
	vec2 hatch_point = wall_uv - vec2(0.67, 0.58);
	float wall_hatch = cut_plate_distance(hatch_point, vec2(0.19, 0.16), 0.05);
	float hatch_inset = inside_edge(wall_hatch, face_aa);
	float hatch_rim = stroke(wall_hatch + 0.014, 0.010, face_aa);
	steel = mix(steel, vec3(0.16, 0.22, 0.28), hatch_inset * 0.70);
	steel += vec3(0.22, 0.25, 0.27) * hatch_rim;
	float hatch_glyph = inside_edge(rect_distance(hatch_point - vec2(0.08, -0.04), vec2(0.055, 0.016)), face_aa);
	energy = max(energy, hatch_glyph);

	// Small service vents and bevel edge highlights enrich close views without
	// creating a window grid or flickering at distance.
	float vent_region = inside_edge(rect_distance(details - vec2(-0.19, -0.18), vec2(0.12, 0.10)), aa);
	float slats = step(0.45, fract(details.y * 36.0 + seed));
	vent = vent_region * mix(0.45, slats, fine_visibility);
	steel = mix(steel, dark_hull * 0.12, vent * 0.9);
	steel += bevel * medium_visibility * vec3(0.12, 0.14, 0.15);
	steel *= 0.90 + 0.15 * plate_variation;
	// Deterministic broad art lighting: no reception of the coincident source
	// caster's shadow acne. Source sun/environment resources are untouched.
	vec3 facing = normalize(source_facing);
	float art_light = 0.70 + 0.26 * max(dot(facing, normalize(vec3(-0.45, 0.65, 0.60))), 0.0);
	steel *= art_light;
	// Roof uses the same technical skin, with a quieter cool-metal finish.
	steel = mix(steel, steel * vec3(0.86, 0.92, 1.0), roof * 0.45);
	// Compatibility's unshaded path may not add EMISSION to the displayed
	// colour. Put luminous circuit colour explicitly into ALBEDO as well.
	float luminous = clamp(energy, 0.0, 1.0);
	ALBEDO = mix(max(steel, vec3(0.0)), accent * 1.12, luminous * 0.94) + accent * luminous * 0.12;
	EMISSION = accent * luminous * emission_strength;
	ALPHA = 1.0;
}
