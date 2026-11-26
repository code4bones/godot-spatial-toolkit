# Changelog

## [Unreleased]

## [0.8.0] - 2026-11-26

- Create editable worlds from multiple GeoJSON sources. Update an existing world by rebuilding affected squares and sharing appearance settings through its attribute bank.
- Browse and filter saved squares in the Chunks tab. Preview the selected square and open its scene with a double-click.
- Assemble and bake a world into a playable scene with an optional custom drone visual and nearby 3D window frames. Export projected roads, the road graph and building footprints alongside the bake.
- Change day and night sky, fog and facade lighting in editable maps and already baked scenes. Configure window layouts, building grouping and road width fallbacks.
- Draw area bounds with Ctrl or Cmd and the left mouse button in Map Explorer. In Map Areas, double-click a row to edit it. Fetch checked areas from Overpass or a local OSM PBF and send them to Spatial as GeoJSON.
- Show area status, dimensions in metres and saved counts for five OSM layers. Keep the checkbox and delete buttons in fixed-width columns at the edges of the table.
- Import Poly Haven and ambientCG PBR materials from the Textures tab. Display imported items first and drag them to compatible Inspector fields.
- Configure one local HTTP proxy and separate switches for Map Explorer tiles, Overpass and Textures.
- Follow the Godot editor language for Spatial Toolkit controls and Inspector groups in English and Russian.
- Run the import dependency check from Project Settings.

## [0.7.0]

- First standalone GitHub snapshot with local GeoJSON import, scene baking, appearance profiles and the optional drone flight rig.
