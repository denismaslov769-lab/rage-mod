--[[
    rage-mod — MoonLoader скрипт для SA-MP
    Порт меню neverlose-last (D3D11 / Dear ImGui -> mimgui):
      * страницы Rage, Legit, Visuals (Players / World), Inventory, Miscellaneous
      * поповер аккаунта: язык (English / Русский), масштаб меню (100/125/150%), масштаб ESP-превью
      * Players: живое ESP-превью (бокс, имя, HP, оружие, дистанция, чамсы, свечение)
      * иконки оружия — настоящие текстуры <model>icon из игры (как в HUD)

    Rage/Legit/ESP/Misc — ТОЛЬКО интерфейс (значения сохраняются в конфиг).
    Anti-Aim (крутилка) — рабочий: Rage -> ANTI-AIM -> Enabled, настройки в «Yaw ›».
    Крутилку видят ДРУГИЕ игроки (подмена поворота в PlayerSync) — и стоя, и на бегу.
    «Show Locally» РЕАЛЬНО крутит персонажа — стоя, на бегу и в прыжке. Движение и прыжок
    скрипт делает сам (камера + WASD/стик), игре ввод движения не отдаётся.
    Автообновление: при запуске проверяет GitHub, вручную — /ragemd_update.

    Шрифты (необязательно): moonloader\resource\rage-mod\SSTMedium.TTF, SSTBold.TTF, fa-solid-900.ttf
    Активация: /ragemd или клавиша (по умолчанию Insert, меняется в меню профиля в тулбаре).
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui, SAMP.Lua (samp.events)
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('4.6.1')

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local ffi      = require 'ffi'
local sampev   = require 'samp.events'
encoding.default = 'CP1251'
local u8  = encoding.UTF8
local new = imgui.new

local CFG_FILE = 'rage-mod.ini'
local menu = new.bool(false)
local O, DEF = {}, {}

-- ============================================================ МАСШТАБ / ШРИФТЫ
-- Всё меню рисуется в «логических» координатах (как в оригинале), а прокси-drawlist
-- масштабирует их вокруг левого верхнего угла окна. Шрифты загружены под каждый масштаб.
local SCALES = { 1.0, 1.25, 1.5 }
local ESP_SCALES = { 1.0, 1.1, 1.2 }
local FS = {}          -- FS[i] = { body=, ctrl=, ... } для каждого масштаба
local F = {}           -- текущий набор шрифтов
local SC, OX, OY = 1, 0, 0

local function applyScale()
    local i = math.max(1, math.min(#SCALES, (O.acc_menu_scale or 0) + 1))
    SC = SCALES[i]
    if FS[i] then for k, v in pairs(FS[i]) do F[k] = v end end
end

-- ============================================================ УТИЛИТЫ
local function chat(text)
    -- SA-MP падает на слишком длинных строках чата — режем до 140 байт
    local ok, s = pcall(u8.decode, u8, '{4E83FF}[rage-mod]{FFFFFF} ' .. tostring(text))
    if not ok or not s then return end
    if #s > 140 then s = s:sub(1, 140) end
    sampAddChatMessage(s, -1)
end

-- ---------- трассировка для поиска краша ----------
-- последние действия скрипта пишутся в moonloader\rage-mod-trace.txt (раз в 0.2 с).
-- После вылета этот файл покажет, что скрипт делал прямо перед крашем.
local TR = { buf = {}, n = 0, last = 0 }
function TR.T(what)
    TR.n = TR.n + 1
    TR.buf[(TR.n - 1) % 40 + 1] = ('%.3f %s'):format(os.clock(), what)
end
function TR.flush()
    if os.clock() - TR.last < 0.2 then return end
    TR.last = os.clock()
    local f = io.open(getWorkingDirectory() .. '\\rage-mod-trace.txt', 'w')
    if not f then return end
    f:write('rage-mod ', thisScript().version, '\n')
    for i = math.max(1, TR.n - 39), TR.n do f:write(TR.buf[(i - 1) % 40 + 1] or '', '\n') end
    f:close()
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function V(x, y) return imgui.ImVec2(x, y) end
local function TV(x, y) return imgui.ImVec2(OX + (x - OX) * SC, OY + (y - OY) * SC) end
local function T(v) return imgui.ImVec2(OX + (v.x - OX) * SC, OY + (v.y - OY) * SC) end

local gA = 1
local function C(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r / 255, g / 255, b / 255, clamp(((a or 255) / 255) * gA, 0, 1)))
end
local function Mix(c1, c2, t)
    t = clamp(t, 0, 1)
    local a1, a2 = c1[4] or 255, c2[4] or 255
    return C(c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t,
             c1[3] + (c2[3] - c1[3]) * t, a1 + (a2 - a1) * t)
end

local anim = {}
local function Motion(key, target, speed, initial)
    local v = anim[key]
    if v == nil then v = initial or target end
    v = v + (target - v) * (1 - math.exp(-(speed or 16) * imgui.GetIO().DeltaTime))
    if math.abs(v - target) < 0.0005 then v = target end
    anim[key] = v
    return v
end

-- прокси drawlist: масштабирует точки/радиусы/толщины
local P = {}
P.__index = P
local function wrapDL(raw) return setmetatable({ raw = raw }, P) end
function P:AddRectFilled(a, b, col, r) self.raw:AddRectFilled(T(a), T(b), col, (r or 0) * SC) end
function P:AddRect(a, b, col, r) self.raw:AddRect(T(a), T(b), col, (r or 0) * SC) end
function P:AddRectFilledMultiColor(a, b, c1, c2, c3, c4) self.raw:AddRectFilledMultiColor(T(a), T(b), c1, c2, c3, c4) end
function P:AddLine(a, b, col, th) self.raw:AddLine(T(a), T(b), col, (th or 1) * SC) end
function P:AddCircle(c, r, col, seg, th) self.raw:AddCircle(T(c), r * SC, col, seg or 24, (th or 1) * SC) end
function P:AddCircleFilled(c, r, col, seg) self.raw:AddCircleFilled(T(c), r * SC, col, seg or 24) end
function P:AddTriangleFilled(a, b, c, col) self.raw:AddTriangleFilled(T(a), T(b), T(c), col) end
function P:AddQuadFilled(a, b, c, d, col) self.raw:AddQuadFilled(T(a), T(b), T(c), T(d), col) end
function P:AddImage(tex, a, b, uv0, uv1, col) self.raw:AddImage(tex, T(a), T(b), uv0, uv1, col) end
function P:AddText(p, col, s) self.raw:AddText(T(p), col, s) end
function P:PushClipRect(a, b, i) self.raw:PushClipRect(T(a), T(b), i) end
function P:PopClipRect() self.raw:PopClipRect() end
function P:PathLineTo(p) self.raw:PathLineTo(T(p)) end
function P:PathArcTo(c, r, a1, a2, seg) self.raw:PathArcTo(T(c), r * SC, a1, a2, seg) end
function P:PathFillConvex(col) self.raw:PathFillConvex(col) end

local function TextSize(str, font)
    if font then imgui.PushFont(font) end
    local s = imgui.CalcTextSize(str)
    if font then imgui.PopFont() end
    return { x = s.x / SC, y = s.y / SC }
end
local function Text(dl, x, y, col, str, font)
    if font then imgui.PushFont(font) end
    dl:AddText(V(x, y), col, str)
    if font then imgui.PopFont() end
end
local function TextY(dl, x, y, h, col, str, font)
    local ts = TextSize(str, font)
    Text(dl, x, y + math.floor((h - ts.y) * 0.5), col, str, font)
end

local function Hit(id, x, y, w, h)
    imgui.SetCursorScreenPos(TV(x, y))
    return imgui.InvisibleButton(id, imgui.ImVec2(math.max(1, w * SC), math.max(1, h * SC)))
end
local function Mouse()
    local m = imgui.GetMousePos()
    return { x = OX + (m.x - OX) / SC, y = OY + (m.y - OY) / SC }
end
local function inRect(m, x, y, w, h) return m.x >= x and m.x <= x + w and m.y >= y and m.y <= y + h end
local function screenL()
    local sw, sh = getScreenResolution()
    return OX - OX / SC, OY - OY / SC, OX + (sw - OX) / SC, OY + (sh - OY) / SC
end

local function Chevron(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.3)
    dl:AddLine(V(x + 3, y + 3), V(x, y + 6), col, 1.3)
end
local function CheckMark(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.5)
    dl:AddLine(V(x + 3, y + 3), V(x + 8, y - 3), col, 1.5)
end

local VTX_OK = true
local function vtxFirst(raw)
    if not VTX_OK then return 0 end
    local ok, n = pcall(function() return raw.VtxBuffer.Size end)
    if not ok then VTX_OK = false; return 0 end
    return n
end
-- pivot в логических координатах
local function vtxScale(raw, first, lx, ly, s, ox, oy)
    if not VTX_OK then return end
    local pv = TV(lx, ly)
    local px, py, dx, dy = pv.x, pv.y, ox * SC, oy * SC
    local ok = pcall(function()
        local buf = raw.VtxBuffer
        for i = first, buf.Size - 1 do
            local p = buf.Data[i].pos
            p.x = px + (p.x - px) * s + dx
            p.y = py + (p.y - py) * s + dy
        end
    end)
    if not ok then VTX_OK = false end
end

local PI = math.pi
local function FillLeftRounded(dl, x1, y1, x2, y2, r, col)
    dl:PathLineTo(V(x2, y1)); dl:PathLineTo(V(x2, y2))
    dl:PathArcTo(V(x1 + r, y2 - r), r, PI * 0.5, PI, 10)
    dl:PathArcTo(V(x1 + r, y1 + r), r, PI, PI * 1.5, 10)
    dl:PathFillConvex(col)
end
local function FillTopRightRounded(dl, x1, y1, x2, y2, r, col)
    dl:PathLineTo(V(x1, y1))
    dl:PathArcTo(V(x2 - r, y1 + r), r, PI * 1.5, PI * 2, 10)
    dl:PathLineTo(V(x2, y2)); dl:PathLineTo(V(x1, y2))
    dl:PathFillConvex(col)
end

-- ============================================================ ЛОКАЛИЗАЦИЯ
local RU = {
    -- навигация / секции
    ['Rage'] = 'Рейдж', ['Legit'] = 'Легит', ['Visuals'] = 'Визуалы', ['Players'] = 'Игроки', ['World'] = 'Мир',
    ['Inventory'] = 'Инвентарь', ['Miscellaneous'] = 'Разное', ['AIMBOT'] = 'АИМБОТ', ['COMMON'] = 'ОБЩЕЕ',
    ['MAIN'] = 'ОСНОВНОЕ', ['OTHER'] = 'ПРОЧЕЕ', ['SELECTION'] = 'ВЫБОР ЦЕЛИ', ['ANTI-AIM'] = 'АНТИ-АИМ',
    ['TRIGGERBOT'] = 'ТРИГГЕРБОТ', ['ENEMY'] = 'ВРАГИ', ['ENEMY MODEL'] = 'МОДЕЛЬ ВРАГА', ['VIEW'] = 'ВИД',
    ['WORLD ESP'] = 'ESP МИРА', ['MISCELLANEOUS'] = 'РАЗНОЕ', ['MOVEMENT'] = 'ДВИЖЕНИЕ', ['FEATURES'] = 'ФУНКЦИИ',
    ['YAW'] = 'ПОВОРОТ', ['BUNNY HOP'] = 'БАННИ-ХОП', ['Direction'] = 'Направление', ['Velocity'] = 'По инерции',
    ['Mouse'] = 'По мышке', ['Hop Speed'] = 'Скорость прыжков', ['Steer In Air'] = 'Рулить мышкой в воздухе',
    -- ряды
    ['Enabled'] = 'Включено', ['Silent Aim'] = 'Тихий аим', ['Automatic Fire'] = 'Автострельба',
    ['Aim Through Walls'] = 'Сквозь стены', ['Refine Shot'] = 'Уточнение выстрела', ['Field of View'] = 'Поле зрения',
    ['History'] = 'История', ['Delay Shot'] = 'Задержка выстрела', ['Remove Spread'] = 'Убрать разброс',
    ['Duck Peek Assist'] = 'Пик из приседа', ['Quick Peek Assist'] = 'Быстрый пик', ['Double Tap'] = 'Двойной выстрел',
    ['Prefer'] = 'Приоритет', ['Hitboxes'] = 'Хитбоксы', ['Hit Chance'] = 'Шанс попадания', ['Min Damage'] = 'Мин. урон',
    ['Quick Stop'] = 'Быстрая остановка', ['Quick Scope'] = 'Быстрый прицел',
    ['Suppress Breathing Animations'] = 'Без анимации дыхания', ['Leg Movement'] = 'Движение ног',
    ['Pitch'] = 'Наклон', ['Yaw'] = 'Поворот', ['Mouse Override'] = 'Управление мышью',
    ['Activation'] = 'Активация', ['Conditions'] = 'Условия', ['Smoothing'] = 'Плавность',
    ['Reaction Time'] = 'Время реакции', ['Recoil Control'] = 'Контроль отдачи', ['Burst Time'] = 'Время очереди',
    ['Visualize'] = 'Визуализация', ['Automatic Weapons'] = 'Автомат. оружие',
    ['Standalone Recoil Control'] = 'Отдельный контроль отдачи', ['Randomize'] = 'Рандомизация',
    ['Offscreen Arrow'] = 'Стрелки за экраном', ['Sounds'] = 'Звуки', ['Player'] = 'Игрок',
    ['Behind Walls'] = 'За стенами', ['On Shot'] = 'При выстреле', ['Ragdolls'] = 'Рэгдоллы',
    ['Soul Particles'] = 'Частицы души', ['Glow'] = 'Свечение', ['View Options'] = 'Настройки вида',
    ['Scope Options'] = 'Настройки прицела', ['Viewmodel Options'] = 'Модель в руках',
    ['Perspective Options'] = 'Перспектива', ['Unlock Spectating'] = 'Свободное наблюдение',
    ['Visual Recoil'] = 'Визуальная отдача', ['Radar'] = 'Радар', ['Scope Overlay'] = 'Оверлей прицела',
    ['Inaccuracy Overlay'] = 'Оверлей разброса', ['Death Notices'] = 'Килфид', ['Scoreboard'] = 'Таблица счёта',
    ['Crosshairs'] = 'Прицелы', ['Bomb'] = 'Бомба', ['Weapons'] = 'Оружие', ['Hostages'] = 'Заложники',
    ['Grenades'] = 'Гранаты', ['Grenade Trajectory'] = 'Траектория гранат',
    ['Grenade Proximity Warnings'] = 'Предупр. о гранатах', ['Windows'] = 'Окна', ['Removals'] = 'Удаления',
    ['Ambience'] = 'Атмосфера', ['Hit Marker'] = 'Хитмаркер', ['Bullet Tracers'] = 'Трассеры',
    ['Bullet Impacts'] = 'Попадания пуль', ['BULLET TRACERS'] = 'ТРАССЕРЫ', ['Local'] = 'Свои',
    ['Duration'] = 'Длительность', ['Bunny Hop'] = 'Банни-хоп', ['Air Strafe'] = 'Стрейф в воздухе',
    ['Jump Bug'] = 'Джамп-баг', ['Standalone Quick Stop'] = 'Быстрая остановка', ['Strafe Assist'] = 'Помощь стрейфа',
    ['Edge Jump'] = 'Прыжок с края', ['Slow Walk'] = 'Медленная ходьба', ['Fast Ladder'] = 'Быстрая лестница',
    ['Quick Switch'] = 'Быстрая смена', ['Super Toss'] = 'Супер-бросок', ['Knife Bot'] = 'Нож-бот',
    ['Prevent AFK Kick'] = 'Анти-AFK', ['Hit Sound'] = 'Звук попадания', ['Automatic Purchase'] = 'Автозакупка',
    ['Automatic Grenade Release'] = 'Автобросок гранаты', ['Auto-Accept Matchmaking'] = 'Автопринятие игры',
    ['Log Events'] = 'Лог событий', ['Mode'] = 'Режим', ['Spin Speed'] = 'Скорость вращения',
    ['Jitter Range'] = 'Диапазон джиттера', ['Disable While Aiming'] = 'Откл. при прицеливании',
    ['Toggle Key'] = 'Клавиша', ['Show Locally'] = 'Показывать у себя', ['Force Sync'] = 'Частая синхронизация',
    ['Weapon'] = 'Оружие',
    -- значения
    ['Off'] = 'Выкл', ['On'] = 'Вкл', ['Latency'] = 'Задержка', ['Performance'] = 'Скорость', ['Default'] = 'Обычный',
    ['Maximum'] = 'Максимум', ['Damage'] = 'Урон', ['Accuracy'] = 'Точность', ['Partial'] = 'Частично',
    ['Full'] = 'Полностью', ['Head'] = 'Голова', ['Body'] = 'Тело', ['Chest'] = 'Грудь', ['Stomach'] = 'Живот',
    ['Arms'] = 'Руки', ['Legs'] = 'Ноги', ['Feet'] = 'Ступни', ['Walking'] = 'Ходьба', ['Sliding'] = 'Скольжение',
    ['Always'] = 'Всегда', ['Assisted'] = 'С помощью', ['On Key'] = 'По клавише', ['Through Walls'] = 'Сквозь стены',
    ['Through Smoke'] = 'Сквозь дым', ['In Air'] = 'В воздухе', ['Flashed'] = 'Ослеплён', ['None'] = 'Нет',
    ['Low'] = 'Низкая', ['Medium'] = 'Средняя', ['High'] = 'Высокая', ['Solid'] = 'Сплошной', ['Flat'] = 'Плоский',
    ['Water Flow'] = 'Переливы', ['Glass'] = 'Стекло', ['Glow Outline'] = 'Контур', ['Perspective'] = 'Перспектива',
    ['Enemies'] = 'Враги', ['Teammates'] = 'Союзники', ['No Shake'] = 'Без тряски', ['No Recoil'] = 'Без отдачи',
    ['Reveal Enemies'] = 'Показ врагов', ['Rotate'] = 'Вращение', ['Zoom Out'] = 'Отдаление',
    ['Damage Dealt'] = 'Нанесённый урон', ['Damage Taken'] = 'Полученный урон', ['Purchases'] = 'Покупки',
    ['Deaths'] = 'Смерти', ['Spin'] = 'Крутилка', ['Jitter'] = 'Джиттер', ['Random'] = 'Случайно',
    ['Backward'] = 'Спиной', ['Backward Flick'] = 'Спиной + флик', ['Flick Time'] = 'Время флика',
    ['PITCH'] = 'НАКЛОН', ['Down'] = 'Вниз', ['Up'] = 'Вверх',
    -- прочее
    ['Language'] = 'Язык', ['Menu Scale'] = 'Масштаб меню', ['ESP Scale'] = 'Масштаб ESP',
    ['Synchronization'] = 'Синхронизация', ['Global'] = 'Общий', ['Save Config'] = 'Сохранить конфиг',
    ['Load Config'] = 'Загрузить конфиг', ['Reset Config'] = 'Сбросить конфиг', ['Open Key: '] = 'Клавиша меню: ',
    ['Notifications: '] = 'Уведомления: ', ['Loadout'] = 'Снаряжение', ['Pistols'] = 'Пистолеты',
    ['Mid-Tier'] = 'Средние', ['Rifles'] = 'Винтовки', ['Box'] = 'Бокс', ['Name'] = 'Имя', ['Health'] = 'HP',
    ['Dist'] = 'Дист.', ['Distance'] = 'Дистанция', ['offline'] = 'оффлайн', ['Profile'] = 'Профиль',
}
do
    local add = {
        ['BACKTRACK'] = 'БЭКТРЕК',
        ['Backtrack'] = 'Бэктрек (призрак)',
        ['Backtrack Time'] = 'Задержка призрака',
        ['Hit Radius'] = 'Радиус попадания',
        ['Hit Mode'] = 'Режим попадания',
        ['Ghost Only'] = 'Только призрак',
        ['Whole Trail'] = 'Весь след',
        ['Send Damage'] = 'Отправлять урон',
        ['Ghost Style'] = 'Вид призрака',
        ['Hidden'] = 'Скрыт',
        ['Ghost Color'] = 'Цвет призрака',
        ['Show Trail'] = 'Показывать след',
        ['VISIBLE CHAMS'] = 'ЧАМСЫ (ВИДИМ)',
        ['HIDDEN CHAMS'] = 'ЧАМСЫ (ЗА СТЕНОЙ)',
        ['ON SHOT CHAMS'] = 'ЧАМСЫ (ВЫСТРЕЛ)',
        ['TEAMMATE CHAMS'] = 'ЧАМСЫ СОЮЗНИКОВ',
        ['LOCAL CHAMS'] = 'СВОИ ЧАМСЫ',
        ['OVERLAY (THROUGH WALLS)'] = 'ОВЕРЛЕЙ (СКВОЗЬ СТЕНЫ)',
        ['Visible'] = 'Видимые',
        ['Teammates'] = 'Союзники',
        ['Overlay (walls)'] = 'Оверлей (сквозь стены)',
        ['Type'] = 'Тип',
        ['Second Color'] = 'Второй цвет',
        ['Opacity'] = 'Непрозрачность',
        ['Animation Speed'] = 'Скорость анимации',
        ['Pulse'] = 'Пульс',
        ['Strobe'] = 'Стробоскоп',
        ['Metallic'] = 'Металл',
        ['Ghost'] = 'Призрак',
        ['Heat'] = 'Жар',
        ['Two-Tone'] = 'Двухцветный',
        ['Wave'] = 'Волна',
        ['Fire'] = 'Огонь',
        ['Ice'] = 'Лёд',
        ['Galaxy'] = 'Галактика',
        ['Dark'] = 'Тёмное',
        ['Neon'] = 'Неон',
        ['Filled'] = 'Заливка',
        ['Glow Aura'] = 'Аура',
        ['Neon Outline'] = 'Неоновый контур',
        ['Hologram'] = 'Голограмма',
        ['Dots'] = 'Точки',
        ['Tube Skeleton'] = 'Трубчатый скелет',
        ['Flame'] = 'Пламя',
        ['When'] = 'Когда',
        ['Visible Only'] = 'Только видимых',
        ['Water Flow'] = 'Переливы',
        ['Glass'] = 'Стекло',
        ['Glow Outline'] = 'Свечение',
    }
    for k, v in pairs(add) do RU[k] = v end
end
do
    local add = {
        ['SKY & FOG'] = 'НЕБО И ТУМАН',
        ['SUN & CLOUDS'] = 'СОЛНЦЕ И ОБЛАКА',
        ['LIGHTING'] = 'ОСВЕЩЕНИЕ',
        ['RAINBOW'] = 'РАДУГА',
        ['ESP TEXT'] = 'ТЕКСТ ESP',
        ['Override Fog'] = 'Свой туман',
        ['Fog Start'] = 'Начало тумана',
        ['Draw Distance'] = 'Дальность прорисовки',
        ['Custom Sky'] = 'Своё небо',
        ['Sky Top'] = 'Верх неба',
        ['Sky Bottom / Fog'] = 'Низ неба / туман',
        ['Custom Sun'] = 'Своё солнце',
        ['Sun Core'] = 'Ядро солнца',
        ['Sun Halo'] = 'Ореол солнца',
        ['Sun Size'] = 'Размер солнца',
        ['Custom Clouds'] = 'Свои облака',
        ['Low Clouds'] = 'Низкие облака',
        ['Fluffy Clouds'] = 'Пушистые облака',
        ['Clouds Alpha'] = 'Прозрачность облаков',
        ['Custom Ambient'] = 'Свой эмбиент',
        ['Ambient Color'] = 'Цвет эмбиента',
        ['Ambient Power'] = 'Сила эмбиента',
        ['Color Filter'] = 'Цветофильтр',
        ['Filter Color'] = 'Цвет фильтра',
        ['Custom Water'] = 'Своя вода',
        ['Water Color'] = 'Цвет воды',
        ['Custom Shadows'] = 'Свои тени',
        ['Shadow Strength'] = 'Сила теней',
        ['Light Shadows'] = 'Тени от фонарей', ['Pole Shadows'] = 'Тени от столбов',
        ['Rainbow'] = 'Радуга',
        ['Saturation'] = 'Насыщенность',
        ['Font Size'] = 'Размер шрифта',
        ['Text Style'] = 'Стиль текста',
        ['Shadow'] = 'Тень',
        ['Sky'] = 'Небо',
        ['Silhouette'] = 'Силуэт',
        ['Chams'] = 'Чамсы',
        ['Tracers'] = 'Трассеры',
        ['Texture'] = 'Текстура',
        ['Keep'] = 'Оставить',
        ['Remove'] = 'Убрать',
        ['Lighting'] = 'Освещение',
        ['Normal'] = 'Обычное',
        ['Bright'] = 'Яркое',
        ['Flat (no light)'] = 'Плоское (без света)',
        ['Silhouette (walls)'] = 'Силуэт (сквозь стены)',
        ['Silhouette When'] = 'Когда силуэт',
        ['Silhouette Width'] = 'Ширина силуэта',
        ['Silhouette Glow'] = 'Свечение силуэта',
        ['Always'] = 'Всегда',
        ['Visibility'] = 'По видимости',
        ['Team Color'] = 'Цвет команды',
        ['Sun & Clouds'] = 'Солнце и облака',
        ['Sky & Fog'] = 'Небо и туман',
        ['ESP Text'] = 'Текст ESP',
    }
    for k, v in pairs(add) do RU[k] = v end
end
do
    local add = {
        ['BOX'] = 'РАМКА',
        ['NAME & FLAGS'] = 'НИК И ФЛАГИ',
        ['HEALTH'] = 'ЗДОРОВЬЕ',
        ['WEAPON'] = 'ОРУЖИЕ',
        ['SKELETON'] = 'СКЕЛЕТ',
        ['EXTRA'] = 'ДОПОЛНИТЕЛЬНО',
        ['CHAMS'] = 'ЧАМСЫ',
        ['HIT MARKER'] = 'ХИТМАРКЕР',
        ['VIEW OPTIONS'] = 'НАСТРОЙКИ ВИДА',
        ['CHINA HAT'] = 'КИТАЙСКАЯ ШЛЯПА', ['China Hat'] = 'Китайская шляпа', ['Hat Size'] = 'Размер шляпы',
        ['Hat Height'] = 'Высота шляпы', ['Hat Alpha'] = 'Прозрачность шляпы', ['Hide In First Person'] = 'Скрывать от первого лица',
        ['WEATHER & TIME'] = 'ПОГОДА И ВРЕМЯ',
        ['SCREEN EFFECTS'] = 'ЭФФЕКТЫ ЭКРАНА',
        ['CROSSHAIR'] = 'ПРИЦЕЛ',
        ['WATERMARK'] = 'ВОТЕРМАРК',
        ['VEHICLES'] = 'ТРАНСПОРТ',
        ['PICKUPS'] = 'ПИКАПЫ',
        ['OBJECTS'] = 'ОБЪЕКТЫ',
        ['Name & Flags'] = 'Ник и флаги',
        ['Skeleton'] = 'Скелет',
        ['Extra'] = 'Дополнительно',
        ['Style'] = 'Стиль',
        ['Corners'] = 'Уголки',
        ['Rounded'] = 'Скруглённая',
        ['Visible Color'] = 'Цвет (видим)',
        ['Hidden Color'] = 'Цвет (за стеной)',
        ['Fill'] = 'Заливка',
        ['Gradient'] = 'Градиент',
        ['Fill Alpha'] = 'Прозрачность заливки',
        ['Outline'] = 'Обводка',
        ['Thickness'] = 'Толщина',
        ['Background'] = 'Подложка',
        ['Color Mode'] = 'Режим цвета',
        ['Player Color'] = 'Цвет игрока',
        ['Custom'] = 'Свой',
        ['White'] = 'Белый',
        ['Custom Color'] = 'Свой цвет',
        ['Show ID'] = 'Показывать ID',
        ['Flags'] = 'Флаги',
        ['Position'] = 'Позиция',
        ['Left'] = 'Слева',
        ['Right'] = 'Справа',
        ['Top'] = 'Сверху',
        ['Bottom'] = 'Снизу',
        ['By Health'] = 'По здоровью',
        ['Show Number'] = 'Число',
        ['Armor Bar'] = 'Полоска брони',
        ['Armor Color'] = 'Цвет брони',
        ['Bar Width'] = 'Ширина полоски',
        ['Icon + Text'] = 'Иконка + текст',
        ['Icon'] = 'Иконка',
        ['Text'] = 'Текст',
        ['Text Color'] = 'Цвет текста',
        ['Icon Size'] = 'Размер иконки',
        ['Circle'] = 'Круг',
        ['Filled'] = 'Заполненный',
        ['Snaplines'] = 'Линии к игрокам',
        ['Center'] = 'Центр',
        ['Snapline Color'] = 'Цвет линий',
        ['Head Dot'] = 'Точка на голове',
        ['Look Direction'] = 'Направление взгляда',
        ['Arrow Size'] = 'Размер стрелки',
        ['Arrow Radius'] = 'Радиус стрелок',
        ['Max Distance'] = 'Макс. дистанция',
        ['Only Visible'] = 'Только видимых',
        ['Show Teammates'] = 'Показывать союзников',
        ['Chams Settings'] = 'Настройки чамсов',
        ['On Shot Color'] = 'Цвет при выстреле',
        ['Brightness'] = 'Яркость',
        ['Paint Same Skin'] = 'Красить мой скин у врагов (красит и меня)',
        ['Local Player'] = 'Свой персонаж',
        ['Local Color'] = 'Свой цвет',
        ['Line'] = 'Линия',
        ['Beam'] = 'Луч',
        ['Laser'] = 'Лазер',
        ['Width'] = 'Толщина',
        ['Crosshair'] = 'Прицел',
        ['Both'] = 'Оба',
        ['Color'] = 'Цвет',
        ['Damage Numbers'] = 'Цифры урона',
        ['Damage Color'] = 'Цвет урона',
        ['Override FOV'] = 'Свой FOV',
        ['Night Vision'] = 'Ночное зрение',
        ['Thermal Vision'] = 'Тепловизор',
        ['Weather & Time'] = 'Погода и время',
        ['Screen Effects'] = 'Эффекты экрана',
        ['Override Time'] = 'Своё время',
        ['Hour'] = 'Час',
        ['Minute'] = 'Минута',
        ['Override Weather'] = 'Своя погода',
        ['Weather'] = 'Погода',
        ['Sunny'] = 'Солнечно',
        ['Extra Sunny'] = 'Очень солнечно',
        ['Clear'] = 'Ясно',
        ['Cloudy'] = 'Облачно',
        ['Rainy'] = 'Дождь',
        ['Foggy'] = 'Туман',
        ['Sandstorm'] = 'Песчаная буря',
        ['Purple'] = 'Фиолетовая',
        ['Green'] = 'Зелёная',
        ['Dark Red'] = 'Тёмно-красная',
        ['Toxic'] = 'Токсичная',
        ['Underwater'] = 'Подводная',
        ['World Tint'] = 'Тонировка мира',
        ['Tint Strength'] = 'Сила тонировки',
        ['Vignette'] = 'Виньетка',
        ['Vignette Strength'] = 'Сила виньетки',
        ['Scanlines'] = 'Сканлайны',
        ['Damage Flash'] = 'Вспышка урона',
        ['Dot'] = 'Точка',
        ['Cross + Dot'] = 'Крест + точка',
        ['T-Shape'] = 'Т-образный',
        ['Cross'] = 'Крест',
        ['Size'] = 'Размер',
        ['Gap'] = 'Зазор',
        ['Dynamic'] = 'Динамический',
        ['Only When Aiming'] = 'Только при прицеливании',
        ['Watermark'] = 'Вотермарк',
        ['Top Right'] = 'Справа сверху',
        ['Top Left'] = 'Слева сверху',
        ['Bottom Right'] = 'Справа снизу',
        ['Bottom Left'] = 'Слева снизу',
        ['Items'] = 'Элементы',
        ['Nick'] = 'Ник',
        ['Time'] = 'Время',
        ['Speed'] = 'Скорость',
        ['Accent'] = 'Акцент',
        ['Keybinds List'] = 'Список функций',
        ['Hide HUD'] = 'Скрыть HUD',
        ['Hide Radar'] = 'Скрыть радар',
        ['Aimbot FOV'] = 'FOV аимбота',
        ['Speed Indicator'] = 'Спидометр',
        ['Vehicles'] = 'Транспорт',
        ['Pickups'] = 'Пикапы',
        ['Objects'] = 'Объекты',
        ['Actors (NPC)'] = 'Актёры (NPC)',
        ['Kill Effect'] = 'Эффект убийства',
        ['Model Name'] = 'Модель',
        ['Driver'] = 'Водитель',
        ['Only Empty'] = 'Только пустые',
        ['Model ID'] = 'ID модели',
        ['Limit'] = 'Лимит',
    }
    for k, v in pairs(add) do RU[k] = v end
end
local function L(s)
    if O.acc_lang == 1 and type(s) == 'string' then return RU[s] or s end
    return s
end

-- ============================================================ ИКОНКИ
local function utf8cp(cp)
    return string.char(0xE0 + bit.rshift(cp, 12), 0x80 + bit.band(bit.rshift(cp, 6), 0x3F), 0x80 + bit.band(cp, 0x3F))
end
local FA = {
    rage = utf8cp(0xf05b), legit = utf8cp(0xf8cc), visuals = utf8cp(0xf03e), players = utf8cp(0xf007),
    world = utf8cp(0xf0ac), inventory = utf8cp(0xf5fd), misc = utf8cp(0xf1de), save = utf8cp(0xf0c7),
    list = utf8cp(0xf03a),
}
FA.user = FA.players
local FA_RANGES = new.ImWchar[3](0xf000, 0xf8ff, 0)

local function rectOutline(dl, x1, y1, x2, y2, col, th)
    dl:AddLine(V(x1, y1), V(x2, y1), col, th); dl:AddLine(V(x2, y1), V(x2, y2), col, th)
    dl:AddLine(V(x2, y2), V(x1, y2), col, th); dl:AddLine(V(x1, y2), V(x1, y1), col, th)
end
local VEC = {}
VEC.rage = function(dl, x, y, c)
    dl:AddCircle(V(x + 7, y + 7), 5, c, 20, 1.5)
    dl:AddLine(V(x + 7, y - 1), V(x + 7, y + 3), c, 1.5); dl:AddLine(V(x + 7, y + 11), V(x + 7, y + 15), c, 1.5)
    dl:AddLine(V(x - 1, y + 7), V(x + 3, y + 7), c, 1.5); dl:AddLine(V(x + 11, y + 7), V(x + 15, y + 7), c, 1.5)
    dl:AddCircleFilled(V(x + 7, y + 7), 1.5, c, 10)
end
VEC.legit = function(dl, x, y, c)
    dl:AddRectFilled(V(x + 2, y), V(x + 12, y + 15), c, 5)
    dl:AddLine(V(x + 7, y + 1), V(x + 7, y + 6), C(18, 21, 30), 1.5)
end
VEC.visuals = function(dl, x, y, c)
    rectOutline(dl, x, y + 1, x + 14, y + 13, c, 1.5)
    dl:AddTriangleFilled(V(x + 2, y + 11), V(x + 6, y + 6), V(x + 9, y + 11), c)
    dl:AddTriangleFilled(V(x + 7, y + 11), V(x + 10, y + 7), V(x + 13, y + 11), c)
    dl:AddCircleFilled(V(x + 10, y + 4.5), 1.5, c, 10)
end
VEC.players = function(dl, x, y, c)
    dl:AddCircleFilled(V(x + 7, y + 4), 3.6, c, 16)
    dl:AddRectFilled(V(x + 1, y + 9), V(x + 13, y + 15), c, 4)
end
VEC.user = VEC.players
VEC.world = function(dl, x, y, c)
    dl:AddCircle(V(x + 7, y + 7), 6.5, c, 24, 1.5)
    dl:AddLine(V(x + 0.5, y + 7), V(x + 13.5, y + 7), c, 1.2)
    dl:AddLine(V(x + 7, y + 0.5), V(x + 7, y + 13.5), c, 1.2)
    dl:AddCircle(V(x + 7, y + 7), 3, c, 16, 1.2)
end
VEC.inventory = function(dl, x, y, c)
    dl:AddQuadFilled(V(x + 7, y + 1), V(x + 14, y + 4.5), V(x + 7, y + 8), V(x, y + 4.5), c)
    dl:AddLine(V(x, y + 8), V(x + 7, y + 11.5), c, 1.5); dl:AddLine(V(x + 7, y + 11.5), V(x + 14, y + 8), c, 1.5)
    dl:AddLine(V(x, y + 11.5), V(x + 7, y + 15), c, 1.5); dl:AddLine(V(x + 7, y + 15), V(x + 14, y + 11.5), c, 1.5)
end
VEC.misc = function(dl, x, y, c)
    for i = 0, 2 do
        local ly = y + 2 + i * 5
        dl:AddLine(V(x, ly), V(x + 14, ly), c, 1.5)
        dl:AddCircleFilled(V(x + ({ 4, 10, 6 })[i + 1], ly), 2.3, c, 12)
    end
end
VEC.save = function(dl, x, y, c)
    dl:AddRectFilled(V(x, y), V(x + 13, y + 13), c, 2)
    dl:AddRectFilled(V(x + 3, y + 1), V(x + 10, y + 5), C(17, 19, 27), 1)
    dl:AddRectFilled(V(x + 3, y + 8), V(x + 10, y + 12), C(17, 19, 27), 1)
end
VEC.list = function(dl, x, y, c)
    for i = 0, 2 do
        dl:AddCircleFilled(V(x + 1.5, y + 2 + i * 5), 1.6, c, 8)
        dl:AddLine(V(x + 5, y + 2 + i * 5), V(x + 14, y + 2 + i * 5), c, 1.6)
    end
end
local function Icon(dl, name, x, y, h, col)
    if F.icon then TextY(dl, x, y, h, col, FA[name], F.icon)
    else VEC[name](dl, x, y + math.floor((h - 14) * 0.5), col) end
end

-- ============================================================ ИКОНКИ ОРУЖИЯ ИЗ ИГРЫ
local WEAPON_MODEL = {
    [1] = 331, [2] = 333, [3] = 334, [4] = 335, [5] = 336, [6] = 337, [7] = 338, [8] = 339, [9] = 341,
    [10] = 321, [11] = 322, [12] = 323, [13] = 324, [14] = 325, [15] = 326, [16] = 342, [17] = 343, [18] = 344,
    [22] = 346, [23] = 347, [24] = 348, [25] = 349, [26] = 350, [27] = 351, [28] = 352, [29] = 353,
    [30] = 355, [31] = 356, [32] = 372, [33] = 357, [34] = 358, [35] = 359, [36] = 360, [37] = 361,
    [38] = 362, [39] = 363, [40] = 364, [41] = 365, [42] = 366, [43] = 367, [44] = 368, [45] = 369, [46] = 371,
}
local WEAPON_NAME = {
    [0] = 'Fist', [1] = 'Brass Knuckles', [2] = 'Golf Club', [3] = 'Nightstick', [4] = 'Knife', [5] = 'Baseball Bat',
    [6] = 'Shovel', [7] = 'Pool Cue', [8] = 'Katana', [9] = 'Chainsaw', [10] = 'Dildo', [11] = 'Dildo', [12] = 'Vibrator',
    [13] = 'Vibrator', [14] = 'Flowers', [15] = 'Cane', [16] = 'Grenade', [17] = 'Tear Gas', [18] = 'Molotov',
    [22] = '9mm', [23] = 'Silenced 9mm', [24] = 'Desert Eagle', [25] = 'Shotgun', [26] = 'Sawn-off',
    [27] = 'Combat Shotgun', [28] = 'Micro Uzi', [29] = 'MP5', [30] = 'AK-47', [31] = 'M4', [32] = 'Tec-9',
    [33] = 'Country Rifle', [34] = 'Sniper Rifle', [35] = 'RPG', [36] = 'HS Rocket', [37] = 'Flamethrower',
    [38] = 'Minigun', [39] = 'Satchel', [40] = 'Detonator', [41] = 'Spraycan', [42] = 'Extinguisher',
    [43] = 'Camera', [44] = 'Night Vision', [45] = 'Thermal', [46] = 'Parachute',
}

local WICON = {}
local function rd32(addr) return ffi.cast('uint32_t*', addr)[0] end
local function rasterExtOffset()
    local off = rd32(0xB4E9E0)
    if off < 0x34 or off > 0x100 then off = 0x34 end
    return off
end
local function findWeaponIconTexture(modelId)
    local mi = rd32(0xA9B0C8 + modelId * 4)
    if mi == 0 then return nil end
    local txd = ffi.cast('int16_t*', mi + 0x0A)[0]
    if txd < 0 then return nil end
    local pool = rd32(0xC8800C)
    if pool == 0 then return nil end
    local objects, flags = rd32(pool), rd32(pool + 4)
    local size = ffi.cast('int32_t*', pool + 8)[0]
    if objects == 0 or flags == 0 or txd >= size then return nil end
    if bit.band(ffi.cast('uint8_t*', flags)[txd], 0x80) ~= 0 then return nil end
    local dict = rd32(objects + txd * 0x0C)
    if dict == 0 then return nil end
    local head = dict + 8
    local link, n = rd32(head), 0
    while link ~= 0 and link ~= head and n < 64 do
        local tex = link - 8
        local raw = ffi.string(ffi.cast('const char*', tex + 0x10), 32)
        local name = (raw:match('^[^%z]*') or ''):lower()
        if name:sub(-4) == 'icon' then
            local raster = rd32(tex)
            if raster ~= 0 then
                local d3d = rd32(raster + rasterExtOffset())
                if d3d ~= 0 then return ffi.cast('void*', d3d) end
            end
        end
        link = rd32(link); n = n + 1
    end
    return nil
end

local function refreshWeaponIcons(force)
    local missing = force
    for wid, mid in pairs(WEAPON_MODEL) do
        if not hasModelLoaded(mid) then missing = true; WICON[wid] = nil end
    end
    if not missing then return end
    for _, mid in pairs(WEAPON_MODEL) do requestModel(mid) end
    loadAllModelsNow()
    for wid, mid in pairs(WEAPON_MODEL) do
        WICON[wid] = hasModelLoaded(mid) and findWeaponIconTexture(mid) or nil
    end
end
local function releaseWeaponIcons()
    for wid, mid in pairs(WEAPON_MODEL) do
        WICON[wid] = nil
        pcall(markModelAsNoLongerNeeded, mid)
    end
end
local function WeaponIcon(dl, wid, cx, cy, s, alpha)
    local tex = wid and WICON[wid]
    if not tex then return false end
    dl:AddImage(tex, V(cx - s * 0.5, cy - s * 0.5), V(cx + s * 0.5, cy + s * 0.5), V(0, 0), V(1, 1), C(255, 255, 255, alpha or 255))
    return true
end
local function heldWeapon()
    if doesCharExist(PLAYER_PED) then return getCurrentCharWeapon(PLAYER_PED) end
    return 0
end

-- ============================================================ НАСТРОЙКИ
local keyNames = { 'Нет', 'Insert', 'Delete', 'Home', 'End', 'F2', 'F3' }
local keyCodes = { 0, 0x2D, 0x2E, 0x24, 0x23, 0x71, 0x72 }
local aaModeItems = { 'Spin', 'Jitter', 'Random', 'Backward', 'Backward Flick' }

local WEAPON_SLOTS = { false, 24, 31, 30, 25, 27, 29, 28, 32, 33, 34 }
local WEAPON_SLOT_NAMES = { 'Global' }
for i = 2, #WEAPON_SLOTS do WEAPON_SLOT_NAMES[i] = WEAPON_NAME[WEAPON_SLOTS[i]] end

DEF.menu_key, DEF.notify, DEF.weapon, DEF.inv_sel = 1, true, 0, 24
DEF.acc_lang, DEF.acc_menu_scale, DEF.acc_esp_scale, DEF.acc_sync = 0, 0, 0, false
DEF.esp_box, DEF.esp_name, DEF.esp_hp, DEF.esp_weapon, DEF.esp_dist = true, true, true, true, true

local function slug(s) return (s:lower():gsub('[^%w]+', '_')) end
local function T_(l, d, key) return { l = l, kind = 'toggle', def = d or false, key = key } end
local function DIS(l) return { l = l, kind = 'disabled' } end
local function SEL(l, items, d, key) return { l = l, kind = 'select', items = items, def = d or 0, key = key } end
local function MUL(l, items, mask, key) return { l = l, kind = 'multi', items = items, def = mask or 0, key = key } end
local function SL(l, mn, mx, d, fmt, float, key) return { l = l, kind = 'slider', min = mn, max = mx, def = d, fmt = fmt, float = float, key = key } end
local function COL(l, d, rgb, key) return { l = l, kind = 'color', def = d or false, rgb = rgb or { 102, 124, 246 }, key = key } end
local function CH(l, sub) return { l = l, kind = 'chevron', sub = sub } end
local function WPN(l) return { l = l, kind = 'weapon' } end

local function CARD(id, rows)
    for _, r in ipairs(rows) do
        if r.def ~= nil then
            r.key = r.key or (id .. '_' .. slug(r.l))
            if DEF[r.key] == nil then DEF[r.key] = r.def end
            if r.kind == 'color' and DEF[r.key .. '_rgb'] == nil then
                DEF[r.key .. '_rgb'] = ((r.rgb[1] * 256 + r.rgb[2]) * 256 + r.rgb[3]) * 256 + (r.rgb[4] or 255)
            end
        end
    end
    return rows
end

local function fmtMinDmg(v)
    v = math.floor(v + 0.5)
    if v == 0 then return 'Auto' elseif v > 100 then return 'HP+' .. (v - 100) end
    return tostring(v)
end

local HB    = { 'Head', 'Chest', 'Stomach', 'Arms', 'Legs', 'Feet' }
local COND  = { 'Through Walls', 'Through Smoke', 'In Air', 'Flashed' }
local CHAMS = { 'Off', 'Solid', 'Flat', 'Water Flow', 'Glass', 'Glow Outline' }

local SUB_YAW = { title = 'YAW', rows = CARD('aa', {
    SEL('Mode', aaModeItems, 0, 'aa_mode'),
    SL('Spin Speed', 1, 60, 25, '%d', false, 'aa_speed'),
    SL('Jitter Range', 0, 180, 90, '%d°', false, 'aa_jitter'),
    SL('Flick Time', 50, 500, 200, '%d ms', false, 'aa_flick_ms'),
    T_('Show Locally', true, 'aa_local'),
    T_('Force Sync', false, 'aa_force'),
    T_('Disable While Aiming', true, 'aa_noaim'),
    SEL('Toggle Key', keyNames, 0, 'aa_key'),
}) }

-- Pitch: наклон головы, который видят другие (подмена направления камеры в AimSync)
local SUB_PITCH = { title = 'PITCH', rows = CARD('aap', {
    SEL('Pitch', { 'Off', 'Down', 'Up' }, 1, 'aa_pitch'),
}) }

-- Bunny Hop: Direction = Velocity — прыжки по инерции (куда летел), Mouse — туда, куда смотрит камера/мышка
local SUB_BHOP = { title = 'BUNNY HOP', rows = CARD('bhop', {
    T_('Enabled', false, 'm_move_bunny_hop'),
    SEL('Direction', { 'Velocity', 'Mouse' }, 1, 'bhop_dir'),
    SL('Hop Speed', 4, 20, 9, '%d', false, 'bhop_speed'),
    T_('Steer In Air', true, 'bhop_steer'),
}) }

-- визуалы (ESP / чамсы / трассеры / мир) — всё в одной таблице, чтобы не упереться в лимит локалов
local VIS = {}
VIS.cp = { open = false, key = nil, x = 0, y = 0, frame = 0, rx = 0, ry = 0, rw = 0, rh = 0 }
-- цвет-ряд без переключателя (только квадратик цвета)
function VIS.CLR(l, rgb, key) return { l = l, kind = 'color', def = true, rgb = rgb, key = key, only = true } end
VIS.HEAD = { 'Off', 'Circle', 'Filled' }
VIS.SUB_BOX = { title = 'BOX', rows = CARD('esp_box', {
    T_('Enabled', true, 'esp_box'),
    SEL('Color Mode', { 'Visibility', 'By Health', 'Team Color' }, 0, 'esp_box_cm'),
    SEL('Style', { 'Corners', 'Full', 'Rounded', '3D' }, 0, 'esp_box_style'),
    VIS.CLR('Visible Color', { 102, 124, 246 }, 'esp_box_vis'),
    VIS.CLR('Hidden Color', { 255, 90, 120 }, 'esp_box_hid'),
    SEL('Fill', { 'Off', 'Solid', 'Gradient' }, 2, 'esp_box_fill'),
    SL('Fill Alpha', 0, 160, 50, '%d', false, 'esp_box_fill_a'),
    T_('Outline', true, 'esp_box_outline'),
    T_('Glow', true, 'esp_box_glow'),
    SL('Thickness', 1, 4, 1.5, '%.1f', true, 'esp_box_th'),
}) }
VIS.SUB_NAME = { title = 'NAME & FLAGS', rows = CARD('esp_name', {
    T_('Enabled', true, 'esp_name'),
    T_('Background', true, 'esp_name_bg'),
    SEL('Color Mode', { 'Player Color', 'Custom', 'White' }, 0, 'esp_name_cm'),
    VIS.CLR('Custom Color', { 255, 255, 255 }, 'esp_name_c'),
    T_('Show ID', true, 'esp_name_id'),
    T_('Distance', true, 'esp_dist'),
    MUL('Flags', { 'AFK', 'Ping', 'Skin', 'Wall', 'Speed' }, 0x09, 'esp_flags'),
}) }
VIS.SUB_HP = { title = 'HEALTH', rows = CARD('esp_hp', {
    T_('Enabled', true, 'esp_hp'),
    SEL('Position', { 'Left', 'Right', 'Top', 'Bottom' }, 0, 'esp_hp_pos'),
    SEL('Color Mode', { 'Gradient', 'By Health', 'Custom' }, 1, 'esp_hp_style'),
    VIS.CLR('Custom Color', { 120, 255, 150 }, 'esp_hp_c'),
    T_('Show Number', true, 'esp_hp_num'),
    T_('Armor Bar', true, 'esp_ar'),
    VIS.CLR('Armor Color', { 110, 170, 255 }, 'esp_ar_c'),
    SL('Bar Width', 2, 6, 3, '%d', false, 'esp_hp_w'),
}) }
VIS.SUB_WPN = { title = 'WEAPON', rows = CARD('esp_wpn', {
    T_('Enabled', true, 'esp_weapon'),
    SEL('Mode', { 'Icon + Text', 'Icon', 'Text' }, 0, 'esp_wpn_mode'),
    VIS.CLR('Text Color', { 196, 202, 222 }, 'esp_wpn_c'),
    SL('Icon Size', 14, 40, 22, '%d', false, 'esp_wpn_size'),
}) }
VIS.SUB_SKEL = { title = 'SKELETON', rows = CARD('esp_skel', {
    COL('Enabled', false, { 255, 255, 255 }, 'esp_skel'),
    VIS.CLR('Hidden Color', { 255, 90, 120 }, 'esp_skel_hid'),
    SL('Thickness', 1, 4, 1.5, '%.1f', true, 'esp_skel_th'),
    SEL('Head', VIS.HEAD, 1, 'esp_skel_head'),
    T_('Outline', true, 'esp_skel_ol'),
    T_('Glow', false, 'esp_skel_glow'),
}) }
VIS.SUB_EXTRA = { title = 'EXTRA', rows = CARD('esp_x', {
    SEL('Snaplines', { 'Off', 'Top', 'Center', 'Bottom' }, 0, 'esp_snap'),
    VIS.CLR('Snapline Color', { 102, 124, 246 }, 'esp_snap_c'),
    COL('Head Dot', false, { 255, 220, 90 }, 'esp_headdot'),
    COL('Look Direction', false, { 255, 255, 255 }, 'esp_look'),
    COL('Offscreen Arrow', true, { 102, 124, 246 }, 'pl_enemy_offscreen_arrow'),
    SL('Arrow Size', 8, 30, 14, '%d', false, 'esp_arrow_size'),
    SL('Arrow Radius', 100, 600, 300, '%d', false, 'esp_arrow_rad'),
    COL('Sounds', false, { 102, 124, 246 }, 'pl_enemy_sounds'),
    SL('Max Distance', 25, 1000, 300, '%d m', false, 'esp_maxdist'),
    T_('Only Visible', false, 'esp_vis_only'),
    T_('Show Teammates', true, 'esp_team'),
}) }
VIS.CHAMS_T = { 'Off', 'Solid', 'Flat', 'Water Flow', 'Glass', 'Glow Outline', 'Pulse', 'Rainbow', 'Gradient', 'Strobe',
    'Metallic', 'Ghost', 'Heat', 'Health', 'Two-Tone', 'Wave', 'Fire', 'Ice', 'Galaxy', 'Toxic' }
VIS.CH_LIGHT = { 'Normal', 'Bright', 'Flat (no light)', 'Dark', 'Neon' }
-- набор настроек чамсов для одного состояния (видим / за стеной / выстрел / союзники / свой)
function VIS.chSet(id, title, modeKey, defMode, colKey, c1, c2)
    return { title = title, id = id, mk = modeKey, ck = colKey, rows = CARD(id, {
        SEL('Type', VIS.CHAMS_T, defMode, modeKey),
        VIS.CLR('Color', c1, colKey),
        VIS.CLR('Second Color', c2, id .. '_c2'),
        SEL('Texture', { 'Keep', 'Remove' }, 1, id .. '_tex'),
        SEL('Lighting', VIS.CH_LIGHT, 1, id .. '_light'),
        SL('Brightness', 20, 300, 100, '%d%%', false, id .. '_br'),
        SL('Opacity', 10, 255, 255, '%d', false, id .. '_alpha'),
        SL('Animation Speed', 1, 20, 6, '%d', false, id .. '_spd'),
    }) }
end
VIS.SUB_CH_VIS  = VIS.chSet('chv', 'VISIBLE CHAMS', 'pl_model_player', 1, 'chm_vis', { 102, 124, 246 }, { 255, 255, 255 })
VIS.SUB_CH_HID  = VIS.chSet('chh', 'HIDDEN CHAMS', 'pl_model_behind_walls', 5, 'chm_hid', { 255, 90, 120 }, { 255, 200, 80 })
VIS.SUB_CH_SHOT = VIS.chSet('chs', 'ON SHOT CHAMS', 'pl_model_on_shot', 1, 'chm_shot', { 255, 255, 255 }, { 255, 80, 80 })
VIS.SUB_CH_TEAM = VIS.chSet('cht', 'TEAMMATE CHAMS', 'chm_team_mode', 0, 'chm_team_c', { 90, 255, 150 }, { 255, 255, 255 })
VIS.SUB_CH_LOC  = VIS.chSet('chl', 'LOCAL CHAMS', 'chm_local', 0, 'chm_local_c', { 255, 200, 80 }, { 255, 90, 200 })
table.insert(VIS.SUB_CH_LOC.rows, T_('Paint Same Skin', false, 'chm_same'))
VIS.SUB_CH_OV = { title = 'OVERLAY (THROUGH WALLS)', rows = CARD('chm_ov', {
    COL('Enabled', true, { 255, 70, 110, 150 }, 'chm_sil'),
    SEL('Style', { 'Filled', 'Glow Aura', 'Neon Outline', 'Hologram', 'Pulse', 'Gradient', 'Dots', 'Tube Skeleton', 'Flame' }, 0, 'chm_sil_style'),
    VIS.CLR('Second Color', { 120, 160, 255, 200 }, 'chm_sil_c2'),
    SEL('When', { 'Behind Walls', 'Always', 'Visible Only' }, 0, 'chm_sil_when'),
    SEL('Color Mode', { 'Custom', 'By Health', 'Team Color' }, 0, 'chm_sil_cm'),
    SL('Width', 50, 250, 100, '%d%%', false, 'chm_sil_w'),
    T_('Glow', true, 'chm_sil_glow'),
    SL('Animation Speed', 1, 20, 6, '%d', false, 'chm_sil_spd'),
    SL('Max Distance', 20, 1000, 300, '%d m', false, 'chm_sil_max'),
}) }
VIS.SUB_TR = { title = 'BULLET TRACERS', rows = CARD('trc', {
    T_('Enabled', true, 'trc_on'),
    COL('Local', true, { 102, 124, 246 }, 'trc_local'),
    COL('Enemies', true, { 255, 92, 92 }, 'trc_enemies'),
    SEL('Style', { 'Line', 'Beam', 'Laser' }, 1, 'trc_style'),
    SL('Width', 1, 4, 1.6, '%.1f', true, 'trc_w'),
    SL('Duration', 1, 10, 3, '%d s', false, 'trc_time'),
}) }
VIS.SUB_HM = { title = 'HIT MARKER', rows = CARD('hm', {
    T_('Enabled', true, 'w_misc_hit_marker'),
    SEL('Style', { 'World', 'Crosshair', 'Both' }, 0, 'hm_style'),
    VIS.CLR('Color', { 255, 255, 255 }, 'hm_c'),
    T_('Damage Numbers', true, 'hm_dmg'),
    VIS.CLR('Damage Color', { 255, 110, 110 }, 'hm_dmg_c'),
    SL('Duration', 0.3, 2, 0.9, '%.1f s', true, 'hm_time'),
}) }
VIS.SUB_VIEW = { title = 'VIEW OPTIONS', rows = CARD('v', {
    T_('Override FOV', false, 'v_fov_on'),
    T_('Night Vision', false, 'v_nv'),
    T_('Thermal Vision', false, 'v_ir'),
    SL('Field of View', 50, 120, 85, '%d', false, 'v_fov'),
}) }
VIS.SUB_HAT = { title = 'CHINA HAT', rows = CARD('hat', {
    COL('Enabled', false, { 102, 124, 246 }, 'hat_on'),
    SL('Hat Size', 20, 80, 42, '%d cm', false, 'hat_size'),
    SL('Hat Height', 10, 60, 24, '%d cm', false, 'hat_height'),
    SL('Hat Alpha', 20, 255, 130, '%d', false, 'hat_alpha'),
    T_('Gradient', true, 'hat_grad'),
    T_('Outline', true, 'hat_ol'),
    T_('Hide In First Person', true, 'hat_fp'),
}) }
VIS.WEATHERS = { 'Sunny', 'Extra Sunny', 'Clear', 'Cloudy', 'Rainy', 'Foggy', 'Sandstorm', 'Purple', 'Green', 'Dark Red', 'Toxic', 'Underwater' }
VIS.WEATHER_ID = { 1, 0, 10, 4, 8, 9, 19, 2009, 2003, 1337, 150, 700 }
VIS.SUB_WT = { title = 'WEATHER & TIME', rows = CARD('wt', {
    T_('Override Time', false, 'wt_time_on'),
    SL('Hour', 0, 23, 12, '%02d', false, 'wt_hour'),
    SL('Minute', 0, 59, 0, '%02d', false, 'wt_min'),
    T_('Override Weather', false, 'wt_on'),
    SEL('Weather', VIS.WEATHERS, 0, 'wt_weather'),
}) }
VIS.SUB_SCR = { title = 'SCREEN EFFECTS', rows = CARD('sc', {
    COL('World Tint', false, { 60, 80, 200 }, 'sc_tint'),
    SL('Tint Strength', 5, 150, 40, '%d', false, 'sc_tint_a'),
    COL('Vignette', false, { 0, 0, 0 }, 'sc_vig'),
    SL('Vignette Strength', 20, 255, 160, '%d', false, 'sc_vig_a'),
    COL('Scanlines', false, { 0, 0, 0 }, 'sc_scan'),
    COL('Damage Flash', true, { 255, 40, 40 }, 'sc_hurt'),
}) }
VIS.SUB_XH = { title = 'CROSSHAIR', rows = CARD('xh', {
    SEL('Style', { 'Off', 'Cross', 'Dot', 'Circle', 'Cross + Dot', 'T-Shape' }, 0, 'xh_style'),
    VIS.CLR('Color', { 120, 255, 160 }, 'xh_c'),
    SL('Size', 2, 24, 7, '%d', false, 'xh_size'),
    SL('Gap', 0, 14, 3, '%d', false, 'xh_gap'),
    SL('Thickness', 1, 4, 2, '%.1f', true, 'xh_th'),
    T_('Outline', true, 'xh_ol'),
    T_('Dynamic', true, 'xh_dyn'),
    T_('Only When Aiming', false, 'xh_aim'),
}) }
VIS.SUB_WM = { title = 'WATERMARK', rows = CARD('wm', {
    T_('Enabled', true, 'wm_on'),
    SEL('Position', { 'Top Right', 'Top Left', 'Bottom Right', 'Bottom Left' }, 0, 'wm_pos'),
    MUL('Items', { 'Nick', 'FPS', 'Ping', 'Time', 'Speed' }, 0x0F, 'wm_items'),
    VIS.CLR('Accent', { 102, 124, 246 }, 'wm_c'),
}) }
VIS.SUB_VEH = { title = 'VEHICLES', rows = CARD('ve', {
    T_('Enabled', false, 've_on'),
    SEL('Box', { 'Off', 'Corners', 'Full', '3D' }, 3, 've_box'),
    VIS.CLR('Color', { 255, 190, 80 }, 've_c'),
    T_('Model Name', true, 've_name'),
    T_('Health', true, 've_hp'),
    T_('Driver', true, 've_driver'),
    T_('Distance', true, 've_dist'),
    T_('Only Empty', false, 've_empty'),
    SL('Max Distance', 25, 500, 150, '%d m', false, 've_max'),
}) }
VIS.SUB_PK = { title = 'PICKUPS', rows = CARD('pk', {
    COL('Enabled', false, { 120, 255, 200 }, 'pk_on'),
    T_('Model ID', true, 'pk_id'),
    T_('Distance', true, 'pk_dist'),
    SL('Max Distance', 10, 300, 100, '%d m', false, 'pk_max'),
}) }
VIS.SUB_OBJ = { title = 'OBJECTS', rows = CARD('ob', {
    COL('Enabled', false, { 200, 160, 255 }, 'ob_on'),
    T_('Model ID', true, 'ob_id'),
    T_('Distance', false, 'ob_dist'),
    SL('Max Distance', 5, 200, 40, '%d m', false, 'ob_max'),
    SL('Limit', 10, 200, 60, '%d', false, 'ob_lim'),
}) }

VIS.SUB_SKY = { title = 'SKY & FOG', rows = CARD('sky', {
    T_('Override Fog', false, 'fog_on'),
    SL('Fog Start', 0, 3000, 250, '%d m', false, 'fog_start'),
    SL('Draw Distance', 50, 3000, 900, '%d m', false, 'fog_far'),
    T_('Custom Sky', false, 'sky_on'),
    VIS.CLR('Sky Top', { 40, 60, 160 }, 'sky_top'),
    VIS.CLR('Sky Bottom / Fog', { 190, 110, 230 }, 'sky_bot'),
}) }
VIS.SUB_SUN = { title = 'SUN & CLOUDS', rows = CARD('sun', {
    T_('Custom Sun', false, 'sun_on'),
    VIS.CLR('Sun Core', { 255, 230, 160 }, 'sun_core'),
    VIS.CLR('Sun Halo', { 255, 120, 60 }, 'sun_halo'),
    SL('Sun Size', 0, 30, 6, '%.1f', true, 'sun_size'),
    T_('Custom Clouds', false, 'cl_on'),
    VIS.CLR('Low Clouds', { 200, 200, 255 }, 'cl_low'),
    VIS.CLR('Fluffy Clouds', { 255, 180, 230 }, 'cl_fluffy'),
    SL('Clouds Alpha', 0, 255, 200, '%d', false, 'cl_alpha'),
}) }
VIS.SUB_LIGHT = { title = 'LIGHTING', rows = CARD('lt', {
    T_('Custom Ambient', false, 'amb_on'),
    VIS.CLR('Ambient Color', { 120, 120, 140 }, 'amb_c'),
    SL('Ambient Power', 0, 300, 100, '%d%%', false, 'amb_pow'),
    T_('Color Filter', false, 'flt_on'),
    VIS.CLR('Filter Color', { 120, 80, 255, 90 }, 'flt_c'),
    T_('Custom Water', false, 'wat_on'),
    VIS.CLR('Water Color', { 40, 160, 255, 200 }, 'wat_c'),
    T_('Custom Shadows', false, 'shd_on'),
    SL('Shadow Strength', 0, 255, 160, '%d', false, 'shd_val'),
    SL('Light Shadows', 0, 255, 160, '%d', false, 'shd_light'),
    SL('Pole Shadows', 0, 255, 160, '%d', false, 'shd_pole'),
}) }
VIS.SUB_RB = { title = 'RAINBOW', rows = CARD('rb', {
    MUL('Rainbow', { 'Box', 'Skeleton', 'Chams', 'Tracers', 'Crosshair', 'Glow', 'Silhouette', 'Snaplines', 'Sky', 'China Hat' }, 0, 'rb_mask'),
    SL('Speed', 1, 20, 6, '%d', false, 'rb_speed'),
    SL('Saturation', 10, 100, 80, '%d%%', false, 'rb_sat'),
}) }
VIS.SUB_TXT = { title = 'ESP TEXT', rows = CARD('txt', {
    SL('Font Size', 9, 26, 13, '%d', false, 'esp_font'),
    SEL('Text Style', { 'Shadow', 'Outline', 'None' }, 0, 'esp_txt_ol'),
}) }

VIS.SUB_BT = { title = 'BACKTRACK', rows = CARD('bt', {
    T_('Enabled', false, 'bt_on'),
    SL('Backtrack Time', 50, 1000, 400, '%d ms', false, 'bt_time'),
    SL('Hit Radius', 0.2, 1.5, 0.55, '%.2f m', true, 'bt_radius'),
    SEL('Hit Mode', { 'Ghost Only', 'Whole Trail' }, 0, 'bt_mode'),
    T_('Send Damage', true, 'bt_damage'),
    SEL('Ghost Style', { 'Skeleton', 'Silhouette', 'Box', 'Hidden' }, 0, 'bt_style'),
    VIS.CLR('Ghost Color', { 160, 200, 255, 200 }, 'bt_ghost'),
    T_('Show Trail', true, 'bt_trail'),
}) }

local ROWS = {
    rage_main = CARD('rage_main', {
        T_('Enabled'), T_('Silent Aim', true), T_('Automatic Fire', true), T_('Aim Through Walls', true),
        SEL('Refine Shot', { 'Off', 'Latency', 'Performance' }, 1),
        SL('Field of View', 0, 180, 180, '%.1f°', true),
    }),
    rage_other = CARD('rage_other', {
        CH('Backtrack', VIS.SUB_BT),
        SEL('Delay Shot', { 'Off', 'Damage', 'Accuracy' }, 1),
        SEL('Remove Spread', { 'Off', 'Partial', 'Full' }, 2),
        DIS('Duck Peek Assist'), DIS('Quick Peek Assist'), T_('Double Tap'),
    }),
    rage_sel = CARD('rage_sel', {
        SEL('Prefer', { 'Damage', 'Accuracy', 'Head', 'Body' }, 0),
        MUL('Hitboxes', HB, 0x07),
        SL('Hit Chance', 0, 100, 0, '%d%%'),
        SL('Min Damage', 0, 130, 112, fmtMinDmg),
        T_('Quick Stop'), T_('Quick Scope'),
    }),
    rage_aa = CARD('rage_aa', {
        T_('Enabled', false, 'aa_enable'),
        T_('Suppress Breathing Animations', true),
        SEL('Leg Movement', { 'Default', 'Walking', 'Sliding' }, 1),
        CH('Pitch', SUB_PITCH), CH('Yaw', SUB_YAW), CH('Mouse Override'),
    }),
    legit_main = CARD('legit_main', { WPN('Weapon'), T_('Enabled') }),
    legit_aim = CARD('legit_aim', {
        T_('Enabled'), SEL('Activation', { 'Always', 'Assisted', 'On Key' }, 1),
        MUL('Conditions', COND, 0x03), MUL('Hitboxes', HB, 0x01),
        SL('Field of View', 0, 150, 20, '%du'), SL('Smoothing', 0, 100, 50, '%d%%'),
        SL('Reaction Time', 0, 500, 0, '%dms'), SL('Min Damage', 0, 130, 101, fmtMinDmg),
        T_('Recoil Control'), T_('Quick Scope'), T_('Quick Stop'),
    }),
    legit_trig = CARD('legit_trig', {
        T_('Enabled'), MUL('Conditions', COND, 0x03), MUL('Hitboxes', HB, 0x07),
        SL('Hit Chance', 0, 100, 92, '%d%%'), SL('Min Damage', 0, 130, 101, fmtMinDmg),
        SL('Reaction Time', 0, 500, 0, '%dms'), SL('Burst Time', 0, 500, 50, '%dms'),
        T_('Quick Scope'),
    }),
    legit_other = CARD('legit_other', {
        T_('Visualize'), T_('Automatic Weapons'), T_('Standalone Recoil Control'),
        SEL('Randomize', { 'None', 'Low', 'Medium', 'High' }, 0),
    }),
    pl_enemy = CARD('pl_enemy', {
        T_('Enabled', true), CH('Box', VIS.SUB_BOX), CH('Name & Flags', VIS.SUB_NAME), CH('Health', VIS.SUB_HP),
        CH('Weapon', VIS.SUB_WPN), CH('Skeleton', VIS.SUB_SKEL), CH('Extra', VIS.SUB_EXTRA),
    }),
    pl_model = CARD('pl_model', {
        CH('Visible', VIS.SUB_CH_VIS), CH('Behind Walls', VIS.SUB_CH_HID), CH('On Shot', VIS.SUB_CH_SHOT),
        CH('Teammates', VIS.SUB_CH_TEAM), CH('Local Player', VIS.SUB_CH_LOC), CH('Overlay (walls)', VIS.SUB_CH_OV),
        COL('Soul Particles', false, { 150, 170, 255 }), COL('Glow', true, { 102, 124, 246 }),
    }),
    w_view = CARD('w_view', {
        CH('View Options', VIS.SUB_VIEW), CH('Lighting', VIS.SUB_LIGHT), CH('Sun & Clouds', VIS.SUB_SUN),
        CH('Weather & Time', VIS.SUB_WT), CH('Screen Effects', VIS.SUB_SCR), CH('Crosshair', VIS.SUB_XH),
        CH('China Hat', VIS.SUB_HAT),
    }),
    w_hud = CARD('w_hud', {
        CH('Watermark', VIS.SUB_WM), T_('Keybinds List', true, 'hud_keys'), T_('Hide HUD', false, 'hud_hide'),
        T_('Hide Radar', false, 'hud_radar'), COL('Aimbot FOV', false, { 255, 255, 255 }, 'hud_fov'), T_('Speed Indicator', false, 'hud_speed'),
    }),
    w_esp = CARD('w_esp', {
        CH('Vehicles', VIS.SUB_VEH), CH('Pickups', VIS.SUB_PK), CH('Objects', VIS.SUB_OBJ),
        COL('Actors (NPC)', false, { 255, 150, 220 }, 'es_actors'), CH('Sky & Fog', VIS.SUB_SKY), CH('ESP Text', VIS.SUB_TXT),
    }),
    w_misc = CARD('w_misc', {
        CH('Hit Marker', VIS.SUB_HM), CH('Bullet Tracers', VIS.SUB_TR), COL('Bullet Impacts', true, { 102, 124, 246 }),
        T_('Kill Effect', true, 'sc_kill'), CH('Rainbow', VIS.SUB_RB),
    }),
    m_move = CARD('m_move', {
        CH('Bunny Hop', SUB_BHOP), T_('Air Strafe'), T_('Jump Bug'), T_('Standalone Quick Stop'),
        T_('Strafe Assist'), T_('Edge Jump'), T_('Slow Walk'), T_('Fast Ladder'),
    }),
    m_feat = CARD('m_feat', {
        T_('Quick Switch'), DIS('Super Toss'), DIS('Knife Bot'), T_('Prevent AFK Kick'), T_('Hit Sound'),
        DIS('Automatic Purchase'), DIS('Automatic Grenade Release'), DIS('Auto-Accept Matchmaking'),
        MUL('Log Events', { 'Damage Dealt', 'Damage Taken', 'Purchases', 'Deaths' }, 0x00),
    }),
}

local INV_COLS = { { 22, 23, 24, 28, 32 }, { 25, 26, 27, 29, 33 }, { 30, 31, 34, 35, 38 } }
local INV_SMALL = { 4, 8, 5, 16, 18, 9 }

local function resetOptions() for k, v in pairs(DEF) do O[k] = v end end
resetOptions()

local function saveConfig()
    local t = { options = {} }
    for k in pairs(DEF) do t.options[k] = O[k] end
    inicfg.save(t, CFG_FILE)
end
DEF.cfg_rev = 3
O.cfg_rev = 3
local function loadConfig()
    local t = inicfg.load(nil, CFG_FILE)
    if not t or not t.options then return false end
    for k, v in pairs(t.options) do
        if DEF[k] ~= nil and type(v) == type(DEF[k]) then O[k] = v end
    end
    -- v3.7: после бана на сервере — один раз выключаем всё, что меняет движение/память/синк
    if (tonumber(t.options.cfg_rev) or 0) < 2 then
        for k in pairs(DEF) do
            if k:find('^m_move_') or k:find('^m_feat_') or k == 'aa_enable' or k == 'aa_force' then O[k] = DEF[k] end
        end
        O.aa_force = false
        O.cfg_rev = 2
        saveConfig()
    end
    -- v4.5.1: чамсы на одинаковом скине красили и своего персонажа — выключаем один раз
    if (tonumber(t.options.cfg_rev) or 0) < 3 then
        O.chm_same = false
        O.cfg_rev = 3
        saveConfig()
    end
    return true
end
local function actSave()  saveConfig(); chat('конфиг сохранён') end
local function actLoad()  if loadConfig() then chat('конфиг загружен') else chat('конфиг не найден') end end
local function actReset() resetOptions(); chat('настройки сброшены') end

-- ============================================================ ПОПАПЫ
local popup = { open = false, owner = nil, frame = 0, x = 0, y = 0, w = 134, ah = 23, rx = 0, ry = 0, rw = 0, rh = 0 }
local account = { open = false, frame = 0 }
local sub = { open = false, frame = 0, def = nil, ax = 0, ay = 0, aw = 0, ah = 0 }

local function OpenPopup(owner, items, get, set, x, y, w, ah, icons)
    local same = popup.open and popup.owner == owner
    popup.open, popup.owner = not same, owner
    popup.items, popup.get, popup.set, popup.icons = items, get, set, icons
    popup.x, popup.y, popup.w, popup.ah = x, y, w, ah or 23
    popup.frame = imgui.GetFrameCount()
end
local function hasBit(m, i) return bit.band(m, bit.lshift(1, i - 1)) ~= 0 end
local function OpenRowPopup(id, row, x, y, w)
    local key = row.key
    if row.kind == 'multi' then
        OpenPopup(id, row.items, function(i) return hasBit(O[key], i) end,
            function(i) O[key] = bit.bxor(O[key], bit.lshift(1, i - 1)); return false end, x, y, 134, 23)
    else
        OpenPopup(id, row.items, function(i) return O[key] == i - 1 end,
            function(i) O[key] = i - 1; return true end, x, y, w, 23)
    end
end
local function multiText(row)
    local t = {}
    for i, n in ipairs(row.items) do if hasBit(O[row.key], i) then t[#t + 1] = L(n) end end
    return #t > 0 and table.concat(t, ', ') or L('None')
end
local function OpenWeaponPopup(owner, x, y, ah)
    OpenPopup(owner, WEAPON_SLOT_NAMES, function(i) return O.weapon == i - 1 end,
        function(i) O.weapon = i - 1; if WEAPON_SLOTS[i] then O.inv_sel = WEAPON_SLOTS[i] end; return true end,
        x, y, 200, ah, WEAPON_SLOTS)
end

-- ============================================================ ВИДЖЕТЫ
local function Toggle(dl, id, x, y, key, enabled)
    if enabled == nil then enabled = true end
    local hov = false
    if enabled and key then
        if Hit(id, x - 5, y - 6, 39, 30) then O[key] = not O[key] end
        hov = imgui.IsItemHovered()
    end
    local on = Motion(id .. '#on', (key and O[key]) and 1 or 0, 19)
    local hv = Motion(id .. '#hv', hov and 1 or 0, 20)
    dl:AddRectFilled(V(x - 1 - hv, y - 1 - hv), V(x + 30 + hv, y + 19 + hv), C(75, 126, 255, 45 * hv), 10)
    dl:AddRectFilled(V(x, y), V(x + 29, y + 18), Mix({ 29, 33, 43 }, { 75, 126, 255 }, on), 9)
    dl:AddCircleFilled(V(x + 9 + 11 * on, y + 9), 7, Mix({ 133, 144, 156 }, { 248, 249, 252 }, on), 24)
end

local function OpenSub(id, def, ax, ay, aw, ah)
    local same = sub.open and sub.owner == id
    sub.open, sub.owner, sub.def = not same, id, def
    sub.ax, sub.ay, sub.aw, sub.ah = ax, ay, aw, ah
    sub.frame = imgui.GetFrameCount()
    popup.open = false
end

-- кнопка выбора оружия с настоящей иконкой (тулбар и Legit)
local function WeaponPicker(dl, id, x, y, minW, h, maxW)
    local wid = WEAPON_SLOTS[O.weapon + 1]
    local label = L(WEAPON_SLOT_NAMES[O.weapon + 1] or 'Global')
    local iconWid = wid or heldWeapon()
    local hasIcon = iconWid and WICON[iconWid] ~= nil
    local tx = hasIcon and 40 or 13
    local w = math.max(minW, tx + TextSize(label, F.ctrl).x + 30)
    if maxW then w = math.min(w, maxW) end
    if Hit(id, x, y, w, h) then OpenWeaponPopup(id, x, y, h) end
    local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == id)) and 1 or 0)
    dl:AddRectFilled(V(x, y), V(x + w, y + h), Mix({ 17, 19, 27 }, { 22, 25, 35 }, r), 6)
    dl:AddRect(V(x, y), V(x + w, y + h), Mix({ 28, 31, 41 }, { 75, 126, 255 }, r * 0.7), 6)
    if hasIcon then WeaponIcon(dl, iconWid, x + 21, y + h * 0.5, h - 4, wid and 255 or 150) end
    dl:PushClipRect(V(x, y), V(x + w - 20, y + h), true)
    TextY(dl, x + tx, y, h, C(184, 187, 197), label, F.ctrl)
    dl:PopClipRect()
    Chevron(dl, x + w - 17, y + h * 0.5 - 4, C(130, 135, 146))
    return w
end

local function RowControl(dl, cx, y, w, row, id, rh)
    rh = rh or 37
    local kind = row.kind
    local disabled = kind == 'disabled'
    -- ширина под подпись (чтобы длинный русский текст не залезал на контрол)
    local lw = w - 60
    if kind == 'select' or kind == 'multi' then lw = w - math.min(134, w * 0.48) - 22
    elseif kind == 'weapon' then lw = w - math.min(160, w * 0.56) - 22
    elseif kind == 'slider' then lw = w - 160
    elseif kind == 'color' then lw = w - 75
    elseif kind == 'chevron' then lw = w - 35 end
    dl:PushClipRect(V(cx, y), V(cx + lw, y + rh), true)
    TextY(dl, cx + 13, y, rh, disabled and C(92, 96, 107) or C(207, 209, 218), L(row.l), F.body)
    dl:PopClipRect()

    if kind == 'toggle' then
        Toggle(dl, id, cx + w - 43, y + (rh - 19) * 0.5, row.key)
    elseif disabled then
        Toggle(dl, id, cx + w - 43, y + (rh - 19) * 0.5, nil, false)
    elseif kind == 'weapon' then
        local cw = math.min(160, w * 0.56)
        WeaponPicker(dl, id, cx + w - cw - 13, y + (rh - 25) * 0.5, cw, 25, cw)
    elseif kind == 'select' or kind == 'multi' then
        local cw = math.min(134, w * 0.48)
        local px, py = cx + w - cw - 13, y + (rh - 23) * 0.5
        local click = Hit(id, px, py, cw, 23)
        local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == id)) and 1 or 0)
        if click then OpenRowPopup(id, row, px, py, cw) end
        dl:AddRectFilled(V(px, py), V(px + cw, py + 23), Mix({ 25, 28, 38 }, { 31, 38, 54 }, r), 5)
        dl:AddRect(V(px, py), V(px + cw, py + 23), Mix({ 32, 35, 46 }, { 75, 126, 255 }, r), 5)
        local value = kind == 'multi' and multiText(row) or L(row.items[O[row.key] + 1]) or 'Select'
        dl:PushClipRect(V(px, py), V(px + cw - 17, py + 23), true)
        TextY(dl, px + 7, py, 23, C(170, 173, 184), value, F.ctrl)
        dl:PopClipRect()
        dl:AddLine(V(px + cw - 13, py + 9), V(px + cw - 9, py + 13), C(139, 143, 154), 1)
        dl:AddLine(V(px + cw - 9, py + 13), V(px + cw - 5, py + 9), C(139, 143, 154), 1)
    elseif kind == 'slider' then
        local key = row.key
        local txt = type(row.fmt) == 'function' and row.fmt(O[key]) or string.format(row.fmt, O[key])
        local pw = math.max(42, TextSize(txt, F.ctrl).x + 10)
        local tw = 80
        local plx = cx + w - 13 - pw
        local sx, sy = plx - 10 - tw, y + math.floor(rh * 0.5)
        Hit(id, sx - 5, sy - 8, tw + 10, 19)
        if imgui.IsItemActive() then
            local t = clamp((Mouse().x - sx) / tw, 0, 1)
            local nv = row.min + (row.max - row.min) * t
            if not row.float then nv = math.floor(nv + 0.5) end
            O[key] = nv
        end
        local shown = Motion(id .. '#v', clamp((O[key] - row.min) / (row.max - row.min), 0, 1), 14)
        dl:AddRectFilled(V(sx, sy), V(sx + tw, sy + 3), C(34, 38, 48), 2)
        dl:AddRectFilled(V(sx, sy), V(sx + tw * shown, sy + 3), C(75, 126, 255), 2)
        dl:AddCircleFilled(V(sx + tw * shown, sy + 1.5), 5.5, C(247, 248, 252), 24)
        local ply = y + (rh - 21) * 0.5
        dl:AddRectFilled(V(plx, ply), V(plx + pw, ply + 21), C(25, 28, 38), 5)
        local tsz = TextSize(txt, F.ctrl)
        TextY(dl, plx + (pw - tsz.x) * 0.5, ply, 21, C(166, 169, 179), txt, F.ctrl)
    elseif kind == 'color' then
        local c = VIS.rgb(row.key)
        local sx = row.only and (cx + w - 41) or (cx + w - 63)
        local sy = y + (rh - 15) * 0.5
        local click = Hit(id .. '#sw', sx - 3, sy - 3, (row.only and 31 or 18), 21)
        local hv = Motion(id .. '#swh', (imgui.IsItemHovered() or (VIS.cp.open and VIS.cp.key == row.key)) and 1 or 0, 20)
        dl:AddRectFilled(V(sx - 1 - hv, sy - 1 - hv), V(sx + (row.only and 26 or 16) + hv, sy + 16 + hv), C(255, 255, 255, 40 + 80 * hv), 6)
        dl:AddRectFilled(V(sx, sy), V(sx + (row.only and 25 or 15), sy + 15), C(c[1], c[2], c[3]), 5)
        if click then VIS.openColor(row.key, sx, sy) end
        if not row.only then Toggle(dl, id, cx + w - 43, y + (rh - 19) * 0.5, row.key) end
    elseif kind == 'chevron' then
        if row.sub then
            local click = Hit(id, cx + 4, y + 3, w - 8, rh - 6)
            local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (sub.open and sub.owner == id)) and 1 or 0, 20)
            if r > 0.001 then dl:AddRectFilled(V(cx + 4, y + 3), V(cx + w - 4, y + rh - 3), C(39, 43, 54, 150 * r), 8) end
            if click then OpenSub(id, row.sub, cx, y, w, rh) end
        end
        Chevron(dl, cx + w - 22, y + (rh - 6) * 0.5, C(187, 190, 199))
    end
end

local function Card(dl, key, x, y, w, h, title, rows, rh)
    rh = rh or 37
    Text(dl, x + 12, y - 18, C(89, 94, 106), L(title), F.cap)
    dl:AddRectFilled(V(x, y), V(x + w, y + h), C(17, 19, 27, 224), 14)
    dl:AddRect(V(x, y), V(x + w, y + h), C(31, 34, 44), 14)
    for i, row in ipairs(rows) do
        local ry = y + (i - 1) * rh
        if i > 1 then dl:AddLine(V(x + 12, ry), V(x + w - 12, ry), C(28, 31, 40)) end
        RowControl(dl, x, ry, w, row, '##' .. key .. i, rh)
    end
end

-- ============================================================ ФИГУРА ИГРОКА (превью)
-- части: {тип, ..., слой}. c = капсула (x1,y1,x2,y2,r), o = круг (x,y,r), q = четырёхугольник
local BODY = {
    { 'c', -34, -242, -44, -192, 8, 'back' }, { 'c', -44, -192, -41, -142, 7, 'back' }, { 'o', -41, -136, 7, 'back' },
    { 'c', -13, -150, -16, -78, 11, 'back' }, { 'c', -16, -78, -18, -12, 9, 'back' }, { 'c', -17, -5, -31, -3, 5, 'back' },
    { 'c', 13, -150, 16, -78, 11, 'mid' }, { 'c', 16, -78, 18, -12, 9, 'mid' }, { 'c', 17, -5, 31, -3, 5, 'mid' },
    { 'q', -34, -250, 34, -250, 23, -162, -23, -162, 'mid' },
    { 'c', -29, -245, 29, -245, 9, 'mid' }, { 'c', -22, -165, 22, -165, 10, 'mid' },
    { 'c', 0, -168, 0, -146, 22, 'mid' },
    { 'c', 34, -242, 45, -192, 8, 'front' }, { 'c', 45, -192, 42, -142, 7, 'front' }, { 'o', 42, -136, 7, 'front' },
    { 'c', 0, -265, 0, -250, 7, 'front' }, { 'o', 0, -283, 17, 'front' },
}
local GLOW_SHAPE = {
    { 'o', 0, -283, 17 }, { 'c', 0, -240, 0, -160, 30 }, { 'c', -40, -240, -42, -140, 8 }, { 'c', 40, -240, 43, -140, 8 },
    { 'c', -14, -150, -18, -8, 11 }, { 'c', 14, -150, 18, -8, 11 },
}

local function partDraw(dl, p, cx, fy, s, col, grow)
    grow = grow or 0
    if p[1] == 'c' then
        local x1, y1, x2, y2, r = cx + p[2] * s, fy + p[3] * s, cx + p[4] * s, fy + p[5] * s, (p[6] + grow) * s
        dl:AddLine(V(x1, y1), V(x2, y2), col, r * 2)
        dl:AddCircleFilled(V(x1, y1), r, col, 20); dl:AddCircleFilled(V(x2, y2), r, col, 20)
    elseif p[1] == 'o' then
        dl:AddCircleFilled(V(cx + p[2] * s, fy + p[3] * s), (p[4] + grow) * s, col, 28)
    elseif p[1] == 'q' and grow == 0 then
        dl:AddQuadFilled(V(cx + p[2] * s, fy + p[3] * s), V(cx + p[4] * s, fy + p[5] * s),
            V(cx + p[6] * s, fy + p[7] * s), V(cx + p[8] * s, fy + p[9] * s), col)
    end
end

-- look: индекс CHAMS (0 Off, 1 Solid, 2 Flat, 3 Water Flow, 4 Glass, 5 Glow Outline)
local function Figure(dl, cx, fy, s, look, glow)
    local t = os.clock()
    -- мягкое свечение
    if glow then
        for i = 4, 1, -1 do
            for _, p in ipairs(GLOW_SHAPE) do partDraw(dl, p, cx, fy, s, C(102, 124, 246, 16), i * 3) end
        end
    end
    if look == 5 then -- контур
        for _, p in ipairs(GLOW_SHAPE) do partDraw(dl, p, cx, fy, s, C(122, 150, 255, 235), 2.5) end
    end
    local function colFor(p)
        local layer = p[#p]
        local shade = layer == 'back' and 0.72 or (layer == 'front' and 1.08 or 1)
        local r, g, b
        if look == 0 then r, g, b = 70, 76, 94
        elseif look == 1 then r, g, b = 91, 133, 255
        elseif look == 2 then r, g, b = 110, 140, 255; shade = 1
        elseif look == 3 then
            local py = p[3] or 0
            local k = 0.5 + 0.5 * math.sin(t * 3 + py * 0.03)
            r, g, b = 60 + 40 * k, 120 + 90 * k, 255
        elseif look == 4 then r, g, b = 86, 112, 168
        else r, g, b = 26, 32, 52 end
        return C(math.min(255, r * shade), math.min(255, g * shade), math.min(255, b * shade), 250)
    end
    for _, layer in ipairs({ 'back', 'mid', 'front' }) do
        for _, p in ipairs(BODY) do
            if p[#p] == layer then partDraw(dl, p, cx, fy, s, colFor(p)) end
        end
    end
    if look == 4 then -- блики стекла
        dl:AddLine(V(cx - 22 * s, fy - 240 * s), V(cx - 14 * s, fy - 175 * s), C(255, 255, 255, 70), 2 * s)
        dl:AddCircle(V(cx, fy - 283 * s), 13 * s, C(255, 255, 255, 60), 24, 1.5 * s)
    end
end

-- ============================================================ СТРАНИЦЫ
local page, pageMix = 'rage', 1
local PAGES = {}

PAGES.rage = function(dl, b)
    Card(dl, 'r1', b.x + 167, b.y + 84, 281, 221, 'MAIN', ROWS.rage_main)
    Card(dl, 'r2', b.x + 458, b.y + 84, 277, 221, 'OTHER', ROWS.rage_other)
    Card(dl, 'r3', b.x + 167, b.y + 340, 281, 221, 'SELECTION', ROWS.rage_sel)
    Card(dl, 'r4', b.x + 458, b.y + 340, 277, 221, 'ANTI-AIM', ROWS.rage_aa)
end

PAGES.legit = function(dl, b)
    Card(dl, 'l1', b.x + 167, b.y + 84, 281, 74, 'MAIN', ROWS.legit_main)
    -- AIMBOT — 11 строк, компактная высота строки, чтобы влезть под MAIN
    Card(dl, 'l2', b.x + 167, b.y + 194, 281, 363, 'AIMBOT', ROWS.legit_aim, 33)
    Card(dl, 'l3', b.x + 458, b.y + 84, 277, 297, 'TRIGGERBOT', ROWS.legit_trig)
    Card(dl, 'l4', b.x + 458, b.y + 413, 277, 148, 'OTHER', ROWS.legit_other)
end

local function localIdentity()
    local name, id = 'Player', -1
    if isSampAvailable() then
        local ok, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then id = pid; name = sampGetPlayerNickname(pid) or name end
    end
    return name, id
end

local ESP_CHIPS = { { 'Box', 'esp_box' }, { 'Name', 'esp_name' }, { 'HP', 'esp_hp' }, { 'Weapon', 'esp_weapon' }, { 'Dist', 'esp_dist' } }

local function cornerBox(dl, x1, y1, x2, y2, col)
    local lw, lh = (x2 - x1) * 0.28, (y2 - y1) * 0.16
    local function seg(ax, ay, bx2, by2)
        dl:AddLine(V(ax, ay), V(bx2, by2), C(0, 0, 0, 170), 3)
        dl:AddLine(V(ax, ay), V(bx2, by2), col, 1.2)
    end
    seg(x1, y1, x1 + lw, y1); seg(x1, y1, x1, y1 + lh)
    seg(x2, y1, x2 - lw, y1); seg(x2, y1, x2, y1 + lh)
    seg(x1, y2, x1 + lw, y2); seg(x1, y2, x1, y2 - lh)
    seg(x2, y2, x2 - lw, y2); seg(x2, y2, x2, y2 - lh)
end

PAGES.players = function(dl, b)
    Card(dl, 'p1', b.x + 177, b.y + 86, 300, 210, 'ENEMY', ROWS.pl_enemy, 30)
    Card(dl, 'p2', b.x + 177, b.y + 322, 300, 240, 'ENEMY MODEL', ROWS.pl_model, 30)

    -- панель превью
    local x1, y1, x2, y2 = b.x + 490, b.y + 68, b.x + 736, b.y + 561
    dl:AddRectFilled(V(x1, y1), V(x2, y2), C(15, 18, 27, 235), 14)
    dl:AddRectFilledMultiColor(V(x1 + 1, y1 + 36), V(x2 - 1, y2 - 60),
        C(30, 42, 70, 60), C(30, 42, 70, 60), C(15, 18, 27, 0), C(15, 18, 27, 0))
    dl:AddRect(V(x1, y1), V(x2, y2), C(31, 34, 44), 14)
    Text(dl, x1 + 16, y1 + 10, C(111, 167, 255), L('Enemies'), F.ctrl)
    local ew = TextSize(L('Enemies'), F.ctrl).x
    dl:AddRectFilled(V(x1 + 16, y1 + 30), V(x1 + 16 + ew, y1 + 32), C(75, 126, 255), 1)
    Icon(dl, 'user', x2 - 52, y1 + 2, 32, C(180, 184, 194))
    Icon(dl, 'list', x2 - 26, y1 + 2, 32, C(180, 184, 194))
    dl:AddLine(V(x1 + 12, y1 + 36), V(x2 - 12, y1 + 36), C(28, 31, 40))

    local espS = ESP_SCALES[(O.acc_esp_scale or 0) + 1] or 1
    local cx, fy, s = (x1 + x2) * 0.5, b.y + 452, 0.9 * espS
    local enabled = O.pl_enemy_enabled

    -- пол и подсветка под ногами
    for i = 1, 5 do
        dl:AddRectFilled(V(cx - (70 - i * 9) * s, fy - 2 - i * 0.6), V(cx + (70 - i * 9) * s, fy + 4 + i * 0.6), C(75, 126, 255, 10), 6)
    end
    if O.pl_enemy_sounds and enabled then
        local k = (os.clock() * 0.8) % 1
        dl:AddCircle(V(cx, fy), 20 + 50 * k, C(102, 124, 246, 140 * (1 - k)), 40, 1.5)
    end

    Figure(dl, cx, fy, s, math.min(5, O.pl_model_player or 3), O.pl_model_glow)

    if enabled then
        local bx1, by1, bx2, by2 = cx - 62 * s, fy - 306 * s, cx + 62 * s, fy + 8 * s
        if O.esp_box then cornerBox(dl, bx1, by1, bx2, by2, C(235, 238, 255)) end
        if O.esp_hp then
            local hp = 0.5 + 0.35 * (0.5 + 0.5 * math.sin(os.clock() * 0.9))
            local hx = bx1 - 7
            dl:AddRectFilled(V(hx - 1, by1 - 1), V(hx + 4, by2 + 1), C(0, 0, 0, 180), 2)
            local top = by2 - (by2 - by1) * hp
            dl:AddRectFilledMultiColor(V(hx, top), V(hx + 3, by2),
                C(120, 255, 140), C(120, 255, 140), C(255, 200, 70), C(255, 200, 70))
            Text(dl, hx - 22, top - 6, C(200, 255, 210), tostring(math.floor(hp * 100)), F.t9)
        end
        if O.esp_name then
            local name = localIdentity()
            local nw = TextSize(name, F.small).x
            Text(dl, cx - nw * 0.5 + 1, by1 - 18 + 1, C(0, 0, 0, 200), name, F.small)
            Text(dl, cx - nw * 0.5, by1 - 18, C(240, 242, 250), name, F.small)
        end
        local wy = by2 + 6
        if O.esp_weapon then
            local wid = WEAPON_SLOTS[O.weapon + 1] or 24
            local wn = WEAPON_NAME[wid] or ''
            if WeaponIcon(dl, wid, cx, wy + 12, 26) then wy = wy + 24 end
            local ww = TextSize(wn, F.t9).x
            Text(dl, cx - ww * 0.5, wy, C(190, 196, 214), wn, F.t9)
        end
        if O.esp_dist then
            Text(dl, bx2 + 6, by2 - 12, C(160, 166, 184), '24m', F.t9)
        end
        if O.pl_enemy_offscreen_arrow then
            local ay = (y1 + y2) * 0.5 - 40
            local pulse = 0.6 + 0.4 * math.sin(os.clock() * 4)
            dl:AddTriangleFilled(V(x1 + 14, ay), V(x1 + 28, ay - 9), V(x1 + 28, ay + 9), C(102, 124, 246, 230 * pulse))
        end
        if O.pl_model_soul_particles then
            for i = 1, 6 do
                local k = (os.clock() * 0.35 + i / 6) % 1
                local px = cx + math.sin(i * 1.7 + os.clock()) * 30 * s
                dl:AddCircleFilled(V(px, fy - k * 300 * s), 2, C(150, 170, 255, 200 * (1 - k)), 10)
            end
        end
    end

    -- чипы элементов ESP (кликабельные)
    local cxp, cyp = x1 + 12, y2 - 40
    for i, ch in ipairs(ESP_CHIPS) do
        local label = L(ch[1])
        local cw = TextSize(label, F.small).x + 14
        local click = Hit('##chip' .. i, cxp, cyp, cw, 24)
        local hv = Motion('chip#hv' .. i, imgui.IsItemHovered() and 1 or 0, 20)
        local on = Motion('chip#on' .. i, O[ch[2]] and 1 or 0, 18)
        if click then O[ch[2]] = not O[ch[2]] end
        dl:AddRectFilled(V(cxp, cyp), V(cxp + cw, cyp + 24), Mix({ 25, 28, 38 }, { 34, 52, 96 }, on), 8)
        dl:AddRect(V(cxp, cyp), V(cxp + cw, cyp + 24), Mix({ 32, 35, 46 }, { 75, 126, 255 }, math.max(on, hv * 0.6)), 8)
        TextY(dl, cxp + 7, cyp, 24, Mix({ 140, 145, 158 }, { 226, 232, 255 }, on), label, F.small)
        cxp = cxp + cw + 5
    end
end

PAGES.world = function(dl, b)
    Card(dl, 'w1', b.x + 177, b.y + 84, 291, 221, 'VIEW', ROWS.w_view)
    Card(dl, 'w2', b.x + 478, b.y + 84, 257, 221, 'HUD', ROWS.w_hud)
    Card(dl, 'w3', b.x + 177, b.y + 350, 291, 221, 'WORLD ESP', ROWS.w_esp)
    Card(dl, 'w4', b.x + 478, b.y + 350, 257, 221, 'MISCELLANEOUS', ROWS.w_misc)
end

local ACCENTS = { { 235, 237, 239 }, { 171, 70, 255 }, { 75, 116, 255 }, { 226, 43, 192 }, { 251, 65, 83 }, { 134, 72, 255 } }

local function WeaponCell(dl, id, x, y, w, h, wid, accent)
    local click = Hit(id, x, y, w, h)
    local hov = Motion(id .. '#hv', imgui.IsItemHovered() and 1 or 0, 18)
    local sel = Motion(id .. '#sel', O.inv_sel == wid and 1 or 0, 18)
    if click then
        O.inv_sel = wid
        for i = 2, #WEAPON_SLOTS do if WEAPON_SLOTS[i] == wid then O.weapon = i - 1 end end
    end
    dl:AddRectFilled(V(x, y), V(x + w, y + h), Mix({ 24, 31, 45, 235 }, { 30, 39, 57, 245 }, hov), 9)
    dl:AddRect(V(x, y), V(x + w, y + h), Mix({ 35, 45, 62 }, { 75, 126, 255 }, math.max(sel, hov * 0.5)), 9)
    dl:AddRectFilled(V(x, y + h - 3), V(x + w, y + h), C(accent[1], accent[2], accent[3]), 0)
    local s = math.min(w - 12, h - 10)
    if not WeaponIcon(dl, wid, x + w * 0.5, y + (h - 3) * 0.5, s) then
        local gun, shade = C(218, 220, 218), C(104, 111, 118)
        local k = math.min(w / 121, h / 91)
        local function q(a, b2) return V(x + a * k, y + b2 * k) end
        local kind = wid % 3
        if kind == 0 then
            dl:AddRectFilled(q(25, 28), q(86, 36), gun, 2 * k); dl:AddRectFilled(q(67, 35), q(77, 60), shade, 2 * k)
            dl:AddRectFilled(q(32, 35), q(41, 55), gun, 2 * k)
        elseif kind == 1 then
            dl:AddLine(q(18, 55), q(94, 27), gun, 7 * k); dl:AddRectFilled(q(70, 27), q(90, 35), shade, 2 * k)
        else
            dl:AddRectFilled(q(16, 32), q(96, 39), gun, 2 * k); dl:AddRectFilled(q(30, 39), q(42, 61), shade, 2 * k)
            dl:AddRectFilled(q(67, 39), q(77, 57), gun, 2 * k)
        end
    end
    if hov > 0.01 and w > 80 then
        Text(dl, x + 8, y + 5, C(205, 209, 219, 255 * hov), WEAPON_NAME[wid] or ('#' .. wid), F.small)
    end
end

PAGES.inventory = function(dl, b)
    dl:AddRectFilled(V(b.x + 159, b.y + 57), V(b.x + 747, b.y + 575), C(17, 27, 42, 155), 0)
    dl:AddRectFilled(V(b.x + 185, b.y + 66), V(b.x + 286, b.y + 91), C(20, 34, 50), 8)
    TextY(dl, b.x + 199, b.y + 66, 25, C(138, 192, 255), L('Loadout'), F.ctrl)
    Figure(dl, b.x + 264, b.y + 452, 0.6, 1, true)
    for r = 0, 4 do
        for c = 0, 2 do
            WeaponCell(dl, '##inv' .. r .. c, b.x + 390 + c * 116, b.y + 88 + r * 96, 108, 91,
                INV_COLS[c + 1][r + 1], ACCENTS[(r + c) % 6 + 1])
        end
    end
    Text(dl, b.x + 424, b.y + 67, C(205, 209, 219), L('Pistols'), F.ctrl)
    Text(dl, b.x + 536, b.y + 67, C(205, 209, 219), L('Mid-Tier'), F.ctrl)
    Text(dl, b.x + 655, b.y + 67, C(205, 209, 219), L('Rifles'), F.ctrl)
    for r = 0, 1 do
        for c = 0, 2 do
            WeaponCell(dl, '##invs' .. r .. c, b.x + 171 + c * 65, b.y + 470 + r * 51, 55, 47,
                INV_SMALL[r * 3 + c + 1], ACCENTS[(r + c + 2) % 6 + 1])
        end
    end
end

PAGES.misc = function(dl, b)
    Card(dl, 'm1', b.x + 171, b.y + 80, 300, 312, 'MOVEMENT', ROWS.m_move)
    Card(dl, 'm2', b.x + 481, b.y + 80, 254, 349, 'FEATURES', ROWS.m_feat)
end

local function ChangePage(p)
    if page == p then return end
    page, pageMix = p, 0
    popup.open, sub.open = false, false
end

-- ============================================================ САЙДБАР / ТУЛБАР
local function Avatar(dl, x, y, r, name)
    dl:AddCircleFilled(V(x, y), r, C(39, 60, 110), 32)
    dl:AddCircle(V(x, y), r, C(75, 126, 255), 32, 1.2)
    local ch = (name or '?'):sub(1, 1):upper()
    local ts = TextSize(ch, F.title)
    Text(dl, x - ts.x * 0.5, y - ts.y * 0.5, C(226, 232, 255), ch, F.title)
end

local function Sidebar(dl, bx, by)
    FillLeftRounded(dl, bx, by, bx + 158, by + 576, 14, C(18, 21, 30, 231))
    dl:AddLine(V(bx + 158, by), V(bx + 158, by + 576), C(30, 33, 43))
    dl:AddRectFilled(V(bx + 15, by + 11), V(bx + 45, by + 43), C(8, 27, 48), 7)
    local lg = TextSize('RM', F.title)
    Text(dl, bx + 30 - lg.x * 0.5, by + 27 - lg.y * 0.5, C(94, 185, 255), 'RM', F.title)
    Text(dl, bx + 53, by + 14, C(228, 230, 236), 'rage-mod', F.title)
    Text(dl, bx + 53, by + 33, C(91, 96, 108), 'San Andreas Multiplayer', F.t8)
    dl:AddLine(V(bx + 10, by + 56), V(bx + 147, by + 56), C(28, 31, 41))
    Text(dl, bx + 16, by + 67, C(91, 96, 108), L('AIMBOT'), F.cap)
    Text(dl, bx + 16, by + 169, C(91, 96, 108), L('COMMON'), F.cap)

    local function nav(key, icon, label, y, target, selected, indent)
        indent = indent or 0
        local px, py = bx + 7 + indent, by + y
        local clicked = Hit('##nav_' .. key, px, py, 140 - indent, 30)
        local r = Motion('nav#' .. key, selected and 1 or (imgui.IsItemHovered() and 0.48 or 0))
        if clicked then ChangePage(target) end
        if r > 0.001 then dl:AddRectFilled(V(px, py), V(px + 140 - indent, py + 30), Mix({ 18, 21, 30, 0 }, { 39, 43, 54 }, r), 6) end
        Icon(dl, icon, px + 10, py, 30, Mix({ 137, 142, 153 }, { 82, 141, 255 }, r))
        dl:PushClipRect(V(px, py), V(px + 140 - indent - 4, py + 30), true)
        TextY(dl, px + 31, py, 30, Mix({ 145, 149, 159 }, { 226, 228, 235 }, r), L(label), F.body)
        dl:PopClipRect()
    end

    local visuals = page == 'players' or page == 'world'
    nav('rage', 'rage', 'Rage', 84, 'rage', page == 'rage')
    nav('legit', 'legit', 'Legit', 120, 'legit', page == 'legit')
    nav('vis', 'visuals', 'Visuals', 190, 'players', visuals)
    local expand = Motion('visual_expand', visuals and 1 or 0, 18)
    if expand > 0.02 then
        local saved = gA
        gA = gA * expand
        nav('players', 'players', 'Players', 226, 'players', page == 'players', 14)
        nav('world', 'world', 'World', 262, 'world', page == 'world', 14)
        gA = saved
    end
    local shift = 72 * expand
    nav('inv', 'inventory', 'Inventory', 226 + shift, 'inventory', page == 'inventory')
    nav('misc', 'misc', 'Miscellaneous', 262 + shift, 'misc', page == 'misc')

    local name, id = localIdentity()
    local ax, ay = bx + 7, by + 531
    if Hit('##account', ax, ay, 140, 38) then
        account.open = not account.open
        account.frame = imgui.GetFrameCount()
    end
    local ar = Motion('account#hv', account.open and 1 or (imgui.IsItemHovered() and 0.5 or 0))
    if ar > 0.001 then dl:AddRectFilled(V(ax, ay), V(ax + 140, ay + 38), C(39, 43, 54, 235 * ar), 6) end
    Avatar(dl, ax + 21, ay + 19, 14, name)
    dl:PushClipRect(V(ax + 43, ay), V(ax + 126, ay + 38), true)
    Text(dl, ax + 43, ay + 4, C(225, 227, 233), name, F.ctrl)
    Text(dl, ax + 43, ay + 20, C(111, 116, 128), id >= 0 and ('ID: ' .. id) or L('offline'), F.small)
    dl:PopClipRect()
    Chevron(dl, ax + 132, ay + 15, C(181, 185, 195))
end

local PROFILE_ITEMS = {
    'Save Config', 'Load Config', 'Reset Config',
    function() return L('Open Key: ') .. (keyNames[O.menu_key + 1] or '?') end,
    function() return L('Notifications: ') .. L(O.notify and 'On' or 'Off') end,
}
local function profileSet(i)
    if i == 1 then actSave() elseif i == 2 then actLoad() elseif i == 3 then actReset()
    elseif i == 4 then O.menu_key = (O.menu_key + 1) % #keyNames; return false
    elseif i == 5 then O.notify = not O.notify; return false end
    return true
end

local function Toolbar(dl, bx, by)
    FillTopRightRounded(dl, bx + 158, by, bx + 748, by + 56, 14, C(11, 13, 20, 225))
    dl:AddLine(V(bx + 158, by + 56), V(bx + 748, by + 56), C(27, 30, 39))
    local px, py = bx + 169, by + 14
    if Hit('##tb_profile', px, py, 166, 30) then
        OpenPopup('##tb_profile', PROFILE_ITEMS, function() return false end, profileSet, px, py, 166, 30)
    end
    local r = Motion('tb_profile#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == '##tb_profile')) and 1 or 0)
    dl:AddRectFilled(V(px, py), V(px + 166, py + 30), Mix({ 17, 19, 27 }, { 22, 25, 35 }, r), 6)
    dl:AddRect(V(px, py), V(px + 166, py + 30), Mix({ 28, 31, 41 }, { 45, 52, 70 }, r), 6)
    Icon(dl, 'save', px + 12, py, 30, C(194, 197, 206))
    TextY(dl, px + 48, py, 30, C(184, 187, 197), L('Profile'), F.ctrl)
    Chevron(dl, px + 148, py + 11, C(130, 135, 146))
    if page == 'rage' or page == 'legit' then
        WeaponPicker(dl, '##tb_weapon', bx + 348, by + 14, 85, 30)
    end
    dl:AddCircle(V(bx + 719, by + 28), 5, C(180, 184, 194), 20, 2)
    dl:AddLine(V(bx + 723, by + 32), V(bx + 727, by + 36), C(180, 184, 194), 2)
end

-- ============================================================ ОКНА ПОВЕРХ
local OVERLAY_FLAGS
local function overlayFlags()
    if not OVERLAY_FLAGS then
        local wf = imgui.WindowFlags
        OVERLAY_FLAGS = bit.bor(wf.NoTitleBar, wf.NoResize, wf.NoMove, wf.NoCollapse,
            wf.NoScrollbar, wf.NoScrollWithMouse, wf.NoSavedSettings)
    end
    return OVERLAY_FLAGS
end
local function beginOverlay(name, x, y, w, h, frame)
    imgui.SetNextWindowFocus()
    imgui.SetNextWindowPos(TV(x, y), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(w * SC, h * SC), imgui.Cond.Always)
    imgui.Begin(name, nil, overlayFlags())
    local raw = imgui.GetWindowDrawList()
    return wrapDL(raw), raw
end
local function popupHovered()
    return popup.open and inRect(Mouse(), popup.rx, popup.ry, popup.rw, popup.rh)
end

local function PopupLayer(reveal)
    local open = Motion('popup_open', popup.open and 1 or 0, 20, 0)
    if open < 0.002 or not popup.items then return end
    local items, icons = popup.items, popup.icons
    local count = #items
    -- ширина под самый длинный пункт (для русского языка)
    local w = popup.w
    for i, it in ipairs(items) do
        local label = L(type(it) == 'function' and it() or it)
        local off = (icons and icons[i] and WICON[icons[i]]) and 70 or 35
        w = math.max(w, off + TextSize(label, F.ctrl).x + 16)
    end
    local h = count * 32 + 8
    local lx0, ly0, lx1, ly1 = screenL()
    local px = clamp(popup.x, lx0 + 10, lx1 - w - 10)
    local py = clamp(popup.y + (popup.ah - h) * 0.5, ly0 + 10, ly1 - h - 10)
    popup.rx, popup.ry, popup.rw, popup.rh = px, py, w, h

    local dl, raw = beginOverlay('##nl_popup', px - 8, py - 6, w + 16, h + 18, popup.frame)
    local first = vtxFirst(raw)
    local e = 1 - (1 - open) ^ 3
    gA = reveal * e
    dl:AddRectFilled(V(px - 5, py - 2), V(px + w + 5, py + h + 8), C(0, 0, 0, 55), 18)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 235), 16)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 205), 16)
    dl:AddLine(V(px + 16, py + 1), V(px + w - 16, py + 1), C(255, 255, 255, 22))
    local accepts = imgui.GetFrameCount() > popup.frame and popup.open
    for i, it in ipairs(items) do
        local label = L(type(it) == 'function' and it() or it)
        local rx, ry = px + 4, py + 4 + (i - 1) * 32
        local clicked = Hit('##pp' .. i, rx, ry, w - 8, 32)
        local hv = Motion('pp#' .. tostring(popup.owner) .. i, imgui.IsItemHovered() and 1 or 0, 22)
        if hv > 0.001 then dl:AddRectFilled(V(rx, ry), V(rx + w - 8, ry + 32), C(75, 126, 255, 25 * hv), 10) end
        local selected = popup.get(i)
        if selected then CheckMark(dl, rx + 14, ry + 16, C(230, 233, 241)) end
        local tx = rx + 35
        if icons and icons[i] and WICON[icons[i]] then
            WeaponIcon(dl, icons[i], rx + 50, ry + 16, 28)
            tx = rx + 70
        end
        TextY(dl, tx, ry, 32, selected and C(224, 229, 243) or C(182, 185, 196), label, F.ctrl)
        if accepts and clicked and popup.set(i) then popup.open = false end
    end
    vtxScale(raw, first, px + w * 0.5, py + h * 0.5, 0.96 + 0.04 * e, 4 * (1 - e), 0)
    if popup.open and imgui.GetFrameCount() > popup.frame and imgui.IsMouseClicked(0) and not imgui.IsWindowHovered(imgui.HoveredFlags.AllowWhenBlockedByActiveItem) then
        popup.open = false
    end
    imgui.End()
end

local function SubPopover(reveal)
    local open = Motion('sub_open', sub.open and 1 or 0, 20, 0)
    if open < 0.002 or not sub.def then return end
    local rows = sub.def.rows
    local w, h = 290, #rows * 37
    local lx0, ly0, lx1, ly1 = screenL()
    local px = sub.ax + sub.aw + 10
    if px + w > lx1 - 10 then px = sub.ax - w - 10 end
    local py = clamp(sub.ay - 4, ly0 + 26, ly1 - h - 10)
    local dl, raw = beginOverlay('##nl_sub', px - 8, py - 26, w + 16, h + 40, sub.frame)
    local first = vtxFirst(raw)
    local e = 1 - (1 - open) ^ 3
    gA = reveal * e
    dl:AddRectFilled(V(px - 5, py - 2), V(px + w + 5, py + h + 8), C(0, 0, 0, 55), 18)
    Text(dl, px + 12, py - 18, C(89, 94, 106), L(sub.def.title), F.cap)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 240), 14)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 205), 14)
    for i, row in ipairs(rows) do
        local ry = py + (i - 1) * 37
        if i > 1 then dl:AddLine(V(px + 12, ry), V(px + w - 12, ry), C(28, 31, 40)) end
        RowControl(dl, px, ry, w, row, '##sub' .. i)
    end
    vtxScale(raw, first, px, py + h * 0.5, 0.96 + 0.04 * e, -6 * (1 - e), 0)
    if sub.open and imgui.GetFrameCount() > sub.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered(imgui.HoveredFlags.AllowWhenBlockedByActiveItem) and not popupHovered()
        and not inRect(Mouse(), sub.ax, sub.ay, sub.aw, sub.ah) and not VIS.cpHovered() then
        sub.open, popup.open, VIS.cp.open = false, false, false
    end
    imgui.End()
end

local ACC_ROWS = {
    { 'Language', 'acc_lang', { 'English', 'Русский' } },
    { 'Menu Scale', 'acc_menu_scale', { '100%', '125%', '150%' } },
    { 'ESP Scale', 'acc_esp_scale', { '100%', '110%', '120%' } },
}

local function AccountPopover(bx, by, reveal)
    local open = Motion('account_open', account.open and 1 or 0, 17, 0)
    if open < 0.002 then return end
    local w, h = 218, 181
    local px, py = bx + 151, by + 380
    local dl = beginOverlay('##nl_account', px - 6, py - 4, w + 12, h + 14, account.frame)
    gA = reveal * open
    dl:AddRectFilled(V(px - 4, py - 2), V(px + w + 4, py + h + 7), C(0, 0, 0, 65), 18)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(24, 25, 34, 245), 16)
    dl:AddRect(V(px, py), V(px + w, py + h), C(48, 51, 64), 16)
    local name, id = localIdentity()
    Avatar(dl, px + 35, py + 34, 18, name)
    dl:PushClipRect(V(px + 62, py), V(px + w - 10, py + 60), true)
    Text(dl, px + 64, py + 15, C(229, 231, 237), name, F.body)
    Text(dl, px + 64, py + 34, C(115, 164, 255), id >= 0 and ('ID: ' .. id .. '  ·  v' .. thisScript().version) or L('offline'), F.ctrl)
    dl:PopClipRect()
    local accepts = imgui.GetFrameCount() > account.frame and account.open
    for i, r in ipairs(ACC_ROWS) do
        local ry = py + 66 + (i - 1) * 28
        local clicked = Hit('##acc' .. i, px + 6, ry, w - 12, 28)
        local hv = Motion('acc#' .. i, (imgui.IsItemHovered() or (popup.open and popup.owner == '##acc' .. i)) and 1 or 0, 22)
        if hv > 0.001 then dl:AddRectFilled(V(px + 6, ry), V(px + w - 6, ry + 28), C(75, 126, 255, 22 * hv), 8) end
        TextY(dl, px + 18, ry, 28, C(185, 188, 198), L(r[1]), F.ctrl)
        local val = r[3][O[r[2]] + 1] or ''
        local vw = TextSize(val, F.small).x
        TextY(dl, px + 186 - vw, ry, 28, C(111, 116, 128), val, F.small)
        Chevron(dl, px + 195, ry + 11, C(150, 154, 165))
        if accepts and clicked then
            local key = r[2]
            OpenPopup('##acc' .. i, r[3], function(k) return O[key] == k - 1 end,
                function(k) O[key] = k - 1; account.frame = imgui.GetFrameCount(); return true end, px + w - 140, ry + 2, 134, 23)
        end
    end
    TextY(dl, px + 18, py + 66 + 3 * 28, 28, C(185, 188, 198), L('Synchronization'), F.ctrl)
    Toggle(dl, '##acc_sync', px + 169, py + 150, 'acc_sync')
    if account.open and imgui.GetFrameCount() > account.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered(imgui.HoveredFlags.AllowWhenBlockedByActiveItem) and not popupHovered()
        and not inRect(Mouse(), bx + 7, by + 531, 140, 38) then
        account.open, popup.open = false, false
    end
    imgui.End()
end

-- ============================================================ РЕНДЕР МЕНЮ
local SHELL_W, SHELL_H = 748, 576
local function closePopups() popup.open, sub.open, account.open, VIS.cp.open = false, false, false, false end
local function toggleMenu()
    menu[0] = not menu[0]
    if menu[0] then anim.reveal = 0 end
    closePopups()
end

imgui.OnFrame(function() return menu[0] end, function()
    applyScale()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(SHELL_W * SC, SHELL_H * SC), imgui.Cond.Always)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

    local wf = imgui.WindowFlags
    imgui.Begin('##neverlose', menu, bit.bor(wf.NoTitleBar, wf.NoResize, wf.NoCollapse, wf.NoScrollbar,
        wf.NoScrollWithMouse, wf.NoSavedSettings, wf.NoBringToFrontOnFocus))
    local raw = imgui.GetWindowDrawList()
    local dl = wrapDL(raw)
    local wp = imgui.GetWindowPos()
    OX, OY = wp.x, wp.y
    local bx, by = wp.x, wp.y
    local reveal = Motion('reveal', 1, 9, 0)
    local re = 1 - (1 - reveal) ^ 4
    local shellFirst = vtxFirst(raw)

    gA = re
    dl:AddRectFilled(V(bx, by), V(bx + SHELL_W, by + SHELL_H), C(13, 15, 22, 222), 14)
    Sidebar(dl, bx, by)
    Toolbar(dl, bx, by)
    pageMix = pageMix + (1 - pageMix) * (1 - math.exp(-15 * imgui.GetIO().DeltaTime))
    local pe = 1 - (1 - pageMix) ^ 3
    gA = re * pe
    local fn = PAGES[page] or PAGES.rage
    fn(dl, { x = bx + 9 * (1 - pe), y = by })
    gA = re
    if re < 0.999 then
        vtxScale(raw, shellFirst, bx + SHELL_W * 0.5, by + SHELL_H * 0.5, 0.92 + 0.08 * re, 0, (1 - re) * 16)
    end
    imgui.End()

    AccountPopover(bx, by, re)
    SubPopover(re)
    PopupLayer(re)
    VIS.ColorPopover(re)
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
    gA = 1
end)

-- ============================================================ ANTI-AIM (крутилка)
local aaFlip, aaSign = false, 1
local aaFlickUntil = 0      -- «Backward Flick»: до этого момента показываем настоящий поворот (стреляем)

-- стреляем прямо сейчас? (ЛКМ с огнестрелом) — для флика без задержки, ещё до пакета пули
local function aaShooting()
    if not isKeyDown(0x01) or sampIsChatInputActive() or sampIsDialogActive() then return false end
    return getCurrentCharWeapon(PLAYER_PED) >= 22
end
local function aaFlicking() return os.clock() < aaFlickUntil or aaShooting() end

-- ничего не делаем, пока игрок не заспавнен и не прошло 5 секунд после спавна
-- (подмена синка / движения / памяти во время коннекта и спавна палится античитом)
local spawnedAt = nil
local function gameReady()
    local ok, sp = pcall(sampIsLocalPlayerSpawned)
    if not ok or not sp or not doesCharExist(PLAYER_PED) then spawnedAt = nil; return false end
    spawnedAt = spawnedAt or os.clock()
    return os.clock() - spawnedAt > 5
end

local function aaActive()
    if not O.aa_enable or not spawnedAt or os.clock() - spawnedAt <= 5 then return false end
    if not doesCharExist(PLAYER_PED) or not isCharOnFoot(PLAYER_PED) then return false end
    if O.aa_noaim and isKeyDown(0x02) then return false end
    return true
end

local function aaSpinAngle() return (os.clock() * O.aa_speed * 24) % 360 end

local function aaYaw(base)
    local m = O.aa_mode
    if m == 0 then return aaSpinAngle()
    elseif m == 1 then
        aaFlip = not aaFlip
        return (base + 180 + (aaFlip and O.aa_jitter or -O.aa_jitter)) % 360
    elseif m == 2 then return math.random(0, 359)
    elseif m == 4 then
        -- спиной; в момент выстрела — резко лицом (настоящий поворот), через Flick Time — обратно
        if aaFlicking() then return base end
    end
    return (base + 180) % 360
end

local function wrapPi(a) return (a + PI) % (2 * PI) - PI end
local localSpinning, lastForce = false, 0

function sampev.onSendPlayerSync(data)
    TR.T('playersync')
    if not aaActive() then return end
    local base = getCharHeading(PLAYER_PED)
    local q = data.quaternion
    -- определяем знак (конвенцию) кватерниона SA-MP по исходному пакету
    local hb = math.rad(base)
    if math.abs(math.sin(hb)) > 0.25 then
        local a0 = 2 * math.atan2(q[3], q[0])
        aaSign = (math.abs(wrapPi(a0 - hb)) <= math.abs(wrapPi(a0 + hb))) and 1 or -1
    end
    local yaw = localSpinning and base or aaYaw(base)
    local h = math.rad(yaw)
    q[0] = math.cos(h / 2)
    q[1] = 0
    q[2] = 0
    q[3] = aaSign * math.sin(h / 2)
end

-- Pitch: другие видят голову, опущенную вниз (Down) или задранную вверх (Up).
-- В момент флика/выстрела AimSync не трогаем — выстрел выглядит честным.
function sampev.onSendAimSync(data)
    TR.T('aimsync')
    if not aaActive() or (O.aa_pitch or 0) == 0 then return end
    if O.aa_mode == 4 and aaFlicking() then return end
    local pitch = math.rad(O.aa_pitch == 1 and -89 or 89)
    local hd = getCharHeading(PLAYER_PED)
    local yaw = math.rad(localSpinning and hd or aaYaw(hd))
    local c = math.cos(pitch)
    data.camFront.x = -math.sin(yaw) * c
    data.camFront.y = math.cos(yaw) * c
    data.camFront.z = math.sin(pitch)
    data.aimZ = pitch
end

-- ---------- настоящая крутилка у себя («Show Locally») на бегу и в прыжке ----------
-- Персонаж РЕАЛЬНО крутится (setCharHeading каждый кадр, в синк уходит этот же поворот).
-- GTA двигает педа по его повороту, поэтому игре мы движение не отдаём:
--   * обнуляем ей стики (setGameKeyState) — анимация бега не тащит педа по «крутящемуся» взгляду;
--   * сами двигаем педа туда, куда жмёте (камера + стик), со скоростью ходьбы/бега/спринта;
--   * прыжок делаем сами (вертикальная скорость), в воздухе управляем горизонтальной скоростью.
local BTN_JUMP, BTN_SPRINT = 14, 16
local AA_SPEED_WALK, AA_SPEED_RUN, AA_SPEED_SPRINT = 1.8, 5.4, 8.2
local AA_JUMP_VZ = 5.5
local aaPos, aaLast, aaJumpHeld, aaJumpT = nil, 0, false, 0

local function camHeading()
    local cx, cy = getActiveCameraCoordinates()
    local px, py = getActiveCameraPointAt()
    return math.deg(math.atan2(-(px - cx), py - cy))
end

-- позиция персонажа в матрице (только X/Y — высоту оставляем игре: склоны, лестницы, гравитация)
local function pedPos()
    local ptr = getCharPointer(PLAYER_PED)
    if not ptr or ptr == 0 then return nil end
    local m = rd32(ptr + 0x14)
    if m == 0 then return nil end
    return ffi.cast('float*', m + 0x30)
end

-- ============================================================ MOVEMENT (общие хелперы)
local AA_SPEED_SLOW = 1.0
local mvJumpT = 0

-- ввод игрока: стик/WASD относительно камеры, прыжок (пробел или кнопка прыжка), спринт, ходьба
local function mvInput(free)
    local lx, ly = getPositionOfAnalogueSticks(0)
    if not free then lx, ly = 0, 0 end
    local I = { moving = lx ~= 0 or ly ~= 0, dx = 0, dy = 0, k = 0 }
    I.jump = free and (isKeyDown(0x20) or isButtonPressed(PLAYER_HANDLE, BTN_JUMP))
    I.sprint = free and (isButtonPressed(PLAYER_HANDLE, BTN_SPRINT) or isKeyDown(0xA0))
    I.walk = free and isKeyDown(0x12)
    if I.moving then
        local mh = math.rad((camHeading() + math.deg(math.atan2(-lx, -ly))) % 360)
        I.dx, I.dy = -math.sin(mh), math.cos(mh)
        I.k = math.min(1, math.sqrt(lx * lx + ly * ly) / 128)
    end
    return I
end

-- прыжок скриптом: приподнимаем педа (снимается флаг «стоит») и даём вертикальную скорость
local function mvDoJump(vx, vy)
    mvJumpT = os.clock()
    local p = pedPos()
    if p then p[2] = p[2] + 0.15 end
    setCharVelocity(PLAYER_PED, vx, vy, AA_JUMP_VZ)
end

-- управление в воздухе: Air Strafe (WASD рулит скоростью) и Strafe Assist (без клавиш — доворот к камере)
-- направление банни-хопа в режиме Mouse: куда смотрит камера (с WASD — относительно камеры); nil — режим Velocity
local function bhopDir(I)
    if O.bhop_dir ~= 1 then return nil end
    if I.moving then return I.dx, I.dy end
    local h = math.rad(camHeading())
    return -math.sin(h), math.cos(h)
end

-- Bunny Hop без подтормаживания: isCharInAir становится false уже ПОСЛЕ касания земли — к этому
-- моменту игра гасит скорость и включает анимацию приземления (FALL_land / JUMP_land), отсюда «торможение».
-- Поэтому прыгаем заранее: когда до земли осталось меньше, чем пролетим за ~2 кадра.
function VIS.bhLanding(x, y, z, vz)
    if vz > -0.5 then return false end
    local gz = getGroundZFor3dCoord(x, y, z)
    if not gz or gz < -90 then return false end
    return (z - gz - 1.0) < (-vz) * 0.034 + 0.12   -- центр педа ~1.0 м над ступнями
end

local function mvAir(I, speed)
    local vx, vy, vz = getCharVelocity(PLAYER_PED)
    local hs = math.sqrt(vx * vx + vy * vy)
    -- банни-хоп по мышке: пока держишь прыжок, полёт поворачивает за камерой
    if O.m_move_bunny_hop and O.bhop_steer and I.jump then
        local ex, ey = bhopDir(I)
        if ex then
            setCharVelocity(PLAYER_PED, ex * O.bhop_speed, ey * O.bhop_speed, vz)
            return
        end
    end
    if I.moving and O.m_move_air_strafe then
        local s = math.max(hs, speed)
        setCharVelocity(PLAYER_PED, I.dx * s, I.dy * s, vz)
    elseif not I.moving and O.m_move_strafe_assist and hs > 1 then
        local h = math.rad(camHeading())
        local cx, cy = -math.sin(h), math.cos(h)
        local nx, ny = vx + (cx * hs - vx) * 0.08, vy + (cy * hs - vy) * 0.08
        local n = math.sqrt(nx * nx + ny * ny)
        if n > 0 then setCharVelocity(PLAYER_PED, nx / n * hs, ny / n * hs, vz) end
    end
end

local function aaMoveTick(free, I)
    local now = os.clock()
    local dt = clamp(now - aaLast, 0, 0.1)
    aaLast = now

    -- игре движение и прыжок не даём (ввод уже прочитан в mvInput)
    setGameKeyState(0, 0)
    setGameKeyState(1, 0)
    setGameKeyState(BTN_JUMP, 0)

    local speed = 0
    if I.moving then
        local walkSpeed = O.m_move_slow_walk and AA_SPEED_SLOW or AA_SPEED_WALK
        speed = (I.sprint and AA_SPEED_SPRINT or (I.walk and walkSpeed or AA_SPEED_RUN)) * I.k
    end
    local dx, dy = I.dx, I.dy

    local x, y, z = getCharCoordinates(PLAYER_PED)
    local vx, vy, vz = getCharVelocity(PLAYER_PED)
    local inAir = isCharInAir(PLAYER_PED)

    -- Bunny Hop: прыжок ещё в воздухе, за мгновение до земли — без потери скорости
    if O.m_move_bunny_hop and I.jump and inAir and now - mvJumpT > 0.2 and VIS.bhLanding(x, y, z, vz) then
        mvJumpT = now
        local ex, ey = bhopDir(I)
        if ex then
            setCharVelocity(PLAYER_PED, ex * O.bhop_speed, ey * O.bhop_speed, AA_JUMP_VZ)
        elseif I.moving then
            local s = math.max(speed, math.sqrt(vx * vx + vy * vy))
            setCharVelocity(PLAYER_PED, dx * s, dy * s, AA_JUMP_VZ)
        else
            setCharVelocity(PLAYER_PED, vx, vy, AA_JUMP_VZ)
        end
        aaPos = nil
        aaJumpHeld = I.jump
        return
    end
    -- прыжок по нажатию; с Bunny Hop — и при зажатой клавише (прыгает сразу при приземлении)
    if I.jump and (not aaJumpHeld or O.m_move_bunny_hop) and not inAir and now - mvJumpT > 0.3 then
        local s = speed
        if O.m_move_bunny_hop then s = math.max(s, math.sqrt(vx * vx + vy * vy)) end
        local ex, ey = nil, nil
        if O.m_move_bunny_hop then ex, ey = bhopDir(I) end
        if ex then mvDoJump(ex * O.bhop_speed, ey * O.bhop_speed) else mvDoJump(dx * s, dy * s) end
        aaPos = nil
        aaJumpHeld = I.jump
        return
    end
    aaJumpHeld = I.jump
    -- первые кадры прыжка игра может гасить вертикальную скорость — дожимаем, пока не оторвались
    if not inAir and now - mvJumpT < 0.15 then
        -- не режем скорость банни-хопа до скорости бега
        local hx, hy = vx, vy
        if hx * hx + hy * hy < speed * speed then hx, hy = dx * speed, dy * speed end
        setCharVelocity(PLAYER_PED, hx, hy, AA_JUMP_VZ)
        aaPos = nil
        return
    end

    if inAir then
        mvAir(I, speed)
        aaPos = nil
        return
    end

    -- на земле: двигаем позицию сами
    if not aaPos or math.abs(aaPos.x - x) + math.abs(aaPos.y - y) > 2.5 then aaPos = { x = x, y = y } end
    if not I.moving then
        aaPos.x, aaPos.y = x, y
        return
    end
    local nx, ny = aaPos.x + dx * speed * dt, aaPos.y + dy * speed * dt
    -- не проходим сквозь стены/машины/объекты (проверка чуть впереди, на уровне пояса)
    TR.T('aa.move.los')
    if isLineOfSightClear(aaPos.x, aaPos.y, z, nx + dx * 0.45, ny + dy * 0.45, z, true, true, false, true, false) then
        aaPos.x, aaPos.y = nx, ny
    end
    local p = pedPos()
    if p then p[0], p[1] = aaPos.x, aaPos.y end
    -- скорость для синхронизации (другие видят плавный бег, а не телепорты)
    setCharVelocity(PLAYER_PED, dx * speed, dy * speed, vz)
end

local function aaTick(free, I)
    localSpinning = false
    if not I or not aaActive() then aaPos = nil; return end
    local m = O.aa_mode
    if O.aa_local and (m == 0 or m == 3 or m == 4) and not isCharInWater(PLAYER_PED) then
        -- Show Locally: Spin — крутим; Backward — спиной к камере; Backward Flick — спиной, при выстреле лицом
        local h
        if m == 0 then
            h = aaSpinAngle()
        else
            local cam = camHeading()
            h = (m == 4 and aaFlicking()) and cam or (cam + 180) % 360
        end
        setCharHeading(PLAYER_PED, h)
        localSpinning = true
        aaMoveTick(free, I)
    else
        aaPos = nil
    end
    -- частая отправка синхронизации, чтобы вращение у других было плавным
    if O.aa_force and os.clock() - lastForce > 0.04 then
        lastForce = os.clock()
        TR.T('aa.forcesync')
        pcall(sampForceOnfootSync)
    end
end

-- ============================================================ MISC: MOVEMENT
local CLIMB_ANIMS = { 'CLIMB_jump', 'CLIMB_jump_B', 'CLIMB_Pull', 'CLIMB_Stand', 'CLIMB_Stand_finish', 'CLIMB_idle', 'CLIMB_jump2fall' }
local WALK_ANIMS  = { 'WALK_player', 'WALK_armed', 'WALK_civi', 'GUNMOVE_FWD' }
local mv = { wasAir = false, prevMoving = false, airVx = 0, airVy = 0, stop = nil }

local function animSpeed(list, k)
    for _, a in ipairs(list) do
        if isCharPlayingAnim(PLAYER_PED, a) then setCharAnimSpeed(PLAYER_PED, a, k) end
    end
end

local function mvTick(free, I)
    if not I or not isCharOnFoot(PLAYER_PED) then mv.wasAir, mv.stop = false, nil; return end
    local now = os.clock()
    local inAir, water = isCharInAir(PLAYER_PED), isCharInWater(PLAYER_PED)
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local vx, vy, vz = getCharVelocity(PLAYER_PED)
    local hs = math.sqrt(vx * vx + vy * vy)

    -- Fast Ladder: ускоряем анимации карабканья
    if O.m_move_fast_ladder then animSpeed(CLIMB_ANIMS, 2.2) end

    -- Jump Bug: гасим скорость падения прямо перед землёй — без урона от падения
    if O.m_move_jump_bug and inAir and not water and vz < -9 then
        TR.T('mv.jumpbug.groundz')
        local gz = getGroundZFor3dCoord(x, y, z)
        if z - gz < 1.6 + (-vz) / 30 then setCharVelocity(PLAYER_PED, vx, vy, -2.0) end
    end

    -- Edge Jump: автопрыжок, когда сходим с края (впереди земля ниже на 1.5+ м)
    if O.m_move_edge_jump and not inAir and not water and now - mvJumpT > 0.4 then
        local ex, ey, es
        if localSpinning then
            if I.moving then ex, ey, es = I.dx, I.dy, I.sprint and AA_SPEED_SPRINT or AA_SPEED_RUN end
        elseif hs > 2 then
            ex, ey, es = vx / hs, vy / hs, hs
        end
        if ex then
            TR.T('mv.edgejump.groundz')
            local g0 = getGroundZFor3dCoord(x, y, z)
            local g1 = getGroundZFor3dCoord(x + ex * 0.8, y + ey * 0.8, z + 0.5)
            if g0 - g1 > 1.5 then mvDoJump(ex * es, ey * es) end
        end
    end

    -- дальше — только для обычного движения (при «Show Locally» бег/прыжок/воздух ведёт aaMoveTick)
    if localSpinning then mv.wasAir, mv.prevMoving, mv.jumpHeld = inAir, I.moving, I.jump; return end

    -- Bunny Hop: держишь прыжок — прыгаем в момент приземления, сохраняя скорость полёта
    -- с банни-хопом прыжок делает скрипт (игровой прыжок блокируем, чтобы не мешал)
    if O.m_move_bunny_hop then setGameKeyState(BTN_JUMP, 0) end
    -- прыжок ещё в воздухе, за мгновение до касания (без кадра на земле и анимации приземления)
    local preLand = O.m_move_bunny_hop and I.jump and inAir and not water and now - mvJumpT > 0.2
        and VIS.bhLanding(x, y, z, vz)
    if preLand or (O.m_move_bunny_hop and I.jump and (mv.wasAir or not mv.jumpHeld) and not inAir and not water and now - mvJumpT > 0.2) then
        local ex, ey = bhopDir(I)
        if ex then
            mv.airVx, mv.airVy = ex * O.bhop_speed, ey * O.bhop_speed
        elseif preLand or not mv.wasAir then
            mv.airVx, mv.airVy = vx, vy       -- по инерции — с текущей скоростью полёта / бега
        end
        if preLand then
            mvJumpT = now
            setCharVelocity(PLAYER_PED, mv.airVx, mv.airVy, AA_JUMP_VZ)
        else
            mvDoJump(mv.airVx, mv.airVy)
        end
        mv.wasAir, mv.prevMoving, mv.jumpHeld = true, I.moving, I.jump
        return
    elseif not inAir and now - mvJumpT < 0.15 then
        setCharVelocity(PLAYER_PED, mv.airVx, mv.airVy, AA_JUMP_VZ)
    end

    if inAir and not water then
        mvAir(I, I.sprint and AA_SPEED_SPRINT or AA_SPEED_RUN)
        local ax, ay = getCharVelocity(PLAYER_PED)
        mv.airVx, mv.airVy = ax, ay
    end

    -- Standalone Quick Stop: отпустил клавиши на бегу — мгновенная остановка без «тормозного пути»
    if O.m_move_standalone_quick_stop and not inAir and not water then
        if I.moving then
            mv.stop = nil
        elseif mv.prevMoving and hs > 2 then
            mv.stop = { x = x, y = y, t = now }
        end
        if mv.stop then
            if now - mv.stop.t < 0.35 then
                local p = pedPos()
                if p then p[0], p[1] = mv.stop.x, mv.stop.y end
                setCharVelocity(PLAYER_PED, 0, 0, vz)
            else
                mv.stop = nil
            end
        end
    end

    -- Slow Walk: с зажатым Alt ходим заметно медленнее
    if O.m_move_slow_walk and I.walk and I.moving and not inAir then animSpeed(WALK_ANIMS, 0.55) end

    mv.wasAir, mv.prevMoving, mv.jumpHeld = inAir, I.moving, I.jump
end

-- ============================================================ RAGE (сайлент аим / автострельба)
-- Всё в одной таблице RG — в главном чанке Lua лимит 200 локальных переменных.
local RG = {
    -- урон за выстрел (стандарт SA-MP; дробовики — сумма дробинок)
    DMG = { [22] = 8.25, [23] = 13.2, [24] = 46.2, [25] = 49.5, [26] = 49.5, [27] = 39.6, [28] = 6.6,
            [29] = 8.25, [30] = 9.9, [31] = 9.9, [32] = 6.6, [33] = 24.75, [34] = 41.25, [38] = 46.2 },
    -- хитбоксы (порядок как в меню Hitboxes): смещение по высоте от центра педа, сбоку, bodypart для урона
    HB = {
        { dz = 0.68, side = 0.00, bp = 9 },   -- Head
        { dz = 0.35, side = 0.00, bp = 3 },   -- Chest
        { dz = 0.05, side = 0.00, bp = 4 },   -- Stomach
        { dz = 0.30, side = 0.28, bp = 6 },   -- Arms
        { dz = -0.45, side = 0.12, bp = 8 },  -- Legs
        { dz = -0.88, side = 0.12, bp = 8 },  -- Feet
    },
    lastT = nil, lastScan = 0,
}

function RG.on() return O.rage_main_enabled end

function RG.cam()
    local cx, cy, cz = getActiveCameraCoordinates()
    local px, py, pz = getActiveCameraPointAt()
    local dx, dy, dz = px - cx, py - cy, pz - cz
    local n = math.sqrt(dx * dx + dy * dy + dz * dz)
    if n < 1e-4 then n = 1 end
    return cx, cy, cz, dx / n, dy / n, dz / n
end

function RG.myId()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    return ok and id or -1
end

-- порядок проверки хитбоксов по «Prefer»
function RG.order()
    local p = O.rage_sel_prefer or 0
    if p == 3 then return { 2, 3, 1, 4, 5, 6 } end       -- Body
    return { 1, 2, 3, 4, 5, 6 }                          -- Damage / Accuracy / Head
end

-- нужен ли такой урон по Min Damage (0 = Auto, >100 = HP+X → только если убиваем)
function RG.dmgOk(dmg, hp)
    local v = O.rage_sel_min_damage or 0
    if v == 0 then return true end
    local req = v > 100 and (hp + (v - 100)) or v
    return dmg >= math.min(req, hp)
end

-- поиск цели: { id, ped, x, y, z, bp, hp, ang }
function RG.find(weapon, strict)
    local dmg = RG.DMG[weapon]
    if not dmg then return nil end
    local cx, cy, cz, fx, fy, fz = RG.cam()
    local fov = O.rage_main_field_of_view or 180
    local walls = O.rage_main_aim_through_walls
    local prefer = O.rage_sel_prefer or 0
    local mask = O.rage_sel_hitboxes or 0x07
    local myId = RG.myId()
    local lead = 0
    if (O.rage_main_refine_shot or 0) == 1 and myId >= 0 then   -- Latency: упреждение на пинг
        local okp, ping = pcall(sampGetPlayerPing, myId)
        lead = (okp and ping or 0) / 1000
    end
    local best, bestScore = nil, math.huge
    for id = 0, sampGetMaxPlayerId(false) do
        if id ~= myId and sampIsPlayerConnected(id) then
            local ok, ped = sampGetCharHandleBySampPlayerId(id)
            if ok and doesCharExist(ped) and not isCharDead(ped) and not sampIsPlayerPaused(id) then
                local hp = sampGetPlayerHealth(id) + sampGetPlayerArmor(id)
                if hp > 0 and (not strict or RG.dmgOk(dmg, hp)) then
                    local x, y, z = getCharCoordinates(ped)
                    if lead > 0 then
                        local vx, vy, vz = getCharVelocity(ped)
                        x, y, z = x + vx * lead, y + vy * lead, z + vz * lead
                    end
                    local h = math.rad(getCharHeading(ped))
                    local rx, ry = math.cos(h), math.sin(h)   -- вправо от педа
                    for _, i in ipairs(RG.order()) do
                        if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then
                            local hb = RG.HB[i]
                            local tx, ty, tz = x + rx * hb.side, y + ry * hb.side, z + hb.dz
                            local dx, dy, dz = tx - cx, ty - cy, tz - cz
                            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                            if dist > 0.5 and dist < 300 then
                                local dot = (dx * fx + dy * fy + dz * fz) / dist
                                local ang = math.deg(math.acos(math.max(-1, math.min(1, dot))))
                                if ang <= fov and (walls or TR.T('rg.find.los') or isLineOfSightClear(cx, cy, cz, tx, ty, tz, true, true, false, true, false)) then
                                    local score = (prefer == 0) and (hp * 1000 + ang) or ang
                                    if score < bestScore then
                                        bestScore = score
                                        best = { id = id, ped = ped, x = tx, y = ty, z = tz, px = x, py = y, pz = z, bp = hb.bp, hp = hp, ang = ang }
                                    end
                                    break   -- первый подходящий хитбокс этой цели (по приоритету)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

-- выстрел ушёл: подменяем пулю на попадание по цели и отправляем урон
function RG.onBullet(data)
    if not RG.on() or not O.rage_main_silent_aim or not spawnedAt then return end
    local w = getCurrentCharWeapon(PLAYER_PED)
    local dmg = RG.DMG[w]
    if not dmg then return end
    local hc = O.rage_sel_hit_chance or 0
    if hc > 0 and math.random(100) > hc then return end
    local t = RG.find(w, false)
    if not t then
        -- Remove Spread: без цели — пуля летит точно в прицел
        local rs = O.rage_other_remove_spread or 0
        if rs > 0 and data.targetType == 0 then
            local cx, cy, cz, fx, fy, fz = RG.cam()
            TR.T('rg.spread.los')
            local ok, cp = processLineOfSight(cx, cy, cz, cx + fx * 300, cy + fy * 300, cz + fz * 300, true, true, false, true, false, false, false, false)
            if ok and cp and cp.pos then
                local k = rs == 2 and 1 or 0.5
                data.target.x = data.target.x + (cp.pos[1] - data.target.x) * k
                data.target.y = data.target.y + (cp.pos[2] - data.target.y) * k
                data.target.z = data.target.z + (cp.pos[3] - data.target.z) * k
            end
        end
        return
    end
    local alreadyHit = data.targetType == 1 and data.targetId == t.id
    data.targetType = 1
    data.targetId = t.id
    data.target.x, data.target.y, data.target.z = t.x, t.y, t.z
    data.center.x, data.center.y, data.center.z = t.x - t.px, t.y - t.py, t.z - t.pz
    if alreadyHit then return end     -- игра сама засчитала попадание — урон не дублируем
    local id, bp = t.id, t.bp
    if bit.band(O.m_feat_log_events or 0, 1) ~= 0 then
        local okn, nm = pcall(sampGetPlayerNickname, id)
        chat(('silent {3DE07A}%.1f{FFFFFF} -> %s[%d]'):format(dmg, okn and nm or '?', id))
    end
    lua_thread.create(function()
        if not sampIsPlayerConnected(id) then return end
        TR.T('rg.givedamage ' .. id .. ' w' .. w)
        sampSendGiveDamage(id, dmg, w, bp)
        pcall(VIS.hit, id, dmg)
        if O.m_feat_hit_sound then addOneOffSound(0.0, 0.0, 0.0, 17802) end
        if O.rage_other_double_tap then
            wait(60)
            TR.T('rg.doubletap ' .. id)
            sampSendGiveDamage(id, dmg, w, bp)
        end
    end)
end

-- каждый кадр: Automatic Fire / Quick Scope / Quick Stop
function RG.tick(free)
    if not RG.on() or not free or not spawnedAt or os.clock() - spawnedAt < 5 then return end
    if not isCharOnFoot(PLAYER_PED) then return end
    local w = getCurrentCharWeapon(PLAYER_PED)
    if not RG.DMG[w] then return end
    local aiming = isKeyDown(0x02)
    local scope = O.rage_sel_quick_scope and (w == 33 or w == 34) and aiming
    if not ((O.rage_main_automatic_fire and aiming) or scope) then return end
    local now = os.clock()
    if now - RG.lastScan > 0.03 then          -- поиск цели не чаще ~30 раз в секунду
        RG.lastScan = now
        RG.lastT = RG.find(w, true)
    end
    if not RG.lastT then return end
    -- Delay Shot: Accuracy — стреляем только когда почти стоим
    if (O.rage_other_delay_shot or 0) == 2 then
        local vx, vy = getCharVelocity(PLAYER_PED)
        if vx * vx + vy * vy > 1 then
            if O.rage_sel_quick_stop then setGameKeyState(0, 0); setGameKeyState(1, 0) end
            return
        end
    end
    if O.rage_sel_quick_stop then setGameKeyState(0, 0); setGameKeyState(1, 0) end
    setGameKeyState(17, 255)
end

-- ============================================================ VISUALS: ESP / CHAMS / TRACERS / WORLD
-- Все игровые функции (координаты, кости, LOS, проекция, погода) вызываются в main-потоке (VIS.tick),
-- в OnFrame только рисуем готовые данные — никаких опкодов в потоке рендера.
VIS.list, VIS.tr, VIS.hits, VIS.souls, VIS.los, VIS.alive, VIS.shot = {}, {}, {}, {}, {}, {}, {}
VIS.drawTr, VIS.drawHits, VIS.drawSouls, VIS.veh, VIS.pk, VIS.obj, VIS.act = {}, {}, {}, {}, {}, {}, {}
VIS.active, VIS.sw, VIS.sh, VIS.st, VIS.cc, VIS.lastHit, VIS.dims = false, 1920, 1080, {}, {}, {}, {}
VIS.ch = { orig = {}, gflag = {}, last = 0, dirty = false }
VIS.LINKS = { { 8, 5 }, { 5, 4 }, { 4, 3 }, { 3, 2 }, { 5, 22 }, { 22, 23 }, { 23, 24 }, { 24, 25 }, { 5, 32 }, { 32, 33 },
    { 33, 34 }, { 34, 35 }, { 2, 51 }, { 51, 52 }, { 52, 53 }, { 53, 54 }, { 2, 41 }, { 41, 42 }, { 42, 43 }, { 43, 44 } }
VIS.BONE_IDS = { 2, 3, 4, 5, 8, 22, 23, 24, 25, 32, 33, 34, 35, 41, 42, 43, 44, 51, 52, 53, 54 }

-- ---------- цвета (O[key_rgb] = 0xRRGGBBAA) ----------
VIS.RB = { esp_box_vis = 1, esp_box_hid = 1, esp_skel = 2, esp_skel_hid = 2, chm_vis = 4, chm_hid = 4, chm_local_c = 4, chm_team_c = 4, chm_shot = 4,
    trc_local = 8, trc_enemies = 8, xh_c = 16, pl_model_glow = 32, chm_sil = 64, esp_snap_c = 128, sky_top = 256, sky_bot = 256, hat_on = 512 }
function VIS.rainbow(off, a)
    local h = (os.clock() * (O.rb_speed or 6) * 0.05 + (off or 0)) % 1
    local sat = (O.rb_sat or 80) / 100
    local function ch(n)
        local k = (n + h * 6) % 6
        local v = 1 - math.max(0, math.min(k, 4 - k, 1))
        return math.floor(255 * (1 - sat + sat * v))
    end
    return { ch(5), ch(3), ch(1), a or 255 }
end
function VIS.rgb(key, raw)
    local v = O[key .. '_rgb'] or DEF[key .. '_rgb'] or 0xFFFFFFFF
    local rb = VIS.RB[key]
    if rb and not raw and bit.band(O.rb_mask or 0, rb) ~= 0 then
        return VIS.rainbow(key == 'sky_bot' and 0.5 or 0, v % 256)
    end
    local c = VIS.cc[key]
    if c and c.v == v then return c end
    c = { math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256, v = v }
    VIS.cc[key] = c
    return c
end
function VIS.C(c, a) return C(c[1], c[2], c[3], (a or 255) * (c[4] or 255) / 255) end

-- ---------- поповер выбора цвета ----------
function VIS.openColor(key, x, y)
    local cp = VIS.cp
    if cp.open and cp.key == key then cp.open = false; return end
    cp.open, cp.key, cp.x, cp.y, cp.frame = true, key, x, y, imgui.GetFrameCount()
    cp.arr = cp.arr or imgui.new.float[4]()
    local c = VIS.rgb(key, true)
    cp.arr[0], cp.arr[1], cp.arr[2], cp.arr[3] = c[1] / 255, c[2] / 255, c[3] / 255, c[4] / 255
    popup.open = false
end
function VIS.cpHovered()
    local cp = VIS.cp
    return cp.open and inRect(Mouse(), cp.rx, cp.ry, cp.rw, cp.rh)
end
function VIS.ColorPopover(reveal)
    local cp = VIS.cp
    if not cp.open or not cp.key or not cp.arr then return end
    local w, h = 236, 268
    local lx0, ly0, lx1, ly1 = screenL()
    local px = clamp(cp.x + 34, lx0 + 10, lx1 - w - 10)
    local py = clamp(cp.y - 30, ly0 + 10, ly1 - h - 10)
    cp.rx, cp.ry, cp.rw, cp.rh = px, py, w, h
    local dl = beginOverlay('##nl_color', px, py, w, h, cp.frame)
    gA = reveal
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 248), 12)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 220), 12)
    local c = VIS.rgb(cp.key)
    dl:AddRectFilled(V(px + w - 40, py + 9), V(px + w - 12, py + 23), C(c[1], c[2], c[3], c[4]), 4)
    Text(dl, px + 12, py + 9, C(150, 155, 170), L('Color'), F.cap)
    imgui.SetCursorScreenPos(TV(px + 12, py + 32))
    imgui.PushItemWidth((w - 24) * SC)
    local f = imgui.ColorEditFlags
    if imgui.ColorPicker4('##cpk', cp.arr, bit.bor(f.NoSidePreview, f.NoSmallPreview, f.AlphaBar, f.NoInputs, f.NoLabel)) then
        local r, g, b, a = cp.arr[0], cp.arr[1], cp.arr[2], cp.arr[3]
        local function q(v) return math.floor(clamp(v, 0, 1) * 255 + 0.5) end
        O[cp.key .. '_rgb'] = ((q(r) * 256 + q(g)) * 256 + q(b)) * 256 + q(a)
    end
    imgui.PopItemWidth()
    if imgui.GetFrameCount() > cp.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered(imgui.HoveredFlags.AllowWhenBlockedByActiveItem) then
        cp.open = false
    end
    imgui.End()
end

function VIS.proj(x, y, z)
    if not isPointOnScreen(x, y, z, 0.2) then return nil end
    local sx, sy = convert3DCoordsToScreen(x, y, z)
    return sx, sy
end

-- ---------- события ----------
function VIS.addTracer(o, t, key)
    if not O.trc_on then return end
    if #VIS.tr > 64 then table.remove(VIS.tr, 1) end
    VIS.tr[#VIS.tr + 1] = { o.x, o.y, o.z, t.x, t.y, t.z, os.clock(), key }
end
function VIS.addImpact(t)
    if not O.w_misc_bullet_impacts then return end
    if #VIS.hits > 80 then table.remove(VIS.hits, 1) end
    VIS.hits[#VIS.hits + 1] = { t.x, t.y, t.z, os.clock(), imp = true }
end
function VIS.ownShot(data)
    if O.trc_local then VIS.addTracer(data.origin, data.target, 'trc_local') end
    VIS.addImpact(data.target)
end
function VIS.hit(id, dmg)
    local now = os.clock()
    if VIS.lastHit[id] and now - VIS.lastHit[id] < 0.03 then return end
    VIS.lastHit[id] = now
    if not O.w_misc_hit_marker then return end
    VIS.xhHitT = now
    local ok, ped = sampGetCharHandleBySampPlayerId(id)
    if not ok or not doesCharExist(ped) then return end
    local x, y, z = getCharCoordinates(ped)
    if #VIS.hits > 80 then table.remove(VIS.hits, 1) end
    VIS.hits[#VIS.hits + 1] = { x + (math.random() - 0.5) * 0.3, y + (math.random() - 0.5) * 0.3, z + 0.5, now, dmg = dmg }
end
function sampev.onBulletSync(playerId, data)
    TR.T('vis.bullet ' .. tostring(playerId))
    VIS.shot[playerId] = os.clock()
    if data and data.origin and data.target then
        if O.trc_enemies then VIS.addTracer(data.origin, data.target, 'trc_enemies') end
        VIS.addImpact(data.target)
    end
end

-- ---------- CHINA HAT (конус над головой; считаем в main-потоке, рисуем в OnFrame) ----------
function VIS.hatTick(cx, cy, cz)
    VIS.hat = nil
    if not O.hat_on or not doesCharExist(PLAYER_PED) then return end
    local ptr = getCharPointer(PLAYER_PED)
    if not ptr or ptr == 0 then return end
    local hx, hy, hz = VIS.bone(ptr, 8)
    if not hx or (hx == 0 and hy == 0 and hz == 0) then return end
    local d2 = (hx - cx) ^ 2 + (hy - cy) ^ 2 + (hz - cz) ^ 2
    if O.hat_fp and d2 < 0.8 * 0.8 then return end      -- от первого лица шляпа закрыла бы экран
    local r, h = (O.hat_size or 42) / 100, (O.hat_height or 24) / 100
    local bz = hz + 0.14
    local ax, ay = VIS.proj(hx, hy, bz + h)
    if not ax then return end
    local N, spin = 36, os.clock() * 0.8
    local ring, dmin, dmax = {}, math.huge, 0
    for i = 0, N - 1 do
        local a = spin + i / N * 2 * math.pi
        local px, py = hx + math.cos(a) * r, hy + math.sin(a) * r
        local sx, sy = VIS.proj(px, py, bz)
        if not sx then return end
        local d = (px - cx) ^ 2 + (py - cy) ^ 2 + (bz - cz) ^ 2
        dmin, dmax = math.min(dmin, d), math.max(dmax, d)
        ring[i + 1] = { sx, sy, d, i / N }
    end
    local segs, span = {}, math.max(dmax - dmin, 1e-4)
    for i = 1, N do
        local p, q = ring[i], ring[i % N + 1]
        local d = (p[3] + q[3]) * 0.5
        segs[i] = { p, q, d, 1 - (d - dmin) / span }
    end
    table.sort(segs, function(a, b) return a[3] > b[3] end)   -- дальние сначала
    VIS.hat = { ax = ax, ay = ay, ring = ring, segs = segs }
end
function VIS.drawHat(dl)
    local h = VIS.hat
    if not h then return end
    local rb = bit.band(O.rb_mask or 0, VIS.RB.hat_on) ~= 0
    local base, alpha = VIS.rgb('hat_on', true), O.hat_alpha or 130
    local apex = V(h.ax, h.ay)
    for _, s in ipairs(h.segs) do
        local c = rb and VIS.rainbow(s[1][4]) or base
        local k = O.hat_grad and (0.5 + 0.5 * s[4]) or 1
        dl:AddTriangleFilled(apex, V(s[1][1], s[1][2]), V(s[2][1], s[2][2]), C(c[1] * k, c[2] * k, c[3] * k, alpha))
    end
    if O.hat_ol then
        local n = #h.ring
        for i = 1, n do
            local p, q = h.ring[i], h.ring[i % n + 1]
            local c = rb and VIS.rainbow(p[4]) or base
            dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(c[1], c[2], c[3], 255), 1.6)
        end
    end
end

-- ---------- кости (CPed::GetBonePosition 0x5E4280, thiscall) ----------
VIS.boneOut = ffi.new('float[3]')
function VIS.bone(ptr, id)
    if not VIS.getBone then VIS.getBone = ffi.cast('void(__thiscall*)(void*, float*, int, bool)', 0x5E4280) end
    VIS.getBone(ffi.cast('void*', ptr), VIS.boneOut, id, false)
    return VIS.boneOut[0], VIS.boneOut[1], VIS.boneOut[2]
end

-- ---------- CHAMS (цвет материалов RenderWare, GTA SA 1.0 US) ----------
-- 0x749B70 RpClumpForAllAtomics; geometry flags |= 0x40 (MODULATEMATERIALCOLOR); RwRGBA материала по +4.
VIS.atoms = {}
function VIS.chInit()
    if VIS.chOk ~= nil then return VIS.chOk end
    VIS.chOk = pcall(function()
        VIS.forAtomics = ffi.cast('void*(__cdecl*)(void*, void*, void*)', 0x749B70)
        VIS.atomCb = ffi.cast('void*(__cdecl*)(void*, void*)', function(a)
            VIS.atoms[#VIS.atoms + 1] = tonumber(ffi.cast('uint32_t', a))
            return a
        end)
    end)
    return VIS.chOk
end
function VIS.pedMaterials(ped, fn)
    local okp, ptr = pcall(getCharPointer, ped)
    if not okp or not ptr or ptr == 0 then return 0 end
    local clump = rd32(ptr + 0x18)
    if clump == 0 or ffi.cast('uint8_t*', clump)[0] ~= 2 then return -1 end
    for i = #VIS.atoms, 1, -1 do VIS.atoms[i] = nil end
    VIS.forAtomics(ffi.cast('void*', clump), VIS.atomCb, nil)
    local cnt = 0
    for _, a in ipairs(VIS.atoms) do
        local g = rd32(a + 0x18)
        if g ~= 0 then
            local mats = rd32(g + 0x20)
            local n = ffi.cast('int32_t*', g + 0x24)[0]
            if mats ~= 0 and n > 0 and n < 64 then
                for m = 0, n - 1 do
                    local mat = rd32(mats + m * 4)
                    if mat ~= 0 then cnt = cnt + 1; if fn then fn(g, mat) end end
                end
            end
        end
    end
    return cnt
end
if jit then jit.off(VIS.pedMaterials, true) end

-- s = { mode, c, c2, tex, light, br, alpha, spd }
function VIS.chGet(set)
    local id = set.id
    return { mode = O[set.mk] or 0, c = VIS.rgb(set.ck), c2 = VIS.rgb(id .. '_c2'), tex = O[id .. '_tex'] or 1,
             light = O[id .. '_light'] or 1, br = (O[id .. '_br'] or 100) / 100, alpha = O[id .. '_alpha'] or 255,
             spd = (O[id .. '_spd'] or 6) / 6 }
end
function VIS.lerpc(a, b, k) return a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k end
function VIS.chamsColor(s, now, mi, mn, hp)
    local mode, c, c2 = s.mode, s.c, s.c2
    local t = now * s.spd
    local r, g, b = c[1], c[2], c[3]
    local a = math.min(c[4] or 255, s.alpha)
    local fr = mn > 1 and mi / (mn - 1) or 0
    if mode == 2 then r, g, b = r * 1.35, g * 1.35, b * 1.35
    elseif mode == 3 then
        local k = t * 2.2 + mi * 0.6
        r = 128 + 127 * math.sin(k); g = 128 + 127 * math.sin(k + 2.09); b = 128 + 127 * math.sin(k + 4.19)
    elseif mode == 4 then a = math.min(a, 110)
    elseif mode == 5 then
        local p = 0.55 + 0.45 * math.sin(t * 5)
        r, g, b = r * p + 90 * (1 - p), g * p + 90 * (1 - p), b * p + 90 * (1 - p)
    elseif mode == 6 then r, g, b = VIS.lerpc(c, c2, 0.5 + 0.5 * math.sin(t * 4))
    elseif mode == 7 then local q = VIS.rainbow(mi * 0.08 + t * 0.1); r, g, b = q[1], q[2], q[3]
    elseif mode == 8 then r, g, b = VIS.lerpc(c, c2, fr)
    elseif mode == 9 then if math.floor(t * 8) % 2 == 0 then r, g, b = c2[1], c2[2], c2[3] end
    elseif mode == 10 then local p = 0.75 + 0.5 * math.max(0, math.sin(t * 2 + mi)); r, g, b = r * p, g * p, b * p
    elseif mode == 11 then a = math.min(a, 50 + 40 * math.sin(t * 3))
    elseif mode == 12 then
        local k = 0.5 + 0.5 * math.sin(t * 1.5 + fr * 3)
        if k < 0.5 then r, g, b = 255 * k * 2, 40 * k, 0 else r, g, b = 255, 40 + 215 * (k - 0.5) * 2, 120 * (k - 0.5) * 2 end
    elseif mode == 13 then local k = clamp((hp or 100) / 100, 0, 1); r, g, b = 255 * math.min(1, 2 * (1 - k)), 255 * math.min(1, 2 * k), 60
    elseif mode == 14 then if mi % 2 == 1 then r, g, b = c2[1], c2[2], c2[3] end
    elseif mode == 15 then r, g, b = VIS.lerpc(c, c2, 0.5 + 0.5 * math.sin(t * 3 + fr * 6.28))
    elseif mode == 16 then
        local k = 0.5 + 0.5 * math.sin(t * 9 + mi * 1.3) * math.sin(t * 5.3)
        r, g, b = 255, 60 + 170 * k, 20 * k
    elseif mode == 17 then local k = 0.5 + 0.5 * math.sin(t * 2 + mi); r, g, b = 140 + 80 * k, 210 + 45 * k, 255; a = math.min(a, 200)
    elseif mode == 18 then
        local k = 0.5 + 0.5 * math.sin(t * 1.2 + mi * 0.9)
        r, g, b = 60 + 120 * k, 20 + 40 * (1 - k), 140 + 115 * k
    elseif mode == 19 then local k = 0.5 + 0.5 * math.sin(t * 6 + mi); r, g, b = 90 + 60 * k, 255, 40 + 40 * k
    end
    local br = s.br
    return math.floor(clamp(r * br, 0, 255)), math.floor(clamp(g * br, 0, 255)), math.floor(clamp(b * br, 0, 255)), math.floor(clamp(a, 0, 255))
end
VIS.LIGHTS = { false, { 2.5, 0, 1 }, { 6, 0, 0 }, { 0.25, 0, 0.35 }, { 10, 1, 1 } }
VIS.matN = {}
function VIS.paintPed(ped, s, now, hp)
    local ch = VIS.ch
    local mode = s and s.mode or 0
    local notex = mode > 0 and s.tex == 1 and mode ~= 4 and mode ~= 11
    local lt = mode > 0 and VIS.LIGHTS[(s.light or 0) + 1] or false
    if mode == 10 and not lt then lt = { 1.5, 1, 1 } end
    local mi, mn = 0, VIS.matN[ped] or 8
    local n = VIS.pedMaterials(ped, function(g, mat)
        local c = ffi.cast('uint8_t*', mat + 4)
        local tex = ffi.cast('uint32_t*', mat)
        local sp = ffi.cast('float*', mat + 0x0C)
        if mode == 0 then
            local o = ch.orig[mat]
            if o then
                c[0], c[1], c[2], c[3] = o[1], o[2], o[3], o[4]
                tex[0] = o.tex; sp[0], sp[1], sp[2] = o.a, o.s, o.d
                ch.orig[mat] = nil
            end
            local f = ch.gflag[g]
            if f then ffi.cast('uint32_t*', g + 8)[0] = f; ch.gflag[g] = nil end
            return
        end
        if not ch.orig[mat] then ch.orig[mat] = { c[0], c[1], c[2], c[3], tex = tex[0], a = sp[0], s = sp[1], d = sp[2] } end
        if not ch.gflag[g] then ch.gflag[g] = ffi.cast('uint32_t*', g + 8)[0] end
        local o = ch.orig[mat]
        ffi.cast('uint32_t*', g + 8)[0] = bit.bor(ch.gflag[g], 0x40)
        c[0], c[1], c[2], c[3] = VIS.chamsColor(s, now, mi, mn, hp)
        tex[0] = notex and 0 or o.tex
        if lt then sp[0], sp[1], sp[2] = lt[1], lt[2], lt[3] else sp[0], sp[1], sp[2] = o.a, o.s, o.d end
        mi = mi + 1
    end)
    if n and n > 0 then VIS.matN[ped] = n end
    return n
end
function VIS.restoreAll()
    if not VIS.chOk or not VIS.ch.dirty then return end
    TR.T('vis.chams.restore')
    for id = 0, sampGetMaxPlayerId(false) do
        local ok, ped = sampGetCharHandleBySampPlayerId(id)
        if ok and doesCharExist(ped) then pcall(VIS.paintPed, ped, nil) end
    end
    if doesCharExist(PLAYER_PED) then pcall(VIS.paintPed, PLAYER_PED, nil) end
    VIS.ch.orig, VIS.ch.gflag, VIS.ch.dirty, VIS.localPainted = {}, {}, false, false
end
function VIS.chamsTick(ready, now)
    local sV, sH, sS = VIS.chGet(VIS.SUB_CH_VIS), VIS.chGet(VIS.SUB_CH_HID), VIS.chGet(VIS.SUB_CH_SHOT)
    local sT, sL = VIS.chGet(VIS.SUB_CH_TEAM), VIS.chGet(VIS.SUB_CH_LOC)
    local want = ready and ((O.pl_enemy_enabled and (sV.mode + sH.mode + sS.mode + sT.mode) > 0) or sL.mode > 0)
    if not want then VIS.restoreAll(); return end
    if now - VIS.ch.last < 0.03 or not VIS.chInit() then return end
    VIS.ch.last = now
    TR.T('vis.chams')
    if sL.mode > 0 then
        VIS.ch.dirty, VIS.localPainted = true, true
        pcall(VIS.paintPed, PLAYER_PED, sL, now, getCharHealth(PLAYER_PED))
    elseif VIS.localPainted then
        VIS.localPainted = false
        pcall(VIS.paintPed, PLAYER_PED, nil)
    end
    if not O.pl_enemy_enabled then return end
    local myModel = getCharModel(PLAYER_PED)
    for _, e in ipairs(VIS.list) do
        if doesCharExist(e.ped) then
            local s = sV
            if not e.vis and sH.mode > 0 then s = sH end
            if e.team then s = sT end
            if sS.mode > 0 and VIS.shot[e.id] and now - VIS.shot[e.id] < 0.3 then s = sS end
            -- геометрия общая на скин: покраска врага с вашим скином покрасит и вас.
            -- Такого врага не красим (рисуем ему оверлей), а свою модель держим в оригинале / в своих чамсах.
            e.sameSkin = getCharModel(e.ped) == myModel
            if e.sameSkin and (not O.chm_same or sL.mode > 0) then s = nil end
            if s and s.mode > 0 then VIS.ch.dirty = true else s = nil end
            if not (e.sameSkin and sL.mode > 0) then
                pcall(VIS.paintPed, e.ped, s, now, e.hp or sampGetPlayerHealth(e.id))
            end
        end
    end
    -- страховка: своя модель всегда в оригинале, если свои чамсы выключены и красить свой скин не просили
    if sL.mode == 0 and not O.chm_same then pcall(VIS.paintPed, PLAYER_PED, nil) end
end
function VIS.diag()
    local ok = VIS.chInit()
    chat('chams init: ' .. tostring(ok) .. ', игроков в списке: ' .. #VIS.list .. ', timecycle: ' .. tostring(VIS.tcState))
    local e = VIS.list[1]
    if not e then chat('рядом нет игроков (включи Игроки -> Включено)'); return end
    local okm, n = pcall(VIS.pedMaterials, e.ped)
    chat(('id %d: материалов %s, скин %d (твой %d)'):format(e.id, tostring(n), getCharModel(e.ped), getCharModel(PLAYER_PED)))
end

-- ---------- оверлей-чамсы сквозь стены (2D по костям) ----------
VIS.SIL_LINKS = { { 8, 5, 0.9 }, { 5, 3, 1.5 }, { 3, 2, 1.5 }, { 22, 23, 0.75 }, { 23, 24, 0.65 }, { 32, 33, 0.75 }, { 33, 34, 0.65 },
    { 41, 42, 0.95 }, { 42, 43, 0.8 }, { 51, 52, 0.95 }, { 52, 53, 0.8 }, { 5, 22, 0.8 }, { 5, 32, 0.8 }, { 2, 41, 0.9 }, { 2, 51, 0.9 } }
function VIS.drawSil(dl, e)
    if e.dist > (O.chm_sil_max or 300) then return end
    local b = e.bones
    local st = O.chm_sil_style or 0
    local base = (e.y2 - e.y1) * 0.075 * (O.chm_sil_w or 100) / 100
    local c, c2 = VIS.rgb('chm_sil'), VIS.rgb('chm_sil_c2')
    local cm = O.chm_sil_cm or 0
    if cm == 1 then local k = (e.hp or 100) / 100; c = { 255 * math.min(1, 2 * (1 - k)), 255 * math.min(1, 2 * k), 70, c[4] }
    elseif cm == 2 then c = { e.r, e.g, e.b, c[4] } end
    local a = c[4] or 150
    local t = os.clock() * (O.chm_sil_spd or 6) / 6
    local ytop, ybot = e.y1, e.y2
    local function colAt(y, mul)
        if st == 5 then
            local k = clamp((y - ytop) / math.max(1, ybot - ytop), 0, 1)
            return C(c[1] + (c2[1] - c[1]) * k, c[2] + (c2[2] - c[2]) * k, c[3] + (c2[3] - c[3]) * k, a * mul)
        elseif st == 8 then
            local k = clamp((y - ytop) / math.max(1, ybot - ytop), 0, 1)
            local f = 0.5 + 0.5 * math.sin(t * 9 + y * 0.15)
            return C(255, 80 + 150 * k * f, 30 * k, a * mul * (0.6 + 0.4 * f))
        elseif st == 4 then
            return C(c[1], c[2], c[3], a * mul * (0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 5))))
        end
        return C(c[1], c[2], c[3], a * mul)
    end
    local function bodyPass(wm, mul, joints)
        for _, ln in ipairs(VIS.SIL_LINKS) do
            local p, q = b[ln[1]], b[ln[2]]
            if p and q then
                local w = base * ln[3] * wm
                local col = colAt((p[2] + q[2]) * 0.5, mul)
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), col, w)
                if joints then dl:AddCircleFilled(V(q[1], q[2]), w * 0.5, col, 12) end
            end
        end
        local s1, s2, h1, h2 = b[22], b[32], b[51], b[41]
        if s1 and s2 and h1 and h2 and wm <= 1 then
            dl:AddQuadFilled(V(s1[1], s1[2]), V(s2[1], s2[2]), V(h2[1], h2[2]), V(h1[1], h1[2]), colAt((s1[2] + h1[2]) * 0.5, mul))
        end
        if b[8] then dl:AddCircleFilled(V(b[8][1], b[8][2]), base * 1.05 * wm, colAt(b[8][2], mul), 20) end
    end
    if O.chm_sil_glow or st == 1 then
        local n = st == 1 and 6 or 3
        for i = n, 1, -1 do bodyPass(1 + i * 0.45, 0.07 + 0.03 * (n - i), true) end
    end
    if st == 1 then return end
    if st == 2 then
        bodyPass(1.25, 1, true)
        local dark = C(10, 12, 20, a * 0.85)
        for _, ln in ipairs(VIS.SIL_LINKS) do
            local p, q = b[ln[1]], b[ln[2]]
            if p and q then
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), dark, base * ln[3] * 0.8)
                dl:AddCircleFilled(V(q[1], q[2]), base * ln[3] * 0.4, dark, 12)
            end
        end
        if b[8] then dl:AddCircleFilled(V(b[8][1], b[8][2]), base * 0.8, dark, 20) end
        return
    end
    if st == 3 then
        bodyPass(1, 0.35, true)
        for y = ytop, ybot, 3 do
            local k = (y + t * 40) % 6 < 3 and 1 or 0.3
            dl:AddLine(V(e.x1, y), V(e.x2, y), C(c[1], c[2], c[3], a * 0.08 * k), 1)
        end
        return
    end
    if st == 6 then
        for _, ln in ipairs(VIS.SIL_LINKS) do
            local p, q = b[ln[1]], b[ln[2]]
            if p and q then
                for k = 0, 1, 0.2 do
                    local x, y = p[1] + (q[1] - p[1]) * k, p[2] + (q[2] - p[2]) * k
                    dl:AddCircleFilled(V(x, y), base * 0.35 * (0.7 + 0.3 * math.sin(t * 6 + k * 8)), colAt(y, 1), 8)
                end
            end
        end
        return
    end
    if st == 7 then
        for _, ln in ipairs(VIS.SIL_LINKS) do
            local p, q = b[ln[1]], b[ln[2]]
            if p and q then
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(c2[1], c2[2], c2[3], a), base * 0.55)
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(c[1], c[2], c[3], a), base * 0.3)
                dl:AddCircleFilled(V(q[1], q[2]), base * 0.35, C(c2[1], c2[2], c2[3], a), 10)
            end
        end
        if b[8] then dl:AddCircle(V(b[8][1], b[8][2]), base, C(c[1], c[2], c[3], a), 20, base * 0.3) end
        return
    end
    bodyPass(1, 1, true)
end

-- ---------- заморозка CTimeCycle::Update (0x561760), чтобы игра не перетирала наши цвета ----------
-- Раньше патчился 0x5BBAC0 — это CTimeCycle::Initialise, а не Update: игра каждый кадр
-- пересчитывала m_CurrentColours и затирала своё небо / тени. Update = CalcColoursForPoint(камера).
VIS.TC_UPDATE = 0x561760
function VIS.tcFreeze(on)
    local mem = require 'memory'
    if on == (VIS.tcState == 'frozen') then return end
    if VIS.tcState == 'bad' and on then return end
    local A = VIS.TC_UPDATE
    if on then
        local pre, first = mem.getuint8(A - 1, true), mem.getuint8(A, true)
        if first == 0xC3 or not (pre == 0xCC or pre == 0x90 or pre == 0xC3) then
            chat('небо/тени: адрес CTimeCycle::Update не совпал — версия игры не 1.0 US?')
            VIS.tcState = 'bad'
            return
        end
        VIS.tcOrig = first
        mem.setuint8(A, 0xC3, true)
        VIS.tcState = 'frozen'
    else
        if VIS.tcOrig then mem.setuint8(A, VIS.tcOrig, true) end
        VIS.tcState = 'normal'
    end
end

-- ---------- небо / туман / свет (CTimeCycle::m_CurrentColours 0xB7C4A0, GTA SA 1.0 US) ----------
function VIS.tc16(addr, c)
    local p = ffi.cast('int16_t*', addr)
    p[0], p[1], p[2] = c[1], c[2], c[3]
end
function VIS.tcF(addr, c, alpha, mul)
    local p = ffi.cast('float*', addr)
    mul = mul or 1
    p[0], p[1], p[2] = c[1] * mul, c[2] * mul, c[3] * mul
    if alpha then p[3] = c[4] or 255 end
end
-- CTimeCycle::CalcColoursForPoint(CVector point, CColourSet* set) — 0x5603D0, cdecl, CVector по значению
function VIS.tcRecalc()
    if not VIS.calcColours then
        VIS.calcColours = ffi.cast('void(__cdecl*)(float, float, float, void*)', 0x5603D0)
    end
    local cx, cy, cz = getActiveCameraCoordinates()
    VIS.calcColours(cx, cy, cz, ffi.cast('void*', 0xB7C4A0))
end
function VIS.timecycTick()
    local need = O.fog_on or O.sky_on or O.sun_on or O.cl_on or O.amb_on or O.flt_on or O.wat_on or O.shd_on
    VIS.tcFreeze(need and true or false)
    if not need or VIS.tcState ~= 'frozen' then return end
    -- Update игры заморожен, поэтому каждый кадр сами считаем «родные» цвета (время суток, погода, зоны)
    -- и поверх пишем только включённые опции. Выключил опцию — сразу вернулись игровые значения,
    -- а не застывшие последние.
    VIS.tcRecalc()
    if O.fog_on then
        ffi.cast('float*', 0xB7C4F0)[0] = O.fog_far or 900
        ffi.cast('float*', 0xB7C4F4)[0] = math.min(O.fog_start or 250, (O.fog_far or 900) - 10)
    end
    if O.sky_on then
        VIS.tc16(0xB7C4C4, VIS.rgb('sky_top'))
        local b = VIS.rgb('sky_bot')
        VIS.tc16(0xB7C4CA, b)
        -- цвет «под горизонтом» (низ неба / дальний туман) Update тоже не пересчитает — пишем сами
        local g = ffi.cast('uint8_t*', 0xB7CB10)
        g[0], g[1], g[2] = b[1], b[2], b[3]
    end
    if O.sun_on then
        VIS.tc16(0xB7C4D0, VIS.rgb('sun_core'))
        VIS.tc16(0xB7C4D6, VIS.rgb('sun_halo'))
        ffi.cast('float*', 0xB7C4DC)[0] = O.sun_size or 6
    end
    if O.cl_on then
        VIS.tc16(0xB7C4FC, VIS.rgb('cl_low'))
        VIS.tc16(0xB7C502, VIS.rgb('cl_fluffy'))
        ffi.cast('float*', 0xB7C538)[0] = O.cl_alpha or 200
    end
    if O.amb_on then
        local m = (O.amb_pow or 100) / 100 / 255
        VIS.tcF(0xB7C4A0, VIS.rgb('amb_c'), false, m)
        VIS.tcF(0xB7C4AC, VIS.rgb('amb_c'), false, m)
    end
    if O.flt_on then
        VIS.tcF(0xB7C518, VIS.rgb('flt_c'), true)
        VIS.tcF(0xB7C528, VIS.rgb('flt_c'), true)
    end
    if O.wat_on then VIS.tcF(0xB7C508, VIS.rgb('wat_c'), true) end
    if O.shd_on then
        -- m_nShadowStrength / m_nLightShadowStrength / m_nPoleShadowStrength
        local sp = ffi.cast('int16_t*', 0xB7C4E8)
        sp[0], sp[1], sp[2] = O.shd_val or 160, O.shd_light or 160, O.shd_pole or 160
    end
end

-- ---------- состояние мира (main-поток) ----------
function VIS.worldTick(now)
    local st = VIS.st
    local okt, et = pcall(VIS.timecycTick)
    if not okt and not st.tcErr then st.tcErr = true; TR.T('vis.tc ' .. tostring(et)) end
    if st.nv ~= (O.v_nv or false) then st.nv = O.v_nv or false; pcall(setNightVision, st.nv) end
    if st.ir ~= (O.v_ir or false) then st.ir = O.v_ir or false; pcall(setInfraredVision, st.ir) end
    if st.hud ~= (O.hud_hide or false) then st.hud = O.hud_hide or false; pcall(displayHud, not st.hud) end
    if st.radar ~= (O.hud_radar or false) then st.radar = O.hud_radar or false; pcall(displayRadar, not st.radar) end
    if O.wt_on then
        if st.w == nil then st.wOrig = VIS.srvWeather or ffi.cast('int16_t*', 0xC81320)[0] end
        if st.w ~= O.wt_weather or now - (st.wt or 0) > 2 then
            st.w, st.wt = O.wt_weather, now
            pcall(forceWeatherNow, VIS.WEATHER_ID[O.wt_weather + 1] or 1)
        end
    elseif st.w ~= nil then
        -- выключили: возвращаем погоду сервера (или ту, что была до включения)
        st.w = nil
        pcall(forceWeatherNow, VIS.srvWeather or st.wOrig or 1)
    end
    if O.wt_time_on then
        if not st.tOn then
            st.tOn = true
            local okt, h, m = pcall(getTimeOfDay)
            st.tOrig = okt and { h, m } or nil
        end
        pcall(setTimeOfDay, O.wt_hour or 12, O.wt_min or 0)
    elseif st.tOn then
        st.tOn = false
        local t = VIS.srvTime or st.tOrig
        if t then pcall(setTimeOfDay, t[1], t[2] or 0) end
    end
    if O.v_fov_on and doesCharExist(PLAYER_PED) then
        local w = getCurrentCharWeapon(PLAYER_PED)
        local scoped = isKeyDown(0x02) and (w == 34 or w == 35 or w == 36 or w == 43)
        if not scoped then pcall(cameraSetLerpFov, O.v_fov, O.v_fov, 1000, true) end
        st.fov = true
    elseif st.fov then
        -- выключили Override FOV: снимаем зафиксированный скриптом FOV
        st.fov = false
        pcall(cameraResetNewScriptables)
        pcall(cameraSetLerpFov, 70, 70, 100, false)
    end
end
-- запоминаем, что ставит сервер, чтобы вернуть это при выключении оверрайдов
function sampev.onSetWeather(id) VIS.srvWeather = id end
function sampev.onSetPlayerTime(h, m) VIS.srvTime = { h, m } end
function sampev.onSetWorldTime(h) VIS.srvTime = { h, 0 } end

-- ---------- сбор данных игроков ----------
function VIS.collectPlayers(now, cx, cy, cz, fx, fy)
    local list = {}
    local myId = RG.myId()
    local okc, myCol = pcall(sampGetPlayerColor, myId)
    local maxd = O.esp_maxdist or 300
    for id = 0, sampGetMaxPlayerId(false) do
        if id ~= myId and sampIsPlayerConnected(id) then
            local ok, ped = sampGetCharHandleBySampPlayerId(id)
            if ok and doesCharExist(ped) then
                local x, y, z = getCharCoordinates(ped)
                local dead = isCharDead(ped) or sampGetPlayerHealth(id) <= 0
                if VIS.alive[id] and dead then
                    if O.pl_model_soul_particles then VIS.souls[#VIS.souls + 1] = { x, y, z, now, seed = math.random() * 10 } end
                    if O.sc_kill and VIS.lastHit[id] and now - VIS.lastHit[id] < 3 then
                        local okn, nm = pcall(sampGetPlayerNickname, id)
                        VIS.killT, VIS.killName = now, (okn and nm) and u8(nm) or '?'
                    end
                end
                VIS.alive[id] = not dead
                local okpc, pc = pcall(sampGetPlayerColor, id)
                pc = okpc and pc or 0xFFFFFFFF
                local team = okc and pc == myCol
                local dx, dy, dz = x - cx, y - cy, z - cz
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if not dead and dist <= maxd and (O.esp_team or not team) then
                    local e = { id = id, ped = ped, dist = dist, team = team }
                    local l = VIS.los[id]
                    if not l or now - l.t > 0.15 then
                        TR.T('vis.los')
                        l = { t = now, v = isLineOfSightClear(cx, cy, cz, x, y, z + 0.6, true, false, false, true, false) }
                        VIS.los[id] = l
                    end
                    e.vis = l.v
                    if not O.esp_vis_only or e.vis then
                        local hx, hy = VIS.proj(x, y, z + 0.95)
                        local bx, by = VIS.proj(x, y, z - 1.0)
                        if hx and bx then
                            e.on = true
                            local h = math.max(by - hy, 8)
                            local w = h * 0.42
                            local mx = (hx + bx) * 0.5
                            e.x1, e.y1, e.x2, e.y2 = mx - w * 0.5, hy - h * 0.08, mx + w * 0.5, by
                            local okn, nm = pcall(sampGetPlayerNickname, id)
                            e.name = (okn and nm) and u8(nm) or '?'
                            e.r, e.g, e.b = bit.band(bit.rshift(pc, 16), 255), bit.band(bit.rshift(pc, 8), 255), bit.band(pc, 255)
                            e.hp = math.max(0, math.min(100, sampGetPlayerHealth(id)))
                            e.ar = math.max(0, math.min(100, sampGetPlayerArmor(id)))
                            e.wid = getCurrentCharWeapon(ped)
                            local vx, vy, vz = getCharVelocity(ped)
                            e.speed = math.sqrt(vx * vx + vy * vy + vz * vz) * 3.6
                            local fl = O.esp_flags or 0
                            if fl ~= 0 then
                                local fls = {}
                                if bit.band(fl, 1) ~= 0 and sampIsPlayerPaused(id) then fls[#fls + 1] = { 'AFK', 255, 200, 80 } end
                                if bit.band(fl, 2) ~= 0 then
                                    local okp, ping = pcall(sampGetPlayerPing, id)
                                    if okp then fls[#fls + 1] = { ping .. 'ms', 170, 200, 255 } end
                                end
                                if bit.band(fl, 4) ~= 0 then fls[#fls + 1] = { 'skin ' .. getCharModel(ped), 200, 200, 210 } end
                                if bit.band(fl, 8) ~= 0 and not e.vis then fls[#fls + 1] = { 'WALL', 255, 120, 140 } end
                                if bit.band(fl, 16) ~= 0 and e.speed > 2 then fls[#fls + 1] = { math.floor(e.speed) .. 'km/h', 160, 255, 190 } end
                                e.flags = fls
                            end
                            -- скелет / точка головы / направление взгляда
                            local okp, ptr = pcall(getCharPointer, ped)
                            if okp and ptr and ptr ~= 0 and (O.esp_skel or O.esp_headdot or O.esp_look or O.chm_sil or (O.pl_model_player or 0) > 0 or (O.pl_model_behind_walls or 0) > 0) then
                                local bones = {}
                                for _, bid in ipairs(VIS.BONE_IDS) do
                                    local okb, bx3, by3, bz3 = pcall(VIS.bone, ptr, bid)
                                    if okb and math.abs(bx3 - x) < 3 and math.abs(by3 - y) < 3 and math.abs(bz3 - z) < 3 then
                                        local sx, sy = VIS.proj(bx3, by3, bz3)
                                        bones[bid] = sx and { sx, sy } or false
                                        if bid == 8 then e.head3 = { bx3, by3, bz3 } end
                                    end
                                end
                                e.bones = bones
                                if O.esp_look and e.head3 then
                                    local hd = math.rad(getCharHeading(ped))
                                    local ex, ey = e.head3[1] - math.sin(hd) * 2.5, e.head3[2] + math.cos(hd) * 2.5
                                    local sx, sy = VIS.proj(ex, ey, e.head3[3])
                                    e.look = sx and { sx, sy } or nil
                                end
                            end
                            if (O.esp_box_style or 0) == 3 then
                                local hd = math.rad(getCharHeading(ped))
                                local fx2, fy2, rx2, ry2 = -math.sin(hd) * 0.35, math.cos(hd) * 0.35, math.cos(hd) * 0.35, math.sin(hd) * 0.35
                                local pts = {}
                                for _, zz in ipairs({ z - 1.0, z + 0.9 }) do
                                    for _, sgn in ipairs({ { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }) do
                                        local sx, sy = VIS.proj(x + fx2 * sgn[1] + rx2 * sgn[2], y + fy2 * sgn[1] + ry2 * sgn[2], zz)
                                        pts[#pts + 1] = sx and { sx, sy } or false
                                    end
                                end
                                e.box3 = pts
                            end
                            if O.pl_enemy_sounds and e.speed > 4 then
                                local k = (now * 1.1 + id * 0.137) % 1
                                local rad = 0.35 + 0.9 * k
                                local pts = {}
                                for i = 0, 17 do
                                    local a = i / 18 * math.pi * 2
                                    local sx, sy = VIS.proj(x + math.cos(a) * rad, y + math.sin(a) * rad, z - 0.95)
                                    pts[#pts + 1] = sx and { sx, sy } or false
                                end
                                e.ring, e.ringA = pts, 1 - k
                            end
                        elseif O.pl_enemy_offscreen_arrow then
                            local rx, ry = fy, -fx
                            local f, r = dx * fx + dy * fy, dx * rx + dy * ry
                            local al = math.sqrt(f * f + r * r); if al < 0.001 then al = 1 end
                            e.ax, e.ay = r / al, -f / al
                        end
                        list[#list + 1] = e
                    end
                end
            end
        end
    end
    return list
end

-- ---------- мир: машины / пикапы / объекты / NPC ----------
function VIS.box3d(x, y, z, hd, mn, mx)
    local c, s = math.cos(hd), math.sin(hd)
    local pts = {}
    for _, zz in ipairs({ mn[3], mx[3] }) do
        for _, p in ipairs({ { mn[1], mn[2] }, { mx[1], mn[2] }, { mx[1], mx[2] }, { mn[1], mx[2] } }) do
            local wx, wy = x + p[1] * c - p[2] * s, y + p[1] * s + p[2] * c
            local sx, sy = VIS.proj(wx, wy, z + zz)
            if not sx then return nil end
            pts[#pts + 1] = { sx, sy }
        end
    end
    return pts
end
function VIS.collectWorld(now, cx, cy, cz)
    local veh = {}
    if O.ve_on then
        local myCar = isCharInAnyCar(PLAYER_PED) and storeCarCharIsInNoSave(PLAYER_PED) or nil
        local okv, cars = pcall(getAllVehicles)
        if okv and cars then
            for _, car in ipairs(cars) do
                if car ~= myCar and doesVehicleExist(car) then
                    local x, y, z = getCarCoordinates(car)
                    local d = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2)
                    if d <= (O.ve_max or 150) then
                        local drv = getDriverOfCar(car)
                        local hasDrv = drv and drv ~= -1 and doesCharExist(drv)
                        if not (O.ve_empty and hasDrv) then
                            local sx, sy = VIS.proj(x, y, z)
                            if sx then
                                local model = getCarModel(car)
                                local e = { sx = sx, sy = sy, dist = d, hp = getCarHealth(car) }
                                local dm = VIS.dims[model]
                                if not dm then
                                    local okd, a1, a2, a3, b1, b2, b3 = pcall(getModelDimensions, model)
                                    dm = okd and { { a1, a2, a3 }, { b1, b2, b3 } } or { { -1, -2.2, -0.8 }, { 1, 2.2, 0.9 } }
                                    local okn, gxt = pcall(getNameOfVehicleModel, model)
                                    local okt, txt = false, nil
                                    if okn and gxt then okt, txt = pcall(getGxtText, gxt) end
                                    dm.name = (okt and txt and txt ~= '') and u8(txt) or ('#' .. model)
                                    VIS.dims[model] = dm
                                end
                                e.name = dm.name
                                if (O.ve_box or 0) > 0 then
                                    e.pts = VIS.box3d(x, y, z, math.rad(getCarHeading(car)), dm[1], dm[2])
                                end
                                if hasDrv and O.ve_driver then
                                    local okid, pid = sampGetPlayerIdByCharHandle(drv)
                                    if okid then
                                        local okn, nm = pcall(sampGetPlayerNickname, pid)
                                        e.driver = (okn and nm) and (u8(nm) .. ' [' .. pid .. ']') or nil
                                    end
                                end
                                veh[#veh + 1] = e
                            end
                        end
                    end
                end
            end
        end
    end
    VIS.veh = veh

    -- пикапы SA-MP: полный обход раз в 0.5 с
    if O.pk_on then
        if now - (VIS.pkScan or 0) > 0.5 then
            VIS.pkScan = now
            local raw = {}
            for i = 0, 4095 do
                local okh, hnd = pcall(sampGetPickupHandleBySampId, i)
                if okh and hnd and hnd ~= 0 and hnd ~= -1 then
                    local okc, x, y, z = pcall(getPickupCoordinates, hnd)
                    if okc and x then
                        local okm, model = pcall(sampGetPickupModelTypeBySampId, i)
                        raw[#raw + 1] = { x, y, z, okm and model or 0 }
                    end
                end
            end
            VIS.pkRaw = raw
        end
        local pk = {}
        for _, p in ipairs(VIS.pkRaw or {}) do
            local d = math.sqrt((p[1] - cx) ^ 2 + (p[2] - cy) ^ 2 + (p[3] - cz) ^ 2)
            if d <= (O.pk_max or 100) then
                local sx, sy = VIS.proj(p[1], p[2], p[3])
                if sx then pk[#pk + 1] = { sx, sy, d, p[4] } end
            end
        end
        VIS.pk = pk
    else VIS.pk = {} end

    local obj = {}
    if O.ob_on then
        local oko, objs = pcall(getAllObjects)
        if oko and objs then
            local lim, maxd = O.ob_lim or 60, O.ob_max or 40
            for _, h in ipairs(objs) do
                if #obj >= lim then break end
                local okc, ok2, x, y, z = pcall(getObjectCoordinates, h)
                if okc and ok2 and x then
                    local d = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2)
                    if d <= maxd then
                        local sx, sy = VIS.proj(x, y, z)
                        if sx then
                            local okm, m = pcall(getObjectModel, h)
                            obj[#obj + 1] = { sx, sy, d, okm and m or 0 }
                        end
                    end
                end
            end
        end
    end
    VIS.obj = obj

    local act = {}
    if O.es_actors then
        local okp, peds = pcall(getAllChars)
        if okp and peds then
            for _, ped in ipairs(peds) do
                if ped ~= PLAYER_PED and doesCharExist(ped) and not isCharDead(ped) then
                    local isPl = sampGetPlayerIdByCharHandle(ped)
                    if not isPl then
                        local x, y, z = getCharCoordinates(ped)
                        local hx, hy = VIS.proj(x, y, z + 0.95)
                        local bx, by = VIS.proj(x, y, z - 1.0)
                        if hx and bx then
                            local h = math.max(by - hy, 8)
                            act[#act + 1] = { (hx + bx) * 0.5, hy, by, h * 0.42, math.floor(getCharHealth(ped)),
                                math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2) }
                        end
                    end
                end
            end
        end
    end
    VIS.act = act
end

-- ---------- BACKTRACK: призрак повторяет путь врага с задержкой; выстрел по призраку = урон по врагу ----------
VIS.bt, VIS.ghosts = {}, {}
VIS.BT_PTS = { 8, 5, 3, 2, 22, 23, 24, 32, 33, 34, 41, 42, 43, 51, 52, 53 }
function VIS.btRecord(now)
    if not O.bt_on then VIS.bt = {}; return end
    local keep = (O.bt_time or 400) / 1000 + 0.15
    local myId = RG.myId()
    local seen = {}
    for id = 0, sampGetMaxPlayerId(false) do
        if id ~= myId and sampIsPlayerConnected(id) then
            local ok, ped = sampGetCharHandleBySampPlayerId(id)
            if ok and doesCharExist(ped) and not isCharDead(ped) then
                seen[id] = true
                local h = VIS.bt[id]
                if not h then h = { recs = {}, last = 0 }; VIS.bt[id] = h end
                if now - h.last >= 0.03 then
                    h.last = now
                    local x, y, z = getCharCoordinates(ped)
                    local rec = { t = now, x = x, y = y, z = z, b = {} }
                    local okp, ptr = pcall(getCharPointer, ped)
                    if okp and ptr and ptr ~= 0 then
                        for _, bid in ipairs(VIS.BT_PTS) do
                            local okb, bx, by, bz = pcall(VIS.bone, ptr, bid)
                            if okb and math.abs(bx - x) < 3 and math.abs(by - y) < 3 and math.abs(bz - z) < 3 then
                                rec.b[bid] = { bx, by, bz }
                            end
                        end
                    end
                    local r = h.recs
                    r[#r + 1] = rec
                    while #r > 0 and now - r[1].t > keep do table.remove(r, 1) end
                end
            end
        end
    end
    for id in pairs(VIS.bt) do if not seen[id] then VIS.bt[id] = nil end end
end
-- запись «призрака»: та, что была bt_time назад
function VIS.btGhost(h, now)
    local target = now - (O.bt_time or 400) / 1000
    local best, bd = nil, 1e9
    for _, r in ipairs(h.recs) do
        local d = math.abs(r.t - target)
        if d < bd then best, bd = r, d end
    end
    return best
end
function VIS.btProject(now)
    local gs = {}
    if O.bt_on and VIS.ready then
        for id, h in pairs(VIS.bt) do
            local g = VIS.btGhost(h, now)
            local cur = h.recs[#h.recs]
            if g and cur and ((g.x - cur.x) ^ 2 + (g.y - cur.y) ^ 2 + (g.z - cur.z) ^ 2) > 0.04 then
                local e = { id = id, bones = {} }
                for bid, p in pairs(g.b) do
                    local sx, sy = VIS.proj(p[1], p[2], p[3])
                    e.bones[bid] = sx and { sx, sy } or false
                end
                local hx, hy = VIS.proj(g.x, g.y, g.z + 0.95)
                local fx, fy = VIS.proj(g.x, g.y, g.z - 1.0)
                if hx and fx then
                    local hh = math.max(fy - hy, 8)
                    e.x1, e.y1, e.x2, e.y2 = (hx + fx) * 0.5 - hh * 0.21, hy, (hx + fx) * 0.5 + hh * 0.21, fy
                end
                if O.bt_trail then
                    local tr = {}
                    for _, r in ipairs(h.recs) do
                        if r.t <= now and r.t >= g.t then
                            local sx, sy = VIS.proj(r.x, r.y, r.z - 0.9)
                            tr[#tr + 1] = sx and { sx, sy } or false
                        end
                    end
                    e.trail = tr
                end
                gs[#gs + 1] = e
            end
        end
    end
    VIS.ghosts = gs
end
-- расстояние от точки до луча
function VIS.rayDist0(ox, oy, oz, dx, dy, dz, px, py, pz)
    local vx, vy, vz = px - ox, py - oy, pz - oz
    local t = vx * dx + vy * dy + vz * dz
    if t < 0.5 then return 1e9, t end
    local cx, cy, cz = ox + dx * t - px, oy + dy * t - py, oz + dz * t - pz
    return math.sqrt(cx * cx + cy * cy + cz * cz), t
end
VIS.rayDist = VIS.rayDist0
function VIS.btShot(data)
    if not O.bt_on or not spawnedAt then return end
    if data.targetType == 1 then return end             -- уже попали в живого игрока (или сработал тихий аим)
    local w = getCurrentCharWeapon(PLAYER_PED)
    local dmg = RG.DMG[w]
    if not dmg then return end
    local ox, oy, oz, dx, dy, dz = RG.cam()
    if data.origin and data.target then      -- реальная линия выстрела (прицел в 3-м лице смещён от центра)
        local vx, vy, vz = data.target.x - data.origin.x, data.target.y - data.origin.y, data.target.z - data.origin.z
        local n = math.sqrt(vx * vx + vy * vy + vz * vz)
        if n > 0.1 then ox, oy, oz, dx, dy, dz = data.origin.x, data.origin.y, data.origin.z, vx / n, vy / n, vz / n end
    end
    local rad = O.bt_radius or 0.55
    local now = os.clock()
    local best, bestT, bestHead = nil, 1e9, false
    for id, h in pairs(VIS.bt) do
        local recs = (O.bt_mode or 0) == 1 and h.recs or { VIS.btGhost(h, now) }
        for _, r in ipairs(recs) do
            if r then
                local pts = { { r.x, r.y, r.z, false }, { r.x, r.y, r.z + 0.45, false }, { r.x, r.y, r.z - 0.5, false } }
                if r.b[8] then pts[#pts + 1] = { r.b[8][1], r.b[8][2], r.b[8][3], true } else pts[#pts + 1] = { r.x, r.y, r.z + 0.7, true } end
                for _, p in ipairs(pts) do
                    local d, t = VIS.rayDist(ox, oy, oz, dx, dy, dz, p[1], p[2], p[3])
                    local lim = p[4] and rad * 0.6 or rad
                    if d < lim and t < bestT and t < 300 then best, bestT, bestHead = id, t, p[4] end
                end
            end
        end
    end
    if not best then return end
    local ok, ped = sampGetCharHandleBySampPlayerId(best)
    if not ok or not doesCharExist(ped) then return end
    local x, y, z = getCharCoordinates(ped)
    local tz = z + (bestHead and 0.68 or 0.3)
    data.targetType, data.targetId = 1, best
    data.target.x, data.target.y, data.target.z = x, y, tz
    data.center.x, data.center.y, data.center.z = 0, 0, tz - z
    local bp = bestHead and 9 or 3
    TR.T('bt.hit ' .. best)
    if O.bt_damage ~= false then
        lua_thread.create(function()
            if not sampIsPlayerConnected(best) then return end
            sampSendGiveDamage(best, dmg, w, bp)
            pcall(VIS.hit, best, dmg)
            if O.m_feat_hit_sound then addOneOffSound(0.0, 0.0, 0.0, 17802) end
        end)
    end
    if bit.band(O.m_feat_log_events or 0, 1) ~= 0 then
        local okn, nm = pcall(sampGetPlayerNickname, best)
        chat(('backtrack {3DE07A}%.1f{FFFFFF} -> %s[%d]'):format(dmg, okn and nm or '?', best))
    end
end
function VIS.drawGhosts(dl)
    local c = VIS.rgb('bt_ghost')
    local st = O.bt_style or 0
    for _, e in ipairs(VIS.ghosts) do
        if e.trail then
            for i = 1, #e.trail - 1 do
                local p, q = e.trail[i], e.trail[i + 1]
                if p and q then dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, 70 + 150 * i / #e.trail), 2) end
            end
        end
        if st == 0 then
            for _, ln in ipairs(VIS.LINKS) do
                local p, q = e.bones[ln[1]], e.bones[ln[2]]
                if p and q then
                    dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, 60), 5)
                    dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, 230), 1.6)
                end
            end
            local hb = e.bones[8]
            if hb and e.y1 then dl:AddCircle(V(hb[1], hb[2]), math.max(3, (e.y2 - e.y1) * 0.065), VIS.C(c, 230), 16, 1.6) end
        elseif st == 1 and e.y1 then
            local save = { e.y1, e.y2 }
            local fake = { bones = e.bones, x1 = e.x1, y1 = e.y1, x2 = e.x2, y2 = e.y2, dist = 0, hp = 100, r = c[1], g = c[2], b = c[3] }
            local oc = O.chm_sil_rgb
            O.chm_sil_rgb = c.v or O.chm_sil_rgb
            pcall(VIS.drawSil, dl, fake)
            O.chm_sil_rgb = oc
        elseif st == 2 and e.y1 then
            dl:AddRect(V(e.x1, e.y1), V(e.x2, e.y2), VIS.C(c, 230), 4, 15, 1.5)
            dl:AddRectFilled(V(e.x1, e.y1), V(e.x2, e.y2), VIS.C(c, 40), 4)
        end
    end
end

-- ---------- сбор всего (main-поток, каждый кадр) ----------
function VIS.tick(ready)
    local now = os.clock()
    VIS.sw, VIS.sh = getScreenResolution()
    VIS.ready = ready
    VIS.worldTick(now)
    if ready then pcall(VIS.btRecord, now) else VIS.bt = {} end
    local cx, cy, cz = getActiveCameraCoordinates()
    local px, py, pz = getActiveCameraPointAt()
    local fx, fy = px - cx, py - cy
    local fl = math.sqrt(fx * fx + fy * fy); if fl < 0.001 then fl = 1 end
    fx, fy = fx / fl, fy / fl
    if ready and O.pl_enemy_enabled then
        TR.T('vis.collect')
        VIS.list = VIS.collectPlayers(now, cx, cy, cz, fx, fy)
    else VIS.list = {} end
    if ready then
        TR.T('vis.world')
        VIS.collectWorld(now, cx, cy, cz)
    else VIS.veh, VIS.pk, VIS.obj, VIS.act = {}, {}, {}, {} end

    -- HUD-данные
    local myId = RG.myId()
    if myId >= 0 then
        local okn, nm = pcall(sampGetPlayerNickname, myId)
        local okp, ping = pcall(sampGetPlayerPing, myId)
        VIS.myName, VIS.myPing = (okn and nm) and u8(nm) or '', okp and ping or 0
    end
    if doesCharExist(PLAYER_PED) then
        local vx, vy, vz = getCharVelocity(PLAYER_PED)
        if isCharInAnyCar(PLAYER_PED) then
            local okc, car = pcall(storeCarCharIsInNoSave, PLAYER_PED)
            if okc and car then VIS.mySpeed = getCarSpeed(car) * 3.6 else VIS.mySpeed = 0 end
        else VIS.mySpeed = math.sqrt(vx * vx + vy * vy) * 3.6 end
        VIS.myWeapon = getCurrentCharWeapon(PLAYER_PED)
    end
    local mx, my = ffi.cast('float*', 0xB6EC14)[0], ffi.cast('float*', 0xB6EC10)[0]
    if not (mx > 0.2 and mx < 0.8 and my > 0.2 and my < 0.8) then mx, my = 0.53, 0.4 end
    local w = VIS.myWeapon or 0
    VIS.aiming = isKeyDown(0x02) and w >= 22 and w <= 38
    if VIS.aiming and (w == 34 or w == 35 or w == 36) then mx, my = 0.5, 0.5 end
    if not VIS.aiming then mx, my = 0.5, 0.5 end
    VIS.xhx, VIS.xhy = VIS.sw * mx, VIS.sh * my
    if VIS.aiming and mx ~= 0.5 then VIS.xhx, VIS.xhy = VIS.sw * mx, VIS.sh * my end

    -- трассеры / попадания / души -> экранные координаты
    local dur = O.trc_time or 3
    local dt = {}
    for i = #VIS.tr, 1, -1 do
        local t = VIS.tr[i]
        local age = now - t[7]
        if age > dur then table.remove(VIS.tr, i)
        elseif ready then
            local pts = {}
            for s = 0, 16 do
                local k = s / 16
                local sx, sy = VIS.proj(t[1] + (t[4] - t[1]) * k, t[2] + (t[5] - t[2]) * k, t[3] + (t[6] - t[3]) * k)
                pts[#pts + 1] = sx and { sx, sy } or false
            end
            dt[#dt + 1] = { pts = pts, a = 1 - age / dur, key = t[8], fresh = age < 0.15 }
        end
    end
    VIS.drawTr = dt
    local dh = {}
    local hmLife = O.hm_time or 0.9
    for i = #VIS.hits, 1, -1 do
        local h = VIS.hits[i]
        local age = now - h[4]
        local life = h.imp and dur or hmLife
        if age > life then table.remove(VIS.hits, i)
        elseif ready then
            local sx, sy = VIS.proj(h[1], h[2], h[3] + (h.dmg and age * 0.6 or 0))
            if sx then
                local s2x = h.imp and VIS.proj(h[1] + 0.06, h[2], h[3]) or nil
                dh[#dh + 1] = { sx, sy, a = 1 - age / life, age = age, dmg = h.dmg, imp = h.imp,
                                size = s2x and math.max(2, math.min(9, math.abs(s2x - sx))) or 4 }
            end
        end
    end
    VIS.drawHits = dh
    local ds = {}
    for i = #VIS.souls, 1, -1 do
        local s = VIS.souls[i]
        local age = now - s[4]
        if age > 2.2 then table.remove(VIS.souls, i)
        elseif ready then
            for p = 1, 14 do
                local k = age / 2.2
                local ang = s.seed + p * 0.45 + age * 1.5
                local rad = 0.25 + 0.25 * math.sin(p * 1.7)
                local sx, sy = VIS.proj(s[1] + math.cos(ang) * rad, s[2] + math.sin(ang) * rad, s[3] - 0.6 + k * 2.4 + (p % 4) * 0.12)
                if sx then ds[#ds + 1] = { sx, sy, (1 - k) } end
            end
        end
    end
    VIS.drawSouls = ds
    pcall(VIS.btProject, now)
    if ready then pcall(VIS.hatTick, cx, cy, cz) else VIS.hat = nil end
    VIS.active = true
    VIS.chamsTick(ready, now)
end

-- ============================================================ отрисовка
function VIS.ts(str)
    local s = imgui.CalcTextSize(str)
    local k = (O.esp_font or 13) / 13
    return { x = s.x * k, y = s.y * k }
end
function VIS.text(dl, x, y, col, str)
    local sz, st = O.esp_font or 13, O.esp_txt_ol or 0
    local offs = st == 0 and { { 1, 1 } } or (st == 1 and { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } or {})
    if sz ~= 13 and VIS.fontPtrOk ~= false then
        local ok = pcall(function()
            local f = imgui.GetFont()
            for _, o in ipairs(offs) do dl:AddTextFontPtr(f, sz, V(x + o[1], y + o[2]), C(0, 0, 0, 200), str) end
            dl:AddTextFontPtr(f, sz, V(x, y), col, str)
        end)
        if ok then return end
        VIS.fontPtrOk = false
    end
    for _, o in ipairs(offs) do dl:AddText(V(x + o[1], y + o[2]), C(0, 0, 0, 200), str) end
    dl:AddText(V(x, y), col, str)
end
function VIS.bigText(dl, x, y, col, str, size)
    local ok = pcall(function()
        local f = imgui.GetFont()
        dl:AddTextFontPtr(f, size, V(x + 2, y + 2), C(0, 0, 0, 180), str)
        dl:AddTextFontPtr(f, size, V(x, y), col, str)
    end)
    if not ok then VIS.text(dl, x, y, col, str) end
end
function VIS.line(dl, a, b, col, th, ol)
    if ol then dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), C(0, 0, 0, 160), th + 2) end
    dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), col, th)
end
function VIS.drawBox(dl, x1, y1, x2, y2, c, e)
    local style, th, ol = O.esp_box_style or 0, O.esp_box_th or 1.5, O.esp_box_outline
    if O.esp_box_glow then
        for i = 1, 5 do dl:AddRect(V(x1 - i, y1 - i), V(x2 + i, y2 + i), VIS.C(c, 46 - i * 8), 4 + i, 15, 2) end
    end
    local fill, fa = O.esp_box_fill or 0, O.esp_box_fill_a or 50
    if fill == 1 then dl:AddRectFilled(V(x1, y1), V(x2, y2), VIS.C(c, fa), style == 2 and 6 or 0)
    elseif fill == 2 then
        dl:AddRectFilledMultiColor(V(x1, y1), V(x2, y2), VIS.C(c, fa * 0.1), VIS.C(c, fa * 0.1), VIS.C(c, fa), VIS.C(c, fa))
    end
    local col = VIS.C(c)
    if style == 3 and e.box3 then
        local p = e.box3
        local E = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
        for _, ed in ipairs(E) do
            if p[ed[1]] and p[ed[2]] then VIS.line(dl, p[ed[1]], p[ed[2]], col, th, ol) end
        end
        return
    end
    if style == 1 or style == 2 or style == 3 then
        local r = style == 2 and 6 or 0
        if ol then
            dl:AddRect(V(x1 - 1, y1 - 1), V(x2 + 1, y2 + 1), C(0, 0, 0, 170), r, 15, 1)
            dl:AddRect(V(x1 + 1, y1 + 1), V(x2 - 1, y2 - 1), C(0, 0, 0, 170), r, 15, 1)
        end
        dl:AddRect(V(x1, y1), V(x2, y2), col, r, 15, th)
        return
    end
    local w, h = x2 - x1, y2 - y1
    local lx, ly = math.max(4, w * 0.28), math.max(4, h * 0.2)
    for pass = ol and 1 or 2, 2 do
        local cc, t = pass == 1 and C(0, 0, 0, 170) or col, pass == 1 and th + 2 or th
        dl:AddLine(V(x1, y1), V(x1 + lx, y1), cc, t); dl:AddLine(V(x1, y1), V(x1, y1 + ly), cc, t)
        dl:AddLine(V(x2, y1), V(x2 - lx, y1), cc, t); dl:AddLine(V(x2, y1), V(x2, y1 + ly), cc, t)
        dl:AddLine(V(x1, y2), V(x1 + lx, y2), cc, t); dl:AddLine(V(x1, y2), V(x1, y2 - ly), cc, t)
        dl:AddLine(V(x2, y2), V(x2 - lx, y2), cc, t); dl:AddLine(V(x2, y2), V(x2, y2 - ly), cc, t)
    end
end
function VIS.hpColors(hk)
    local st = O.esp_hp_style or 1
    if st == 2 then local c = VIS.rgb('esp_hp_c'); return VIS.C(c), VIS.C(c) end
    if st == 1 then
        local r, g = 255 * math.min(1, 2 * (1 - hk)), 255 * math.min(1, 2 * hk)
        local c = C(r, g, 70)
        return c, c
    end
    return C(120, 255, 150), C(255, 80, 80)
end

function VIS.drawPlayer(dl, e, sw, sh, now)
    local vis = e.vis
    if e.on then
        local x1, y1, x2, y2 = e.x1, e.y1, e.x2, e.y2
        local cxm = (x1 + x2) * 0.5
        gA = clamp(1.25 - e.dist / math.max(50, O.esp_maxdist or 300), 0.4, 1)
        local acc = vis and VIS.rgb('esp_box_vis') or VIS.rgb('esp_box_hid')
        local bcm = O.esp_box_cm or 0
        if bcm == 1 then local hk = e.hp / 100; acc = { 255 * math.min(1, 2 * (1 - hk)), 255 * math.min(1, 2 * hk), 70, 255 }
        elseif bcm == 2 then acc = { e.r, e.g, e.b, 255 } end
        local sw2 = O.chm_sil_when or 0
        if O.chm_sil and e.bones and (sw2 == 1 or (sw2 == 0 and not vis) or (sw2 == 2 and vis)) then pcall(VIS.drawSil, dl, e)
        elseif e.sameSkin and e.bones and not O.chm_same and ((O.pl_model_player or 0) > 0 or (O.pl_model_behind_walls or 0) > 0) then
            pcall(VIS.drawSil, dl, e)      -- скин как у вас: вместо покраски модели — оверлей
        end
        if O.pl_model_glow then
            local gc = VIS.rgb('pl_model_glow')
            local w, h = x2 - x1, y2 - y1
            for i = 1, 6 do
                local g = i * w * 0.07
                dl:AddRectFilled(V(x1 - g, y1 - g * 0.6), V(x2 + g, y2 + g * 0.4), VIS.C(gc, 16 - i * 2), w * 0.5)
            end
        end
        if e.ring then
            local sc = VIS.rgb('pl_enemy_sounds')
            for i = 1, #e.ring do
                local a, b = e.ring[i], e.ring[i % #e.ring + 1]
                if a and b then
                    dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), VIS.C(sc, 70 * e.ringA), 4)
                    dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), VIS.C(sc, 230 * e.ringA), 1.5)
                end
            end
        end
        local snap = O.esp_snap or 0
        if snap > 0 then
            local oy = snap == 1 and 0 or (snap == 2 and sh * 0.5 or sh)
            local ty = snap == 1 and y1 or y2
            local c = VIS.rgb('esp_snap_c')
            dl:AddLine(V(sw * 0.5, oy), V(cxm, ty), VIS.C(c, 60), 3)
            dl:AddLine(V(sw * 0.5, oy), V(cxm, ty), VIS.C(c, 220), 1)
        end
        if O.esp_box then VIS.drawBox(dl, x1, y1, x2, y2, acc, e) end
        if O.esp_skel and e.bones then
            local sc = vis and VIS.rgb('esp_skel') or VIS.rgb('esp_skel_hid')
            local th, col = O.esp_skel_th or 1.5, VIS.C(sc)
            for _, ln in ipairs(VIS.LINKS) do
                local a, b = e.bones[ln[1]], e.bones[ln[2]]
                if a and b then
                    if O.esp_skel_glow then dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), VIS.C(sc, 50), th + 4) end
                    VIS.line(dl, a, b, col, th, O.esp_skel_ol)
                end
            end
            local hm, hb = O.esp_skel_head or 1, e.bones[8]
            if hm > 0 and hb then
                local r = math.max(2.5, (y2 - y1) * 0.065)
                if hm == 2 then dl:AddCircleFilled(V(hb[1], hb[2]), r, VIS.C(sc, 120), 20) end
                if O.esp_skel_ol then dl:AddCircle(V(hb[1], hb[2]), r, C(0, 0, 0, 160), 20, th + 2) end
                dl:AddCircle(V(hb[1], hb[2]), r, col, 20, th)
            end
        end
        if O.esp_headdot and e.bones and e.bones[8] then
            local hb, c = e.bones[8], VIS.rgb('esp_headdot')
            local r = math.max(2, (y2 - y1) * 0.03)
            dl:AddCircleFilled(V(hb[1], hb[2]), r + 2, C(0, 0, 0, 150), 16)
            dl:AddCircleFilled(V(hb[1], hb[2]), r, VIS.C(c), 16)
        end
        if O.esp_look and e.look and e.bones and e.bones[8] then
            local c = VIS.rgb('esp_look')
            VIS.line(dl, e.bones[8], e.look, VIS.C(c), 1.3, true)
            dl:AddCircleFilled(V(e.look[1], e.look[2]), 2.5, VIS.C(c), 10)
        end
        -- полоски HP / броня
        local bw = O.esp_hp_w or 3
        local padL, padR, padT, padB = 0, 0, 0, 0
        if O.esp_hp then
            local pos, hk = O.esp_hp_pos or 0, e.hp / 100
            local c1, c2 = VIS.hpColors(hk)
            if pos <= 1 then
                local bx = pos == 0 and (x1 - 4 - bw) or (x2 + 4)
                if pos == 0 then padL = bw + 5 else padR = bw + 5 end
                dl:AddRectFilled(V(bx - 1, y1 - 1), V(bx + bw + 1, y2 + 1), C(0, 0, 0, 190), 2)
                local top = y2 - (y2 - y1) * hk
                dl:AddRectFilledMultiColor(V(bx, top), V(bx + bw, y2), c1, c1, c2, c2)
                if O.esp_hp_num and e.hp < 100 then
                    local s = tostring(math.floor(e.hp))
                    local ts = VIS.ts(s)
                    VIS.text(dl, bx + bw * 0.5 - ts.x * 0.5, top - ts.y * 0.5, C(240, 255, 240), s)
                end
            else
                local by = pos == 2 and (y1 - 4 - bw) or (y2 + 4)
                if pos == 2 then padT = bw + 5 else padB = bw + 5 end
                dl:AddRectFilled(V(x1 - 1, by - 1), V(x2 + 1, by + bw + 1), C(0, 0, 0, 190), 2)
                dl:AddRectFilledMultiColor(V(x1, by), V(x1 + (x2 - x1) * hk, by + bw), c2, c1, c1, c2)
                if O.esp_hp_num and e.hp < 100 then
                    VIS.text(dl, x1 + (x2 - x1) * hk - 4, by - 6, C(240, 255, 240), tostring(math.floor(e.hp)))
                end
            end
        end
        if O.esp_ar and e.ar > 0 then
            local ak, ac = e.ar / 100, VIS.rgb('esp_ar_c')
            local by = y2 + 3 + padB
            dl:AddRectFilled(V(x1 - 1, by - 1), V(x2 + 1, by + 3), C(0, 0, 0, 190), 2)
            dl:AddRectFilled(V(x1, by), V(x1 + (x2 - x1) * ak, by + 2), VIS.C(ac), 1)
            padB = padB + 6
        end
        -- ник
        if O.esp_name then
            local label = O.esp_name_id and (e.name .. ' ' .. e.id) or e.name
            local ts = VIS.ts(label)
            local cm = O.esp_name_cm or 0
            local nc = cm == 0 and C(e.r, e.g, e.b) or (cm == 1 and VIS.C(VIS.rgb('esp_name_c')) or C(242, 244, 252))
            local py1 = y1 - ts.y - 7 - padT
            if O.esp_name_bg then
                local px1 = cxm - ts.x * 0.5 - 7
                dl:AddRectFilled(V(px1, py1 - 2), V(px1 + ts.x + 14, py1 + ts.y + 2), C(14, 16, 24, 190), 6)
                dl:AddRectFilled(V(px1 + 3, py1 + ts.y), V(px1 + ts.x + 11, py1 + ts.y + 2), C(e.r, e.g, e.b, 255), 1)
                VIS.text(dl, cxm - ts.x * 0.5, py1, cm == 0 and C(242, 244, 252) or nc, label)
            else
                VIS.text(dl, cxm - ts.x * 0.5, py1, nc, label)
            end
        end
        -- оружие
        local wy = y2 + 3 + padB
        if O.esp_weapon and e.wid and e.wid > 0 then
            local mode = O.esp_wpn_mode or 0
            if mode ~= 2 and WICON[e.wid] then
                local s = O.esp_wpn_size or 22
                dl:AddImage(WICON[e.wid], V(cxm - s * 0.5, wy), V(cxm + s * 0.5, wy + s), V(0, 0), V(1, 1), C(255, 255, 255, 235))
                wy = wy + s
            end
            if mode ~= 1 or not WICON[e.wid] then
                local wn = WEAPON_NAME[e.wid] or ('#' .. e.wid)
                local ts = VIS.ts(wn)
                VIS.text(dl, cxm - ts.x * 0.5, wy, VIS.C(VIS.rgb('esp_wpn_c')), wn)
                wy = wy + ts.y
            end
        end
        -- справа: дистанция и флаги
        local fy = y1 - 1
        local fx = x2 + 5 + padR
        if O.esp_dist then VIS.text(dl, fx, fy, C(170, 176, 196), ('%dm'):format(math.floor(e.dist))); fy = fy + VIS.ts('A').y end
        if e.flags then
            for _, f in ipairs(e.flags) do VIS.text(dl, fx, fy, C(f[2], f[3], f[4]), f[1]); fy = fy + VIS.ts('A').y end
        end
        gA = 1
    elseif e.ax and O.pl_enemy_offscreen_arrow then
        local cx, cy = sw * 0.5, sh * 0.5
        local rad = math.min(O.esp_arrow_rad or 300, math.min(sw, sh) * 0.48)
        local ax, ay = e.ax, e.ay
        local tx, ty = cx + ax * rad, cy + ay * rad
        local px, py = -ay, ax
        local pulse = 0.55 + 0.45 * math.sin(now * 5 + e.id)
        local c = VIS.rgb('pl_enemy_offscreen_arrow')
        local s = O.esp_arrow_size or 14
        local p1 = V(tx + ax * s, ty + ay * s)
        local p2 = V(tx - ax * s * 0.4 + px * s * 0.75, ty - ay * s * 0.4 + py * s * 0.75)
        local p3 = V(tx - ax * s * 0.4 - px * s * 0.75, ty - ay * s * 0.4 - py * s * 0.75)
        dl:AddTriangleFilled(p1, p2, p3, VIS.C(c, 210 * pulse))
        dl:AddTriangle(p1, p2, p3, C(255, 255, 255, 120 * pulse), 1.2)
        if O.esp_dist then
            local s2 = ('%dm'):format(math.floor(e.dist))
            local ts = VIS.ts(s2)
            VIS.text(dl, tx - ax * (s + 6) - ts.x * 0.5, ty - ay * (s + 6) - ts.y * 0.5, C(220, 224, 240, 220 * pulse), s2)
        end
    end
end

function VIS.drawWorld(dl)
    local vc = VIS.rgb('ve_c')
    for _, v in ipairs(VIS.veh) do
        local col = VIS.C(vc)
        local mode = O.ve_box or 0
        local tx, ty = v.sx, v.sy
        if v.pts and mode > 0 then
            local p = v.pts
            local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
            for _, q in ipairs(p) do minx, miny, maxx, maxy = math.min(minx, q[1]), math.min(miny, q[2]), math.max(maxx, q[1]), math.max(maxy, q[2]) end
            if mode == 3 then
                local E = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
                dl:AddQuadFilled(V(p[5][1], p[5][2]), V(p[6][1], p[6][2]), V(p[7][1], p[7][2]), V(p[8][1], p[8][2]), VIS.C(vc, 35))
                for _, ed in ipairs(E) do VIS.line(dl, p[ed[1]], p[ed[2]], col, 1.3, true) end
            elseif mode == 2 then
                dl:AddRect(V(minx, miny), V(maxx, maxy), C(0, 0, 0, 160), 0, 15, 3)
                dl:AddRect(V(minx, miny), V(maxx, maxy), col, 0, 15, 1.3)
            else
                local lx, ly = (maxx - minx) * 0.25, (maxy - miny) * 0.25
                for _, cr in ipairs({ { minx, miny, 1, 1 }, { maxx, miny, -1, 1 }, { minx, maxy, 1, -1 }, { maxx, maxy, -1, -1 } }) do
                    VIS.line(dl, { cr[1], cr[2] }, { cr[1] + lx * cr[3], cr[2] }, col, 1.5, true)
                    VIS.line(dl, { cr[1], cr[2] }, { cr[1], cr[2] + ly * cr[4] }, col, 1.5, true)
                end
            end
            tx, ty = (minx + maxx) * 0.5, miny - 4
        end
        local lines = {}
        if O.ve_name then lines[#lines + 1] = { v.name, C(255, 255, 255) } end
        if O.ve_driver and v.driver then lines[#lines + 1] = { v.driver, C(170, 200, 255) } end
        if O.ve_dist then lines[#lines + 1] = { ('%dm'):format(math.floor(v.dist)), C(170, 176, 196) } end
        local yy = ty - #lines * VIS.ts('A').y - (O.ve_hp and 6 or 0)
        for _, l in ipairs(lines) do
            local ts = VIS.ts(l[1])
            VIS.text(dl, tx - ts.x * 0.5, yy, l[2], l[1]); yy = yy + VIS.ts('A').y
        end
        if O.ve_hp then
            local k = clamp((v.hp - 250) / 750, 0, 1)
            dl:AddRectFilled(V(tx - 25, yy + 1), V(tx + 25, yy + 5), C(0, 0, 0, 190), 2)
            dl:AddRectFilled(V(tx - 24, yy + 2), V(tx - 24 + 48 * k, yy + 4), C(255 * (1 - k) + 60 * k, 220 * k + 60, 80), 1)
        end
    end
    local pc = VIS.rgb('pk_on')
    for _, p in ipairs(VIS.pk) do
        local x, y = p[1], p[2]
        local s = 5 + 2 * math.sin(os.clock() * 4)
        dl:AddQuadFilled(V(x, y - s), V(x + s, y), V(x, y + s), V(x - s, y), VIS.C(pc, 200))
        dl:AddQuad(V(x, y - s - 2), V(x + s + 2, y), V(x, y + s + 2), V(x - s - 2, y), C(0, 0, 0, 150), 1)
        local t = (O.pk_id and ('pickup ' .. p[4]) or '') .. (O.pk_dist and ((O.pk_id and ' ' or '') .. math.floor(p[3]) .. 'm') or '')
        if t ~= '' then local ts = VIS.ts(t); VIS.text(dl, x - ts.x * 0.5, y + 8, VIS.C(pc), t) end
    end
    local oc = VIS.rgb('ob_on')
    for _, o in ipairs(VIS.obj) do
        dl:AddCircle(V(o[1], o[2]), 4, VIS.C(oc), 12, 1.5)
        local t = (O.ob_id and tostring(o[4]) or '') .. (O.ob_dist and ((O.ob_id and ' ' or '') .. math.floor(o[3]) .. 'm') or '')
        if t ~= '' then VIS.text(dl, o[1] + 6, o[2] - 7, VIS.C(oc, 220), t) end
    end
    local ac = VIS.rgb('es_actors')
    for _, a in ipairs(VIS.act) do
        local cx, y1, y2, w = a[1], a[2], a[3], a[4]
        dl:AddRect(V(cx - w * 0.5 - 1, y1 - 1), V(cx + w * 0.5 + 1, y2 + 1), C(0, 0, 0, 150), 3, 15, 1)
        dl:AddRect(V(cx - w * 0.5, y1), V(cx + w * 0.5, y2), VIS.C(ac), 3, 15, 1.3)
        local t = ('NPC %d hp %dm'):format(a[5], math.floor(a[6]))
        local ts = VIS.ts(t)
        VIS.text(dl, cx - ts.x * 0.5, y1 - 15, VIS.C(ac), t)
    end
end

function VIS.drawScreenFx(dl, sw, sh, now)
    if O.sc_tint then dl:AddRectFilled(V(0, 0), V(sw, sh), VIS.C(VIS.rgb('sc_tint'), O.sc_tint_a or 40)) end
    if O.sc_scan then
        local c = VIS.rgb('sc_scan')
        for y = 0, sh, 3 do dl:AddLine(V(0, y), V(sw, y), VIS.C(c, 40), 1) end
    end
    if O.sc_vig then
        local c, a = VIS.rgb('sc_vig'), O.sc_vig_a or 160
        local bw, bh = sw * 0.22, sh * 0.22
        local s, t = VIS.C(c, a), VIS.C(c, 0)
        dl:AddRectFilledMultiColor(V(0, 0), V(bw, sh), s, t, t, s)
        dl:AddRectFilledMultiColor(V(sw - bw, 0), V(sw, sh), t, s, s, t)
        dl:AddRectFilledMultiColor(V(0, 0), V(sw, bh), s, s, t, t)
        dl:AddRectFilledMultiColor(V(0, sh - bh), V(sw, sh), t, t, s, s)
    end
end

function VIS.drawHud(dl, sw, sh, now)
    -- урон по вам
    if O.sc_hurt and VIS.hurtT and now - VIS.hurtT < 0.6 then
        local c, k = VIS.rgb('sc_hurt'), 1 - (now - VIS.hurtT) / 0.6
        local bw = sw * 0.12
        local s, t = VIS.C(c, 150 * k), VIS.C(c, 0)
        dl:AddRectFilledMultiColor(V(0, 0), V(bw, sh), s, t, t, s)
        dl:AddRectFilledMultiColor(V(sw - bw, 0), V(sw, sh), t, s, s, t)
    end
    -- убийство
    if O.sc_kill and VIS.killT and now - VIS.killT < 1.6 then
        local k = 1 - (now - VIS.killT) / 1.6
        local bw = sw * 0.08
        local s, t = C(255, 255, 255, 70 * k), C(255, 255, 255, 0)
        dl:AddRectFilledMultiColor(V(0, 0), V(sw, bw), s, s, t, t)
        local str = 'KILL  ' .. (VIS.killName or '')
        local ts = imgui.CalcTextSize(str)
        local sc = 2
        VIS.bigText(dl, sw * 0.5 - ts.x * sc * 0.5, sh * 0.22 - 10 * (1 - k), C(255, 90, 90, 255 * k), str, 13 * sc)
    end
    local xx, xy = VIS.xhx or sw * 0.5, VIS.xhy or sh * 0.5
    -- FOV аимбота
    if O.hud_fov and RG.on() then
        local fov = O.rage_main_field_of_view or 180
        if fov < 80 then
            local r = math.tan(math.rad(fov)) / math.tan(math.rad(35)) * sw * 0.5
            if r < sw then
                local c = VIS.rgb('hud_fov')
                dl:AddCircleFilled(V(xx, xy), r, VIS.C(c, 12), 64)
                dl:AddCircle(V(xx, xy), r, VIS.C(c, 150), 64, 1.2)
            end
        end
    end
    -- прицел
    local st = O.xh_style or 0
    if st > 0 and (not O.xh_aim or VIS.aiming) then
        local c = VIS.C(VIS.rgb('xh_c'))
        local sz, gap, th = O.xh_size or 7, O.xh_gap or 3, O.xh_th or 2
        if O.xh_dyn then gap = gap + math.min(12, (VIS.mySpeed or 0) * 0.25) end
        local function L2(a1, b1, a2, b2)
            if O.xh_ol then dl:AddLine(V(a1, b1), V(a2, b2), C(0, 0, 0, 200), th + 2) end
            dl:AddLine(V(a1, b1), V(a2, b2), c, th)
        end
        if st == 1 or st == 4 or st == 5 then
            if st ~= 5 then L2(xx, xy - gap, xx, xy - gap - sz) end
            L2(xx, xy + gap, xx, xy + gap + sz)
            L2(xx - gap, xy, xx - gap - sz, xy)
            L2(xx + gap, xy, xx + gap + sz, xy)
        end
        if st == 2 or st == 4 then
            if O.xh_ol then dl:AddCircleFilled(V(xx, xy), th + 1.5, C(0, 0, 0, 200), 12) end
            dl:AddCircleFilled(V(xx, xy), th + 0.5, c, 12)
        end
        if st == 3 then
            if O.xh_ol then dl:AddCircle(V(xx, xy), gap + sz * 0.5, C(0, 0, 0, 200), 32, th + 2) end
            dl:AddCircle(V(xx, xy), gap + sz * 0.5, c, 32, th)
        end
    end
    -- хитмаркер у прицела
    local hs = O.hm_style or 0
    if O.w_misc_hit_marker and hs > 0 and VIS.xhHitT and now - VIS.xhHitT < (O.hm_time or 0.9) then
        local k = 1 - (now - VIS.xhHitT) / (O.hm_time or 0.9)
        local c = VIS.rgb('hm_c')
        local g, s = 5 + (1 - k) * 4, 7
        for _, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            dl:AddLine(V(xx + d[1] * g, xy + d[2] * g), V(xx + d[1] * (g + s), xy + d[2] * (g + s)), C(0, 0, 0, 180 * k), 4)
            dl:AddLine(V(xx + d[1] * g, xy + d[2] * g), V(xx + d[1] * (g + s), xy + d[2] * (g + s)), VIS.C(c, 255 * k), 2)
        end
    end
    -- скорость
    if O.hud_speed then
        local sp = math.floor(VIS.mySpeed or 0)
        local str = sp .. ' km/h'
        local ts = imgui.CalcTextSize(str)
        local k = clamp(sp / 60, 0, 1)
        VIS.bigText(dl, sw * 0.5 - ts.x, sh * 0.78, C(255 * k + 120 * (1 - k), 255 - 80 * k, 140), str, 26)
    end
    -- watermark
    if O.wm_on then
        local it = O.wm_items or 0x0F
        local parts = { 'rage-mod' }
        if bit.band(it, 1) ~= 0 and VIS.myName then parts[#parts + 1] = VIS.myName end
        if bit.band(it, 2) ~= 0 then parts[#parts + 1] = math.floor(imgui.GetIO().Framerate) .. ' fps' end
        if bit.band(it, 4) ~= 0 then parts[#parts + 1] = (VIS.myPing or 0) .. ' ms' end
        if bit.band(it, 8) ~= 0 then parts[#parts + 1] = os.date('%H:%M:%S') end
        if bit.band(it, 16) ~= 0 then parts[#parts + 1] = math.floor(VIS.mySpeed or 0) .. ' km/h' end
        local str = table.concat(parts, '  |  ')
        local ts = imgui.CalcTextSize(str)
        local w, h = ts.x + 22, ts.y + 12
        local pos = O.wm_pos or 0
        local x = (pos == 1 or pos == 3) and 12 or (sw - w - 12)
        local y = (pos >= 2) and (sh - h - 12) or 12
        local ac = VIS.rgb('wm_c')
        dl:AddRectFilled(V(x, y), V(x + w, y + h), C(14, 16, 24, 215), 7)
        dl:AddRectFilledMultiColor(V(x + 6, y), V(x + w - 6, y + 2), VIS.C(ac), C(255, 255, 255, 200), C(255, 255, 255, 200), VIS.C(ac))
        dl:AddText(V(x + 11, y + 6), C(232, 235, 245), str)
    end
    -- активные функции
    if O.hud_keys then
        local act = {}
        local function add(on, n) if on then act[#act + 1] = n end end
        add(RG.on(), 'Rage Aimbot'); add(RG.on() and O.rage_main_silent_aim, 'Silent Aim')
        add(RG.on() and O.rage_main_automatic_fire, 'Auto Fire'); add(RG.on() and O.rage_other_double_tap, 'Double Tap')
        add(O.aa_enable, 'Anti-Aim'); add(O.m_move_bunny_hop, 'Bunny Hop'); add(O.m_move_air_strafe, 'Air Strafe')
        add(O.m_move_slow_walk, 'Slow Walk'); add(O.v_nv, 'Night Vision'); add(O.v_ir, 'Thermal')
        if #act > 0 then
            local x, y, w = 12, sh * 0.42, 150
            local ac = VIS.rgb('wm_c')
            dl:AddRectFilled(V(x, y), V(x + w, y + 22 + #act * 16), C(14, 16, 24, 205), 7)
            dl:AddRectFilled(V(x + 6, y), V(x + w - 6, y + 2), VIS.C(ac), 1)
            dl:AddText(V(x + 10, y + 5), C(232, 235, 245), 'keybinds')
            for i, n in ipairs(act) do
                dl:AddText(V(x + 10, y + 6 + i * 16), C(190, 195, 210), n)
                dl:AddText(V(x + w - 30, y + 6 + i * 16), VIS.C(ac), 'on')
            end
        end
    end
end

imgui.OnFrame(function() return VIS.active end, function(self)
    self.HideCursor = true
    local dl = imgui.GetBackgroundDrawList()
    local sw, sh = VIS.sw, VIS.sh
    local now = os.clock()
    local saveA = gA
    gA = 1
    pcall(VIS.drawScreenFx, dl, sw, sh, now)
    if VIS.ready then pcall(VIS.drawHat, dl) end
    if VIS.ready then
        local style, wd = O.trc_style or 1, O.trc_w or 1.6
        for _, t in ipairs(VIS.drawTr) do
            local c, a = VIS.rgb(t.key), t.a
            for i = 1, #t.pts - 1 do
                local p, q = t.pts[i], t.pts[i + 1]
                if p and q then
                    local k = i / #t.pts
                    if style >= 1 then dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, 55 * a), wd + 4) end
                    if style == 2 then
                        dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, 30 * a), wd + 9)
                        dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(255, 255, 255, 230 * a), math.max(1, wd * 0.5))
                    end
                    dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), VIS.C(c, (120 + 135 * k) * a), wd)
                    if t.fresh then dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(255, 255, 255, 200 * a), 0.8) end
                end
            end
            local last = t.pts[#t.pts]
            if style == 2 and last then dl:AddCircleFilled(V(last[1], last[2]), wd + 2, VIS.C(c, 200 * a), 12) end
        end
        local ic = VIS.rgb('w_misc_bullet_impacts')
        local hc, dc = VIS.rgb('hm_c'), VIS.rgb('hm_dmg_c')
        local hs = O.hm_style or 0
        for _, h in ipairs(VIS.drawHits) do
            local x, y = h[1], h[2]
            if h.imp then
                local s = h.size
                dl:AddRectFilled(V(x - s, y - s), V(x + s, y + s), VIS.C(ic, 60 * h.a), 2)
                dl:AddRect(V(x - s, y - s), V(x + s, y + s), VIS.C(ic, 230 * h.a), 2, 15, 1.2)
            else
                if hs ~= 1 then
                    local g, s = 4 + h.age * 6, 5
                    for _, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
                        dl:AddLine(V(x + d[1] * g, y + d[2] * g), V(x + d[1] * (g + s), y + d[2] * (g + s)), C(0, 0, 0, 160 * h.a), 3.5)
                        dl:AddLine(V(x + d[1] * g, y + d[2] * g), V(x + d[1] * (g + s), y + d[2] * (g + s)), VIS.C(hc, 255 * h.a), 1.6)
                    end
                end
                if h.dmg and O.hm_dmg then
                    local s2 = ('-%d'):format(math.floor(h.dmg + 0.5))
                    local ts = imgui.CalcTextSize(s2)
                    VIS.text(dl, x - ts.x * 0.5, y - 22 - ts.y, VIS.C(dc, 255 * h.a), s2)
                end
            end
        end
        local soc = VIS.rgb('pl_model_soul_particles')
        for _, p in ipairs(VIS.drawSouls) do
            dl:AddCircleFilled(V(p[1], p[2]), 5, VIS.C(soc, 40 * p[3]), 12)
            dl:AddCircleFilled(V(p[1], p[2]), 2, C(255, 255, 255, 220 * p[3]), 8)
        end
        pcall(VIS.drawWorld, dl)
        pcall(VIS.drawGhosts, dl)
        for _, e in ipairs(VIS.list) do pcall(VIS.drawPlayer, dl, e, sw, sh, now) end
        gA = 1
    end
    pcall(VIS.drawHud, dl, sw, sh, now)
    gA = saveA
end)

-- ============================================================ MISC: FEATURES
local memory = require 'memory'

-- Prevent AFK Kick: игра не встаёт на паузу при сворачивании (SA-MP не считает вас AFK)
local afkPatched = false
local function writeBytes(addr, bytes)
    for i, b in ipairs(bytes) do memory.setuint8(addr + i - 1, b, true) end
end
local function setAntiAfk(on)
    on = on and true or false
    if on == afkPatched then return end
    afkPatched = on
    if on then
        writeBytes(0x747FB6, { 0x01 })
        writeBytes(0x74805A, { 0x01 })
        writeBytes(0x74542B, { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 })
        writeBytes(0x53EA88, { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 })
    else
        writeBytes(0x747FB6, { 0x00 })
        writeBytes(0x74805A, { 0x00 })
        writeBytes(0x74542B, { 0x50, 0x51, 0xFF, 0x15, 0x00, 0x83, 0x85, 0x00 })
        writeBytes(0x53EA88, { 0x0F, 0x84, 0x7B, 0x01, 0x00, 0x00 })
    end
end

-- Quick Switch: после выстрела из медленного оружия — мгновенно на кулак и обратно (сбивает анимацию перезарядки)
local QS_WEAPONS = { [24] = true, [25] = true, [27] = false, [33] = true, [34] = true }
local qsPending, qsBusy = false, false

function sampev.onSendBulletSync(data)
    TR.T('bulletsync')
    pcall(RG.onBullet, data)
    pcall(VIS.btShot, data)
    pcall(VIS.ownShot, data)
    if O.aa_enable and O.aa_mode == 4 then aaFlickUntil = os.clock() + (O.aa_flick_ms or 200) / 1000 end
    if O.m_feat_quick_switch and spawnedAt then qsPending = true end
end

local function qsTick()
    if not qsPending then return end
    qsPending = false
    if qsBusy or not doesCharExist(PLAYER_PED) then return end
    local w = getCurrentCharWeapon(PLAYER_PED)
    if not QS_WEAPONS[w] then return end
    qsBusy = true
    lua_thread.create(function()
        wait(30)
        TR.T('qs.switch0')
        setCurrentCharWeapon(PLAYER_PED, 0)
        wait(60)
        TR.T('qs.switchback ' .. w)
        if doesCharExist(PLAYER_PED) then setCurrentCharWeapon(PLAYER_PED, w) end
        qsBusy = false
    end)
end

-- Hit Sound + Log Events
local function pname(id)
    local ok, n = pcall(sampGetPlayerNickname, id)
    return (ok and n or '?') .. '[' .. id .. ']'
end
local function logOn(bitv) return bit.band(O.m_feat_log_events or 0, bitv) ~= 0 end

function sampev.onSendGiveDamage(id, dmg, weapon, part)
    pcall(VIS.hit, id, dmg)
    if O.m_feat_hit_sound then addOneOffSound(0.0, 0.0, 0.0, 17802) end
    if logOn(1) then chat(('урон {3DE07A}%.1f{FFFFFF} -> %s'):format(dmg, pname(id))) end
end

-- урон от окружения (id 65535: падение, огонь, вода и т.п.) не логируем — иначе флуд;
-- урон от одного игрока, пришедший подряд, суммируем в одну строку раз в 0.5 с
local takeAcc = { id = -1, dmg = 0, t = 0 }
function sampev.onSendTakeDamage(id, dmg, weapon, part)
    VIS.hurtT = os.clock()
    if not logOn(2) or id == 65535 then return end
    local now = os.clock()
    if takeAcc.id == id and now - takeAcc.t < 0.5 then
        takeAcc.dmg = takeAcc.dmg + dmg
        return
    end
    if takeAcc.id ~= -1 and takeAcc.dmg > 0 then
        chat(('получено {E03D3D}%.1f{FFFFFF} от %s'):format(takeAcc.dmg, pname(takeAcc.id)))
    end
    takeAcc.id, takeAcc.dmg, takeAcc.t = id, dmg, now
end

local function logTick()
    if takeAcc.id ~= -1 and os.clock() - takeAcc.t >= 0.5 then
        if takeAcc.dmg > 0 then chat(('получено {E03D3D}%.1f{FFFFFF} от %s'):format(takeAcc.dmg, pname(takeAcc.id))) end
        takeAcc.id, takeAcc.dmg = -1, 0
    end
end

function sampev.onPlayerDeathNotification(killer, killed, reason)
    if not logOn(8) then return end
    local ok, my = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok or (killer ~= my and killed ~= my) then return end
    local k = killer == 65535 and 'мир' or pname(killer)
    chat(('{E0B33D}%s{FFFFFF} убил {E0B33D}%s'):format(k, pname(killed)))
end

-- ============================================================ AUTO-UPDATE (GitHub)
-- raw.githubusercontent.com/.../main/ кэшируется CDN ~5 минут и отдаёт старую версию,
-- поэтому сначала берём SHA последнего коммита через API, а файл качаем по этому SHA
-- (такая ссылка всегда указывает ровно на нужную версию — кэш не мешает).
local GH_REPO = 'denismaslov769-lab/rage-mod'
local GH_FILE = 'rage-mod.lua'
local GH_BRANCH = 'main'

local function verNum(v)
    local a, b, c = tostring(v or ''):match('(%d+)%.?(%d*)%.?(%d*)')
    return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end

-- скачать url во временный файл и вернуть содержимое в cb(text|nil)
local function fetch(url, cb)
    local dl = require('moonloader').download_status
    local tmp = getWorkingDirectory() .. '\\rage-mod.update.tmp'
    os.remove(tmp)
    local done = false
    -- ?t= — обходим кэш Windows (URLDownloadToFile кэширует ответы)
    local sep = url:find('?', 1, true) and '&' or '?'
    downloadUrlToFile(url .. sep .. 't=' .. os.time() .. math.random(1000, 9999), tmp, function(_, status)
        if done or status ~= dl.STATUS_ENDDOWNLOADDATA then return end
        done = true
        lua_thread.create(function()
            wait(100)
            local f = io.open(tmp, 'rb')
            local text = f and f:read('*a') or nil
            if f then f:close() end
            os.remove(tmp)
            cb(text)
        end)
    end)
end

local function installUpdate(code, manual)
    local remote = code and code:match("script_version%('([^']+)'%)")
    if not remote or #code < 10000 then
        if manual then chat('обновление: GitHub вернул не скрипт (репозиторий приватный?)') end
        return
    end
    if verNum(remote) <= verNum(thisScript().version) then
        if manual then chat('у вас последняя версия {4E83FF}v' .. thisScript().version) end
        return
    end
    local out = io.open(thisScript().path, 'wb')
    if not out then chat('{E03D3D}обновление: нет доступа к файлу скрипта') return end
    out:write(code); out:close()
    return remote
end

-- cb(newVersion|nil) вызывается один раз, когда проверка закончена
local function checkUpdate(manual, cb)
    if manual then chat('проверяю обновления...') end
    fetch('https://api.github.com/repos/' .. GH_REPO .. '/commits/' .. GH_BRANCH, function(json)
        local sha = json and json:match('"sha"%s*:%s*"(%x+)"')
        local ref = sha or GH_BRANCH     -- API недоступно (лимит) — пробуем ветку напрямую
        fetch('https://raw.githubusercontent.com/' .. GH_REPO .. '/' .. ref .. '/' .. GH_FILE, function(code)
            local v = installUpdate(code, manual)
            if cb then cb(v) end
        end)
    end)
end

-- Обновление на старте: проверяем ДО инициализации (иконки, хуки ввода, патчи памяти, мимгуи-рендер).
-- Перезагрузка «на горячую» посреди игры роняла GTA, поэтому:
--   * на старте — ждём результат и, если обновились, перезагружаемся, пока скрипт ещё ничего не трогал;
--   * /ragemd_update в игре — только скачивает, новая версия включится при следующем запуске.
local function startupUpdate()
    local result, finished = nil, false
    checkUpdate(false, function(v) result, finished = v, true end)
    local t0 = os.clock()
    while not finished and os.clock() - t0 < 8 do wait(100) end
    if result then
        chat('обновлено до {3DE07A}v' .. result .. '{FFFFFF}, перезагружаюсь...')
        wait(1500)               -- даём загрузчику полностью закрыть соединения
        thisScript():reload()
        return true
    end
    return false
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    if startupUpdate() then return end
    loadConfig()
    sampRegisterChatCommand('ragemd', toggleMenu)
    sampRegisterChatCommand('ragemd_chams', function() pcall(VIS.diag) end)
    sampRegisterChatCommand('ragemd_update', function()
        checkUpdate(true, function(v)
            if v then chat('скачана {3DE07A}v' .. v .. '{FFFFFF} — включится после перезапуска игры (или Ctrl+R)') end
        end)
    end)
    refreshWeaponIcons(true)
    chat('загружен. Меню: {4E83FF}/ragemd')

    local lastIconCheck = os.clock()
    while true do
        wait(0)
        local free = not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive()
        local key = keyCodes[O.menu_key + 1]
        if key and key ~= 0 and isKeyJustPressed(key) and free then toggleMenu() end
        if menu[0] and isKeyJustPressed(0x1B) then closePopups() end
        local aak = keyCodes[O.aa_key + 1]
        if aak and aak ~= 0 and isKeyJustPressed(aak) and free then
            O.aa_enable = not O.aa_enable
            if O.notify then chat('Anti-Aim: ' .. (O.aa_enable and '{3DE07A}ON' or '{E03D3D}OFF')) end
        end
        TR.T('frame')
        TR.flush()
        local ready = gameReady()
        local I = ready and mvInput(free) or nil
        aaTick(free, I)
        mvTick(free, I)
        if ready then qsTick(); RG.tick(free) end
        local okv, ev = pcall(VIS.tick, ready)
        if not okv then TR.T('vis.err ' .. tostring(ev)) end
        logTick()
        setAntiAfk(ready and O.m_feat_prevent_afk_kick)
        if os.clock() - lastIconCheck > 1.5 then
            lastIconCheck = os.clock()
            refreshWeaponIcons(false)
        end
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then
        pcall(setAntiAfk, false)
        pcall(VIS.restoreAll)
        pcall(VIS.tcFreeze, false)
        if VIS.st.w ~= nil then pcall(forceWeatherNow, VIS.srvWeather or VIS.st.wOrig or 1) end
        if VIS.st.fov then pcall(cameraResetNewScriptables) end
        saveConfig()
        releaseWeaponIcons()
    end
end

