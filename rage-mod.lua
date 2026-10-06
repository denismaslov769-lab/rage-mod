--[[
    rage-mod — MoonLoader скрипт для SA-MP
    Полный порт меню neverlose-last (D3D11 / Dear ImGui -> mimgui):
      * все страницы 1:1 — Rage, Legit, Visuals (Players / World), Inventory, Miscellaneous
      * те же координаты, размеры, цвета, скругления и анимации (Motion), что в neverlose_menu.cpp
      * поповер аккаунта, стеклянные выпадающие списки (масштаб 0.96 -> 1), плавная смена страниц,
        появление меню (масштаб 0.92 -> 1), раскрытие группы Visuals
      * Inventory: вместо нарисованных пушек — НАСТОЯЩИЕ иконки оружия из игры
        (те же текстуры <model>icon, что рисует HUD GTA SA), берутся прямо из TXD в памяти

    ВАЖНО: Rage/Legit/ESP/Misc здесь — ТОЛЬКО интерфейс (значения сохраняются в конфиг).
    Anti-Aim (крутилка) — рабочий: Rage -> ANTI-AIM -> Enabled, настройки в «Yaw ›».

    Шрифты (необязательно, но для 1:1 вида положите из архива neverlose-last в
    moonloader\resource\rage-mod\):  SSTMedium.TTF, SSTBold.TTF, fa-solid-900.ttf
    Без них используется Segoe UI и векторные иконки.

    Активация: /ragemd или клавиша (по умолчанию Insert, меняется в меню профиля в тулбаре).
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui, SAMP.Lua (samp.events)
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('3.1.0')

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
local F = {}

-- ============================================================ УТИЛИТЫ
local function chat(text)
    sampAddChatMessage(u8:decode('{4E83FF}[rage-mod]{FFFFFF} ' .. text), -1)
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function V(x, y) return imgui.ImVec2(x, y) end

local gA = 1 -- глобальный множитель альфы (анимации появления)
local function C(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r / 255, g / 255, b / 255, clamp(((a or 255) / 255) * gA, 0, 1)))
end
local function Mix(c1, c2, t)
    t = clamp(t, 0, 1)
    local a1, a2 = c1[4] or 255, c2[4] or 255
    return C(c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t,
             c1[3] + (c2[3] - c1[3]) * t, a1 + (a2 - a1) * t)
end

-- экспоненциальное сглаживание — Motion() из оригинала
local anim = {}
local function Motion(key, target, speed, initial)
    local v = anim[key]
    if v == nil then v = initial or target end
    v = v + (target - v) * (1 - math.exp(-(speed or 16) * imgui.GetIO().DeltaTime))
    if math.abs(v - target) < 0.0005 then v = target end
    anim[key] = v
    return v
end

local function TextSize(str, font)
    if font then imgui.PushFont(font) end
    local s = imgui.CalcTextSize(str)
    if font then imgui.PopFont() end
    return s
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
    imgui.SetCursorScreenPos(V(x, y))
    return imgui.InvisibleButton(id, V(w, h))
end
local function inRect(m, x, y, w, h) return m.x >= x and m.x <= x + w and m.y >= y and m.y <= y + h end

local function Chevron(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.3)
    dl:AddLine(V(x + 3, y + 3), V(x, y + 6), col, 1.3)
end
local function CheckMark(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.5)
    dl:AddLine(V(x + 3, y + 3), V(x + 8, y - 3), col, 1.5)
end

-- трансформация вершин (масштаб/сдвиг как в оригинале). Если mimgui не даёт
-- доступ к VtxBuffer — просто пропускаем, остаётся анимация альфой.
local VTX_OK = true
local function vtxFirst(dl)
    if not VTX_OK then return 0 end
    local ok, n = pcall(function() return dl.VtxBuffer.Size end)
    if not ok then VTX_OK = false; return 0 end
    return n
end
local function vtxScale(dl, first, px, py, s, ox, oy)
    if not VTX_OK then return end
    local ok = pcall(function()
        local buf = dl.VtxBuffer
        for i = first, buf.Size - 1 do
            local p = buf.Data[i].pos
            p.x = px + (p.x - px) * s + ox
            p.y = py + (p.y - py) * s + oy
        end
    end)
    if not ok then VTX_OK = false end
end

-- закруглённые только некоторые углы (без наложения полупрозрачных прямоугольников)
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

-- ============================================================ ИКОНКИ (Font Awesome как в оригинале)
local function utf8cp(cp)
    return string.char(0xE0 + bit.rshift(cp, 12), 0x80 + bit.band(bit.rshift(cp, 6), 0x3F), 0x80 + bit.band(cp, 0x3F))
end
local FA = {
    rage = utf8cp(0xf05b),    -- ICON_FA_CROSSHAIRS
    legit = utf8cp(0xf8cc),   -- ICON_FA_MOUSE
    visuals = utf8cp(0xf03e), -- ICON_FA_IMAGE
    players = utf8cp(0xf007), -- ICON_FA_USER
    world = utf8cp(0xf0ac),   -- ICON_FA_GLOBE
    inventory = utf8cp(0xf5fd), -- ICON_FA_LAYER_GROUP
    misc = utf8cp(0xf1de),    -- ICON_FA_SLIDERS_H
    save = utf8cp(0xf0c7),    -- ICON_FA_SAVE
    list = utf8cp(0xf03a),    -- ICON_FA_LIST
}
FA.user = FA.players
local FA_RANGES = new.ImWchar[3](0xf000, 0xf8ff, 0)

-- векторный фолбэк, если fa-solid-900.ttf не найден
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

-- иконка, вертикально по центру строки высотой h
local function Icon(dl, name, x, y, h, col)
    if F.icon then TextY(dl, x, y, h, col, FA[name], F.icon)
    else VEC[name](dl, x, y + math.floor((h - 14) * 0.5), col) end
end

-- ============================================================ ИКОНКИ ОРУЖИЯ ИЗ ИГРЫ
-- Каждое оружие в GTA SA имеет в своём TXD текстуру "<model>icon" — её рисует HUD.
-- Достаём IDirect3DTexture9* этой текстуры и отдаём в ImGui как ImTextureID.
local WEAPON_MODEL = {
    [1] = 331, [2] = 333, [3] = 334, [4] = 335, [5] = 336, [6] = 337, [7] = 338, [8] = 339, [9] = 341,
    [10] = 321, [11] = 322, [12] = 323, [13] = 324, [14] = 325, [15] = 326, [16] = 342, [17] = 343, [18] = 344,
    [22] = 346, [23] = 347, [24] = 348, [25] = 349, [26] = 350, [27] = 351, [28] = 352, [29] = 353,
    [30] = 355, [31] = 356, [32] = 372, [33] = 357, [34] = 358, [35] = 359, [36] = 360, [37] = 361,
    [38] = 362, [39] = 363, [40] = 364, [41] = 365, [42] = 366, [43] = 367, [44] = 368, [45] = 369, [46] = 371,
}
local WEAPON_NAME = {
    [1] = 'Brass Knuckles', [2] = 'Golf Club', [3] = 'Nightstick', [4] = 'Knife', [5] = 'Baseball Bat',
    [6] = 'Shovel', [7] = 'Pool Cue', [8] = 'Katana', [9] = 'Chainsaw', [14] = 'Flowers', [15] = 'Cane',
    [16] = 'Grenade', [17] = 'Tear Gas', [18] = 'Molotov', [22] = '9mm', [23] = 'Silenced 9mm',
    [24] = 'Desert Eagle', [25] = 'Shotgun', [26] = 'Sawn-off', [27] = 'Combat Shotgun', [28] = 'Micro Uzi',
    [29] = 'MP5', [30] = 'AK-47', [31] = 'M4', [32] = 'Tec-9', [33] = 'Country Rifle', [34] = 'Sniper Rifle',
    [35] = 'RPG', [36] = 'HS Rocket', [37] = 'Flamethrower', [38] = 'Minigun', [39] = 'Satchel',
    [41] = 'Spraycan', [42] = 'Extinguisher', [43] = 'Camera', [46] = 'Parachute',
}

local WICON = {}          -- [weaponId] = ImTextureID (void*)
local WICON_NEEDED = {}   -- какие оружия нужны меню

local function rd32(addr) return ffi.cast('uint32_t*', addr)[0] end

local function rasterExtOffset()
    local off = rd32(0xB4E9E0)            -- _RwD3D9RasterExtOffset
    if off < 0x34 or off > 0x100 then off = 0x34 end
    return off
end

local function findWeaponIconTexture(modelId)
    local mi = rd32(0xA9B0C8 + modelId * 4)       -- CModelInfo::ms_modelInfoPtrs
    if mi == 0 then return nil end
    local txd = ffi.cast('int16_t*', mi + 0x0A)[0] -- CBaseModelInfo::m_nTxdIndex
    if txd < 0 then return nil end
    local pool = rd32(0xC8800C)                    -- CTxdStore::ms_pTxdPool
    if pool == 0 then return nil end
    local objects, flags = rd32(pool), rd32(pool + 4)
    local size = ffi.cast('int32_t*', pool + 8)[0]
    if objects == 0 or flags == 0 or txd >= size then return nil end
    if bit.band(ffi.cast('uint8_t*', flags)[txd], 0x80) ~= 0 then return nil end
    local dict = rd32(objects + txd * 0x0C)       -- TxdDef::m_pRwDictionary
    if dict == 0 then return nil end
    local head = dict + 8                          -- RwTexDictionary::texturesInDict
    local link, n = rd32(head), 0
    while link ~= 0 and link ~= head and n < 64 do
        local tex = link - 8                       -- RwTexture::lInDictionary
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

local function needWeapon(id) if WEAPON_MODEL[id] then WICON_NEEDED[id] = true end end

local function refreshWeaponIcons(force)
    local missing = force
    for wid in pairs(WICON_NEEDED) do
        if not hasModelLoaded(WEAPON_MODEL[wid]) then missing = true; WICON[wid] = nil end
    end
    if not missing then return end
    for wid in pairs(WICON_NEEDED) do requestModel(WEAPON_MODEL[wid]) end
    loadAllModelsNow()
    for wid in pairs(WICON_NEEDED) do
        local mid = WEAPON_MODEL[wid]
        WICON[wid] = hasModelLoaded(mid) and findWeaponIconTexture(mid) or nil
    end
end

local function releaseWeaponIcons()
    for wid in pairs(WICON_NEEDED) do
        WICON[wid] = nil
        pcall(markModelAsNoLongerNeeded, WEAPON_MODEL[wid])
    end
end

-- рисует иконку оружия, вписанную в квадрат s x s с центром (cx, cy)
local function WeaponIcon(dl, wid, cx, cy, s, alpha)
    local tex = WICON[wid]
    if not tex then return false end
    dl:AddImage(tex, V(cx - s * 0.5, cy - s * 0.5), V(cx + s * 0.5, cy + s * 0.5), V(0, 0), V(1, 1), C(255, 255, 255, alpha or 255))
    return true
end

-- ============================================================ НАСТРОЙКИ (единое хранилище)
local O, DEF = {}, {}

local keyNames = { 'Нет', 'Insert', 'Delete', 'Home', 'End', 'F2', 'F3' }
local keyCodes = { 0, 0x2D, 0x2E, 0x24, 0x23, 0x71, 0x72 }
local aaModeItems = { 'Spin', 'Jitter', 'Random', 'Backward' }

-- выбор оружия в тулбаре (кнопка «Global» в оригинале)
local WEAPON_SLOTS = { false, 24, 31, 30, 25, 27, 29, 28, 32, 33, 34 }
local WEAPON_SLOT_NAMES = { 'Global' }
for i = 2, #WEAPON_SLOTS do WEAPON_SLOT_NAMES[i] = WEAPON_NAME[WEAPON_SLOTS[i]]; needWeapon(WEAPON_SLOTS[i]) end

DEF.menu_key, DEF.notify, DEF.weapon, DEF.inv_sel = 1, true, 0, 24
DEF.acc_lang, DEF.acc_menu_scale, DEF.acc_esp_scale, DEF.acc_sync = 0, 0, 0, false

local function slug(s) return (s:lower():gsub('[^%w]+', '_')) end

-- конструкторы рядов
local function T(l, d, key)   return { l = l, kind = 'toggle', def = d or false, key = key } end
local function DIS(l)         return { l = l, kind = 'disabled' } end
local function SEL(l, items, d, key) return { l = l, kind = 'select', items = items, def = d or 0, key = key } end
local function MUL(l, items, mask, key) return { l = l, kind = 'multi', items = items, def = mask or 0, key = key } end
local function SL(l, mn, mx, d, fmt, float, key) return { l = l, kind = 'slider', min = mn, max = mx, def = d, fmt = fmt, float = float, key = key } end
local function COL(l, d, rgb) return { l = l, kind = 'color', def = d or false, rgb = rgb or { 102, 124, 246 } } end
local function CH(l, sub)     return { l = l, kind = 'chevron', sub = sub } end

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

-- подменю «Yaw ›» — рабочая крутилка
local SUB_YAW = { title = 'YAW', rows = CARD('aa', {
    SEL('Mode', aaModeItems, 0, 'aa_mode'),
    SL('Spin Speed', 1, 90, 25, '%d°', false, 'aa_speed'),
    SL('Jitter Range', 0, 180, 90, '%d°', false, 'aa_jitter'),
    T('Disable While Aiming', true, 'aa_noaim'),
    SEL('Toggle Key', keyNames, 0, 'aa_key'),
}) }

local ROWS = {
    rage_main = CARD('rage_main', {
        T('Enabled', true), T('Silent Aim', true), T('Automatic Fire', true), T('Aim Through Walls', true),
        SEL('Refine Shot', { 'Off', 'Latency', 'Performance' }, 1),
        SL('Field of View', 0, 180, 180, '%.1f°', true),
    }),
    rage_other = CARD('rage_other', {
        SEL('History', { 'Off', 'Default', 'Maximum' }, 2),
        SEL('Delay Shot', { 'Off', 'Damage', 'Accuracy' }, 1),
        SEL('Remove Spread', { 'Off', 'Partial', 'Full' }, 2),
        T('Duck Peek Assist'), T('Quick Peek Assist'), T('Double Tap'),
    }),
    rage_sel = CARD('rage_sel', {
        SEL('Prefer', { 'Damage', 'Accuracy', 'Head', 'Body' }, 0),
        MUL('Hitboxes', HB, 0x07),
        SL('Hit Chance', 0, 100, 0, '%d%%'),
        SL('Min Damage', 0, 130, 112, fmtMinDmg),
        T('Quick Stop'), T('Quick Scope'),
    }),
    rage_aa = CARD('rage_aa', {
        T('Enabled', false, 'aa_enable'),
        T('Suppress Breathing Animations', true),
        SEL('Leg Movement', { 'Default', 'Walking', 'Sliding' }, 1),
        CH('Pitch'), CH('Yaw', SUB_YAW), CH('Mouse Override'),
    }),

    legit_main = CARD('legit_main', { T('Enabled') }),
    legit_aim = CARD('legit_aim', {
        T('Enabled'), SEL('Activation', { 'Always', 'Assisted', 'On Key' }, 1),
        MUL('Conditions', COND, 0x03), MUL('Hitboxes', HB, 0x01),
        SL('Field of View', 0, 150, 20, '%du'), SL('Smoothing', 0, 100, 50, '%d%%'),
        SL('Reaction Time', 0, 500, 0, '%dms'), SL('Min Damage', 0, 130, 101, fmtMinDmg),
        T('Recoil Control'), T('Quick Scope'), T('Quick Stop'),
    }),
    legit_trig = CARD('legit_trig', {
        T('Enabled'), MUL('Conditions', COND, 0x03), MUL('Hitboxes', HB, 0x07),
        SL('Hit Chance', 0, 100, 92, '%d%%'), SL('Min Damage', 0, 130, 101, fmtMinDmg),
        SL('Reaction Time', 0, 500, 0, '%dms'), SL('Burst Time', 0, 500, 50, '%dms'),
        T('Quick Scope'),
    }),
    legit_other = CARD('legit_other', {
        T('Visualize'), T('Automatic Weapons'), T('Standalone Recoil Control'),
        SEL('Randomize', { 'None', 'Low', 'Medium', 'High' }, 0),
    }),

    pl_enemy = CARD('pl_enemy', { T('Enabled', true), COL('Offscreen Arrow'), COL('Sounds') }),
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
        T('Grenade Trajectory', true), T('Grenade Proximity Warnings', true),
    }),
    w_misc = CARD('w_misc', {
        CH('Windows'), CH('Removals'), CH('Ambience'), CH('Hit Marker'), CH('Bullet Tracers'), COL('Bullet Impacts', true),
    }),

    m_move = CARD('m_move', {
        T('Bunny Hop', true), T('Air Strafe', true), T('Jump Bug', true), T('Standalone Quick Stop', true),
        T('Strafe Assist', true), T('Edge Jump'), T('Slow Walk'), T('Fast Ladder', true),
    }),
    m_feat = CARD('m_feat', {
        T('Quick Switch', true), T('Super Toss'), DIS('Knife Bot'), T('Prevent AFK Kick', true), T('Hit Sound', true),
        T('Automatic Purchase'), T('Automatic Grenade Release', true), T('Auto-Accept Matchmaking', true),
        MUL('Log Events', { 'Damage Dealt', 'Damage Taken', 'Purchases', 'Deaths' }, 0x03),
    }),
}

-- Inventory: 5 рядов x 3 колонки (Pistols / Mid-Tier / Rifles) + 2x3 снизу слева
local INV_COLS = {
    { 22, 23, 24, 28, 32 },   -- Pistols
    { 25, 26, 27, 29, 33 },   -- Mid-Tier
    { 30, 31, 34, 35, 38 },   -- Rifles
}
local INV_SMALL = { 4, 8, 5, 16, 18, 9 }
for _, col in ipairs(INV_COLS) do for _, w in ipairs(col) do needWeapon(w) end end
for _, w in ipairs(INV_SMALL) do needWeapon(w) end

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
-- popup: стеклянный список. get(i) -> выбран?, set(i) -> клик (true = закрыть)
local popup = { open = false, owner = nil, frame = 0, x = 0, y = 0, w = 134, ah = 23,
                rx = 0, ry = 0, rw = 0, rh = 0 }
local account = { open = false, frame = 0 }
local sub = { open = false, frame = 0, def = nil, x = 0, y = 0, ax = 0, ay = 0, aw = 0, ah = 0 }

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
        OpenPopup(id, row.items,
            function(i) return hasBit(O[key], i) end,
            function(i) O[key] = bit.bxor(O[key], bit.lshift(1, i - 1)); return false end,
            x, y, 134, 23)
    else
        OpenPopup(id, row.items,
            function(i) return O[key] == i - 1 end,
            function(i) O[key] = i - 1; return true end,
            x, y, w, 23)
    end
end

local function multiText(row)
    local t = {}
    for i, n in ipairs(row.items) do if hasBit(O[row.key], i) then t[#t + 1] = n end end
    return #t > 0 and table.concat(t, ', ') or 'None'
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

local function RowControl(dl, cx, y, w, row, id)
    local kind = row.kind
    local disabled = kind == 'disabled'
    TextY(dl, cx + 13, y, 37, disabled and C(92, 96, 107) or C(207, 209, 218), row.l, F.body)

    if kind == 'toggle' then
        Toggle(dl, id, cx + w - 43, y + 9, row.key)

    elseif disabled then
        Toggle(dl, id, cx + w - 43, y + 9, nil, false)

    elseif kind == 'select' or kind == 'multi' then
        local cw = math.min(134, w * 0.48)
        local px, py = cx + w - cw - 13, y + 7
        local click = Hit(id, px, py, cw, 23)
        local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == id)) and 1 or 0)
        if click then OpenRowPopup(id, row, px, py, cw) end
        dl:AddRectFilled(V(px, py), V(px + cw, py + 23), Mix({ 25, 28, 38 }, { 31, 38, 54 }, r), 5)
        dl:AddRect(V(px, py), V(px + cw, py + 23), Mix({ 32, 35, 46 }, { 75, 126, 255 }, r), 5)
        local value = kind == 'multi' and multiText(row) or row.items[O[row.key] + 1] or 'Select'
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
        local sx, sy = plx - 10 - tw, y + 18
        Hit(id, sx - 5, sy - 8, tw + 10, 19)
        if imgui.IsItemActive() then
            local t = clamp((imgui.GetMousePos().x - sx) / tw, 0, 1)
            local nv = row.min + (row.max - row.min) * t
            if not row.float then nv = math.floor(nv + 0.5) end
            O[key] = nv
        end
        local target = clamp((O[key] - row.min) / (row.max - row.min), 0, 1)
        local shown = Motion(id .. '#v', target, 14)
        dl:AddRectFilled(V(sx, sy), V(sx + tw, sy + 3), C(34, 38, 48), 2)
        dl:AddRectFilled(V(sx, sy), V(sx + tw * shown, sy + 3), C(75, 126, 255), 2)
        dl:AddCircleFilled(V(sx + tw * shown, sy + 1.5), 5.5, C(247, 248, 252), 24)
        local ply = y + 8
        dl:AddRectFilled(V(plx, ply), V(plx + pw, ply + 21), C(25, 28, 38), 5)
        local tsz = TextSize(txt, F.ctrl)
        TextY(dl, plx + (pw - tsz.x) * 0.5, ply, 21, C(166, 169, 179), txt, F.ctrl)

    elseif kind == 'color' then
        local c = row.rgb
        dl:AddRectFilled(V(cx + w - 63, y + 11), V(cx + w - 48, y + 26), C(c[1], c[2], c[3]), 5)
        Toggle(dl, id, cx + w - 43, y + 9, row.key)

    elseif kind == 'chevron' then
        if row.sub then
            local click = Hit(id, cx + 4, y + 3, w - 8, 31)
            local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (sub.open and sub.owner == id)) and 1 or 0, 20)
            if r > 0.001 then dl:AddRectFilled(V(cx + 4, y + 3), V(cx + w - 4, y + 34), C(39, 43, 54, 150 * r), 8) end
            if click then OpenSub(id, row.sub, cx, y, w, 37) end
        end
        Chevron(dl, cx + w - 22, y + 15, C(187, 190, 199))
    end
end

local function Card(dl, key, x, y, w, h, title, rows)
    Text(dl, x + 12, y - 18, C(89, 94, 106), title, F.cap)
    dl:AddRectFilled(V(x, y), V(x + w, y + h), C(17, 19, 27, 224), 14)
    dl:AddRect(V(x, y), V(x + w, y + h), C(31, 34, 44), 14)
    for i, row in ipairs(rows) do
        local ry = y + (i - 1) * 37
        if i > 1 then dl:AddLine(V(x + 12, ry), V(x + w - 12, ry), C(28, 31, 40)) end
        RowControl(dl, x, ry, w, row, '##' .. key .. i)
    end
end

-- солдат-превью (Players / Inventory) — 1:1 из оригинала
local function Soldier(dl, x, y)
    local function P(a, b) return V(x + a, y + b) end
    local blue, edge, dark = C(91, 133, 255, 210), C(211, 220, 255, 235), C(39, 49, 77, 245)
    dl:AddCircleFilled(P(0, -120), 22, dark, 32); dl:AddCircle(P(0, -120), 22, edge, 32, 2)
    dl:AddRectFilled(P(-29.5, -97.5), P(29.5, -23.5), blue, 13.5)
    dl:AddRectFilled(P(-26.5, -94.5), P(26.5, -26.5), dark, 10.5)
    dl:AddQuadFilled(P(-25, -85), P(-48, -30), P(-37, -22), P(-10, -66), dark)
    dl:AddQuadFilled(P(25, -85), P(51, -45), P(41, -35), P(10, -66), dark)
    dl:AddRectFilled(P(-23, -25), P(-4, 60), dark, 8); dl:AddRectFilled(P(4, -25), P(23, 60), dark, 8)
    dl:AddLine(P(-55, -42), P(62, -53), edge, 5); dl:AddRectFilled(P(30, -58), P(77, -49), blue, 2)
    dl:AddCircle(P(0, -120), 10, blue, 32, 2); dl:AddLine(P(-20, -115), P(20, -115), blue, 2)
    dl:AddLine(P(-35, 62), P(-4, 62), edge, 3); dl:AddLine(P(4, 62), P(35, 62), edge, 3)
end

-- ячейка оружия: фон/рамка/полоса редкости как в оригинале + реальная иконка оружия
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
        -- фолбэк, пока иконка не загрузилась: оригинальная векторная пушка
        local gun, shade = C(218, 220, 218), C(104, 111, 118)
        local k = math.min(w / 121, h / 91)
        local function q(a, b) return V(x + a * k, y + b * k) end
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
    Card(dl, 'l1', b.x + 167, b.y + 84, 281, 40, 'MAIN', ROWS.legit_main)
    Card(dl, 'l2', b.x + 167, b.y + 160, 281, 401, 'AIMBOT', ROWS.legit_aim)
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

PAGES.players = function(dl, b)
    Card(dl, 'p1', b.x + 177, b.y + 86, 300, 116, 'ENEMY', ROWS.pl_enemy)
    Card(dl, 'p2', b.x + 177, b.y + 239, 300, 264, 'ENEMY MODEL', ROWS.pl_model)
    Text(dl, b.x + 557, b.y + 75, C(111, 167, 255), 'Enemies', F.ctrl)
    Icon(dl, 'user', b.x + 654, b.y + 75, 16, C(180, 184, 194))
    Icon(dl, 'list', b.x + 706, b.y + 75, 16, C(180, 184, 194))
    Soldier(dl, b.x + 626, b.y + 438)
    local name = localIdentity()
    Text(dl, b.x + 609, b.y + 116, C(255, 112, 135), 'C4', F.t8)
    local nw = TextSize(name, F.t9).x
    Text(dl, b.x + 626 - nw * 0.5, b.y + 128, C(253, 213, 90), name, F.t9)
    Text(dl, b.x + 612, b.y + 141, C(227, 231, 241), '65%', F.t8)
    dl:AddRectFilled(V(b.x + 535, b.y + 495), V(b.x + 715, b.y + 499), C(34, 38, 48), 2)
    dl:AddRectFilled(V(b.x + 535, b.y + 495), V(b.x + 640, b.y + 499), C(75, 126, 255), 2)
end

PAGES.world = function(dl, b)
    Card(dl, 'w1', b.x + 177, b.y + 84, 291, 221, 'VIEW', ROWS.w_view)
    Card(dl, 'w2', b.x + 478, b.y + 84, 257, 221, 'HUD', ROWS.w_hud)
    Card(dl, 'w3', b.x + 177, b.y + 350, 291, 221, 'WORLD ESP', ROWS.w_esp)
    Card(dl, 'w4', b.x + 478, b.y + 350, 257, 221, 'MISCELLANEOUS', ROWS.w_misc)
end

local ACCENTS = { { 235, 237, 239 }, { 171, 70, 255 }, { 75, 116, 255 }, { 226, 43, 192 }, { 251, 65, 83 }, { 134, 72, 255 } }

PAGES.inventory = function(dl, b)
    dl:AddRectFilled(V(b.x + 159, b.y + 57), V(b.x + 747, b.y + 575), C(17, 27, 42, 155), 0)
    dl:AddRectFilled(V(b.x + 185, b.y + 66), V(b.x + 286, b.y + 91), C(20, 34, 50), 8)
    TextY(dl, b.x + 199, b.y + 66, 25, C(138, 192, 255), 'Loadout', F.ctrl)
    Soldier(dl, b.x + 264, b.y + 388)
    for r = 0, 4 do
        for c = 0, 2 do
            WeaponCell(dl, '##inv' .. r .. c, b.x + 390 + c * 116, b.y + 88 + r * 96, 108, 91,
                INV_COLS[c + 1][r + 1], ACCENTS[(r + c) % 6 + 1])
        end
    end
    Text(dl, b.x + 424, b.y + 67, C(205, 209, 219), 'Pistols', F.ctrl)
    Text(dl, b.x + 536, b.y + 67, C(205, 209, 219), 'Mid-Tier', F.ctrl)
    Text(dl, b.x + 655, b.y + 67, C(205, 209, 219), 'Rifles', F.ctrl)
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
    Text(dl, bx + 16, by + 67, C(91, 96, 108), 'AIMBOT', F.cap)
    Text(dl, bx + 16, by + 169, C(91, 96, 108), 'COMMON', F.cap)

    local function nav(key, icon, label, y, target, selected, indent)
        indent = indent or 0
        local px, py = bx + 7 + indent, by + y
        local clicked = Hit('##nav_' .. key, px, py, 140 - indent, 30)
        local r = Motion('nav#' .. key, selected and 1 or (imgui.IsItemHovered() and 0.48 or 0))
        if clicked then ChangePage(target) end
        if r > 0.001 then dl:AddRectFilled(V(px, py), V(px + 140 - indent, py + 30), Mix({ 18, 21, 30, 0 }, { 39, 43, 54 }, r), 6) end
        Icon(dl, icon, px + 10, py, 30, Mix({ 137, 142, 153 }, { 82, 141, 255 }, r))
        TextY(dl, px + 31, py, 30, Mix({ 145, 149, 159 }, { 226, 228, 235 }, r), label, F.body)
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
    Text(dl, ax + 43, ay + 20, C(111, 116, 128), id >= 0 and ('ID: ' .. id) or 'offline', F.small)
    dl:PopClipRect()
    Chevron(dl, ax + 132, ay + 15, C(181, 185, 195))
end

local PROFILE_ITEMS = {
    'Save Config', 'Load Config', 'Reset Config',
    function() return 'Open Key: ' .. (keyNames[O.menu_key + 1] or '?') end,
    function() return 'Notifications: ' .. (O.notify and 'On' or 'Off') end,
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

    -- профиль конфига (как «Nonprime 7.2»)
    local px, py = bx + 169, by + 14
    if Hit('##tb_profile', px, py, 166, 30) then
        OpenPopup('##tb_profile', PROFILE_ITEMS, function() return false end, profileSet, px, py, 166, 30)
    end
    local r = Motion('tb_profile#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == '##tb_profile')) and 1 or 0)
    dl:AddRectFilled(V(px, py), V(px + 166, py + 30), Mix({ 17, 19, 27 }, { 22, 25, 35 }, r), 6)
    dl:AddRect(V(px, py), V(px + 166, py + 30), Mix({ 28, 31, 41 }, { 45, 52, 70 }, r), 6)
    Icon(dl, 'save', px + 12, py, 30, C(194, 197, 206))
    TextY(dl, px + 48, py, 30, C(184, 187, 197), 'Default', F.ctrl)
    Chevron(dl, px + 148, py + 11, C(130, 135, 146))

    -- «Global» / выбор оружия — с настоящей иконкой
    if page == 'rage' or page == 'legit' then
        local wid = WEAPON_SLOTS[O.weapon + 1]
        local label = WEAPON_SLOT_NAMES[O.weapon + 1] or 'Global'
        local hasIcon = wid and WICON[wid] ~= nil
        local tx = hasIcon and 40 or 13
        local gw = math.max(85, tx + TextSize(label, F.ctrl).x + 30)
        local gx, gy = bx + 348, by + 14
        if Hit('##tb_weapon', gx, gy, gw, 30) then
            OpenPopup('##tb_weapon', WEAPON_SLOT_NAMES,
                function(i) return O.weapon == i - 1 end,
                function(i) O.weapon = i - 1; if WEAPON_SLOTS[i] then O.inv_sel = WEAPON_SLOTS[i] end; return true end,
                gx, gy, 190, 30, WEAPON_SLOTS)
        end
        local wr = Motion('tb_weapon#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == '##tb_weapon')) and 1 or 0)
        dl:AddRectFilled(V(gx, gy), V(gx + gw, gy + 30), Mix({ 17, 19, 27 }, { 22, 25, 35 }, wr), 6)
        dl:AddRect(V(gx, gy), V(gx + gw, gy + 30), Mix({ 28, 31, 41 }, { 45, 52, 70 }, wr), 6)
        if hasIcon then WeaponIcon(dl, wid, gx + 22, gy + 15, 26) end
        TextY(dl, gx + tx, gy, 30, C(184, 187, 197), label, F.ctrl)
        Chevron(dl, gx + gw - 17, gy + 11, C(130, 135, 146))
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
    if imgui.GetFrameCount() <= frame + 1 then imgui.SetNextWindowFocus() end
    imgui.SetNextWindowPos(V(x, y), imgui.Cond.Always)
    imgui.SetNextWindowSize(V(w, h), imgui.Cond.Always)
    imgui.Begin(name, nil, overlayFlags())
    return imgui.GetWindowDrawList()
end

local function popupHovered()
    return popup.open and inRect(imgui.GetMousePos(), popup.rx, popup.ry, popup.rw, popup.rh)
end

local function PopupLayer(reveal)
    local open = Motion('popup_open', popup.open and 1 or 0, 20, 0)
    if open < 0.002 or not popup.items then return end
    local items, icons = popup.items, popup.icons
    local count = #items
    local w, h = popup.w, count * 32 + 8
    local sw, sh = getScreenResolution()
    local px = clamp(popup.x, 10, sw - w - 10)
    local py = clamp(popup.y + (popup.ah - h) * 0.5, 10, sh - h - 10)
    popup.rx, popup.ry, popup.rw, popup.rh = px, py, w, h

    local dl = beginOverlay('##nl_popup', px - 8, py - 6, w + 16, h + 18, popup.frame)
    local first = vtxFirst(dl)
    local e = 1 - (1 - open) ^ 3
    gA = reveal * e
    dl:AddRectFilled(V(px - 5, py - 2), V(px + w + 5, py + h + 8), C(0, 0, 0, 55), 18)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 235), 16)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 205), 16)
    dl:AddLine(V(px + 16, py + 1), V(px + w - 16, py + 1), C(255, 255, 255, 22))

    local accepts = imgui.GetFrameCount() > popup.frame and popup.open
    for i, it in ipairs(items) do
        local label = type(it) == 'function' and it() or it
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

    local pv = V(px + w * 0.5, py + h * 0.5)
    vtxScale(dl, first, pv.x, pv.y, 0.96 + 0.04 * e, 4 * (1 - e), 0)

    if popup.open and imgui.GetFrameCount() > popup.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered() then
        popup.open = false
    end
    imgui.End()
end

local function SubPopover(reveal)
    local open = Motion('sub_open', sub.open and 1 or 0, 20, 0)
    if open < 0.002 or not sub.def then return end
    local rows = sub.def.rows
    local w, h = 270, #rows * 37
    local sw, sh = getScreenResolution()
    local px = sub.ax + sub.aw + 10
    if px + w > sw - 10 then px = sub.ax - w - 10 end
    local py = clamp(sub.ay - 4, 10, sh - h - 10)
    local dl = beginOverlay('##nl_sub', px - 8, py - 26, w + 16, h + 40, sub.frame)
    local first = vtxFirst(dl)
    local e = 1 - (1 - open) ^ 3
    gA = reveal * e
    dl:AddRectFilled(V(px - 5, py - 2), V(px + w + 5, py + h + 8), C(0, 0, 0, 55), 18)
    Text(dl, px + 12, py - 18, C(89, 94, 106), sub.def.title, F.cap)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 240), 14)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 205), 14)
    for i, row in ipairs(rows) do
        local ry = py + (i - 1) * 37
        if i > 1 then dl:AddLine(V(px + 12, ry), V(px + w - 12, ry), C(28, 31, 40)) end
        RowControl(dl, px, ry, w, row, '##sub' .. i)
    end
    vtxScale(dl, first, px, py + h * 0.5, 0.96 + 0.04 * e, -6 * (1 - e), 0)

    if sub.open and imgui.GetFrameCount() > sub.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered() and not popupHovered()
        and not inRect(imgui.GetMousePos(), sub.ax, sub.ay, sub.aw, sub.ah) then
        sub.open, popup.open = false, false
    end
    imgui.End()
end

local ACC_ROWS = {
    { 'Language', 'acc_lang', { 'English', 'Русский' } },
    { 'Menu Scale', 'acc_menu_scale', { '100%', '125%', '150%' } },
    { 'ESP Scale', 'acc_esp_scale', { '100%', '125%', '150%' } },
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
    Text(dl, px + 64, py + 34, C(115, 164, 255), id >= 0 and ('ID: ' .. id .. '  ·  v' .. thisScript().version) or 'offline', F.ctrl)
    dl:PopClipRect()

    local accepts = imgui.GetFrameCount() > account.frame and account.open
    for i, r in ipairs(ACC_ROWS) do
        local ry = py + 66 + (i - 1) * 28
        local clicked = Hit('##acc' .. i, px + 6, ry, w - 12, 28)
        local hv = Motion('acc#' .. i, (imgui.IsItemHovered() or (popup.open and popup.owner == '##acc' .. i)) and 1 or 0, 22)
        if hv > 0.001 then dl:AddRectFilled(V(px + 6, ry), V(px + w - 6, ry + 28), C(75, 126, 255, 22 * hv), 8) end
        TextY(dl, px + 18, ry, 28, C(185, 188, 198), r[1], F.ctrl)
        local val = r[3][O[r[2]] + 1] or ''
        local vw = TextSize(val, F.small).x
        TextY(dl, px + 186 - vw, ry, 28, C(111, 116, 128), val, F.small)
        Chevron(dl, px + 195, ry + 11, C(150, 154, 165))
        if accepts and clicked then
            local key = r[2]
            OpenPopup('##acc' .. i, r[3], function(k) return O[key] == k - 1 end,
                function(k) O[key] = k - 1; return true end, px + w - 140, ry + 2, 134, 23)
        end
    end
    TextY(dl, px + 18, py + 66 + 3 * 28, 28, C(185, 188, 198), 'Synchronization', F.ctrl)
    Toggle(dl, '##acc_sync', px + 169, py + 150, 'acc_sync')

    if account.open and imgui.GetFrameCount() > account.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered() and not popupHovered()
        and not inRect(imgui.GetMousePos(), bx + 7, by + 531, 140, 38) then
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
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(V(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V(0.5, 0.5))
    imgui.SetNextWindowSize(V(SHELL_W, SHELL_H), imgui.Cond.Always)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

    local wf = imgui.WindowFlags
    imgui.Begin('##neverlose', menu, bit.bor(wf.NoTitleBar, wf.NoResize, wf.NoCollapse, wf.NoScrollbar,
        wf.NoScrollWithMouse, wf.NoSavedSettings, wf.NoBringToFrontOnFocus))

    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local bx, by = wp.x, wp.y
    local reveal = Motion('reveal', 1, 9, 0)
    local re = 1 - (1 - reveal) ^ 4
    local shellFirst = vtxFirst(dl)

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
        vtxScale(dl, shellFirst, bx + SHELL_W * 0.5, by + SHELL_H * 0.5, 0.92 + 0.08 * re, 0, (1 - re) * 16)
    end
    imgui.End()

    AccountPopover(bx, by, re)
    SubPopover(re)
    PopupLayer(re)
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
    gA = 1
end)

-- ============================================================ ANTI-AIM (рабочий)
local aaAngle, aaFlip = 0, false

local function aaHeading(base)
    local m = O.aa_mode
    if m == 0 then
        aaAngle = (aaAngle + O.aa_speed) % 360
        return aaAngle
    elseif m == 1 then
        aaFlip = not aaFlip
        local j = aaFlip and O.aa_jitter or -O.aa_jitter
        return (base + 180 + j) % 360
    elseif m == 2 then
        return math.random(0, 359)
    end
    return (base + 180) % 360
end

function sampev.onSendPlayerSync(data)
    if not O.aa_enable then return end
    if O.aa_noaim and isKeyDown(0x02) then return end
    local h = math.rad(aaHeading(getCharHeading(PLAYER_PED)))
    data.quaternion[0] = math.cos(h / 2)
    data.quaternion[1] = 0
    data.quaternion[2] = 0
    data.quaternion[3] = math.sin(h / 2)
end

-- ============================================================ INIT / MAIN
imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local st = imgui.GetStyle()
    st.WindowRounding, st.WindowBorderSize = 14, 0
    st.WindowPadding, st.ItemSpacing = V(0, 0), V(0, 0)

    local glyph = io.Fonts:GetGlyphRangesCyrillic()
    local res = getWorkingDirectory() .. '\\resource\\rage-mod\\'
    local sys = getFolderPath(0x14) .. '\\'
    local function pick(list)
        for _, p in ipairs(list) do if doesFileExist(p) then return p end end
    end
    local medium = pick({ res .. 'SSTMedium.TTF', sys .. 'seguisb.ttf', sys .. 'segoeui.ttf', sys .. 'arial.ttf' })
    local bold   = pick({ res .. 'SSTBold.TTF', sys .. 'segoeuib.ttf', sys .. 'arialbd.ttf' }) or medium
    local fa     = pick({ res .. 'fa-solid-900.ttf', getWorkingDirectory() .. '\\resource\\fonts\\fa-solid-900.ttf' })

    local cfg = imgui.ImFontConfig()
    cfg.OversampleH = 3
    cfg.PixelSnapH = true

    io.Fonts:Clear()
    F.body  = io.Fonts:AddFontFromFileTTF(medium, 15.0, cfg, glyph)
    F.ctrl  = io.Fonts:AddFontFromFileTTF(medium, 14.0, cfg, glyph)
    F.small = io.Fonts:AddFontFromFileTTF(medium, 12.0, cfg, glyph)
    F.cap   = io.Fonts:AddFontFromFileTTF(medium, 10.0, cfg, glyph)
    F.t9    = io.Fonts:AddFontFromFileTTF(medium, 9.0, cfg, glyph)
    F.t8    = io.Fonts:AddFontFromFileTTF(medium, 8.0, cfg, glyph)
    F.title = io.Fonts:AddFontFromFileTTF(bold, 16.0, cfg, glyph)
    if fa then F.icon = io.Fonts:AddFontFromFileTTF(fa, 13.0, cfg, FA_RANGES) end
end)

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadConfig()
    sampRegisterChatCommand('ragemd', toggleMenu)
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

        -- иконки оружия: следим, чтобы модели не выгрузились стримером
        if os.clock() - lastIconCheck > 1.5 then
            lastIconCheck = os.clock()
            refreshWeaponIcons(false)
        end
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then
        saveConfig()
        releaseWeaponIcons()
    end
end
