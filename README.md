# Godot Spatial Toolkit

[Русская версия](./README.ru.md)

Spatial Toolkit is a Godot 4 editor addon for turning GeoJSON into editable, playable 3D maps. It provides Map Explorer, a native scene importer, appearance profiles, scene baking, and an optional flight rig.

## Install

1. Copy `addons/spatial_toolkit` into your Godot project.
2. Enable **Spatial Toolkit** in **Project → Project Settings → Plugins**.
3. Open **Spatial** and run its dependency check with your Python executable. Native import uses Python 3.10 or newer, pyproj, and GEOS 3.10 or newer.
4. Open a GeoJSON file in **Map Explorer** and send it to **Spatial**. Set the import options and create the map. The importer creates a separate scene in the selected output folder.

The addon has been tested with Godot 4.7.2 and 4.6.3. Local GeoJSON import works offline. Map Explorer can use online data providers.

## Customize a map

The package includes procedural materials and the flight rig. You can add your own textures and materials or import them through Asset Browser. Save the current map's appearance as a `.tres` profile in Spatial to reuse its materials and colors on a later import. Flight audio can be assigned in the camera Inspector.

## Development workflow from selected areas to a playable map

This workflow describes the development version for the next standalone update. The installation steps above describe the current standalone snapshot.

```mermaid
flowchart TD
    MAP["Map Explorer<br/>Select areas on the map (BBox)"] --> DOWNLOAD["Download OSM data as GeoJSON"]
    DOWNLOAD --> SOURCES["Spatial<br/>Add areas to the GeoJSON source array"]
    LOCAL["Local GeoJSON files"] --> SOURCES
    SOURCES --> SELECTED{"Saved world selected?"}
    SELECTED -->|New world| CREATE["Create world<br/>Merge the sources and generate editable squares"]
    SELECTED -->|Existing world| UPDATE["Update world<br/>Process new or changed sources and save affected squares"]
    PROFILE["Optional appearance profile (.tres)"] -.-> CREATE
    CREATE --> INDEX["world.json<br/>Index of saved square scenes"]
    UPDATE --> INDEX
    INDEX --> EDIT["Open and customize a square<br/>Materials, colors, roofs, window styles, sky"]
    EDIT --> BANK["Attribute bank<br/>Shared appearance rules"]
    BANK -.->|Apply across the world| EDIT
    BANK -.->|Apply to generated squares| UPDATE
    EDIT --> SAVE["Save the square in Godot"]
    SAVE --> BAKE["Assemble and bake world<br/>Read the saved square scenes from world.json"]
    INDEX --> BAKE
    BAKE --> PLAY["One playable map.scn<br/>Bake reports and coordinate data"]
    BAKE -.-> WINDOWS["Optional nearby 3D frames<br/>window_detail.bin"]
```

1. In **Map Explorer**, select areas on the map, download them, and send their GeoJSON to **Spatial**. You can also start with local GeoJSON files.
2. Use **Создать мир** to merge the sources and create editable squares. To extend a world, keep its `world.json` selected under **Сохранённый мир**, add the new areas to the source array, then press **Обновить мир**. The update saves only affected squares.
3. Use **Открыть выбранный квадрат** and edit the layers and building groups in the Inspector. Set materials, tints, roof variants and window styles, and preview the sky. The world's `attribute_bank.tres` shares group and per-object appearance assignments across squares. Use **Сохранить оформление…** to export a reusable profile for another world. Save scene edits in Godot.
4. Set the optional **Добавить дрон** and **3D-рамы вблизи** flags, then press **Собрать и запечь мир**. Spatial builds a separate playable `map.scn` from the saved squares, batches compatible meshes, and can merge static collisions. The output includes reports and `world_data.json` with roads and building data. The 3D frame option saves window positions in `window_detail.bin`. Open the baked scene and press **F6** to play.

## License

[MIT](./LICENSE)
