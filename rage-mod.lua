--[[
    rage-mod — MoonLoader скрипт для SA-MP
    Меню в стиле MIDNIGHT (CS2-софт): шапка с вкладками, боковая панель,
    карточки-секции, кастомные виджеты (чекбоксы, выпадающие списки,
    слайдеры с кольцевым бегунком).

    ВАЖНО: боевые разделы (Aimbot/Triggerbot) здесь — ТОЛЬКО интерфейс.
    Элементы хранят значения в конфиге и НЕ подключены к наведению/стрельбе.

    Активация: команда /ragemd или клавиша из настроек.
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('2.0.0')

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local ffi      = require 'ffi'
encoding.default = 'CP1251'
local u8  = encoding.UTF8
local new = imgui.new

local CFG_FILE = 'rage-mod.ini'

-- ===================== СОСТОЯНИЕ =====================
local menu = new.bool(false)
local topTab  = new.int(1)        -- 0 = GLOBALS, 1 = WEAPONS
local sidePage = 1                -- выбранный пункт сайдбара (индекс)

-- Палитра MIDNIGHT
local COL = {
    windowBg   = {0.078, 0.082, 0.094},
    panelBg    = {0.102, 0.107, 0.121},
    sidebarBg  = {0.086, 0.090, 0.102},
    fieldBg    = {0.145, 0.153, 0.172},
    fieldHover = {0.176, 0.184, 0.204},
    track      = {0.223, 0.235, 0.262},
    border     = {0.160, 0.168, 0.188},
    text       = {0.820, 0.835, 0.862},
    textDim    = {0.420, 0.445, 0.498},
    textHead   = {0.520, 0.545, 0.600},
    accent     = {0.243, 0.608, 0.882},
}

-- Оружие (для списка в разделе Weapon)
local weapons = { 'AWP', 'AK-47', 'M4A4', 'M4A1-S', 'Deagle', 'Glock-18', 'USP-S', 'AUG', 'SG 553' }
local weaponIdx = new.int(0)

-- Наборы хитбоксов (мультивыбор)
local hitboxNames = { 'Head', 'Chest', 'Stomach', 'Pelvis', 'Arms', 'Legs' }

-- ===================== НАСТРОЙКИ (ЗАГЛУШКИ) =====================
local S = {
    -- Aimbot (интерфейс)
    aim_enable   = new.bool(true),
    aim_hb       = { new.bool(true), new.bool(true), new.bool(true), new.bool(false), new.bool(false), new.bool(false) },
    aim_ignjump  = new.bool(false),
    aim_fovtype  = new.int(0),     -- Static / Dynamic
    aim_smooth   = new.int(0),     -- Decrease / Static / Increase
    aim_autofire = new.int(0),     -- Auto-fire hitchance
    aim_fov      = new.float(2.3), -- Settings: FOV

    -- Triggerbot (интерфейс)
    tb_enable    = new.bool(true),
    tb_hb        = { new.bool(true), new.bool(true), new.bool(true), new.bool(false), new.bool(false), new.bool(false) },
    tb_type      = new.int(0),     -- Normal / Burst
    tb_onlyzoom  = new.bool(false),
    tb_hitchance = new.int(73),
    tb_delaybf   = new.float(0.0),
    tb_delayaf   = new.float(0.0),
    tb_autowall  = new.bool(false),
    tb_mindmg    = new.int(100),
    tb_delaytype = new.int(0),     -- Delays: Type

    -- Прочее
    menu_key     = new.int(1),
}

local hbRefs = { aim = S.aim_hb, tb = S.tb_hb }

local fovTypeItems    = { 'Static', 'Dynamic' }
local smoothTypeItems = { 'Decrease', 'Static', 'Increase' }
local tbTypeItems     = { 'Normal', 'Burst' }
local delayTypeItems  = { 'Static', 'Random' }

local keyNames = { 'Нет', 'Insert', 'Delete', 'Home', 'End', 'F2', 'F3' }
local keyCodes = { 0, 0x2D, 0x2E, 0x24, 0x23, 0x71, 0x72 }
local keyItems = new['const char*'][#keyNames](keyNames)

-- Сайдбар: группы и пункты
local sidebar = {
    { group = 'Combat' },
    { page = 'Aimbot',  icon = 'aim' },
    { group = 'Visuals' },
    { page = 'Players', icon = 'ply' },
    { page = 'Items',   icon = 'itm' },
    { page = 'View',    icon = 'eye' },
    { page = 'Hud',     icon = 'hud' },
    { group = 'Misc' },
    { page = 'Main',    icon = 'main' },
    { page = 'Cloud',   icon = 'cloud' },
}

local font_logo, font_main, font_big

-- ===================== УТИЛИТЫ =====================
local function chat(text)
    sampAddChatMessage(u8:decode('{3D9BE0}[rage-mod]{FFFFFF} ' .. text), -1)
end

local function V4(t, a) return imgui.ImVec4(t[1], t[2], t[3], a or 1) end
local function U32(t, a) return imgui.GetColorU32Vec4(imgui.ImVec4(t[1], t[2], t[3], a or 1)) end
local function accV(a) return V4(COL.accent, a) end
local function accU(a) return U32(COL.accent, a) end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Текст выбранных хитбоксов ("Head, Chest, Stomach")
local function hbText(refs)
    local t = {}
    for i, b in ipairs(refs) do if b[0] then t[#t + 1] = hitboxNames[i] end end
    if #t == 0 then return 'None' end
    return table.concat(t, ', ')
end

-- ===================== ТЕМА =====================
local function applyTheme()
    local st = imgui.GetStyle()
    local c, col = st.Colors, imgui.Col
    st.WindowRounding   = 10
    st.ChildRounding    = 6
    st.PopupRounding    = 6
    st.FrameRounding    = 4
    st.GrabRounding     = 4
    st.ScrollbarRounding = 6
    st.WindowBorderSize = 0
    st.ChildBorderSize  = 0
    st.FrameBorderSize  = 0
    st.PopupBorderSize  = 1
    st.WindowPadding    = imgui.ImVec2(0, 0)
    st.FramePadding     = imgui.ImVec2(8, 5)
    st.ItemSpacing      = imgui.ImVec2(8, 8)
    st.ScrollbarSize    = 7
    st.GrabMinSize      = 8

    c[col.Text]            = V4(COL.text)
    c[col.TextDisabled]    = V4(COL.textDim)
    c[col.WindowBg]        = V4(COL.windowBg)
    c[col.ChildBg]         = V4(COL.panelBg, 0)
    c[col.PopupBg]         = V4(COL.fieldBg, 0.99)
    c[col.Border]          = V4(COL.border)
    c[col.FrameBg]         = V4(COL.fieldBg)
    c[col.FrameBgHovered]  = V4(COL.fieldHover)
    c[col.FrameBgActive]   = V4(COL.fieldHover)
    c[col.CheckMark]       = V4({1, 1, 1})
    c[col.SliderGrab]      = accV()
    c[col.SliderGrabActive]= accV()
    c[col.Button]          = V4(COL.fieldBg)
    c[col.ButtonHovered]   = V4(COL.fieldHover)
    c[col.ButtonActive]    = accV(0.8)
    c[col.Header]          = accV(0.25)
    c[col.HeaderHovered]   = V4(COL.fieldHover)
    c[col.HeaderActive]    = accV(0.4)
    c[col.Separator]       = V4(COL.border)
    c[col.ScrollbarBg]     = V4(COL.windowBg, 0)
    c[col.ScrollbarGrab]   = V4(COL.track)
    c[col.ScrollbarGrabHovered] = accV(0.6)
    c[col.ScrollbarGrabActive]  = accV()
end

-- ===================== КАСТОМНЫЕ ВИДЖЕТЫ =====================

-- Заголовок секции (серый, с тонкой линией-разделителем)
local function SectionHeader(title)
    imgui.Dummy(imgui.ImVec2(0, 2))
    imgui.TextColored(V4(COL.textHead), title)
    imgui.Dummy(imgui.ImVec2(0, 2))
end

-- Чекбокс с акцентной заливкой и подписью справа
local function Check(id, label, bool)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local sz = 16
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(sz, sz))
    if clicked then bool[0] = not bool[0] end
    local hov = imgui.IsItemHovered()
    if bool[0] then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + sz, p.y + sz), accU(), 4)
        -- галочка
        dl:AddLine(imgui.ImVec2(p.x + 4, p.y + 8), imgui.ImVec2(p.x + 7, p.y + 11.5), U32({1,1,1}), 1.8)
        dl:AddLine(imgui.ImVec2(p.x + 7, p.y + 11.5), imgui.ImVec2(p.x + 12.5, p.y + 4.5), U32({1,1,1}), 1.8)
    else
        dl:AddRectFilled(p, imgui.ImVec2(p.x + sz, p.y + sz), U32(hov and COL.fieldHover or COL.fieldBg), 4)
        dl:AddRect(p, imgui.ImVec2(p.x + sz, p.y + sz), U32(COL.border), 4)
    end
    if label and label ~= '' then
        imgui.SameLine(0, 8)
        imgui.SetCursorPosY(imgui.GetCursorPosY() - 1)
        imgui.Text(label)
    end
    return clicked
end

-- Выпадающий список (одиночный выбор), вид — тёмное поле с текстом и шевроном
local function fieldBox(id, text, h)
    h = h or 28
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local hov = imgui.IsItemHovered()
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), U32(hov and COL.fieldHover or COL.fieldBg), 4)
    local ts = imgui.CalcTextSize(text)
    dl:AddText(imgui.ImVec2(p.x + 10, p.y + (h - ts.y) * 0.5), U32(COL.text), text)
    -- шеврон
    local cx, cy = p.x + w - 16, p.y + h * 0.5
    dl:AddLine(imgui.ImVec2(cx, cy - 2), imgui.ImVec2(cx + 4, cy + 2), U32(COL.textDim), 1.4)
    dl:AddLine(imgui.ImVec2(cx + 4, cy + 2), imgui.ImVec2(cx + 8, cy - 2), U32(COL.textDim), 1.4)
    return clicked, p, w, h
end

local function Combo(id, items, idxptr)
    local clicked = fieldBox(id, items[idxptr[0] + 1])
    if clicked then imgui.OpenPopup(id .. '_pp') end
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(6, 6))
    if imgui.BeginPopup(id .. '_pp') then
        for i, it in ipairs(items) do
            if imgui.Selectable(it .. '##' .. id .. i, idxptr[0] == i - 1) then idxptr[0] = i - 1 end
        end
        imgui.EndPopup()
    end
    imgui.PopStyleVar()
end

-- Мультивыбор хитбоксов
local function MultiHitbox(id, refs)
    local clicked = fieldBox(id, hbText(refs))
    if clicked then imgui.OpenPopup(id .. '_pp') end
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(8, 8))
    if imgui.BeginPopup(id .. '_pp') then
        for i, name in ipairs(hitboxNames) do
            Check(id .. '_hb' .. i, name, refs[i])
        end
        imgui.EndPopup()
    end
    imgui.PopStyleVar()
end

-- Слайдер: подпись слева, значение справа, трек с кольцевым бегунком
local function Slider(id, label, ptr, vmin, vmax, isFloat, fmt)
    imgui.Text(label)
    local v = ptr[0]
    local txt = string.format(fmt, v)
    local tw = imgui.CalcTextSize(txt)
    imgui.SameLine()
    local avail = imgui.GetContentRegionAvail().x
    imgui.SetCursorPosX(imgui.GetCursorPosX() + avail - tw.x)
    imgui.TextColored(V4({0.92, 0.93, 0.95}), txt)

    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    imgui.InvisibleButton(id, imgui.ImVec2(w, 14))
    if imgui.IsItemActive() then
        local mx = imgui.GetMousePos().x
        local t  = clamp((mx - p.x) / w, 0, 1)
        local nv = vmin + (vmax - vmin) * t
        if not isFloat then nv = math.floor(nv + 0.5) end
        ptr[0] = nv
    end
    local t = clamp((ptr[0] - vmin) / (vmax - vmin), 0, 1)
    local ly = p.y + 7
    local kx = p.x + w * t
    dl:AddLine(imgui.ImVec2(p.x, ly), imgui.ImVec2(p.x + w, ly), U32(COL.track), 3)
    dl:AddLine(imgui.ImVec2(p.x, ly), imgui.ImVec2(kx, ly), accU(), 3)
    dl:AddCircleFilled(imgui.ImVec2(kx, ly), 6, accU(), 20)
    dl:AddCircleFilled(imgui.ImVec2(kx, ly), 3, U32({1, 1, 1}), 16)
    imgui.Dummy(imgui.ImVec2(0, 2))
end

-- Иконка пункта сайдбара (простые фигуры на drawlist)
local function drawSideIcon(dl, x, y, kind, col)
    local s = 7
    if kind == 'aim' then
        dl:AddCircle(imgui.ImVec2(x + s, y + s), 6, col, 16, 1.6)
        dl:AddLine(imgui.ImVec2(x + s, y - 1), imgui.ImVec2(x + s, y + 3), col, 1.6)
        dl:AddLine(imgui.ImVec2(x + s, y + 2 * s + 1), imgui.ImVec2(x + s, y + 2 * s - 3), col, 1.6)
        dl:AddLine(imgui.ImVec2(x - 1, y + s), imgui.ImVec2(x + 3, y + s), col, 1.6)
        dl:AddLine(imgui.ImVec2(x + 2 * s + 1, y + s), imgui.ImVec2(x + 2 * s - 3, y + s), col, 1.6)
    elseif kind == 'ply' then
        dl:AddCircleFilled(imgui.ImVec2(x + s, y + 4), 4, col, 16)
        dl:AddRectFilled(imgui.ImVec2(x + 1, y + 9), imgui.ImVec2(x + 2 * s + 1, y + 2 * s + 2), col, 3)
    elseif kind == 'itm' then
        dl:AddRect(imgui.ImVec2(x, y + 2), imgui.ImVec2(x + 2 * s + 2, y + 2 * s), col, 2, 0, 1.6)
        dl:AddLine(imgui.ImVec2(x, y + 6), imgui.ImVec2(x + 2 * s + 2, y + 6), col, 1.6)
    elseif kind == 'eye' then
        dl:AddCircle(imgui.ImVec2(x + s, y + s), 6, col, 16, 1.6)
        dl:AddCircleFilled(imgui.ImVec2(x + s, y + s), 2.2, col, 12)
    elseif kind == 'hud' then
        dl:AddRect(imgui.ImVec2(x, y + 1), imgui.ImVec2(x + 2 * s + 2, y + 2 * s + 1), col, 2, 0, 1.6)
        dl:AddLine(imgui.ImVec2(x + s + 1, y + 1), imgui.ImVec2(x + s + 1, y + 2 * s + 1), col, 1.4)
    elseif kind == 'main' then
        dl:AddRectFilled(imgui.ImVec2(x, y + 1), imgui.ImVec2(x + 5, y + 6), col, 1)
        dl:AddRectFilled(imgui.ImVec2(x + 8, y + 1), imgui.ImVec2(x + 13, y + 6), col, 1)
        dl:AddRectFilled(imgui.ImVec2(x, y + 9), imgui.ImVec2(x + 5, y + 14), col, 1)
        dl:AddRectFilled(imgui.ImVec2(x + 8, y + 9), imgui.ImVec2(x + 13, y + 14), col, 1)
    elseif kind == 'cloud' then
        dl:AddCircleFilled(imgui.ImVec2(x + 4, y + 9), 4, col, 14)
        dl:AddCircleFilled(imgui.ImVec2(x + 10, y + 8), 5, col, 14)
        dl:AddRectFilled(imgui.ImVec2(x + 3, y + 9), imgui.ImVec2(x + 13, y + 13), col, 1)
    end
end

-- ===================== СТРАНИЦЫ КОНТЕНТА =====================

-- Колонка-обёртка
local function column(id, w, fn)
    imgui.BeginChild(id, imgui.ImVec2(w, 0), false)
    imgui.PushItemWidth(-1)
    fn()
    imgui.PopItemWidth()
    imgui.EndChild()
end

-- Левая колонка WEAPONS: Weapon + Aimbot + Settings
local function colWeaponLeft()
    SectionHeader('Weapon')
    Combo('##weapon', weapons, weaponIdx)
    imgui.Dummy(imgui.ImVec2(0, 6))

    SectionHeader('Aimbot')
    Check('##aim_en', 'Enable', S.aim_enable)
    imgui.Text('Hitboxes')
    MultiHitbox('##aim_hb', S.aim_hb)
    Check('##aim_ij', 'Ignore jump', S.aim_ignjump)
    imgui.Text('Fov type')
    Combo('##aim_fovtype', fovTypeItems, S.aim_fovtype)
    imgui.Text('Smooth type')
    Combo('##aim_smooth', smoothTypeItems, S.aim_smooth)
    Slider('##aim_af', 'Auto-fire hitchance', S.aim_autofire, 0, 100, false, '%d')
    imgui.Dummy(imgui.ImVec2(0, 6))

    SectionHeader('Settings')
    Slider('##aim_fov', 'FOV', S.aim_fov, 0, 10, true, '%.1f')
end

-- Правая колонка WEAPONS: Triggerbot + Delays
local function colWeaponRight()
    SectionHeader('Triggerbot')
    Check('##tb_en', 'Enable', S.tb_enable)
    imgui.Text('Hitboxes')
    MultiHitbox('##tb_hb', S.tb_hb)
    imgui.Text('Type')
    Combo('##tb_type', tbTypeItems, S.tb_type)
    Check('##tb_oz', 'Only zoom', S.tb_onlyzoom)
    Slider('##tb_hc', 'Hitchance', S.tb_hitchance, 0, 100, false, '%d')
    Slider('##tb_dbf', 'Delay before shot', S.tb_delaybf, 0, 1, true, '%.3f')
    Slider('##tb_daf', 'Delay after shot', S.tb_delayaf, 0, 1, true, '%.3f')
    Check('##tb_aw', 'Auto wall', S.tb_autowall)
    Slider('##tb_md', 'Min damage', S.tb_mindmg, 0, 100, false, '%d')
    imgui.Dummy(imgui.ImVec2(0, 6))

    SectionHeader('Delays')
    imgui.Text('Type')
    imgui.SameLine()
    imgui.TextDisabled('(?)')
    if imgui.IsItemHovered() then
        imgui.BeginTooltip(); imgui.Text('Shot delay behaviour'); imgui.EndTooltip()
    end
    Combo('##tb_dtype', delayTypeItems, S.tb_delaytype)
end

-- Страница Aimbot (как на скриншоте — две колонки)
local function pageAimbot()
    local avail = imgui.GetContentRegionAvail()
    local colW = (avail.x - 14) / 2
    column('##wcol_l', colW, colWeaponLeft)
    imgui.SameLine(0, 14)
    column('##wcol_r', colW, colWeaponRight)
end

-- Заглушки прочих страниц
local function placeholder(title, lines)
    SectionHeader(title)
    for _, l in ipairs(lines) do imgui.TextDisabled(l) end
end

local function pageSimple(name)
    local avail = imgui.GetContentRegionAvail()
    local colW = (avail.x - 14) / 2
    if name == 'Players' then
        column('##p_l', colW, function()
            placeholder('ESP', { 'Box', 'Skeleton', 'Name', 'Health' })
        end)
        imgui.SameLine(0, 14)
        column('##p_r', colW, function()
            placeholder('Colors', { 'Visible', 'Hidden' })
        end)
    elseif name == 'Items' then
        column('##i_l', colW, function()
            placeholder('World', { 'Dropped weapons', 'Grenades' })
        end)
        imgui.SameLine(0, 14)
        column('##i_r', colW, function()
            placeholder('Filter', { 'Distance' })
        end)
    elseif name == 'View' then
        column('##v_l', colW, function()
            placeholder('Camera', { 'FOV', 'Thirdperson' })
        end)
        imgui.SameLine(0, 14)
        column('##v_r', colW, function()
            placeholder('World', { 'Nightmode' })
        end)
    elseif name == 'Hud' then
        column('##h_l', colW, function()
            placeholder('Watermark', { 'Enable', 'Position' })
        end)
        imgui.SameLine(0, 14)
        column('##h_r', colW, function()
            placeholder('Keybinds', { 'Show list' })
        end)
    elseif name == 'Main' then
        column('##m_l', colW, function()
            placeholder('Menu', { 'Accent color', 'Rounding' })
            imgui.Text('Open key')
            Combo('##menukey', keyNames, S.menu_key)
        end)
        imgui.SameLine(0, 14)
        column('##m_r', colW, function()
            placeholder('Config', { 'Save', 'Load', 'Reset' })
        end)
    elseif name == 'Cloud' then
        column('##c_l', colW, function()
            placeholder('Configs', { 'No cloud configs' })
        end)
        imgui.SameLine(0, 14)
        column('##c_r', colW, function()
            placeholder('Account', { 'Not logged in' })
        end)
    end
end

-- GLOBALS вкладка
local function pageGlobals()
    local avail = imgui.GetContentRegionAvail()
    local colW = (avail.x - 14) / 2
    column('##g_l', colW, function()
        placeholder('General', { 'Master switch', 'Panic key' })
    end)
    imgui.SameLine(0, 14)
    column('##g_r', colW, function()
        placeholder('Profiles', { 'Active profile' })
    end)
end

-- ===================== РЕНДЕР МЕНЮ =====================
local HEADER_H  = 46
local SIDEBAR_W = 168

imgui.OnFrame(function() return menu[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(700, 470), imgui.Cond.Always)

    imgui.Begin('##midnight', menu, bit.bor(
        imgui.WindowFlags.NoTitleBar, imgui.WindowFlags.NoResize,
        imgui.WindowFlags.NoCollapse, imgui.WindowFlags.NoScrollbar,
        imgui.WindowFlags.NoScrollWithMouse))

    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local ws = imgui.GetWindowSize()

    -- ===== Шапка =====
    -- логотип: треугольник + MIDNIGHT
    local lx, ly = wp.x + 22, wp.y + 16
    dl:AddTriangleFilled(
        imgui.ImVec2(lx + 7, ly),
        imgui.ImVec2(lx + 14, ly + 13),
        imgui.ImVec2(lx, ly + 13), U32(COL.text))
    dl:AddTriangleFilled(
        imgui.ImVec2(lx + 7, ly + 4),
        imgui.ImVec2(lx + 11, ly + 13),
        imgui.ImVec2(lx + 3, ly + 13), U32(COL.windowBg))
    imgui.PushFont(font_main)
    dl:AddText(imgui.ImVec2(lx + 24, ly + 1), U32(COL.text), 'MIDNIGHT')
    imgui.PopFont()

    -- верхние вкладки GLOBALS / WEAPONS
    local tabNames = { 'GLOBALS', 'WEAPONS' }
    local tx = wp.x + 170
    for i = 1, 2 do
        local name = tabNames[i]
        local tsz = imgui.CalcTextSize(name)
        imgui.SetCursorScreenPos(imgui.ImVec2(tx, wp.y + 14))
        if imgui.InvisibleButton('##tt' .. i, imgui.ImVec2(tsz.x + 6, 22)) then topTab[0] = i - 1 end
        local active = topTab[0] == i - 1
        local hov = imgui.IsItemHovered()
        local col = active and U32(COL.text) or (hov and U32(COL.text) or U32(COL.textDim))
        dl:AddText(imgui.ImVec2(tx + 3, wp.y + 17), col, name)
        if active then
            dl:AddRectFilled(imgui.ImVec2(tx, wp.y + HEADER_H - 2),
                imgui.ImVec2(tx + tsz.x + 6, wp.y + HEADER_H), accU(), 1)
        end
        tx = tx + tsz.x + 34
    end

    -- иконки справа: поиск + шестерёнка
    local gx = wp.x + ws.x - 30
    dl:AddCircle(imgui.ImVec2(gx, wp.y + 22), 3.2, U32(COL.textDim), 14, 1.6)
    local sx = wp.x + ws.x - 58
    dl:AddCircle(imgui.ImVec2(sx, wp.y + 20), 4, U32(COL.textDim), 14, 1.6)
    dl:AddLine(imgui.ImVec2(sx + 3, wp.y + 23), imgui.ImVec2(sx + 7, wp.y + 27), U32(COL.textDim), 1.6)

    -- линия под шапкой
    dl:AddLine(imgui.ImVec2(wp.x, wp.y + HEADER_H), imgui.ImVec2(wp.x + ws.x, wp.y + HEADER_H), U32(COL.border), 1)

    -- ===== Сайдбар =====
    dl:AddRectFilled(imgui.ImVec2(wp.x, wp.y + HEADER_H),
        imgui.ImVec2(wp.x + SIDEBAR_W, wp.y + ws.y), U32(COL.sidebarBg), 0)
    dl:AddLine(imgui.ImVec2(wp.x + SIDEBAR_W, wp.y + HEADER_H),
        imgui.ImVec2(wp.x + SIDEBAR_W, wp.y + ws.y), U32(COL.border), 1)

    imgui.SetCursorScreenPos(imgui.ImVec2(wp.x, wp.y + HEADER_H + 10))
    imgui.BeginChild('##sidebar', imgui.ImVec2(SIDEBAR_W, ws.y - HEADER_H - 10), false)
    for idx, item in ipairs(sidebar) do
        if item.group then
            imgui.Dummy(imgui.ImVec2(0, 4))
            imgui.SetCursorPosX(18)
            imgui.TextColored(V4(COL.textHead), item.group)
            imgui.Dummy(imgui.ImVec2(0, 2))
        else
            local p = imgui.GetCursorScreenPos()
            local w = SIDEBAR_W
            local h = 30
            if imgui.InvisibleButton('##side' .. idx, imgui.ImVec2(w, h)) then sidePage = idx end
            local active = sidePage == idx
            local hov = imgui.IsItemHovered()
            if active then
                dl:AddRectFilled(imgui.ImVec2(p.x + 8, p.y), imgui.ImVec2(p.x + w - 10, p.y + h), accU(0.14), 5)
                dl:AddRectFilled(imgui.ImVec2(p.x, p.y + 5), imgui.ImVec2(p.x + 3, p.y + h - 5), accU(), 2)
            elseif hov then
                dl:AddRectFilled(imgui.ImVec2(p.x + 8, p.y), imgui.ImVec2(p.x + w - 10, p.y + h), U32({1,1,1}, 0.04), 5)
            end
            local col = active and accU() or (hov and U32(COL.text) or U32(COL.textDim))
            drawSideIcon(dl, p.x + 18, p.y + 8, item.icon, col)
            dl:AddText(imgui.ImVec2(p.x + 40, p.y + (h - imgui.CalcTextSize(item.page).y) * 0.5), col, item.page)
        end
    end
    imgui.EndChild()

    -- ===== Контент =====
    imgui.SetCursorScreenPos(imgui.ImVec2(wp.x + SIDEBAR_W + 16, wp.y + HEADER_H + 12))
    imgui.BeginChild('##content', imgui.ImVec2(ws.x - SIDEBAR_W - 32, ws.y - HEADER_H - 24), false)
    local pageName = sidebar[sidePage] and sidebar[sidePage].page or 'Aimbot'
    if topTab[0] == 0 then
        pageGlobals()
    else
        if pageName == 'Aimbot' then
            pageAimbot()
        else
            pageSimple(pageName)
        end
    end
    imgui.EndChild()

    imgui.End()
end)

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
    if not t then return end
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
end

-- ===================== INIT / MAIN =====================
imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local glyph = io.Fonts:GetGlyphRangesCyrillic()
    local path = getFolderPath(0x14) .. '\\trebucbd.ttf'
    io.Fonts:Clear()
    font_main = io.Fonts:AddFontFromFileTTF(path, 15.0, nil, glyph)
    font_big  = io.Fonts:AddFontFromFileTTF(path, 20.0, nil, glyph)
    font_logo = font_big
    applyTheme()
end)

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadConfig()
    sampRegisterChatCommand('ragemd', function() menu[0] = not menu[0] end)
    chat('загружен. Меню: {3D9BE0}/ragemd')

    while true do
        wait(0)
        local key = keyCodes[S.menu_key[0] + 1]
        if key and key ~= 0 and isKeyJustPressed(key)
            and not sampIsChatInputActive() and not sampIsDialogActive()
            and not isSampfuncsConsoleActive() then
            menu[0] = not menu[0]
        end
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then saveConfig() end
end
