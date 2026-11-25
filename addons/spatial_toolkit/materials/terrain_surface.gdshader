shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley;

#define OPAQUE_TERRAIN
#include "res://addons/spatial_toolkit/materials/textured_surface.gdshaderinc"
