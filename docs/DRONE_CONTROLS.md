# Управление дроном

[English](#drone-controls)

На новой карте дрон по умолчанию использует **Gamepad Flight** с поэтапным захватом. Чтобы поменять режим в готовой сцене `map.scn`, выберите **FlyPlayer** и откройте **Drone Controls → Flight Controller** в Инспекторе. Сохраните сцену и нажмите **F6**.

Раздел **Project Settings → General → Spatial Toolkit → Flight** доступен сразу после включения аддона. **Default Controller** выбирает контроллер для новых дронов. **Invert Ws** и **Invert Gamepad Pitch** задают начальное состояние инверсии. Для сохранённого дрона эти параметры берутся из его сцены.

## Режим «Паук»

Запустите сцену с дроном через **F6** и нажмите **`/`**. В первый раз паук появляется на поверхности под дроном. **V** или **△** на DS4 переключает вид от первого и третьего лица. В третьем лице видна модель робота-паука, а камера приближается у препятствий. Для ходьбы и лазанья используйте **WASD** или левый стик, для обзора — мышь или правый стик. Двигайтесь в сторону стены, чтобы перейти на неё, и продолжайте движение у угла или кромки крыши, чтобы перейти на соседнюю поверхность. **Esc** освобождает курсор, ЛКМ захватывает его снова. На DS4 управление приостанавливается и возобновляется через **Options**.

Повторное **`/`** возвращает к дрону. Следующее включение паука сохраняет его положение и выбранный вид. Для лазанья используются статические коллизии карты. Действия `spider_toggle` и `flight_toggle_view` настраиваются в **Project Settings → Input Map**. Для ручной проверки переключитесь на третье лицо, перейдите с земли на фасад, обогните внешний угол боковым ходом и поднимитесь на крышу. Подведите камеру к стене и проверьте, как она приближается к пауку.

## Контроллеры

| Действие | Classic / Классический | Bank and Edge Tracking / Крен и слежение у края | Reticle Flight / Полёт по прицелу |
| --- | --- | --- | --- |
| Движение мыши | Указатель свободен. У края окна движение указателя разворачивает дрон. | Указатель свободен. Камера следует за манёврами дрона, а движение указателя само по себе её не поворачивает. | Мышь поворачивает камеру и задаёт курс через прицел, закреплённый в центре. |
| **W / S** | Поднять и опустить нос. | Поднять и опустить нос. Удержание позволяет выполнить петлю. | Разгон, торможение и задний ход. Заданная скорость сохраняется после отпускания. |
| **A / D** | Повернуть влево и вправо. | Сместиться влево и вправо с креном. При выходе к краю кадра камера и дрон начинают поворачивать. | Сместиться влево и вправо. Направление прицела сохраняется. |
| **Q / E** | Зарезервированы. | Снизиться и подняться. | Снизиться и подняться. |
| **Колесо** | Изменить скорость полёта. Переход через ноль включает задний ход. | Изменить скорость полёта. Переход через ноль включает задний ход. | Изменить заданную скорость теми же ступенями. |
| **ЛКМ** во время полёта | В первом сегменте захватить цель, во втором выстрелить. При отсутствии индикатора цели выстрелить по указателю. | Выбрать точку. С места дрон стартует на скорости 10 м/с по умолчанию. | Выстрелить по центральному прицелу. |
| **Space + ЛКМ** | Выбрать точку полёта. При нулевой скорости дрон ждёт разгона колесом. | Выстрелить по указателю. | Выстрел назначен на ЛКМ. |
| **Удерживать ПКМ и двигать мышь** | Осмотреться, сохраняя курс. После отпускания камера сохраняет угол обзора. | Осмотреться, сохраняя курс. После отпускания камера сохраняет угол обзора. | Осмотреться, сохраняя курс. После отпускания камера возвращается к курсу и снова показывает прицел. |

## DualShock 4

### Gamepad Flight / Полёт с геймпадом

- Левый стик влево и вправо смещает дрон боком с сохранением курса. Движение стика вперёд и назад позволяет точнее набирать и сбрасывать скорость. В нейтрали сохраняется крейсерская скорость.
- Правый стик одновременно поворачивает камеру и задаёт курс. Для мёртвой петли наберите скорость и удерживайте правый стик в направлении подъёма носа до полного оборота. Прицел начинается в центре экрана, над кораблём.
- Удерживайте **L2** и двигайте правый стик, чтобы переместить прицел, сохраняя курс. Затем нажмите **△**, чтобы задать полёт к точке под прицелом. Камера следует за новым курсом, и прицел возвращается в центр. △ срабатывает и пока L2 удерживается, и после его отпускания. **R3** центрирует прицел вручную.
- Удерживайте **L1** и двигайте правый стик, чтобы осмотреться, сохраняя курс. После отпускания камера возвращается к курсу.
- Обычное движение левого стика вперёд набирает крейсерскую скорость без пламени сопел. Для форсированного разгона нажмите левый стик (**L3**) и толкните его вперёд. Пламя сопел появляется только при этом троттле. **○** резко тормозит до нуля. Наведите прицел на видимый патруль и нажмите **✕**, чтобы выбрать его. **← / →** на крестовине циклически переключают видимые цели. **R1** подтверждает сегменты захвата, **R2** стреляет из состояния **READY**.
- **V** переключает вид от первого и третьего лица, **Share** открывает обзор карты, **Options** останавливает и возобновляет управление полётом. При возврате в окно игры управление возобновляется, если полёт был активен.

### Classic, Bank and Edge Tracking, Reticle Flight

| Управление | Classic | Bank and Edge Tracking | Reticle Flight |
| --- | --- | --- | --- |
| Левый стик | Поворот и тангаж | Боковое смещение и тангаж | Боковое смещение и высота |
| Правый стик | Движение прицела по экрану | Движение прицела по экрану | Поворот дрона по центральному прицелу |
| Крестовина ↑ / ↓ | | Подъём и снижение | |
| ✕ | Задать точку полёта | Задать точку полёта | |

- **R1 / L1** увеличивают и уменьшают крейсерскую скорость, включая задний ход после перехода через ноль. **○** сбрасывает скорость и отменяет точку полёта.
- **R2** стреляет одним нажатием. В Classic нажмите его в первом сегменте для захвата, отпустите и нажмите снова во втором для выстрела.
- **R3** возвращает подвижный прицел в центр. **△** переключает вид от первого и третьего лица в этих режимах, **Share** открывает или закрывает обзор карты, **Options** останавливает и возобновляет управление полётом.
- По умолчанию инверсия тангажа геймпада выключена: стик вперёд поднимает нос, назад опускает. Это настраивается через **Gamepad Invert Pitch**. Там же настраиваются мёртвая зона стиков, скорость подвижного прицела и темп изменения крейсерской скорости.

## Назначение кнопок и осей

Действия `flight_*` и `map_*` появятся в **Project → Project Settings → Input Map** при включении аддона. В режиме Gamepad Flight ось Left X управляет боковым движением. Добавляйте и удаляйте привязки в Input Map, затем запустите сцену заново.

| Действия | Управление |
| --- | --- |
| `flight_move_*` | Левый стик и WASD. В Gamepad Flight это боковое смещение и точная регулировка скорости. |
| `flight_look_*` | Правый стик. В Gamepad Flight он задаёт курс и обзор, а при удержании `flight_free_aim` двигает прицел. |
| `flight_gamepad_accelerate`, `flight_gamepad_brake`, `flight_gamepad_orbit` | Разгон, торможение и свободный обзор в Gamepad Flight. По умолчанию L3, ○ и L1. Разгон требует нажатия L3 и движения левого стика вперёд. |
| `flight_free_aim`, `flight_gamepad_destination`, `flight_fire`, `flight_center_aim` | Свободный прицел, назначение точки полёта, выстрел и центрирование прицела. По умолчанию L2, △, R2 и R3. |
| `flight_gamepad_select_target` | Выбор ближайшего видимого патруля внутри квадрата SEARCH под прицелом в Gamepad Flight. По умолчанию ✕. |
| `flight_target_left`, `flight_target_right` | Циклический выбор видимого патруля. По умолчанию ← и → на крестовине. |
| `flight_target_confirm` | Подтвердить сегмент в режиме Staged. По умолчанию R1. |
| `flight_primary_click`, `flight_click_modifier`, `flight_destination` | Основной щелчок, его модификатор и отдельная команда выбора точки полёта. |
| `map_*`, `flight_patrol_camera_1`–`flight_patrol_camera_9` | Управление обзором карты и выбор камер патрулей. |

Свободный прицел и выстрел можно переназначить на триггеры через `flight_free_aim` и `flight_fire`. Для стика каждое направление назначается отдельно. Движение мыши считывается напрямую, кнопку свободного обзора можно изменить через `flight_free_look`.

## Поэтапный захват в Gamepad Flight

1. Наведите прицел в квадрат **SEARCH** и нажмите **R1**, когда дуга дойдёт до первого сегмента. Патруль переходит в **LOCKED**, и под его рамкой начинает убывать полоса времени.
2. Пока **LOCKED** действует, можно уйти с цели и вернуться. Наведитесь на того же патрульного и нажмите **R1** во втором сегменте. Патруль перейдёт в **READY** со своим таймером.
3. Нажмите **R2**, пока действует **READY**. Выстрел сохраняет цель, даже если она вышла из кадра. Снаряд вылетает через 200 мс. После истечения **LOCKED** или **READY** захват начинается с **SEARCH**.

Когда патруль вне кадра, статус и оставшееся время видны внизу экрана. Настройки находятся в **FlyCamera → Target Lock**.

- **Locked Duration Seconds** (8 с) и **Ready Duration Seconds** (5 с) задают длительность состояний. **Ready Audio** задаёт сигнал готовности.
- **Progress Speed** задаёт скорость дуги. При **0,5×** полный оборот занимает **3,2 с**.
- **First Window Width** и **Second Window Width** задают ширину сегментов в процентах от круга. По умолчанию **21%** и **20%**. Каждый новый сегмент появляется в случайном месте и сохраняет позицию до конца попытки.

В поле **Mode** можно выбрать **Classic Timing** с прежними двумя нажатиями R2 и фиксированными сегментами.

## Захват патруля в Classic

Вокруг видимого летающего патруля на расстоянии до 150 м появляется квадрат **SEARCH**. Наведите указатель внутрь квадрата, чтобы начать отсчёт. Одна убывающая дуга показывает оставшееся время, два утолщённых сегмента на ней обозначают окна. Выход указателя за границы квадрата сбрасывает попытку и возвращает **SEARCH**.

На геймпаде **← / →** переключают рамку **SEARCH** между видимыми патрулями в экранном порядке. При выборе другого патруля отсчёт начинается заново после наведения в его рамку.

Нажмите **ЛКМ**, когда край дуги войдёт в первый сегмент. Сегмент позеленеет, появится рамка **TARGET LOCKED**, а отсчёт продолжится. **ЛКМ** во втором сегменте подтверждает выстрел по захваченной цели. Снаряд вылетает через 200 мс. Пропуск окна или потеря цели до подтверждения сбрасывает захват. При попадании по летающему патрулю камера снаряда плавно приближается к взрыву, а вспышка, дым и искры идут на скорости 0,8×.

Подтверждённый выстрел в Classic или Staged сохраняет цель за препятствием. Для патруля с графом снаряд ищет обход по сохранённым связям и переходам между чанками и возобновляет прямое наведение, когда освобождается линия полёта. Он проверяет столкновения до попадания или истечения 8 секунд полёта. Для патруля без графа прямое наведение длится до 1,75 секунды.

Скорость отсчёта настраивается в `FlyPlayer/CameraPivot/CameraBoom/FlyCamera` через **Target Lock → Progress Speed** («Захват цели»). По умолчанию **0,5×** даёт **3,2 секунды** на попытку. При **1×** отсчёт длится **1,6 секунды**.

В той же группе назначьте аудиофайлы в **Search Audio**, **Locked Audio** и **Fired Audio**. **Search** звучит при появлении SEARCH, **Locked** при первом попадании в сегмент, **Fired** сразу при подтверждении выстрела. Пустое поле отключает соответствующий звук. **Audio Volume Db** задаёт общую громкость этих трёх сигналов. **Drone Audio → Launch Audio** играет в момент вылета снаряда, через 200 мс после подтверждения обычного или наведённого выстрела.

## Камера и карта

- При касании земли дрон выравнивается вдоль поверхности и продолжает полёт на текущей крейсерской скорости. В Gamepad Flight камера плавно доворачивается вслед за дроном. Крутой склон останавливает дрон.
- **V** переключает вид от третьего и первого лица. Модель дрона видна от третьего лица.
- **Esc** останавливает полёт и освобождает мышь. Первый щелчок в окне возвращает управление.
- **Tab** открывает обзор карты и останавливает полёт. Повторный **Tab** возвращает выбранный вид полёта.
- В обзоре **WASD** и перетаскивание средней кнопкой перемещают карту, колесо меняет масштаб, а перетаскивание с **ПКМ** вращает обзор. **Home** показывает карту целиком, **F** наводит камеру на здания, **H** переключает легенду. **ЛКМ** добавляет отметку маршрута или удаляет её при щелчке по маркеру.

## Настройки в Инспекторе

- **FlyPlayer → Drone Controls → Invert Gamepad Pitch** меняет направление тангажа от стика. В Gamepad Flight это ось правого стика. То же значение доступно на `FlyCamera` в группе **Gamepad**.
- **Invert Ws** на `FlyPlayer` меняет направление тангажа от W/S в Classic и Bank and Edge Tracking. В Reticle Flight и Gamepad Flight W/S регулируют скорость.
- В `FlyPlayer/CameraPivot/CameraBoom/FlyCamera` откройте **Camera Framing → Vertical Screen Offset**. Положительное значение опускает модель в кадре от третьего лица. По умолчанию установлено **12%** для Classic и Bank and Edge Tracking и **24%** для Reticle Flight.
- В **Reticle Flight Controls** на `FlyCamera` можно настроить ускорение, скорость бокового движения и подъёма. Общие настройки камеры задают чувствительность мыши, шаг колеса и пределы скорости.
- В **Gamepad Maneuver** на `FlyCamera` параметры **Button Acceleration Mps2** и **Button Braking Mps2** задают интенсивность разгона и торможения кнопками. По умолчанию 80 и 120 м/с². **Max Bank Angle Degrees** задаёт максимальный визуальный крен.
- В **Gamepad Flight** боковой ход по умолчанию достигает 32 м/с. Скорость задаётся в **Reticle Flight Controls → Strafe Speed Mps**, а скорость набора и сброса бокового хода — в **Gamepad Maneuver → Strafe Acceleration Mps2** (120 м/с²). Горизонталь стика линейна за пределами мёртвой зоны.

---

# Drone controls

[Русская версия](#управление-дроном)

New maps default to **Gamepad Flight** with staged capture. To change the mode in a baked `map.scn`, select **FlyPlayer** and open **Drone Controls → Flight Controller** in the Inspector. Save the scene and press **F6**.

**Project Settings → General → Spatial Toolkit → Flight** is available as soon as the addon is enabled. **Default Controller** selects the controller for new drones. **Invert Ws** and **Invert Gamepad Pitch** set their initial inversion preferences. Saved drones use the values authored in their scenes.

## Spider mode

Run a scene with a drone using **F6** and press **`/`**. The spider starts on the surface below the drone. Press **V** or **Triangle** on DualShock 4 to switch between first and third person. Third person shows a demo spider robot with a chase camera that pulls in near obstacles. Use **WASD** or the left stick to move and the mouse or right stick to look. Move into a wall to climb it, then keep moving at a corner or roof edge to cross to the adjoining surface. Press **Esc** to release the mouse and click to capture it again. On DualShock 4, **Options** toggles control.

Press **`/`** again to return to the drone. The spider keeps its last position and view. Traversal uses the map's static collisions. Remap `spider_toggle` and `flight_toggle_view` in **Project Settings → Input Map**. To check a scene manually, switch to third person, climb from the ground onto a wall, strafe around an outside corner and cross the roof. Move the camera near a wall and check that it pulls in toward the spider.

## Controllers

| Action | Classic | Bank and Edge Tracking | Reticle Flight |
| --- | --- | --- | --- |
| Move the mouse | Move the pointer freely. Near the viewport edge, the pointer steers the drone. | Move the pointer freely. The camera follows the drone's maneuvers. Moving the pointer alone leaves the camera in place. | Turn the view and steer through the fixed center reticle. |
| **W / S** | Pitch up and down. | Pitch up and down. Hold either key to loop. | Accelerate, brake, and reverse. Releasing the key holds the selected speed. |
| **A / D** | Turn left and right. | Bank and strafe left or right. Steering at the framing boundary turns the drone and camera. | Strafe left or right while holding your aim. |
| **Q / E** | Reserved. | Descend and ascend. | Descend and ascend. |
| **Mouse wheel** | Adjust cruise speed. Scroll through zero to reverse. | Adjust cruise speed. Scroll through zero to reverse. | Adjust cruise speed in the same steps. |
| **Left click** while flying | Lock in the first timing window and fire in the second. With no target indicator, fire at the pointer. | Select a destination. From a standstill, the default starting speed is 10 m/s. | Fire along the center reticle. |
| **Space + left click** | Select a flight destination. From a standstill, use the wheel to begin moving. | Fire at the pointer. | Fire is bound to left click. |
| **Hold right mouse and move** | Look around while holding course. Releasing the button keeps the viewing angle. | Look around while holding course. Releasing the button keeps the viewing angle. | Look around while holding course. Releasing the button aligns the camera with the course and restores the reticle. |

## DualShock 4

### Gamepad Flight

- Move the left stick sideways to strafe while holding course. Push forward or pull back for finer speed control. A neutral stick keeps the chosen cruise speed.
- The right stick turns the camera and sets the flight direction. To fly a vertical loop, build speed and hold the right stick in the pitch-up direction through a full rotation. The reticle starts at screen center above the craft.
- Hold **L2** and move the right stick to position the reticle while holding course. Then press **Triangle** to set the flight destination at the reticle. The camera follows the new course and the reticle returns to center. Triangle works while L2 is held or after you release it. Press **R3** to center the reticle manually.
- Hold **L1** and move the right stick to orbit the camera while holding course. Release **L1** to align the camera with the course again.
- Pushing the left stick forward normally increases cruise speed without nozzle flame. Press the left stick (**L3**) while pushing it forward for boosted acceleration. The nozzle flame appears only during this throttle. **Circle** brakes sharply to zero. Aim at a visible patrol and press **Cross** to select it. **D-pad left/right** cycles visible targets. **R1** confirms the capture windows, and **R2** fires from **READY**.
- **V** switches between first and third person, **Share** opens the map overview, and **Options** stops or resumes flight controls. Returning to the game window resumes controls if flight was active.

### Classic, Bank and Edge Tracking, Reticle Flight

| Input | Classic | Bank and Edge Tracking | Reticle Flight |
| --- | --- | --- | --- |
| Left stick | Turn and pitch | Strafe and pitch | Strafe and lift |
| Right stick | Move the on-screen aim | Move the on-screen aim | Turn the drone with the center reticle |
| D-pad up / down | | Ascend and descend | |
| Cross | Set a destination | Set a destination | |

- **R1 / L1** increase and decrease cruise speed. Going through zero engages reverse. **Circle** zeros cruise speed and clears the destination.
- **R2** fires once per press. For Classic patrol lock, press during the first window, then release and press during the second window to shoot.
- **R3** centers the movable reticle. **Triangle** switches the view in these modes, **Share** opens or closes the map overview, and **Options** stops or resumes flight controls.
- Gamepad pitch inversion is off by default: pushing the pitch stick forward raises the nose, and pulling back lowers it. **Gamepad Invert Pitch** changes this. The **Gamepad** inspector group on `FlyCamera` also sets stick deadzone, pointer speed and cruise adjustment rate.

## Remapping buttons and axes

Enabling the addon registers `flight_*` and `map_*` actions in **Project → Project Settings → Input Map**. The Left X axis controls strafe in Gamepad Flight. Edit bindings in Input Map, then run the scene again.

| Actions | Controls |
| --- | --- |
| `flight_move_*` | Left stick and WASD. In Gamepad Flight, these control strafe and fine speed adjustment. |
| `flight_look_*` | Right stick. In Gamepad Flight, it steers the craft and the view, or moves the reticle while `flight_free_aim` is held. |
| `flight_gamepad_accelerate`, `flight_gamepad_brake`, `flight_gamepad_orbit` | Accelerate, brake and orbit the camera in Gamepad Flight. The defaults are L3, Circle and L1. Acceleration requires pressing L3 while pushing the left stick forward. |
| `flight_free_aim`, `flight_gamepad_destination`, `flight_fire`, `flight_center_aim` | Free aim, set a flight destination, fire, and recenter aim. The defaults are L2, Triangle, R2 and R3. |
| `flight_gamepad_select_target` | Select the nearest visible patrol whose SEARCH box covers the reticle in Gamepad Flight. The default is Cross. |
| `flight_target_left`, `flight_target_right` | Cycle visible patrol targets. The defaults are D-pad left and right. |
| `flight_target_confirm` | Confirm the timing window in Staged mode. The default is R1. |
| `flight_primary_click`, `flight_click_modifier`, `flight_destination` | Primary click, its modifier, and the dedicated destination action. |
| `map_*`, `flight_patrol_camera_1`–`flight_patrol_camera_9` | Map overview controls and patrol camera selection. |

You can bind free aim and fire to triggers through `flight_free_aim` and `flight_fire`. Each stick direction has its own action. Mouse motion is read directly, and `flight_free_look` sets which button is held to look around.

## Staged patrol capture in Gamepad Flight

1. Aim into the **SEARCH** box and press **R1** as the arc reaches the first window. The patrol becomes **LOCKED**, and its expiry bar begins to drain beneath the box.
2. You can look away and return while **LOCKED** lasts. Aim at the same patrol and press **R1** in the second window. The patrol becomes **READY** with its own timer.
3. Press **R2** before **READY** expires. The shot keeps its target even if the patrol is off-screen. The rocket launches after 200 ms. When **LOCKED** or **READY** expires, capture starts again at **SEARCH**.

The status and time remaining appear at the bottom of the screen when the patrol is out of view. Tune the challenge on **FlyCamera → Target Lock**.

- **Locked Duration Seconds** (8 s) and **Ready Duration Seconds** (5 s) set how long the states last. **Ready Audio** sets the readiness cue.
- **Progress Speed** sets the speed of the arc. At **0.5×**, a full turn takes **3.2 s**.
- **First Window Width** and **Second Window Width** set how much of the circle each segment covers. Their defaults are **21%** and **20%**. Each new timing window gets a random position and holds it until the attempt ends.

Select **Classic Timing** under **Mode** to restore the earlier two-press R2 sequence with fixed segments.

## Patrol lock in Classic

A **SEARCH** square appears around a visible flying patrol within 150 m. Aim inside the square to start the countdown. One shrinking arc shows the remaining time, with two thicker segments marking the timing windows. Moving the pointer outside the square resets the round to **SEARCH**.

Use **D-pad left/right** to move **SEARCH** through visible patrols in screen order. Selecting another patrol starts a fresh attempt when you aim inside its square.

Left-click as the arc reaches the first segment. It turns green and **TARGET LOCKED** appears while the countdown continues. Left-click in the second window to confirm a shot. The rocket launches 200 ms later. Missing a window or losing sight of the patrol before confirmation clears the lock. An aerial patrol hit pushes the projectile camera closer and plays the flash, smoke and sparks at 0.8× speed.

Confirmed Classic and Staged shots keep their lock behind obstacles. For a patrol with a flight graph, the rocket can detour along published links and portals, then resume direct guidance when the approach is clear. Collisions apply throughout its 8-second lifetime. For patrols without a flight graph, direct guidance lasts up to 1.75 seconds.

Set **Target Lock → Progress Speed** on `FlyPlayer/CameraPivot/CameraBoom/FlyCamera`. The default **0.5×** gives **3.2 seconds** per attempt. At **1×**, the countdown takes **1.6 seconds**.

Assign **Search Audio**, **Locked Audio** and **Fired Audio** in the same group. These cues play when SEARCH appears, the first window acquires a lock, and a shot is accepted. Empty slots stay silent, and **Audio Volume Db** sets their shared level. **Drone Audio → Launch Audio** plays when the rocket appears, 200 ms after accepting a normal or guided shot.

## Camera and map

- Ground contact aligns the drone with the surface and carries the current cruise speed into the glide. The Gamepad Flight camera eases into the new course. Steep terrain stops the drone.
- **V** switches between third and first person. The drone model is visible in third person.
- **Esc** stops flight and releases the mouse. The first click in the window resumes flight controls.
- **Tab** stops flight and opens the map overview. Press **Tab** again to return to your flight view.
- In the overview, **WASD** and middle drag pan the map, the wheel zooms, and right drag rotates. **Home** frames the map, **F** frames the buildings, and **H** toggles the legend. Left click places a waypoint or removes one when you click its marker.

## Inspector settings

- **FlyPlayer → Drone Controls → Invert Gamepad Pitch** reverses pitch from the stick. Gamepad Flight uses the right stick for this. The same setting is available in the **Gamepad** group on `FlyCamera`.
- **Invert Ws** on `FlyPlayer` reverses W/S pitch in Classic and Bank and Edge Tracking. W/S adjust speed in Reticle Flight and Gamepad Flight.
- On `FlyPlayer/CameraPivot/CameraBoom/FlyCamera`, open **Camera Framing → Vertical Screen Offset**. Positive values move the model down in third person. The defaults are **12%** for Classic and Bank and Edge Tracking and **24%** for Reticle Flight.
- **Reticle Flight Controls** on `FlyCamera` sets acceleration, strafe speed, and lift speed. The shared camera settings control mouse sensitivity, wheel step, and speed limits.
- Under **Gamepad Maneuver** on `FlyCamera`, **Button Acceleration Mps2** and **Button Braking Mps2** set the button response, with defaults of 80 and 120 m/s². **Max Bank Angle Degrees** sets the visual bank limit.
- **Gamepad Flight** strafes at up to 32 m/s by default. **Reticle Flight Controls → Strafe Speed Mps** sets that limit. **Gamepad Maneuver → Strafe Acceleration Mps2** sets how quickly lateral speed builds and falls (120 m/s² by default). Horizontal stick response is linear outside the deadzone.
