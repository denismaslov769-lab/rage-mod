--[[
    rage-mod — MoonLoader скрипт для SA-MP
    Меню в стиле NEVERLOSE (порт neverlose-last: D3D11/ImGui -> mimgui):
    сайдбар с группами и раскрывающимся Visuals, тулбар с профилем и
    выбором оружия, карточки с рядами 37px, pill-тогглы, анимированные
    слайдеры с value-pill, выпадающие списки со стеклянным попапом,
    поповер аккаунта, плавное появление меню и смена страниц.

    ВАЖНО: Aimbot/Triggerbot/ESP здесь — ТОЛЬКО интерфейс (значения
    сохраняются в конфиг, но не подключены к игре).
    Anti-Aim (крутилка) — рабочий: подменяет поворот персонажа в
    исходящем PlayerSync. Режимы: Spin / Jitter / Random / Backward.

    Активация: команда /ragemd или клавиша из настроек.
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui, SAMP.Lua (samp.events)
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('3.0.0')

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local ffi      = require 'ffi'
local sampev   = require 'samp.events'
encoding.default = 'CP1251'
local u8  = encoding.UTF8
local new = imgui.new

local CFG_FILE = 'rage-mod.ini'

-- ===================== СОСТОЯНИЕ =====================
local menu = new.bool(false)

local weapons = { 'Deagle', 'M4', 'AK-47', 'Shotgun', 'Combat Shotgun', 'MP5', 'Uzi', 'Tec-9', 'Rifle', 'Sniper' }
local weaponIdx = new.int(0)

local hitboxNames = { 'Head', 'Chest', 'Stomach', 'Pelvis', 'Arms', 'Legs' }

local S = {
    -- Aimbot (интерфейс)
    aim_enable   = new.bool(true),
    aim_hb       = { new.bool(true), new.bool(true), new.bool(true), new.bool(false), new.bool(false), new.bool(false) },
    aim_ignjump  = new.bool(false),
    aim_fovtype  = new.int(0),
    aim_smooth   = new.int(0),
    aim_autofire = new.int(0),
    aim_fov      = new.float(2.3),

    -- Triggerbot (интерфейс)
    tb_enable    = new.bool(true),
    tb_hb        = { new.bool(true), new.bool(true), new.bool(true), new.bool(false), new.bool(false), new.bool(false) },
    tb_type      = new.int(0),
    tb_onlyzoom  = new.bool(false),
    tb_hitchance = new.int(73),
    tb_delaybf   = new.float(0.0),
    tb_delayaf   = new.float(0.0),
    tb_autowall  = new.bool(false),
    tb_mindmg    = new.int(100),
    tb_delaytype = new.int(0),

    -- Anti-Aim / крутилка (рабочее)
    aa_enable    = new.bool(false),
    aa_mode      = new.int(0),
    aa_speed     = new.int(25),
    aa_jitter    = new.int(90),
    aa_noaim     = new.bool(true),
    aa_key       = new.int(0),

    -- Visuals (интерфейс)
    esp_box      = new.bool(true),
    esp_skel     = new.bool(false),
    esp_name     = new.bool(true),
    esp_hp       = new.bool(true),
    esp_dist     = new.bool(false),
    col_vis      = new.bool(true),
    col_hid      = new.bool(false),
    v_third      = new.bool(false),
    v_fov        = new.int(70),
    v_night      = new.bool(false),
    w_weap       = new.bool(false),
    w_gren       = new.bool(false),
    w_dist       = new.int(150),
    hud_wm       = new.bool(true),
    hud_kb       = new.bool(false),

    -- Прочее
    menu_key     = new.int(1),
    notify       = new.bool(true),
}

local fovTypeItems    = { 'Static', 'Dynamic' }
local smoothTypeItems = { 'Decrease', 'Static', 'Increase' }
local tbTypeItems     = { 'Normal', 'Burst' }
local delayTypeItems  = { 'Static', 'Random' }
local aaModeItems     = { 'Spin', 'Jitter', 'Random', 'Backward' }

local keyNames = { 'Нет', 'Insert', 'Delete', 'Home', 'End', 'F2', 'F3' }
local keyCodes = { 0, 0x2D, 0x2E, 0x24, 0x23, 0x71, 0x72 }

-- снимок значений по умолчанию (для Reset)
local DEFAULTS, DEFAULT_HB = {}, { aim = {}, tb = {} }
for k, v in pairs(S) do if type(v) == 'cdata' then DEFAULTS[k] = v[0] end end
for i = 1, #hitboxNames do DEFAULT_HB.aim[i] = S.aim_hb[i][0]; DEFAULT_HB.tb[i] = S.tb_hb[i][0] end

local F = {}  -- шрифты

-- ===================== УТИЛИТЫ =====================
local function chat(text)
    sampAddChatMessage(u8:decode('{4E83FF}[rage-mod]{FFFFFF} ' .. text), -1)
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function V(x, y) return imgui.ImVec2(x, y) end

local gA = 1  -- глобальный множитель прозрачности (анимации)
local function C(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r / 255, g / 255, b / 255, ((a or 255) / 255) * gA))
end
local function Mix(c1, c2, t)
    t = clamp(t, 0, 1)
    local a1, a2 = c1[4] or 255, c2[4] or 255
    return C(c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t,
             c1[3] + (c2[3] - c1[3]) * t, a1 + (a2 - a1) * t)
end

-- экспоненциальное сглаживание (как Motion() в оригинале)
local anim = {}
local function Motion(key, target, speed, initial)
    local v = anim[key]
    if v == nil then v = initial or target end
    local dt = imgui.GetIO().DeltaTime
    v = v + (target - v) * (1 - math.exp(-(speed or 16) * dt))
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

local function Chevron(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.3)
    dl:AddLine(V(x + 3, y + 3), V(x, y + 6), col, 1.3)
end

local function CheckMark(dl, x, y, col)
    dl:AddLine(V(x, y), V(x + 3, y + 3), col, 1.5)
    dl:AddLine(V(x + 3, y + 3), V(x + 8, y - 3), col, 1.5)
end

local function hbText(refs)
    local t = {}
    for i, b in ipairs(refs) do if b[0] then t[#t + 1] = hitboxNames[i] end end
    if #t == 0 then return 'None' end
    return table.concat(t, ', ')
end

-- ===================== ИКОНКИ (вектор вместо Font Awesome) =====================
local function rectOutline(dl, x1, y1, x2, y2, col, th)
    dl:AddLine(V(x1, y1), V(x2, y1), col, th); dl:AddLine(V(x2, y1), V(x2, y2), col, th)
    dl:AddLine(V(x2, y2), V(x1, y2), col, th); dl:AddLine(V(x1, y2), V(x1, y1), col, th)
end

local ICON = {}
ICON.rage = function(dl, x, y, c)
    dl:AddCircle(V(x + 7, y + 7), 5, c, 20, 1.5)
    dl:AddLine(V(x + 7, y - 1), V(x + 7, y + 3), c, 1.5)
    dl:AddLine(V(x + 7, y + 11), V(x + 7, y + 15), c, 1.5)
    dl:AddLine(V(x - 1, y + 7), V(x + 3, y + 7), c, 1.5)
    dl:AddLine(V(x + 11, y + 7), V(x + 15, y + 7), c, 1.5)
    dl:AddCircleFilled(V(x + 7, y + 7), 1.5, c, 10)
end
ICON.legit = function(dl, x, y, c)
    dl:AddRectFilled(V(x + 2, y), V(x + 12, y + 15), c, 5)
    dl:AddLine(V(x + 7, y + 1), V(x + 7, y + 6), C(18, 21, 30), 1.5)
end
ICON.visuals = function(dl, x, y, c)
    rectOutline(dl, x, y + 1, x + 14, y + 13, c, 1.5)
    dl:AddTriangleFilled(V(x + 2, y + 11), V(x + 6, y + 6), V(x + 9, y + 11), c)
    dl:AddTriangleFilled(V(x + 7, y + 11), V(x + 10, y + 7), V(x + 13, y + 11), c)
    dl:AddCircleFilled(V(x + 10, y + 4.5), 1.5, c, 10)
end
ICON.players = function(dl, x, y, c)
    dl:AddCircleFilled(V(x + 7, y + 4), 3.6, c, 16)
    dl:AddRectFilled(V(x + 1, y + 9), V(x + 13, y + 15), c, 4)
end
ICON.world = function(dl, x, y, c)
    dl:AddCircle(V(x + 7, y + 7), 6.5, c, 24, 1.5)
    dl:AddLine(V(x + 0.5, y + 7), V(x + 13.5, y + 7), c, 1.2)
    dl:AddLine(V(x + 7, y + 0.5), V(x + 7, y + 13.5), c, 1.2)
    dl:AddCircle(V(x + 7, y + 7), 3, c, 16, 1.2)
end
ICON.misc = function(dl, x, y, c)
    for i = 0, 2 do
        local ly = y + 2 + i * 5
        dl:AddLine(V(x, ly), V(x + 14, ly), c, 1.5)
        local kx = x + ({ 4, 10, 6 })[i + 1]
        dl:AddCircleFilled(V(kx, ly), 2.3, c, 12)
    end
end
ICON.save = function(dl, x, y, c)
    dl:AddRectFilled(V(x, y), V(x + 13, y + 13), c, 2)
    dl:AddRectFilled(V(x + 3, y + 1), V(x + 10, y + 5), C(17, 19, 27), 1)
    dl:AddRectFilled(V(x + 3, y + 8), V(x + 10, y + 12), C(17, 19, 27), 1)
end
ICON.gun = function(dl, x, y, c)
    dl:AddRectFilled(V(x, y + 2), V(x + 14, y + 6), c, 1)
    dl:AddRectFilled(V(x + 2, y + 6), V(x + 6, y + 12), c, 1)
end

-- ===================== КОНФИГ =====================
local function saveConfig()
    local t = { settings = {}, hb = {} }
    for k, v in pairs(S) do
        if type(v) == 'cdata' then t.settings[k] = v[0] end
    end
    t.settings.weaponIdx = weaponIdx[0]
    for i = 1, #hitboxNames do
        t.hb['aim' .. i] = S.aim_hb[i][0]
        t.hb['tb' .. i]  = S.tb_hb[i][0]
    end
    inicfg.save(t, CFG_FILE)
end

local function loadConfig()
    local t = inicfg.load(nil, CFG_FILE)
    if not t then return false end
    if t.settings then
        for k, v in pairs(S) do
            if type(v) == 'cdata' and t.settings[k] ~= nil then v[0] = t.settings[k] end
        end
        if t.settings.weaponIdx ~= nil then weaponIdx[0] = t.settings.weaponIdx end
    end
    if t.hb then
        for i = 1, #hitboxNames do
            if t.hb['aim' .. i] ~= nil then S.aim_hb[i][0] = t.hb['aim' .. i] end
            if t.hb['tb' .. i]  ~= nil then S.tb_hb[i][0]  = t.hb['tb' .. i]  end
        end
    end
    return true
end

local function resetConfig()
    for k, v in pairs(DEFAULTS) do S[k][0] = v end
    for i = 1, #hitboxNames do S.aim_hb[i][0] = DEFAULT_HB.aim[i]; S.tb_hb[i][0] = DEFAULT_HB.tb[i] end
    weaponIdx[0] = 0
end

local function actSave()  saveConfig();  chat('конфиг сохранён') end
local function actLoad()  if loadConfig() then chat('конфиг загружен') else chat('конфиг не найден') end end
local function actReset() resetConfig(); chat('настройки сброшены') end

-- ===================== ПОПАПЫ =====================
local popup = { open = false, owner = nil, multi = false, items = nil, ref = nil,
                x = 0, y = 0, w = 134, ox = 0, oy = 0, ow = 0, oh = 0, frame = 0 }
local account = { open = false, frame = 0 }

local function OpenPopup(owner, multi, items, ref, x, y, w, ow, oh)
    local same = popup.open and popup.owner == owner
    popup.open  = not same
    popup.owner = owner
    popup.multi = multi
    popup.items = items
    popup.ref   = ref
    popup.x, popup.y, popup.w = x, y, w
    popup.ox, popup.oy, popup.ow, popup.oh = x, y, ow or w, oh or 23
    popup.frame = imgui.GetFrameCount()
end

-- ===================== ВИДЖЕТЫ =====================
local function Toggle(dl, id, x, y, ref, enabled)
    if enabled == nil then enabled = true end
    local hov = false
    if enabled and ref then
        if Hit(id, x - 5, y - 6, 39, 30) then ref[0] = not ref[0] end
        hov = imgui.IsItemHovered()
    end
    local on = Motion(id .. '#on', (ref and ref[0]) and 1 or 0, 19)
    local hv = Motion(id .. '#hv', hov and 1 or 0, 20)
    if hv > 0.001 then
        dl:AddRectFilled(V(x - 1 - hv, y - 1 - hv), V(x + 30 + hv, y + 19 + hv), C(75, 126, 255, 45 * hv), 10)
    end
    dl:AddRectFilled(V(x, y), V(x + 29, y + 18), Mix({ 29, 33, 43 }, { 75, 126, 255 }, on), 9)
    local alphaMul = enabled and 255 or 120
    dl:AddCircleFilled(V(x + 9 + 11 * on, y + 9), 7,
        Mix({ 133, 144, 156, alphaMul }, { 248, 249, 252, alphaMul }, on), 24)
end

-- Ряд карточки: { label, type, ... }
--  toggle: ref | select: items, ref | multi: names, refs
--  slider: ref, min, max, isFloat, fmt | action: fn | color: ref, {r,g,b}
--  info: text | disabled
local function RowControl(dl, cx, y, w, row, id)
    local label, kind = row[1], row[2]
    local disabled = kind == 'disabled'
    TextY(dl, cx + 13, y, 37, disabled and C(92, 96, 107) or C(207, 209, 218), label, F.body)

    if kind == 'toggle' then
        Toggle(dl, id, cx + w - 43, y + 9, row[3])

    elseif kind == 'disabled' then
        Toggle(dl, id, cx + w - 43, y + 9, nil, false)

    elseif kind == 'select' or kind == 'multi' then
        local cw = math.min(134, w * 0.48)
        local px, py = cx + w - cw - 13, y + 7
        local click = Hit(id, px, py, cw, 23)
        local r = Motion(id .. '#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == id)) and 1 or 0)
        if click then OpenPopup(id, kind == 'multi', row[3], row[4], px, py, kind == 'multi' and 134 or cw) end
        dl:AddRectFilled(V(px, py), V(px + cw, py + 23), Mix({ 25, 28, 38 }, { 31, 38, 54 }, r), 5)
        dl:AddRect(V(px, py), V(px + cw, py + 23), Mix({ 32, 35, 46 }, { 75, 126, 255 }, r), 5)
        local value = kind == 'multi' and hbText(row[4]) or row[3][row[4][0] + 1] or 'Select'
        dl:PushClipRect(V(px, py), V(px + cw - 17, py + 23), true)
        TextY(dl, px + 7, py, 23, C(170, 173, 184), value, F.ctrl)
        dl:PopClipRect()
        dl:AddLine(V(px + cw - 13, py + 9), V(px + cw - 9, py + 13), C(139, 143, 154), 1)
        dl:AddLine(V(px + cw - 9, py + 13), V(px + cw - 5, py + 9), C(139, 143, 154), 1)

    elseif kind == 'slider' then
        local ref, vmin, vmax, isFloat, fmt = row[3], row[4], row[5], row[6], row[7]
        local txt = string.format(fmt, ref[0])
        local pw = math.max(42, TextSize(txt, F.ctrl).x + 12)
        local tw = 80
        local sx, sy = cx + w - pw - 13 - 10 - tw, y + 18
        Hit(id, sx - 5, sy - 8, tw + 10, 19)
        local active, hov = imgui.IsItemActive(), imgui.IsItemHovered()
        if active then
            local t = clamp((imgui.GetMousePos().x - sx) / tw, 0, 1)
            local nv = vmin + (vmax - vmin) * t
            if not isFloat then nv = math.floor(nv + 0.5) end
            ref[0] = nv
        end
        local target = clamp((ref[0] - vmin) / (vmax - vmin), 0, 1)
        local shown = Motion(id .. '#v', target, 14, 0)
        local halo = Motion(id .. '#h', (active or hov) and 1 or 0, 18)
        dl:AddRectFilled(V(sx, sy), V(sx + tw, sy + 3), C(34, 38, 48), 2)
        dl:AddRectFilled(V(sx, sy), V(sx + tw * shown, sy + 3), C(75, 126, 255), 2)
        if halo > 0.001 then dl:AddCircleFilled(V(sx + tw * shown, sy + 1.5), 5.5 + 3.5 * halo, C(75, 126, 255, 60 * halo), 24) end
        dl:AddCircleFilled(V(sx + tw * shown, sy + 1.5), 5.5, C(247, 248, 252), 24)
        local plx, ply = cx + w - pw - 13, y + 8
        dl:AddRectFilled(V(plx, ply), V(plx + pw, ply + 21), C(25, 28, 38), 5)
        local tsz = TextSize(txt, F.ctrl)
        TextY(dl, plx + (pw - tsz.x) * 0.5, ply, 21, C(166, 169, 179), txt, F.ctrl)

    elseif kind == 'color' then
        local c = row[4]
        dl:AddRectFilled(V(cx + w - 63, y + 11), V(cx + w - 48, y + 26), C(c[1], c[2], c[3]), 5)
        Toggle(dl, id, cx + w - 43, y + 9, row[3])

    elseif kind == 'action' then
        local click = Hit(id, cx + 4, y + 3, w - 8, 31)
        local r = Motion(id .. '#hv', imgui.IsItemHovered() and 1 or 0, 20)
        if r > 0.001 then dl:AddRectFilled(V(cx + 4, y + 3), V(cx + w - 4, y + 34), C(39, 43, 54, 160 * r), 8) end
        TextY(dl, cx + 13, y, 37, Mix({ 207, 209, 218 }, { 102, 164, 255 }, r), label, F.body)
        Chevron(dl, cx + w - 22, y + 15, C(187, 190, 199))
        if click then row[3]() end

    elseif kind == 'info' then
        local ts = TextSize(row[3], F.ctrl)
        TextY(dl, cx + w - 13 - ts.x, y, 37, C(146, 150, 162), row[3], F.ctrl)
    end
end

local function Card(dl, key, x, y, w, title, rows)
    local h = #rows * 37
    Text(dl, x + 12, y - 18, C(89, 94, 106), title, F.cap)
    dl:AddRectFilled(V(x, y), V(x + w, y + h), C(17, 19, 27, 224), 13)
    dl:AddRect(V(x, y), V(x + w, y + h), C(31, 34, 44), 13)
    for i, row in ipairs(rows) do
        local ry = y + (i - 1) * 37
        if i > 1 then dl:AddLine(V(x + 12, ry), V(x + w - 12, ry), C(28, 31, 40)) end
        RowControl(dl, x, ry, w, row, '##' .. key .. '_' .. row[1])
    end
    return y + h + 36
end

-- ===================== СТРАНИЦЫ =====================
local page, pageMix = 'rage', 1
local LX, LW, RX, RW, TOP = 167, 281, 458, 277, 84

local PAGES = {}
PAGES.rage = function(dl, bx, by)
    local y = Card(dl, 'r_main', bx + LX, by + TOP, LW, 'MAIN', {
        { 'Enabled',             'toggle', S.aim_enable },
        { 'FOV Type',            'select', fovTypeItems, S.aim_fovtype },
        { 'Smooth Type',         'select', smoothTypeItems, S.aim_smooth },
        { 'Field of View',       'slider', S.aim_fov, 0, 10, true, '%.1f°' },
        { 'Auto-Fire Hitchance', 'slider', S.aim_autofire, 0, 100, false, '%d%%' },
    })
    Card(dl, 'r_sel', bx + LX, y, LW, 'SELECTION', {
        { 'Hitboxes',    'multi',  hitboxNames, S.aim_hb },
        { 'Ignore Jump', 'toggle', S.aim_ignjump },
    })
    Card(dl, 'r_aa', bx + RX, by + TOP, RW, 'ANTI-AIM', {
        { 'Enabled',              'toggle', S.aa_enable },
        { 'Yaw Mode',             'select', aaModeItems, S.aa_mode },
        { 'Spin Speed',           'slider', S.aa_speed, 1, 90, false, '%d°' },
        { 'Jitter Range',         'slider', S.aa_jitter, 0, 180, false, '%d°' },
        { 'Disable While Aiming', 'toggle', S.aa_noaim },
        { 'Toggle Key',           'select', keyNames, S.aa_key },
    })
end

PAGES.legit = function(dl, bx, by)
    Card(dl, 'l_tb', bx + LX, by + TOP, LW, 'TRIGGERBOT', {
        { 'Enabled',    'toggle', S.tb_enable },
        { 'Type',       'select', tbTypeItems, S.tb_type },
        { 'Hitboxes',   'multi',  hitboxNames, S.tb_hb },
        { 'Only Zoom',  'toggle', S.tb_onlyzoom },
        { 'Hit Chance', 'slider', S.tb_hitchance, 0, 100, false, '%d%%' },
        { 'Min Damage', 'slider', S.tb_mindmg, 0, 100, false, '%d' },
        { 'Auto Wall',  'toggle', S.tb_autowall },
    })
    Card(dl, 'l_dl', bx + RX, by + TOP, RW, 'DELAYS', {
        { 'Type',        'select', delayTypeItems, S.tb_delaytype },
        { 'Before Shot', 'slider', S.tb_delaybf, 0, 1, true, '%.2fs' },
        { 'After Shot',  'slider', S.tb_delayaf, 0, 1, true, '%.2fs' },
    })
end

PAGES.players = function(dl, bx, by)
    Card(dl, 'p_esp', bx + LX, by + TOP, LW, 'ENEMY ESP', {
        { 'Box',      'toggle', S.esp_box },
        { 'Skeleton', 'toggle', S.esp_skel },
        { 'Name',     'toggle', S.esp_name },
        { 'Health',   'toggle', S.esp_hp },
        { 'Distance', 'toggle', S.esp_dist },
    })
    Card(dl, 'p_col', bx + RX, by + TOP, RW, 'ENEMY MODEL', {
        { 'Visible',  'color', S.col_vis, { 102, 124, 246 } },
        { 'Hidden',   'color', S.col_hid, { 246, 102, 124 } },
        { 'Ragdolls', 'disabled' },
    })
end

PAGES.world = function(dl, bx, by)
    local y = Card(dl, 'w_view', bx + LX, by + TOP, LW, 'VIEW', {
        { 'Thirdperson',   'toggle', S.v_third },
        { 'Field of View', 'slider', S.v_fov, 50, 120, false, '%d°' },
        { 'Night Mode',    'toggle', S.v_night },
    })
    Card(dl, 'w_hud', bx + LX, y, LW, 'HUD', {
        { 'Watermark',    'toggle', S.hud_wm },
        { 'Keybind List', 'toggle', S.hud_kb },
    })
    Card(dl, 'w_esp', bx + RX, by + TOP, RW, 'WORLD ESP', {
        { 'Dropped Weapons', 'toggle', S.w_weap },
        { 'Grenades',        'toggle', S.w_gren },
        { 'Max Distance',    'slider', S.w_dist, 10, 300, false, '%dm' },
    })
end

PAGES.misc = function(dl, bx, by)
    local y = Card(dl, 'm_menu', bx + LX, by + TOP, LW, 'MENU', {
        { 'Open Key',           'select', keyNames, S.menu_key },
        { 'Chat Notifications', 'toggle', S.notify },
    })
    Card(dl, 'm_cfg', bx + LX, y, LW, 'CONFIG', {
        { 'Save Config',  'action', actSave },
        { 'Load Config',  'action', actLoad },
        { 'Reset Config', 'action', actReset },
    })
    Card(dl, 'm_about', bx + RX, by + TOP, RW, 'ABOUT', {
        { 'Version', 'info', thisScript().version },
        { 'Command', 'info', '/ragemd' },
        { 'Config',  'info', CFG_FILE },
    })
end

local function ChangePage(p)
    if page == p then return end
    page, pageMix = p, 0
    popup.open = false
end

-- ===================== САЙДБАР / ТУЛБАР =====================
local function localIdentity()
    local name, id = 'Player', -1
    if isSampAvailable() then
        local ok, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then id = pid; name = sampGetPlayerNickname(pid) or name end
    end
    return name, id
end

local function Avatar(dl, x, y, r, name)
    dl:AddCircleFilled(V(x, y), r, C(39, 60, 110), 32)
    dl:AddCircle(V(x, y), r, C(75, 126, 255), 32, 1.2)
    local ch = (name or '?'):sub(1, 1):upper()
    local ts = TextSize(ch, F.bold)
    Text(dl, x - ts.x * 0.5, y - ts.y * 0.5, C(226, 232, 255), ch, F.bold)
end

local function Sidebar(dl, bx, by)
    dl:AddRectFilled(V(bx, by), V(bx + 158, by + 576), C(18, 21, 30, 231), 14)
    dl:AddRectFilled(V(bx + 145, by), V(bx + 158, by + 576), C(18, 21, 30, 231))
    dl:AddLine(V(bx + 158, by), V(bx + 158, by + 576), C(30, 33, 43))

    dl:AddRectFilled(V(bx + 15, by + 11), V(bx + 45, by + 43), C(8, 27, 48), 7)
    local lg = TextSize('RM', F.bold)
    Text(dl, bx + 30 - lg.x * 0.5, by + 27 - lg.y * 0.5, C(94, 185, 255), 'RM', F.bold)
    Text(dl, bx + 53, by + 12, C(228, 230, 236), 'rage-mod', F.bold)
    Text(dl, bx + 53, by + 31, C(91, 96, 108), 'SA-MP', F.cap)
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
        ICON[icon](dl, px + 10, py + 8, Mix({ 137, 142, 153 }, { 82, 141, 255 }, r))
        TextY(dl, px + 31, py, 30, Mix({ 145, 149, 159 }, { 226, 228, 235 }, r), label, F.body)
    end

    local visuals = page == 'players' or page == 'world'
    nav('rage',  'rage',    'Rage',    84,  'rage',    page == 'rage')
    nav('legit', 'legit',   'Legit',   120, 'legit',   page == 'legit')
    nav('vis',   'visuals', 'Visuals', 190, 'players', visuals)
    local expand = Motion('visual_expand', visuals and 1 or 0, 18)
    if expand > 0.02 then
        local saved = gA
        gA = gA * expand
        nav('players', 'players', 'Players', 226, 'players', page == 'players', 14)
        nav('world',   'world',   'World',   262, 'world',   page == 'world', 14)
        gA = saved
    end
    local shift = 72 * expand
    nav('misc', 'misc', 'Miscellaneous', 226 + shift, 'misc', page == 'misc')

    -- аккаунт
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
    Text(dl, ax + 43, ay + 21, C(111, 116, 128), id >= 0 and ('ID: ' .. id) or 'offline', F.small)
    dl:PopClipRect()
    Chevron(dl, ax + 132, ay + 15, C(181, 185, 195))
end

local function Toolbar(dl, bx, by)
    local tb = C(11, 13, 20, 225)
    dl:AddRectFilled(V(bx + 158, by), V(bx + 748, by + 56), tb, 14)
    dl:AddRectFilled(V(bx + 158, by), V(bx + 734, by + 56), tb)
    dl:AddRectFilled(V(bx + 158, by + 14), V(bx + 748, by + 56), tb)
    dl:AddLine(V(bx + 158, by + 56), V(bx + 748, by + 56), C(27, 30, 39))

    -- профиль (клик = сохранить конфиг)
    local px, py = bx + 169, by + 14
    if Hit('##tb_profile', px, py, 166, 30) then actSave() end
    local r = Motion('tb_profile#hv', imgui.IsItemHovered() and 1 or 0)
    dl:AddRectFilled(V(px, py), V(px + 166, py + 30), Mix({ 17, 19, 27 }, { 24, 27, 37 }, r), 6)
    dl:AddRect(V(px, py), V(px + 166, py + 30), Mix({ 28, 31, 41 }, { 75, 126, 255 }, r), 6)
    ICON.save(dl, px + 12, py + 9, C(194, 197, 206))
    TextY(dl, px + 40, py, 30, C(184, 187, 197), CFG_FILE, F.ctrl)
    Chevron(dl, px + 148, py + 11, C(130, 135, 146))

    -- выбор оружия для Rage/Legit
    if page == 'rage' or page == 'legit' then
        local gx, gy, gw = bx + 348, by + 14, 130
        local click = Hit('##tb_weapon', gx, gy, gw, 30)
        local wr = Motion('tb_weapon#hv', (imgui.IsItemHovered() or (popup.open and popup.owner == '##tb_weapon')) and 1 or 0)
        if click then OpenPopup('##tb_weapon', false, weapons, weaponIdx, gx, gy + 3, gw, gw, 30) end
        dl:AddRectFilled(V(gx, gy), V(gx + gw, gy + 30), Mix({ 17, 19, 27 }, { 24, 27, 37 }, wr), 6)
        dl:AddRect(V(gx, gy), V(gx + gw, gy + 30), Mix({ 28, 31, 41 }, { 75, 126, 255 }, wr), 6)
        ICON.gun(dl, gx + 11, gy + 9, C(194, 197, 206))
        TextY(dl, gx + 33, gy, 30, C(184, 187, 197), weapons[weaponIdx[0] + 1] or 'Global', F.ctrl)
        Chevron(dl, gx + gw - 17, gy + 11, C(130, 135, 146))
    end

    -- поиск (декор)
    dl:AddCircle(V(bx + 719, by + 28), 5, C(180, 184, 194), 20, 2)
    dl:AddLine(V(bx + 723, by + 32), V(bx + 727, by + 36), C(180, 184, 194), 2)
end

-- ===================== СЛОИ ПОВЕРХ (отдельные окна) =====================
local OVERLAY_FLAGS
local function overlayFlags()
    if not OVERLAY_FLAGS then
        local wf = imgui.WindowFlags
        OVERLAY_FLAGS = bit.bor(wf.NoTitleBar, wf.NoResize, wf.NoMove, wf.NoCollapse,
            wf.NoScrollbar, wf.NoScrollWithMouse, wf.NoSavedSettings)
    end
    return OVERLAY_FLAGS
end

local function inRect(m, x, y, w, h) return m.x >= x and m.x <= x + w and m.y >= y and m.y <= y + h end

local function PopupLayer(reveal)
    local open = Motion('popup_open', popup.open and 1 or 0, 20, 0)
    if open < 0.002 or not popup.items then return end
    local count = #popup.items
    local w, h = popup.w, count * 32 + 8
    local sw, sh = getScreenResolution()
    local e = 1 - (1 - open) ^ 3
    local px = clamp(popup.x, 10, sw - w - 10) + 4 * (1 - e)
    local py = clamp(popup.y + (23 - h) * 0.5, 10, sh - h - 10)

    imgui.SetNextWindowPos(V(px - 6, py - 4), imgui.Cond.Always)
    imgui.SetNextWindowSize(V(w + 12, h + 14), imgui.Cond.Always)
    imgui.Begin('##nl_popup', nil, overlayFlags())
    local dl = imgui.GetWindowDrawList()
    gA = reveal * e
    dl:AddRectFilled(V(px - 5, py - 2), V(px + w + 5, py + h + 8), C(0, 0, 0, 55), 18)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(20, 20, 29, 240), 15)
    dl:AddRect(V(px, py), V(px + w, py + h), C(57, 61, 76, 205), 15)
    dl:AddLine(V(px + 16, py + 1), V(px + w - 16, py + 1), C(255, 255, 255, 22))

    local accepts = imgui.GetFrameCount() > popup.frame and popup.open
    for i, name in ipairs(popup.items) do
        local rx, ry = px + 4, py + 4 + (i - 1) * 32
        local clicked = Hit('##pp_row' .. i, rx, ry, w - 8, 32)
        local hv = Motion('pp#' .. tostring(popup.owner) .. i, imgui.IsItemHovered() and 1 or 0, 22)
        if hv > 0.001 then dl:AddRectFilled(V(rx, ry), V(rx + w - 8, ry + 32), C(75, 126, 255, 25 * hv), 10) end
        local selected
        if popup.multi then selected = popup.ref[i][0] else selected = popup.ref[0] == i - 1 end
        if selected then CheckMark(dl, rx + 14, ry + 16, C(230, 233, 241)) end
        TextY(dl, rx + 35, ry, 32, selected and C(224, 229, 243) or C(182, 185, 196), name, F.ctrl)
        if accepts and clicked then
            if popup.multi then popup.ref[i][0] = not popup.ref[i][0]
            else popup.ref[0] = i - 1; popup.open = false end
        end
    end

    if popup.open and imgui.GetFrameCount() > popup.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered() and not inRect(imgui.GetMousePos(), popup.ox, popup.oy, popup.ow, popup.oh) then
        popup.open = false
    end
    imgui.End()
end

local function AccountPopover(bx, by, reveal)
    local open = Motion('account_open', account.open and 1 or 0, 17, 0)
    if open < 0.002 then return end
    local e = 1 - (1 - open) ^ 3
    local w, h = 218, 186
    local px, py = bx + 151, by + 375 + 8 * (1 - e)
    imgui.SetNextWindowPos(V(px - 6, py - 4), imgui.Cond.Always)
    imgui.SetNextWindowSize(V(w + 12, h + 14), imgui.Cond.Always)
    imgui.Begin('##nl_account', nil, overlayFlags())
    local dl = imgui.GetWindowDrawList()
    gA = reveal * e

    dl:AddRectFilled(V(px - 4, py - 2), V(px + w + 4, py + h + 7), C(0, 0, 0, 65), 18)
    dl:AddRectFilled(V(px, py), V(px + w, py + h), C(24, 25, 34, 245), 16)
    dl:AddRect(V(px, py), V(px + w, py + h), C(48, 51, 64), 16)

    local name, id = localIdentity()
    Avatar(dl, px + 35, py + 34, 18, name)
    dl:PushClipRect(V(px + 62, py), V(px + w - 10, py + 60), true)
    Text(dl, px + 64, py + 15, C(229, 231, 237), name, F.body)
    Text(dl, px + 64, py + 34, C(115, 164, 255), id >= 0 and ('ID: ' .. id .. '  |  v' .. thisScript().version) or 'offline', F.ctrl)
    dl:PopClipRect()
    dl:AddLine(V(px + 14, py + 62), V(px + w - 14, py + 62), C(40, 43, 55))

    local rows = { { 'Save Config', actSave }, { 'Load Config', actLoad }, { 'Reset Config', actReset } }
    local accepts = imgui.GetFrameCount() > account.frame and account.open
    for i, r in ipairs(rows) do
        local ry = py + 68 + (i - 1) * 28
        local clicked = Hit('##acc_row' .. i, px + 6, ry, w - 12, 28)
        local hv = Motion('acc#' .. i, imgui.IsItemHovered() and 1 or 0, 22)
        if hv > 0.001 then dl:AddRectFilled(V(px + 6, ry), V(px + w - 6, ry + 28), C(75, 126, 255, 25 * hv), 8) end
        TextY(dl, px + 18, ry, 28, Mix({ 185, 188, 198 }, { 224, 229, 243 }, hv), r[1], F.ctrl)
        Chevron(dl, px + 195, ry + 11, C(150, 154, 165))
        if accepts and clicked then r[2]() end
    end
    local ty = py + 68 + 3 * 28
    TextY(dl, px + 18, ty, 28, C(185, 188, 198), 'Notifications', F.ctrl)
    Toggle(dl, '##acc_notify', px + 169, ty + 5, S.notify)

    if account.open and imgui.GetFrameCount() > account.frame and imgui.IsMouseClicked(0)
        and not imgui.IsWindowHovered() and not inRect(imgui.GetMousePos(), bx + 7, by + 531, 140, 38) then
        account.open = false
    end
    imgui.End()
end

-- ===================== РЕНДЕР МЕНЮ =====================
local SHELL_W, SHELL_H = 748, 576

local function toggleMenu()
    menu[0] = not menu[0]
    if menu[0] then anim.reveal = 0 end
    popup.open, account.open = false, false
end

imgui.OnFrame(function() return menu[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(V(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V(0.5, 0.5))
    imgui.SetNextWindowSize(V(SHELL_W, SHELL_H), imgui.Cond.Always)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

    local wf = imgui.WindowFlags
    imgui.Begin('##neverlose', menu, bit.bor(wf.NoTitleBar, wf.NoResize, wf.NoCollapse,
        wf.NoScrollbar, wf.NoScrollWithMouse, wf.NoSavedSettings))

    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local reveal = Motion('reveal', 1, 9, 0)
    local re = 1 - (1 - reveal) ^ 4
    local bx, by = wp.x, wp.y + (1 - re) * 16

    gA = re
    dl:AddRectFilled(V(bx, by), V(bx + SHELL_W, by + SHELL_H), C(13, 15, 22, 235), 14)
    Sidebar(dl, bx, by)
    Toolbar(dl, bx, by)

    pageMix = pageMix + (1 - pageMix) * (1 - math.exp(-15 * imgui.GetIO().DeltaTime))
    local pe = 1 - (1 - pageMix) ^ 3
    gA = re * pe
    local fn = PAGES[page] or PAGES.rage
    fn(dl, bx + 9 * (1 - pe), by)
    gA = re

    dl:AddRect(V(bx, by), V(bx + SHELL_W, by + SHELL_H), C(30, 33, 43), 14)
    imgui.End()
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
    AccountPopover(bx, by, re)
    PopupLayer(re)
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
    gA = 1
end)

-- ===================== ANTI-AIM =====================
local aaAngle, aaFlip = 0, false

local function aaHeading(base)
    local m = S.aa_mode[0]
    if m == 0 then                                   -- Spin
        aaAngle = (aaAngle + S.aa_speed[0]) % 360
        return aaAngle
    elseif m == 1 then                               -- Jitter (вокруг "спиной")
        aaFlip = not aaFlip
        local j = aaFlip and S.aa_jitter[0] or -S.aa_jitter[0]
        return (base + 180 + j) % 360
    elseif m == 2 then                               -- Random
        return math.random(0, 359)
    end
    return (base + 180) % 360                        -- Backward
end

function sampev.onSendPlayerSync(data)
    if not S.aa_enable[0] then return end
    if S.aa_noaim[0] and isKeyDown(0x02) then return end
    local h = math.rad(aaHeading(getCharHeading(PLAYER_PED)))
    -- поворот вокруг оси Z: (w, x, y, z)
    data.quaternion[0] = math.cos(h / 2)
    data.quaternion[1] = 0
    data.quaternion[2] = 0
    data.quaternion[3] = math.sin(h / 2)
end

-- ===================== INIT / MAIN =====================
local function applyStyle()
    local st = imgui.GetStyle()
    st.WindowRounding = 14
    st.WindowBorderSize = 0
    st.WindowPadding = V(0, 0)
    st.ItemSpacing = V(0, 0)
    st.Colors[imgui.Col.Text] = imgui.ImVec4(0.85, 0.86, 0.89, 1)
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local glyph = io.Fonts:GetGlyphRangesCyrillic()
    local dir = getFolderPath(0x14) .. '\\'
    local function pick(list)
        for _, n in ipairs(list) do
            if doesFileExist(dir .. n) then return dir .. n end
        end
        return dir .. 'arial.ttf'
    end
    local regular = pick({ 'seguisb.ttf', 'segoeui.ttf', 'trebucbd.ttf', 'arial.ttf' })
    local bold    = pick({ 'segoeuib.ttf', 'trebucbd.ttf', 'arialbd.ttf' })
    io.Fonts:Clear()
    F.body  = io.Fonts:AddFontFromFileTTF(regular, 15.0, nil, glyph)
    F.ctrl  = io.Fonts:AddFontFromFileTTF(regular, 14.0, nil, glyph)
    F.small = io.Fonts:AddFontFromFileTTF(regular, 12.0, nil, glyph)
    F.cap   = io.Fonts:AddFontFromFileTTF(bold,    10.0, nil, glyph)
    F.bold  = io.Fonts:AddFontFromFileTTF(bold,    16.0, nil, glyph)
    applyStyle()
end)

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadConfig()
    sampRegisterChatCommand('ragemd', toggleMenu)
    chat('загружен. Меню: {4E83FF}/ragemd')

    while true do
        wait(0)
        local free = not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive()

        local key = keyCodes[S.menu_key[0] + 1]
        if key and key ~= 0 and isKeyJustPressed(key) and free then
            toggleMenu()
        end

        local aak = keyCodes[S.aa_key[0] + 1]
        if aak and aak ~= 0 and isKeyJustPressed(aak) and free then
            S.aa_enable[0] = not S.aa_enable[0]
            if S.notify[0] then
                chat('Anti-Aim: ' .. (S.aa_enable[0] and '{3DE07A}ON' or '{E03D3D}OFF'))
            end
        end
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then saveConfig() end
end
