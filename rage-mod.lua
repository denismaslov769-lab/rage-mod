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
    «Show Locally» крутит и вашего персонажа (тоже на бегу: направление бега берётся из
    камеры + WASD, поэтому персонаж бежит туда, куда вы жмёте, а не туда, куда смотрит).

    Шрифты (необязательно): moonloader\resource\rage-mod\SSTMedium.TTF, SSTBold.TTF, fa-solid-900.ttf
    Активация: /ragemd или клавиша (по умолчанию Insert, меняется в меню профиля в тулбаре).
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui, SAMP.Lua (samp.events)
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('3.3.0')

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
    sampAddChatMessage(u8:decode('{4E83FF}[rage-mod]{FFFFFF} ' .. text), -1)
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
    ['YAW'] = 'ПОВОРОТ',
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
    ['Bullet Impacts'] = 'Попадания пуль', ['Bunny Hop'] = 'Банни-хоп', ['Air Strafe'] = 'Стрейф в воздухе',
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
    ['Backward'] = 'Спиной',
    -- прочее
    ['Language'] = 'Язык', ['Menu Scale'] = 'Масштаб меню', ['ESP Scale'] = 'Масштаб ESP',
    ['Synchronization'] = 'Синхронизация', ['Global'] = 'Общий', ['Save Config'] = 'Сохранить конфиг',
    ['Load Config'] = 'Загрузить конфиг', ['Reset Config'] = 'Сбросить конфиг', ['Open Key: '] = 'Клавиша меню: ',
    ['Notifications: '] = 'Уведомления: ', ['Loadout'] = 'Снаряжение', ['Pistols'] = 'Пистолеты',
    ['Mid-Tier'] = 'Средние', ['Rifles'] = 'Винтовки', ['Box'] = 'Бокс', ['Name'] = 'Имя', ['Health'] = 'HP',
    ['Dist'] = 'Дист.', ['Distance'] = 'Дистанция', ['offline'] = 'оффлайн', ['Profile'] = 'Профиль',
}
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
local aaModeItems = { 'Spin', 'Jitter', 'Random', 'Backward' }

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
local function COL(l, d, rgb) return { l = l, kind = 'color', def = d or false, rgb = rgb or { 102, 124, 246 } } end
local function CH(l, sub) return { l = l, kind = 'chevron', sub = sub } end
local function WPN(l) return { l = l, kind = 'weapon' } end

local function CARD(id, rows)
    for _, r in ipairs(rows) do
        if r.def ~= nil then
            r.key = r.key or (id .. '_' .. slug(r.l))
            if DEF[r.key] == nil then DEF[r.key] = r.def end
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
    T_('Show Locally', true, 'aa_local'),
    T_('Force Sync', true, 'aa_force'),
    T_('Disable While Aiming', true, 'aa_noaim'),
    SEL('Toggle Key', keyNames, 0, 'aa_key'),
}) }

local ROWS = {
    rage_main = CARD('rage_main', {
        T_('Enabled', true), T_('Silent Aim', true), T_('Automatic Fire', true), T_('Aim Through Walls', true),
        SEL('Refine Shot', { 'Off', 'Latency', 'Performance' }, 1),
        SL('Field of View', 0, 180, 180, '%.1f°', true),
    }),
    rage_other = CARD('rage_other', {
        SEL('History', { 'Off', 'Default', 'Maximum' }, 2),
        SEL('Delay Shot', { 'Off', 'Damage', 'Accuracy' }, 1),
        SEL('Remove Spread', { 'Off', 'Partial', 'Full' }, 2),
        T_('Duck Peek Assist'), T_('Quick Peek Assist'), T_('Double Tap'),
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
        CH('Pitch'), CH('Yaw', SUB_YAW), CH('Mouse Override'),
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
    pl_enemy = CARD('pl_enemy', { T_('Enabled', true), COL('Offscreen Arrow', true), COL('Sounds') }),
    pl_model = CARD('pl_model', {
        SEL('Player', CHAMS, 3), SEL('Behind Walls', CHAMS, 5), SEL('On Shot', CHAMS, 1), SEL('History', CHAMS, 1),
        DIS('Ragdolls'), COL('Soul Particles'), COL('Glow', true),
    }),
    w_view = CARD('w_view', {
        CH('View Options'), CH('Scope Options'), CH('Viewmodel Options'), CH('Perspective Options'),
        MUL('Unlock Spectating', { 'Perspective', 'Enemies', 'Teammates' }, 0x03),
        MUL('Visual Recoil', { 'No Shake', 'No Recoil' }, 0x03),
    }),
    w_hud = CARD('w_hud', {
        MUL('Radar', { 'Reveal Enemies', 'Rotate', 'Zoom Out' }, 0x03),
        COL('Scope Overlay', true), COL('Inaccuracy Overlay', true),
        CH('Death Notices'), CH('Scoreboard'), CH('Crosshairs'),
    }),
    w_esp = CARD('w_esp', {
        CH('Bomb'), CH('Weapons'), CH('Hostages'), CH('Grenades'),
        T_('Grenade Trajectory', true), T_('Grenade Proximity Warnings', true),
    }),
    w_misc = CARD('w_misc', {
        CH('Windows'), CH('Removals'), CH('Ambience'), CH('Hit Marker'), CH('Bullet Tracers'), COL('Bullet Impacts', true),
    }),
    m_move = CARD('m_move', {
        T_('Bunny Hop', true), T_('Air Strafe', true), T_('Jump Bug', true), T_('Standalone Quick Stop', true),
        T_('Strafe Assist', true), T_('Edge Jump'), T_('Slow Walk'), T_('Fast Ladder', true),
    }),
    m_feat = CARD('m_feat', {
        T_('Quick Switch', true), T_('Super Toss'), DIS('Knife Bot'), T_('Prevent AFK Kick', true), T_('Hit Sound', true),
        T_('Automatic Purchase'), T_('Automatic Grenade Release', true), T_('Auto-Accept Matchmaking', true),
        MUL('Log Events', { 'Damage Dealt', 'Damage Taken', 'Purchases', 'Deaths' }, 0x03),
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
local function loadConfig()
    local t = inicfg.load(nil, CFG_FILE)
    if not t or not t.options then return false end
    for k, v in pairs(t.options) do
        if DEF[k] ~= nil and type(v) == type(DEF[k]) then O[k] = v end
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

local function RowControl(dl, cx, y, w, row, id)
    local kind = row.kind
    local disabled = kind == 'disabled'
    -- ширина под подпись (чтобы длинный русский текст не залезал на контрол)
    local lw = w - 60
    if kind == 'select' or kind == 'multi' then lw = w - math.min(134, w * 0.48) - 22
    elseif kind == 'weapon' then lw = w - math.min(160, w * 0.56) - 22
    elseif kind == 'slider' then lw = w - 160
    elseif kind == 'color' then lw = w - 75
    elseif kind == 'chevron' then lw = w - 35 end
    dl:PushClipRect(V(cx, y), V(cx + lw, y + 37), true)
    TextY(dl, cx + 13, y, 37, disabled and C(92, 96, 107) or C(207, 209, 218), L(row.l), F.body)
    dl:PopClipRect()

    if kind == 'toggle' then
        Toggle(dl, id, cx + w - 43, y + 9, row.key)
    elseif disabled then
        Toggle(dl, id, cx + w - 43, y + 9, nil, false)
    