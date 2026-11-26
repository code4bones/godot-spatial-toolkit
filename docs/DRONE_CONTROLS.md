# Управление дроном

[English](#drone-controls)

Откройте запечённую сцену `map.scn` и выберите узел **FlyPlayer**. В Инспекторе откройте **Drone Controls** («Управление дроном») и установите **Flight Controller**. Сохраните сцену и нажмите **F6**. Контроллер можно менять на уже запечённой карте.

## Контроллеры

| Действие | Classic / Классический | Bank and Edge Tracking / Крен и слежение у края | Reticle Flight / Полёт по прицелу |
| --- | --- | --- | --- |
| Движение мыши | Указатель свободен. У края окна движение указателя разворачивает дрон. | Указатель свободен. Камера следует за манёврами дрона, а движение указателя само по себе её не поворачивает. | Мышь поворачивает камеру и задаёт курс через прицел, закреплённый в центре. |
| **W / S** | Поднять и опустить нос. | Поднять и опустить нос. Удержание позволяет выполнить петлю. | Разгон, торможение и задний ход. Заданная скорость сохраняется после отпускания. |
| **A / D** | Повернуть влево и вправо. | Сместиться влево и вправо с креном. При выходе к краю кадра камера и дрон начинают поворачивать. | Сместиться влево и вправо. Направление прицела сохраняется. |
| **Q / E** | Снизиться и подняться. | Снизиться и подняться. | Снизиться и подняться. |
| **Колесо** | Изменить скорость полёта. Переход через ноль включает задний ход. | Изменить скорость полёта. Переход через ноль включает задний ход. | Изменить заданную скорость теми же ступенями. |
| **ЛКМ** во время полёта | Выбрать точку. При нулевой скорости дрон ждёт разгона колесом. | Выбрать точку. С места дрон стартует на скорости 10 м/с по умолчанию. | Выстрелить по центральному прицелу. |
| **Space + ЛКМ** | Выстрелить по указателю. | Выстрелить по указателю. | Выстрел назначен на ЛКМ. |
| **Удерживать ПКМ и двигать мышь** | Осмотреться, сохраняя курс. После отпускания камера сохраняет угол обзора. | Осмотреться, сохраняя курс. После отпускания камера сохраняет угол обзора. | Осмотреться, сохраняя курс. После отпускания камера возвращается к курсу и снова показывает прицел. |

## Камера и карта

- **V** переключает вид от третьего и первого лица. Модель дрона видна от третьего лица.
- **Esc** останавливает полёт и освобождает мышь. Первый щелчок в окне возвращает управление.
- **Tab** открывает обзор карты и останавливает полёт. Повторный **Tab** возвращает выбранный вид полёта.
- В обзоре **WASD** и перетаскивание средней кнопкой перемещают карту, колесо меняет масштаб, а перетаскивание с **ПКМ** вращает обзор. **Home** показывает карту целиком, **F** наводит камеру на здания, **H** переключает легенду. **ЛКМ** добавляет отметку маршрута или удаляет её при щелчке по маркеру.

## Настройки в Инспекторе

- **Invert Ws** на `FlyPlayer` меняет направление тангажа от W/S у классического контроллера и режима с креном.
- В `FlyPlayer/CameraPivot/CameraBoom/FlyCamera` откройте **Camera Framing → Vertical Screen Offset**. Положительное значение опускает модель в кадре от третьего лица. По умолчанию установлено **12%** для Classic и Bank and Edge Tracking и **24%** для Reticle Flight.
- В **Reticle Flight Controls** на `FlyCamera` можно настроить ускорение, скорость бокового движения и подъёма. Общие настройки камеры задают чувствительность мыши, шаг колеса и пределы скорости.

---

# Drone controls

[Русская версия](#управление-дроном)

Open the baked `map.scn` scene and select **FlyPlayer**. Set **Drone Controls → Flight Controller** in the Inspector, save the scene, and press **F6**. You can change controllers on an existing baked map.

## Controllers

| Action | Classic | Bank and Edge Tracking | Reticle Flight |
| --- | --- | --- | --- |
| Move the mouse | Move the pointer freely. Near the viewport edge, the pointer steers the drone. | Move the pointer freely. The camera follows the drone's maneuvers. Moving the pointer alone leaves the camera in place. | Turn the view and steer through the fixed center reticle. |
| **W / S** | Pitch up and down. | Pitch up and down. Hold either key to loop. | Accelerate, brake, and reverse. Releasing the key holds the selected speed. |
| **A / D** | Turn left and right. | Bank and strafe left or right. Steering at the framing boundary turns the drone and camera. | Strafe left or right while holding your aim. |
| **Q / E** | Descend and ascend. | Descend and ascend. | Descend and ascend. |
| **Mouse wheel** | Adjust cruise speed. Scroll through zero to reverse. | Adjust cruise speed. Scroll through zero to reverse. | Adjust cruise speed in the same steps. |
| **Left click** while flying | Select a destination. From a standstill, use the wheel to begin moving. | Select a destination. From a standstill, the default starting speed is 10 m/s. | Fire along the center reticle. |
| **Space + left click** | Fire at the pointer. | Fire at the pointer. | Fire is bound to left click. |
| **Hold right mouse and move** | Look around while holding course. Releasing the button keeps the viewing angle. | Look around while holding course. Releasing the button keeps the viewing angle. | Look around while holding course. Releasing the button aligns the camera with the course and restores the reticle. |

## Camera and map

- **V** switches between third and first person. The drone model is visible in third person.
- **Esc** stops flight and releases the mouse. The first click in the window resumes flight controls.
- **Tab** stops flight and opens the map overview. Press **Tab** again to return to your flight view.
- In the overview, **WASD** and middle drag pan the map, the wheel zooms, and right drag rotates. **Home** frames the map, **F** frames the buildings, and **H** toggles the legend. Left click places a waypoint or removes one when you click its marker.

## Inspector settings

- **Invert Ws** on `FlyPlayer` reverses W/S pitch in Classic and Bank and Edge Tracking.
- On `FlyPlayer/CameraPivot/CameraBoom/FlyCamera`, open **Camera Framing → Vertical Screen Offset**. Positive values move the model down in third person. The defaults are **12%** for Classic and Bank and Edge Tracking and **24%** for Reticle Flight.
- **Reticle Flight Controls** on `FlyCamera` sets acceleration, strafe speed, and lift speed. The shared camera settings control mouse sensitivity, wheel step, and speed limits.
