"""Deterministic hollow building shells with real, edge-local window apertures.

OSM supplies footprints and height evidence, not these facade layouts. All inputs
and this module's outputs are in source-local metres; gameplay scaling is a
separate final transform. The same triangles serve rendering and collision.
"""
import math

from .preview_geometry import FOUNDATION_BOTTOM, FOUNDATION_RENDER_TOP, signed_area, surface


WINDOW_SPACING = 2.7
WINDOW_WIDTH = 1.08
WALL_THICKNESS = 0.2
MAX_BUILDING_OPENINGS = 10000
MAX_MAP_OPENINGS = 75000
MAX_SAMPLES = 8


class FacadeBudgetError(RuntimeError):
    """Reject the operation instead of silently dropping an expensive building."""


def _cross(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _raw_quad(vertices, normals, points, normal):
    # Godot's front faces are clockwise, opposite the ordinary cross product.
    a, b, c, d = points
    cross = _cross([b[i] - a[i] for i in range(3)], [c[i] - a[i] for i in range(3)])
    if sum(cross[i] * normal[i] for i in range(3)) > 0:
        b, d = d, b
    vertices.extend([a, b, c, a, c, d])
    normals.extend([normal] * 6)


def _quad(vertices, normals, points, normal):
    # The partition is a rendering boundary, not an extra ledge or physical
    # surface. Clamp the existing vertical rectangle into two disjoint pieces;
    # both retain the original plane, winding and normal, with no horizontal cap.
    ys = [point[1] for point in points]
    if abs(normal[1]) < 1e-8 and min(ys) < FOUNDATION_RENDER_TOP < max(ys):
        lower = [[p[0], min(p[1], FOUNDATION_RENDER_TOP), p[2]] for p in points]
        upper = [[p[0], max(p[1], FOUNDATION_RENDER_TOP), p[2]] for p in points]
        _raw_quad(vertices, normals, lower, normal)
        _raw_quad(vertices, normals, upper, normal)
    else:
        _raw_quad(vertices, normals, points, normal)


def plan_facade(polygons, height, wall_height, floor_height, grid_stride=1):
    """Plan/count a facade without allocating any window triangles.

    Selection retains at least one aperture on every originally eligible edge.
    Coordinates, height and all opening sizes remain in source-local metres.
    """
    if isinstance(grid_stride, bool) or not isinstance(grid_stride, int) or grid_stride < 1:
        raise ValueError("Facade grid stride must be a positive integer")
    base_y = min(0.08, height * 0.1)
    wall_top = min(height, max(0.0, wall_height))
    floor_height = min(6.0, max(2.0, float(floor_height)))
    pane_height = floor_height * 0.43
    # The last row needs room for the whole aperture, not an entire extra storey.
    full_rows = max(0, math.floor((wall_top - base_y - floor_height * 0.715) / floor_height) + 1)
    rows = (full_rows + grid_stride - 1) // grid_stride
    plans, count, full_count = [], 0, 0
    for part, rings in enumerate(polygons):
        for ring_index, ring in enumerate(rings):
            sign = (1 if signed_area(ring) > 0 else -1) * (1 if ring_index == 0 else -1)
            for edge_index, (a, b) in enumerate(zip(ring, ring[1:])):
                dx, dz = b[0] - a[0], b[1] - a[1]
                length = math.hypot(dx, dz)
                if length < 1e-8:
                    continue
                full_columns = max(0, math.floor(length / WINDOW_SPACING))
                columns = (full_columns + grid_stride - 1) // grid_stride
                count += rows * columns
                full_count += full_rows * full_columns
                tangent = [dx / length, 0.0, dz / length]
                normal = [sign * dz / length, 0.0, -sign * dx / length]
                plans.append((part, ring_index, edge_index, a, length, tangent, normal, columns, full_columns))
    return {"base_y": base_y, "floor_height": floor_height, "pane_height": pane_height,
            "rows": rows, "full_rows": full_rows, "edges": plans, "count": count,
            "estimated_full_count": full_count, "grid_stride": grid_stride}


def count_plan_at_stride(plan, grid_stride):
    """Count the exact selected apertures using the same integer rule as mesh generation."""
    rows = (plan["full_rows"] + grid_stride - 1) // grid_stride
    return rows * sum((edge[8] + grid_stride - 1) // grid_stride for edge in plan["edges"])


def choose_grid_stride(plans, density_mode="auto", map_budget=MAX_MAP_OPENINGS,
                       building_budget=MAX_BUILDING_OPENINGS):
    """Smallest global stride fitting both budgets; fail if even one/edge cannot fit."""
    if density_mode not in ("auto", "full"):
        raise ValueError("Window density must be 'auto' or 'full'")

    def fits(stride):
        total = 0
        for plan in plans:
            count = count_plan_at_stride(plan, stride)
            if count > building_budget:
                return False
            total += count
            if total > map_budget:
                return False
        return True

    if fits(1):
        return 1
    full_count = sum(plan["estimated_full_count"] for plan in plans)
    if density_mode == "full":
        raise FacadeBudgetError(
            f"Full window density needs {full_count} openings; budgets are {building_budget} "
            f"per building / {map_budget} per map. Use automatic window density, import a "
            "smaller area or disable open windows; no buildings were silently omitted.")
    minimum = [sum(edge[8] > 0 for edge in plan["edges"]) if plan["full_rows"] else 0
               for plan in plans]
    if sum(minimum) > map_budget or any(count > building_budget for count in minimum):
        raise FacadeBudgetError(
            f"At least {sum(minimum)} openings are needed to retain one on every eligible "
            f"facade edge; budgets are {building_budget} per building / {map_budget} per map. "
            "Import a smaller area or disable open windows; no buildings were silently omitted.")
    high = 2
    while not fits(high):
        high *= 2
    low = 2
    while low < high:
        middle = (low + high) // 2
        if fits(middle):
            high = middle
        else:
            low = middle + 1
    return low


def plan_limited_facade(full_plan, window_limit=6):
    """Allocate a total building cap across exterior sides and polygon parts.

    A small number of windows is placed symmetrically on each chosen side.
    Courtyard edges remain solid. The normal full/auto layout is unchanged.
    """
    if isinstance(window_limit, bool) or not isinstance(window_limit, int) or not 1 <= window_limit <= 1000:
        raise ValueError("Window limit must be an integer between 1 and 1000")
    eligible = [(index, edge) for index, edge in enumerate(full_plan["edges"])
                if edge[1] == 0 and edge[8] > 0 and full_plan["full_rows"] > 0]
    capacity = sum(edge[8] * full_plan["full_rows"] for _, edge in eligible)
    total = min(window_limit, capacity)
    allocation = {index: 0 for index, _ in eligible}
    if total >= len(eligible):
        for index, _ in eligible:
            allocation[index] = 1
        remaining = total - len(eligible)
        # Give extras to the longest sides first, then repeat if the user asks
        # for a larger cap. Capacity prevents overlapping duplicate apertures.
        longest_first = sorted(eligible, key=lambda value: (-value[1][4], value[0]))
        while remaining:
            for index, edge in longest_first:
                if allocation[index] < edge[8] * full_plan["full_rows"]:
                    allocation[index] += 1
                    remaining -= 1
                    if remaining == 0:
                        break
    elif total:
        # More exterior sides than available windows: sample around the whole
        # eligible perimeter instead of exhausting the first polygon's edges.
        perimeter = sum(edge[4] for _, edge in eligible)
        centers, along = [], 0.0
        for index, edge in eligible:
            centers.append((index, along + edge[4] * 0.5))
            along += edge[4]
        for position in range(total):
            target = (position + 0.5) * perimeter / total

            def circular_distance(value):
                distance = abs(value[1] - target)
                return min(distance, perimeter - distance), value[0]

            index, _ = min((value for value in centers if allocation[value[0]] == 0),
                           key=circular_distance)
            allocation[index] = 1
    limited_rows = {}
    for index, edge in eligible:
        amount = allocation[index]
        if not amount:
            continue
        columns = edge[8]
        rows = (amount + columns - 1) // columns
        per_row, extra = divmod(amount, rows)
        offset = (edge[4] - columns * WINDOW_SPACING) * 0.5
        row_layouts = []
        for row in range(rows):
            row_columns = per_row + int(row < extra)
            center_y = (full_plan["base_y"] + (row + 0.5)
                        * full_plan["full_rows"] / rows * full_plan["floor_height"])
            centers_u = [offset + (column + 0.5) * columns / row_columns * WINDOW_SPACING
                         for column in range(row_columns)]
            row_layouts.append((center_y, centers_u))
        limited_rows[index] = row_layouts
    return {**full_plan, "count": total, "limited_rows": limited_rows,
            "window_limit": window_limit, "density_mode": "limited",
            "eligible_exterior_edges": len(eligible), "selected": True}


def building_with_openings(geometry, polygons, height, wall_height, floor_height,
                           remaining_budget=MAX_MAP_OPENINGS, grid_stride=1,
                           plan=None, roof_triangles=None):
    """Return a hollow shell and bounded manifest from a count-only facade plan.

    Walls extend inward by 0.2m with inner faces and aperture reveals. Roof and
    base floor retain all polygon holes. Internal corner bands may overlap; no
    rooms or intermediate floors are made. A stride changes spacing, never the
    physical aperture dimensions. Stride 1 retains the original exact geometry.
    """
    plan = plan if plan is not None else plan_facade(polygons, height, wall_height, floor_height, grid_stride)
    if plan["count"] > MAX_BUILDING_OPENINGS or plan["count"] > remaining_budget:
        raise FacadeBudgetError(
            "Facade opening budget exceeded (maximum 10000 per building, "
            "75000 per map). Import a smaller area or use automatic window density; "
            "no buildings were silently omitted.")
    base_y, floor_height, pane_height = (plan[key] for key in ("base_y", "floor_height", "pane_height"))
    rows, full_rows, count = (plan[key] for key in ("rows", "full_rows", "count"))
    grid_stride = plan["grid_stride"]
    roofs = roof_triangles if roof_triangles is not None else [
        triangle for rings in polygons for triangle in geometry.polygon(rings)]

    vertices, normals = surface(roofs, height)
    floor_v, floor_n = surface(roofs, base_y)
    vertices.extend(floor_v)
    normals.extend(floor_n)
    samples = []
    limited = "limited_rows" in plan
    for plan_edge_index, edge in enumerate(plan["edges"]):
        part, ring_index, edge_index, a, length, tangent, normal, columns, full_columns = edge
        inward = [-value * WALL_THICKNESS for value in normal]

        def point(u, y, inside=False):
            return [a[0] + tangent[0] * u + (inward[0] if inside else 0), y,
                    a[1] + tangent[2] * u + (inward[2] if inside else 0)]

        def rectangle(u0, u1, y0, y1):
            if u1 - u0 <= 1e-9 or y1 - y0 <= 1e-9:
                return
            _quad(vertices, normals, [point(u0, y0), point(u1, y0),
                                     point(u1, y1), point(u0, y1)], normal)
            _quad(vertices, normals, [point(u0, y0, True), point(u1, y0, True),
                                     point(u1, y1, True), point(u0, y1, True)],
                  [-value for value in normal])

        # Continue each outer/courtyard boundary below the flat ground without
        # lowering the hall floor or moving any aperture. This vertical strip
        # closes the former ground-to-wall gap; it adds no horizontal cap.
        _quad(vertices, normals, [point(0, FOUNDATION_BOTTOM), point(length, FOUNDATION_BOTTOM),
                                 point(length, base_y), point(0, base_y)], normal)

        # Close vertical ends only. The complete roof and base floor above
        # already close the horizontal wall boundaries: extra horizontal caps
        # would cover the same area at exactly the same depth. Bottom caps also
        # had opposite normals to the floor, making the overlap visibly flicker.
        for u, outward in ((0.0, [-v for v in tangent]), (length, tangent)):
            _quad(vertices, normals, [point(u, base_y), point(u, height),
                                     point(u, height, True), point(u, base_y, True)], outward)
        limited_rows = plan.get("limited_rows", {}).get(plan_edge_index, []) if limited else None
        if (limited and not limited_rows) or (not limited and (columns == 0 or rows == 0)):
            rectangle(0.0, length, base_y, height)
            continue
        offset = (length - full_columns * WINDOW_SPACING) * 0.5
        previous_top = base_y
        edge_rows = len(limited_rows) if limited else rows
        for row in range(edge_rows):
            if limited:
                center_y, centers_u = limited_rows[row]
            elif grid_stride == 1:
                center_y = base_y + (row + 0.5) * floor_height
            else:
                selected_row = (full_rows - 1) * 0.5 if rows == 1 else (full_rows - 1) * row / (rows - 1)
                center_y = base_y + (selected_row + 0.5) * floor_height
            y0, y1 = center_y - pane_height * 0.5, center_y + pane_height * 0.5
            rectangle(0.0, length, previous_top, y0)
            previous_right = 0.0
            edge_columns = len(centers_u) if limited else columns
            for column in range(edge_columns):
                if limited:
                    center_u = centers_u[column]
                elif grid_stride == 1:
                    center_u = offset + (column + 0.5) * WINDOW_SPACING
                else:
                    selected_column = ((full_columns - 1) * 0.5 if columns == 1 else
                                       (full_columns - 1) * column / (columns - 1))
                    center_u = offset + (selected_column + 0.5) * WINDOW_SPACING
                u0, u1 = center_u - WINDOW_WIDTH * 0.5, center_u + WINDOW_WIDTH * 0.5
                rectangle(previous_right, u0, y0, y1)
                # Jambs, sill and lintel bridge exterior to interior faces. There
                # is deliberately no face across the aperture or glass collider.
                for u, facing in ((u0, tangent), (u1, [-v for v in tangent])):
                    _quad(vertices, normals, [point(u, y0), point(u, y1),
                                             point(u, y1, True), point(u, y0, True)], facing)
                for y, facing in ((y0, [0, 1, 0]), (y1, [0, -1, 0])):
                    _quad(vertices, normals, [point(u0, y), point(u1, y),
                                             point(u1, y, True), point(u0, y, True)], facing)
                # One central opening per edge gives useful, well-separated
                # entry points instead of spending the manifest on one facade.
                if len(samples) < MAX_SAMPLES and (limited or (row == rows // 2 and column == columns // 2)):
                    samples.append({"center": point(center_u, center_y), "normal": normal,
                                    "tangent": tangent, "width_m": WINDOW_WIDTH,
                                    "height_m": pane_height, "part": part,
                                    "ring": ring_index, "edge": edge_index})
                previous_right = u1
            rectangle(previous_right, length, y0, y1)
            previous_top = y1
        rectangle(0.0, length, previous_top, height)
    return vertices, normals, {
        "enabled": True, "count": count, "floor_height_m": floor_height,
        "base_floor_y_m": base_y, "foundation_bottom_y_m": FOUNDATION_BOTTOM,
        "foundation_render_top_y_m": FOUNDATION_RENDER_TOP,
        "wall_thickness_m": WALL_THICKNESS, "samples": samples,
        "layout": "limited_exterior_windows" if limited else "edge_local_regular_grid",
        "interior": "empty_hall_no_intermediate_floors",
        "grid_stride": grid_stride, "estimated_full_count": plan["estimated_full_count"],
        "planned_count": count, "adjusted": count != plan["estimated_full_count"] if limited else grid_stride > 1,
        **({"window_limit": plan["window_limit"], "density_mode": "limited", "selected": True,
            "eligible_exterior_edges": plan["eligible_exterior_edges"]} if limited else {}),
        "assumption": "Procedural open apertures and inward wall thickness; not surveyed OSM windows",
        "no_openings_reason": "" if count else "No facade segment/storey fits a complete aperture",
    }
