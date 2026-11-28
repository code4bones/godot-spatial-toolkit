# Changelog

## [Unreleased]

## [0.11.0] - 2026-11-28

- Switch the spider between first and third person with V or Triangle. Third person follows an animated demo robot along facades and roofs and retracts the camera at obstacles.
- Align generated roads, paths, water and land use with the flat ground while retaining their material draw order. Existing generated scenes correct the former height offsets at runtime.
- Switch between the drone and first-person spider movement with `/`. Walk onto facades, move around exterior corners and cross roofs using static map collisions.
- Document how to attach a custom character model and drive surface traversal in a consuming project.

## [0.10.1] - 2026-11-28

- Document how agents can inspect maps with Godot MCP and build gameplay from the saved world data.
- Register flight controls and defaults when the addon is enabled in a new project.
- Store the HTTP proxy and its service switches in local editor data for each project.
- Default Map Areas to `https://ovp.dresel.systems/api` for Overpass.

## [0.10.0] - 2026-11-28

- Download CityGML building data on demand for Helsinki, Munich, Montréal, Zürich and Lyon. Verify source checksums, show progress and allow cancellation. The archive cache lives in Godot's user data directory.
- Combine measured CityGML buildings with OSM surroundings for a selected area. Show dataset coverage in Map Explorer and preserve source IDs and attribution in generated scenes.
- Apply the shared attribute bank when baking every square. Saving an edited square refreshes appearance across the editable world and reports progress.
- Save world bakes and their flight graphs in numbered folders under the world directory. Build the graph for a selected bake from the Spatial dock.
- Draw and tune patrol zones in the editor. Flying patrols follow the graph, pursue the player and return to their zones. The HUD and minimap show nearby and off-screen patrols.
- Default new drone rigs to Gamepad Flight with staged target capture. Hold L2 to aim, press Triangle to select a course and recenter the reticle, and use Cross to select a patrol. Press L3 and push forward for boost. Pitch inversion defaults to off.
- Restore active Gamepad Flight controls when the game window regains focus. The left stick strafes while holding course.
- Glide along the ground after contact and ease the chase camera toward the new flight angle.
- Select World Style presets or an existing flight graph through Quick Load in the editor.

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
