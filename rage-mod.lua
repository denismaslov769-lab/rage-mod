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
script_version('4.1.0')

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

-- визуалы (ESP / чамсы / трассеры) — всё в одной таблице, чтобы не упереться в лимит локалов
local VIS = {}
VIS.SUB_TR = { title = 'BULLET TRACERS', rows = CARD('trc', {
    T_('Enabled', true, 'trc_on'),
    COL('Local', true, { 102, 124, 246 }),
    COL('Enemies', true, { 255, 92, 92 }),
    SL('Duration', 1, 10, 3, '%d s', false, 'trc_time'),
}) }

local ROWS = {
    rage_main = CARD('rage_main', {
        T_('Enabled'), T_('Silent Aim', true), T_('Automatic Fire', true), T_('Aim Through Walls', true),
        SEL('Refine Shot', { 'Off', 'Latency', 'Performance' }, 1),
        SL('Field of View', 0, 180, 180, '%.1f°', true),
    }),
    rage_other = CARD('rage_other', {
        DIS('History'),
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
    pl_enemy = CARD('pl_enemy', { T_('Enabled', true), COL('Offscreen Arrow', true), COL('Sounds') }),
    pl_model = CARD('pl_model', {
        SEL('Player', CHAMS, 3), SEL('Behind Walls', CHAMS, 5), SEL('On Shot', CHAMS, 1), DIS('History'),
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
        CH('Windows'), CH('Removals'), CH('Ambience'), COL('Hit Marker', true, { 255, 255, 255 }), CH('Bullet Tracers', VIS.SUB_TR), COL('Bullet Impacts', true),
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
DEF.cfg_rev = 2
O.cfg_rev = 2
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
        local c = row.rgb
        dl:AddRectFilled(V(cx + w - 63, y + (rh - 15) * 0.5), V(cx + w - 48, y + (rh + 15) * 0.5), C(c[1], c[2], c[3]), 5)
        Toggle(dl, id, cx + w - 43, y + (rh - 19) * 0.5, row.key)
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
    Card(dl, 'p1', b.x + 177, b.y + 86, 300, 116, 'ENEMY', ROWS.pl_enemy)
    Card(dl, 'p2', b.x + 177, b.y + 239, 300, 264, 'ENEMY MODEL', ROWS.pl_model)

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

    Figure(dl, cx, fy, s, O.pl_model_player or 3, O.pl_model_glow)

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
        and not inRect(Mouse(), sub.ax, sub.ay, sub.aw, sub.ah) then
        sub.open, popup.open = false, false
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
local function closePopups() popup.open, sub.open, account.open = false, false, false end
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
        setCharVelocity(PLAYER_PED, dx * speed, dy * speed, AA_JUMP_VZ)
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
    if O.m_move_bunny_hop and I.jump and (mv.wasAir or not mv.jumpHeld) and not inAir and not water and now - mvJumpT > 0.2 then
        local ex, ey = bhopDir(I)
        if ex then
            mv.airVx, mv.airVy = ex * O.bhop_speed, ey * O.bhop_speed
        elseif not mv.wasAir then
            mv.airVx, mv.airVy = vx, vy       -- первый прыжок по инерции — с текущей скоростью бега
        end
        mvDoJump(mv.airVx, mv.airVy)
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

-- ============================================================ VISUALS: ESP / CHAMS / TRACERS
-- Все игровые функции (координаты, LOS, проекция) вызываются в main-потоке (VIS.tick),
-- в OnFrame только рисуем готовые данные — никаких опкодов в потоке рендера.
VIS.list, VIS.tr, VIS.hits, VIS.souls, VIS.los, VIS.alive, VIS.shot = {}, {}, {}, {}, {}, {}, {}
VIS.drawTr, VIS.drawHits, VIS.drawSouls, VIS.active = {}, {}, {}, false
VIS.ch = { orig = {}, gflag = {}, last = 0, dirty = false }

function VIS.rowRgb(rows, label, def)
    for _, r in ipairs(rows) do if r.l == label and r.rgb then return r.rgb end end
    return def
end
VIS.rgbArrow  = VIS.rowRgb(ROWS.pl_enemy, 'Offscreen Arrow', { 102, 124, 246 })
VIS.rgbSound  = VIS.rowRgb(ROWS.pl_enemy, 'Sounds', { 102, 124, 246 })
VIS.rgbSoul   = VIS.rowRgb(ROWS.pl_model, 'Soul Particles', { 150, 170, 255 })
VIS.rgbGlow   = VIS.rowRgb(ROWS.pl_model, 'Glow', { 102, 124, 246 })
VIS.rgbHit    = VIS.rowRgb(ROWS.w_misc, 'Hit Marker', { 255, 255, 255 })
VIS.rgbImpact = VIS.rowRgb(ROWS.w_misc, 'Bullet Impacts', { 102, 124, 246 })
VIS.rgbTrLoc  = VIS.rowRgb(VIS.SUB_TR.rows, 'Local', { 102, 124, 246 })
VIS.rgbTrEn   = VIS.rowRgb(VIS.SUB_TR.rows, 'Enemies', { 255, 92, 92 })

function VIS.proj(x, y, z)
    if not isPointOnScreen(x, y, z, 0.2) then return nil end
    local sx, sy = convert3DCoordsToScreen(x, y, z)
    return sx, sy
end

-- ---------- события ----------
function VIS.addTracer(o, t, rgb)
    if not O.trc_on then return end
    if #VIS.tr > 64 then table.remove(VIS.tr, 1) end
    VIS.tr[#VIS.tr + 1] = { o.x, o.y, o.z, t.x, t.y, t.z, os.clock(), rgb }
end
function VIS.ownShot(data)
    if not O.trc_local then
        if O.w_misc_bullet_impacts then VIS.addImpact(data.target) end
        return
    end
    VIS.addTracer(data.origin, data.target, VIS.rgbTrLoc)
    if O.w_misc_bullet_impacts then VIS.addImpact(data.target) end
end
function VIS.addImpact(t)
    if #VIS.hits > 64 then table.remove(VIS.hits, 1) end
    VIS.hits[#VIS.hits + 1] = { t.x, t.y, t.z, os.clock(), imp = true }
end
VIS.lastHit = {}
function VIS.hit(id, dmg)
    if not O.w_misc_hit_marker then return end
    local now = os.clock()
    if VIS.lastHit[id] and now - VIS.lastHit[id] < 0.03 then return end
    VIS.lastHit[id] = now
    local ok, ped = sampGetCharHandleBySampPlayerId(id)
    if not ok or not doesCharExist(ped) then return end
    local x, y, z = getCharCoordinates(ped)
    if #VIS.hits > 64 then table.remove(VIS.hits, 1) end
    VIS.hits[#VIS.hits + 1] = { x + (math.random() - 0.5) * 0.3, y + (math.random() - 0.5) * 0.3, z + 0.5, now, dmg = dmg }
end
function sampev.onBulletSync(playerId, data)
    TR.T('vis.bullet ' .. tostring(playerId))
    VIS.shot[playerId] = os.clock()
    if O.trc_on and O.trc_enemies and data and data.origin and data.target then
        VIS.addTracer(data.origin, data.target, VIS.rgbTrEn)
        if O.w_misc_bullet_impacts then VIS.addImpact(data.target) end
    end
end

-- ---------- CHAMS (цвет материалов RenderWare, GTA SA 1.0 US) ----------
-- 0x749B70 RpClumpForAllAtomics; geometry flags |= 0x40 (MODULATEMATERIALCOLOR); RwRGBA материала по +4.
-- Геометрия общая на скин: скины, совпадающие с вашим, не красим (иначе покрасится и ваш перс).
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
    if not okp or not ptr or ptr == 0 then return end
    local clump = rd32(ptr + 0x18)
    if clump == 0 or ffi.cast('uint8_t*', clump)[0] ~= 2 then return end
    for i = #VIS.atoms, 1, -1 do VIS.atoms[i] = nil end
    VIS.forAtomics(ffi.cast('void*', clump), VIS.atomCb, nil)
    for _, a in ipairs(VIS.atoms) do
        local g = rd32(a + 0x18)
        if g ~= 0 then
            local mats = rd32(g + 0x20)
            local n = ffi.cast('int32_t*', g + 0x24)[0]
            if mats ~= 0 and n > 0 and n < 64 then
                for m = 0, n - 1 do
                    local mat = rd32(mats + m * 4)
                    if mat ~= 0 then fn(g, mat) end
                end
            end
        end
    end
end
if jit then jit.off(VIS.pedMaterials, true) end

function VIS.chamsColor(mode, rgb, now)
    local r, g, b, a = rgb[1], rgb[2], rgb[3], 255
    if mode == 2 then r, g, b = math.min(255, r * 1.35), math.min(255, g * 1.35), math.min(255, b * 1.35)
    elseif mode == 3 then
        local k = now * 2.2
        r = 128 + 127 * math.sin(k); g = 128 + 127 * math.sin(k + 2.09); b = 128 + 127 * math.sin(k + 4.19)
    elseif mode == 4 then a = 110
    elseif mode == 5 then
        local p = 0.65 + 0.35 * math.sin(now * 5)
        r, g, b = r * p + 255 * (1 - p) * 0.3, g * p + 255 * (1 - p) * 0.3, b * p + 255 * (1 - p) * 0.3
    end
    return math.floor(r), math.floor(g), math.floor(b), a
end

function VIS.paintPed(ped, mode, rgb, now)
    local ch = VIS.ch
    local cr, cg, cb, ca
    if mode > 0 then cr, cg, cb, ca = VIS.chamsColor(mode, rgb, now) end
    VIS.pedMaterials(ped, function(g, mat)
        local c = ffi.cast('uint8_t*', mat + 4)
        if mode == 0 then
            local o = ch.orig[mat]
            if o then c[0], c[1], c[2], c[3] = o[1], o[2], o[3], o[4]; ch.orig[mat] = nil end
            local f = ch.gflag[g]
            if f then ffi.cast('uint32_t*', g + 8)[0] = f; ch.gflag[g] = nil end
            return
        end
        if not ch.orig[mat] then ch.orig[mat] = { c[0], c[1], c[2], c[3] } end
        if not ch.gflag[g] then ch.gflag[g] = ffi.cast('uint32_t*', g + 8)[0] end
        ffi.cast('uint32_t*', g + 8)[0] = bit.bor(ch.gflag[g], 0x40)
        c[0], c[1], c[2], c[3] = cr, cg, cb, ca
    end)
end

function VIS.restoreAll()
    if not VIS.chOk or not VIS.ch.dirty then return end
    TR.T('vis.chams.restore')
    for id = 0, sampGetMaxPlayerId(false) do
        local ok, ped = sampGetCharHandleBySampPlayerId(id)
        if ok and doesCharExist(ped) then pcall(VIS.paintPed, ped, 0) end
    end
    if doesCharExist(PLAYER_PED) then pcall(VIS.paintPed, PLAYER_PED, 0) end
    VIS.ch.orig, VIS.ch.gflag, VIS.ch.dirty = {}, {}, false
end

function VIS.chamsTick(ready, now)
    local mP, mW, mS = O.pl_model_player or 0, O.pl_model_behind_walls or 0, O.pl_model_on_shot or 0
    local want = ready and O.pl_enemy_enabled and (mP + mW + mS) > 0
    if not want then VIS.restoreAll(); return end
    if now - VIS.ch.last < 0.05 or not VIS.chInit() then return end
    VIS.ch.last = now
    TR.T('vis.chams')
    local myModel = getCharModel(PLAYER_PED)
    for _, e in ipairs(VIS.list) do
        if doesCharExist(e.ped) then
            local mode, rgb = mP, VIS.rgbGlow
            if not e.vis then mode, rgb = (mW > 0 and mW or mP), { 255, 90, 120 } end
            if mS > 0 and VIS.shot[e.id] and now - VIS.shot[e.id] < 0.3 then mode, rgb = mS, { 255, 255, 255 } end
            if getCharModel(e.ped) == myModel then mode = 0 end
            if mode > 0 then VIS.ch.dirty = true end
            pcall(VIS.paintPed, e.ped, mode, rgb, now)
        end
    end
end

-- ---------- сбор данных (main-поток, каждый кадр) ----------
function VIS.tick(ready)
    local now = os.clock()
    local list = {}
    local espOn = ready and O.pl_enemy_enabled
    if espOn then
        TR.T('vis.collect')
        local myId = RG.myId()
        local cx, cy, cz = getActiveCameraCoordinates()
        local px, py, pz = getActiveCameraPointAt()
        local fx, fy = px - cx, py - cy
        local fl = math.sqrt(fx * fx + fy * fy); if fl < 0.001 then fl = 1 end
        fx, fy = fx / fl, fy / fl
        for id = 0, sampGetMaxPlayerId(false) do
            if id ~= myId and sampIsPlayerConnected(id) then
                local ok, ped = sampGetCharHandleBySampPlayerId(id)
                if ok and doesCharExist(ped) then
                    local x, y, z = getCharCoordinates(ped)
                    local dead = isCharDead(ped) or sampGetPlayerHealth(id) <= 0
                    if VIS.alive[id] and dead and O.pl_model_soul_particles then
                        VIS.souls[#VIS.souls + 1] = { x, y, z, now, seed = math.random() * 10 }
                    end
                    VIS.alive[id] = not dead
                    if not dead then
                        local e = { id = id, ped = ped }
                        local dx, dy, dz = x - cx, y - cy, z - cz
                        e.dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                        local l = VIS.los[id]
                        if not l or now - l.t > 0.15 then
                            TR.T('vis.los')
                            l = { t = now, v = isLineOfSightClear(cx, cy, cz, x, y, z + 0.6, true, false, false, true, false) }
                            VIS.los[id] = l
                        end
                        e.vis = l.v
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
                            local okc, col = pcall(sampGetPlayerColor, id)
                            col = okc and col or 0xFFFFFFFF
                            e.r, e.g, e.b = bit.band(bit.rshift(col, 16), 255), bit.band(bit.rshift(col, 8), 255), bit.band(col, 255)
                            e.hp = math.max(0, math.min(100, sampGetPlayerHealth(id)))
                            e.ar = math.max(0, math.min(100, sampGetPlayerArmor(id)))
                            e.wid = getCurrentCharWeapon(ped)
                            if O.pl_enemy_sounds then
                                local vx, vy = getCharVelocity(ped)
                                if vx * vx + vy * vy > 1.5 then
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
    VIS.list = list

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
            dt[#dt + 1] = { pts = pts, a = 1 - age / dur, rgb = t[8], fresh = age < 0.15 }
        end
    end
    VIS.drawTr = dt
    local dh = {}
    for i = #VIS.hits, 1, -1 do
        local h = VIS.hits[i]
        local age = now - h[4]
        local life = h.imp and dur or 1.2
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
    VIS.active = (#list + #dt + #dh + #ds) > 0
    VIS.chamsTick(ready, now)
end

-- ---------- отрисовка ----------
function VIS.vText(dl, x, y, col, str)
    dl:AddText(V(x + 1, y + 1), C(0, 0, 0, 200), str)
    dl:AddText(V(x, y), col, str)
end
function VIS.vRoundBox(dl, x1, y1, x2, y2, rgb, glow)
    if glow then
        for i = 1, 4 do
            dl:AddRect(V(x1 - i, y1 - i), V(x2 + i, y2 + i), C(rgb[1], rgb[2], rgb[3], 48 - i * 10), 4 + i, 15, 2)
        end
    end
    dl:AddRectFilledMultiColor(V(x1, y1), V(x2, y2), C(rgb[1], rgb[2], rgb[3], 6), C(rgb[1], rgb[2], rgb[3], 6),
        C(rgb[1], rgb[2], rgb[3], 46), C(rgb[1], rgb[2], rgb[3], 46))
    local w, h = x2 - x1, y2 - y1
    local lx, ly = math.max(4, w * 0.28), math.max(4, h * 0.2)
    local sh, cl = C(0, 0, 0, 170), C(rgb[1], rgb[2], rgb[3], 255)
    for pass = 1, 2 do
        local col, th = pass == 1 and sh or cl, pass == 1 and 3.2 or 1.4
        dl:AddLine(V(x1, y1), V(x1 + lx, y1), col, th); dl:AddLine(V(x1, y1), V(x1, y1 + ly), col, th)
        dl:AddLine(V(x2, y1), V(x2 - lx, y1), col, th); dl:AddLine(V(x2, y1), V(x2, y1 + ly), col, th)
        dl:AddLine(V(x1, y2), V(x1 + lx, y2), col, th); dl:AddLine(V(x1, y2), V(x1, y2 - ly), col, th)
        dl:AddLine(V(x2, y2), V(x2 - lx, y2), col, th); dl:AddLine(V(x2, y2), V(x2, y2 - ly), col, th)
    end
end

function VIS.drawPlayer(dl, e, sw, sh, now)
    local vis = e.vis
    local acc = vis and VIS.rgbGlow or { 255, 90, 120 }
    if e.on then
        local x1, y1, x2, y2 = e.x1, e.y1, e.x2, e.y2
        local fade = clamp(1.25 - e.dist / 250, 0.35, 1)
        gA = fade
        if e.ring then
            for i = 1, #e.ring do
                local a, b = e.ring[i], e.ring[i % #e.ring + 1]
                if a and b then
                    dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), C(VIS.rgbSound[1], VIS.rgbSound[2], VIS.rgbSound[3], 70 * e.ringA), 4)
                    dl:AddLine(V(a[1], a[2]), V(b[1], b[2]), C(VIS.rgbSound[1], VIS.rgbSound[2], VIS.rgbSound[3], 230 * e.ringA), 1.5)
                end
            end
        end
        if O.esp_box then VIS.vRoundBox(dl, x1, y1, x2, y2, acc, O.pl_model_glow) end
        if O.esp_hp then
            local bx = x1 - 6
            local hk = e.hp / 100
            dl:AddRectFilled(V(bx - 1.5, y1 - 1), V(bx + 2.5, y2 + 1), C(0, 0, 0, 190), 2)
            local top = y2 - (y2 - y1) * hk
            local cTop = hk > 0.5 and C(120, 255, 150) or C(255, 210, 80)
            local cBot = hk > 0.25 and C(60, 210, 110) or C(255, 70, 70)
            dl:AddRectFilledMultiColor(V(bx - 0.5, top), V(bx + 1.5, y2), cTop, cTop, cBot, cBot)
            if e.hp < 100 then
                local s = tostring(math.floor(e.hp))
                local ts = imgui.CalcTextSize(s)
                VIS.vText(dl, bx - ts.x * 0.5, top - ts.y * 0.5, C(235, 255, 240), s)
            end
            if e.ar > 0 then
                local ak = e.ar / 100
                dl:AddRectFilled(V(x1, y2 + 3), V(x2, y2 + 6), C(0, 0, 0, 190), 2)
                dl:AddRectFilledMultiColor(V(x1 + 1, y2 + 4), V(x1 + 1 + (x2 - x1 - 2) * ak, y2 + 5),
                    C(110, 170, 255), C(170, 210, 255), C(170, 210, 255), C(110, 170, 255))
            end
        end
        if O.esp_name then
            local label = e.name .. ' ' .. e.id
            local ts = imgui.CalcTextSize(label)
            local cx = (x1 + x2) * 0.5
            local px1, py1 = cx - ts.x * 0.5 - 7, y1 - ts.y - 9
            dl:AddRectFilled(V(px1, py1), V(px1 + ts.x + 14, py1 + ts.y + 4), C(14, 16, 24, 190), 6)
            dl:AddRectFilled(V(px1 + 3, py1 + ts.y + 2), V(px1 + ts.x + 11, py1 + ts.y + 4), C(e.r, e.g, e.b, 255), 1)
            VIS.vText(dl, cx - ts.x * 0.5, py1 + 1, C(242, 244, 252), label)
        end
        local wy = y2 + ((e.ar > 0 and O.esp_hp) and 9 or 4)
        if O.esp_weapon and e.wid and e.wid > 0 then
            local cx = (x1 + x2) * 0.5
            if WICON[e.wid] then
                local s = 22
                dl:AddImage(WICON[e.wid], V(cx - s * 0.5, wy), V(cx + s * 0.5, wy + s), V(0, 0), V(1, 1), C(255, 255, 255, 235))
                wy = wy + s
            end
            local wn = WEAPON_NAME[e.wid] or ('#' .. e.wid)
            local ts = imgui.CalcTextSize(wn)
            VIS.vText(dl, cx - ts.x * 0.5, wy, C(196, 202, 222), wn)
            wy = wy + ts.y
        end
        if O.esp_dist then
            local s = ('%dm'):format(math.floor(e.dist))
            VIS.vText(dl, x2 + 5, y1, C(170, 176, 196), s)
            if not vis then VIS.vText(dl, x2 + 5, y1 + 13, C(255, 120, 140), 'WALL') end
        end
        gA = 1
    elseif e.ax and O.pl_enemy_offscreen_arrow then
        local cx, cy = sw * 0.5, sh * 0.5
        local rad = math.min(sw, sh) * 0.36
        local ax, ay = e.ax, e.ay
        local tx, ty = cx + ax * rad, cy + ay * rad
        local px, py = -ay, ax
        local pulse = 0.55 + 0.45 * math.sin(now * 5 + e.id)
        local c = VIS.rgbArrow
        local s = 14
        local p1 = V(tx + ax * s, ty + ay * s)
        local p2 = V(tx - ax * s * 0.4 + px * s * 0.75, ty - ay * s * 0.4 + py * s * 0.75)
        local p3 = V(tx - ax * s * 0.4 - px * s * 0.75, ty - ay * s * 0.4 - py * s * 0.75)
        dl:AddTriangleFilled(p1, p2, p3, C(c[1], c[2], c[3], 210 * pulse))
        dl:AddTriangle(p1, p2, p3, C(255, 255, 255, 120 * pulse), 1.2)
        if O.esp_dist then
            local s2 = ('%dm'):format(math.floor(e.dist))
            local ts = imgui.CalcTextSize(s2)
            VIS.vText(dl, tx - ax * 18 - ts.x * 0.5, ty - ay * 18 - ts.y * 0.5, C(220, 224, 240, 220 * pulse), s2)
        end
    end
end

imgui.OnFrame(function() return VIS.active end, function(self)
    self.HideCursor = true
    local dl = imgui.GetBackgroundDrawList()
    local sw, sh = getScreenResolution()
    local now = os.clock()
    local saveA = gA
    gA = 1
    for _, t in ipairs(VIS.drawTr) do
        local c, a = t.rgb, t.a
        for i = 1, #t.pts - 1 do
            local p, q = t.pts[i], t.pts[i + 1]
            if p and q then
                local k = i / #t.pts
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(c[1], c[2], c[3], 55 * a), 5)
                dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(c[1], c[2], c[3], (120 + 135 * k) * a), 1.6)
                if t.fresh then dl:AddLine(V(p[1], p[2]), V(q[1], q[2]), C(255, 255, 255, 200 * a), 0.8) end
            end
        end
    end
    for _, h in ipairs(VIS.drawHits) do
        local x, y = h[1], h[2]
        if h.imp then
            local c, s = VIS.rgbImpact, h.size
            dl:AddRectFilled(V(x - s, y - s), V(x + s, y + s), C(c[1], c[2], c[3], 60 * h.a), 2)
            dl:AddRect(V(x - s, y - s), V(x + s, y + s), C(c[1], c[2], c[3], 230 * h.a), 2, 15, 1.2)
        else
            local c = VIS.rgbHit
            local g, s = 4 + h.age * 6, 5
            for _, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
                dl:AddLine(V(x + d[1] * g, y + d[2] * g), V(x + d[1] * (g + s), y + d[2] * (g + s)), C(0, 0, 0, 160 * h.a), 3.5)
                dl:AddLine(V(x + d[1] * g, y + d[2] * g), V(x + d[1] * (g + s), y + d[2] * (g + s)), C(c[1], c[2], c[3], 255 * h.a), 1.6)
            end
            if h.dmg then
                local s2 = ('-%d'):format(math.floor(h.dmg + 0.5))
                local ts = imgui.CalcTextSize(s2)
                VIS.vText(dl, x - ts.x * 0.5, y - 22 - ts.y, C(255, 110, 110, 255 * h.a), s2)
            end
        end
    end
    for _, p in ipairs(VIS.drawSouls) do
        local c = VIS.rgbSoul
        dl:AddCircleFilled(V(p[1], p[2]), 5, C(c[1], c[2], c[3], 40 * p[3]), 12)
        dl:AddCircleFilled(V(p[1], p[2]), 2, C(255, 255, 255, 220 * p[3]), 8)
    end
    for _, e in ipairs(VIS.list) do pcall(VIS.drawPlayer, dl, e, sw, sh, now) end
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
        saveConfig()
        releaseWeaponIcons()
    end
end

