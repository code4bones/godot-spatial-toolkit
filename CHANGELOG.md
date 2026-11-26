# Changelog

## [Unreleased]

## [0.9.0] - 2026-11-27

- Document the three drone controllers, camera and overview controls, and settings in the drone controls guide.
- Fire with left click in Reticle Flight. Hold right mouse to look around while the drone maintains its course.
- Add Reticle Flight to the baked drone's controller options. Mouse movement steers the center reticle, W/S adjust cruise speed, and A/D and Q/E apply lateral and vertical thrust.
- Rebuild the Chunks preview viewport if the open dock still holds a legacy instance after a script reload.
- Save a PNG thumbnail with each new or updated world square. The Chunks tab reads it on first selection and refreshes the preview after scene edits.
- Adjust the drone's vertical position in the third-person view under FlyCamera → Camera Framing. The default shifts it down by 12% of the viewport height.
- Build Chunks preview geometry over several frames and cache rendered previews for repeat selections. Read saved scene resources on the editor thread to avoid the threaded preview regression.

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
