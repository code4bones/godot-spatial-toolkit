# Godot Spatial Toolkit

Spatial Toolkit is a Godot 4 editor addon for turning GeoJSON into editable, playable 3D maps. It provides Map Explorer, a native scene importer, appearance profiles, scene baking, and an optional flight rig.

## Install

1. Copy `addons/spatial_toolkit` into your Godot project.
2. Enable **Spatial Toolkit** in **Project → Project Settings → Plugins**.
3. Open **Spatial** and run its dependency check with your Python executable. Native import uses Python 3.10 or newer, pyproj, and GEOS 3.10 or newer.
4. Open a GeoJSON file in **Map Explorer** and send it to **Spatial**. Set the import options and create the map. The importer creates a separate scene in the selected output folder.

The addon has been tested with Godot 4.7.2 and 4.6.3. Local GeoJSON import works offline. Map Explorer can use online data providers.

The package includes procedural materials and the flight rig. You can add your own textures and materials or import them through Asset Browser. Flight audio can be assigned in the camera Inspector.

## License

[MIT](LICENSE)
