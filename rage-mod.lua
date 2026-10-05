--[[
    rage-mod — MoonLoader скрипт для SA-MP
    Активация: /ragemd (или клавиша, выбранная в меню)
    Стиль меню вдохновлён интерфейсами популярных CS2-читов (тёмная тема, боковая панель,
    группбоксы, тумблеры, акцентный цвет, оверлей-виджеты: watermark, keybind-list и т.д.)
    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui
]]

script_name('rage-mod')
script_author('rage-mod')
script_version('1.0.0')

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local ffi      = require 'ffi'
encoding.default = 'CP1251'
local u8  = encoding.UTF8
local new = imgui.new

local CFG_FILE = 'rage-mod.ini'

-- ===================== НАСТРОЙКИ =====================
local menu = new.bool(false)
local tab  = 1

local S = {
    -- Мир
    time_on     = new.bool(false), time_h = new.int(12), time_m = new.int(0),
    weather_on  = new.bool(false), weather_idx = new.int(0),
    -- Виджеты
    wm_on       = new.bool(true),  wm_nick = new.bool(true), wm_fps = new.bool(true),
    wm_ping     = new.bool(true),  wm_time = new.bool(true),
    info_on     = new.bool(false), info_hp = new.bool(true), info_arm = new.bool(true),
    info_pos    = new.bool(true),  info_speed = new.bool(true),
    flist_on    = new.bool(true),
    clock_on    = new.bool(false), clock_fmt = new.int(0),
    notif_on    = new.bool(true),
    widget_alpha= new.float(0.85),
    -- Меню
    rounding    = new.float(6.0),
    menu_alpha  = new.float(0.97),
    anim        = new.bool(true),
    menu_key    = new.int(1),
}
local accent  = new.float[4](0.0, 0.63, 1.0, 1.0)
local wm_text = new.char[64]('rage-mod')

local weatherNames = { 'Ясно', 'Облачно', 'Дождь', 'Туман', 'Песчаная буря', 'Зелёный смог' }
local weatherIds   = { 0, 4, 8, 9, 19, 20 }
local weatherItems = new['const char*'][#weatherNames](weatherNames)

local keyNames = { 'Нет', 'Insert', 'Delete', 'Home', 'End', 'F2', 'F3' }
local keyCodes = { 0, 0x2D, 0x2E, 0x24, 0x23, 0x71, 0x72 }
local keyItems = new['const char*'][#keyNames](keyNames)

local tabs = {
    { name = 'Мир',     desc = 'Клиентское время и погода' },
    { name = 'Виджеты', desc = 'Оверлей: watermark, инфо-панель, список функций' },
    { name = 'Меню',    desc = 'Внешний вид интерфейса' },
    { name = 'Разное',  desc = 'Полезные утилиты' },
    { name = 'Конфиг',  desc = 'Сохранение и загрузка настроек' },
}

local font_big, font_main
local notifs = {}
local anims  = {}

-- ===================== УТИЛИТЫ =====================
local function chat(text)
    sampAddChatMessage(u8:decode('{00A0FF}[rage-mod]{FFFFFF} ' .. text), -1)
end

local function notify(text)
    if S.notif_on[0] then table.insert(notifs, { text = text, t = os.clock() }) end
end

local function V4(r, g, b, a) return imgui.ImVec4(r, g, b, a or 1) end
local function U32(r, g, b, a) return imgui.GetColorU32Vec4(imgui.ImVec4(r, g, b, a or 1)) end
local function accV(a) return V4(accent[0], accent[1], accent[2], a or 1) end
local function accU(a) return U32(accent[0], accent[1], accent[2], a or 1) end
local function stripId(label) return (label:gsub('##.*$', '')) end

local function applyTheme()
    local st = imgui.GetStyle()
    local c, col = st.Colors, imgui.Col
    local r = S.rounding[0]
    st.WindowRounding, st.ChildRounding, st.PopupRounding = r, r, r
    st.FrameRounding, st.GrabRounding, st.ScrollbarRounding = r * 0.6, r * 0.6, r
    st.WindowBorderSize, st.ChildBorderSize, st.FrameBorderSize = 1, 1, 0
    st.WindowPadding = imgui.ImVec2(10, 10)
    st.FramePadding  = imgui.ImVec2(6, 4)
    st.ItemSpacing   = imgui.ImVec2(8, 7)
    st.GrabMinSize   = 8
    st.ScrollbarSize = 8

    c[col.Text]             = V4(0.92, 0.93, 0.96)
    c[col.TextDisabled]     = V4(0.48, 0.52, 0.60)
    c[col.WindowBg]         = V4(0.035, 0.045, 0.075)
    c[col.ChildBg]          = V4(0.055, 0.065, 0.105)
    c[col.PopupBg]          = V4(0.05, 0.06, 0.10, 0.98)
    c[col.Border]           = V4(0.11, 0.13, 0.19)
    c[col.BorderShadow]     = V4(0, 0, 0, 0)
    c[col.FrameBg]          = V4(0.09, 0.10, 0.16)
    c[col.FrameBgHovered]   = V4(0.12, 0.14, 0.21)
    c[col.FrameBgActive]    = V4(0.14, 0.16, 0.24)
    c[col.TitleBg]          = V4(0.04, 0.05, 0.08)
    c[col.TitleBgActive]    = V4(0.04, 0.05, 0.08)
    c[col.ScrollbarBg]      = V4(0, 0, 0, 0)
    c[col.ScrollbarGrab]    = V4(0.15, 0.17, 0.25)
    c[col.ScrollbarGrabHovered] = accV(0.6)
    c[col.ScrollbarGrabActive]  = accV()
    c[col.CheckMark]        = accV()
    c[col.SliderGrab]       = accV()
    c[col.SliderGrabActive] = accV(0.8)
    c[col.Button]           = V4(0.09, 0.10, 0.16)
    c[col.ButtonHovered]    = accV(0.55)
    c[col.ButtonActive]     = accV(0.85)
    c[col.Header]           = accV(0.35)
    c[col.HeaderHovered]    = accV(0.5)
    c[col.HeaderActive]     = accV(0.7)
    c[col.Separator]        = V4(0.11, 0.13, 0.19)
    c[col.PlotHistogram]    = accV()
    c[col.TextSelectedBg]   = accV(0.35)
end

-- ===================== КАСТОМНЫЕ ВИДЖЕТЫ =====================
-- Тумблер (toggle switch) с анимацией
local function Toggle(label, bool)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local h  = 16
    local w  = 30
    local clicked = imgui.InvisibleButton(label, imgui.ImVec2(w, h))
    if clicked then bool[0] = not bool[0] end
    local target = bool[0] and 1 or 0
    local t = anims[label] or target
    if S.anim[0] then
        t = t + (target - t) * math.min(1, imgui.GetIO().DeltaTime * 14)
    else
        t = target
    end
    anims[label] = t
    local bg = imgui.ImVec4(
        0.12 + (accent[0] - 0.12) * t,
        0.14 + (accent[1] - 0.14) * t,
        0.21 + (accent[2] - 0.21) * t, 1)
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.GetColorU32Vec4(bg), h * 0.5)
    local rad = h * 0.5 - 3
    local cx = p.x + rad + 3 + (w - rad * 2 - 6) * t
    dl:AddCircleFilled(imgui.ImVec2(cx, p.y + h * 0.5), rad, U32(1, 1, 1, 0.95), 16)
    imgui.SameLine()
    imgui.SetCursorPosY(imgui.GetCursorPosY() - 1)
    imgui.Text(stripId(label))
    return clicked
end

-- Подсказка "(?)"
local function Hint(text)
    imgui.SameLine()
    imgui.TextDisabled('(?)')
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.Text(text)
        imgui.EndTooltip()
    end
end

-- Группбокс с заголовком
local function BeginGroup(title, size)
    imgui.BeginChild('##grp_' .. title, size, true)
    imgui.TextColored(accV(), title)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + 1), U32(0.11, 0.13, 0.19))
    imgui.Dummy(imgui.ImVec2(0, 3))
    imgui.PushItemWidth(-1)
end

local function EndGroup()
    imgui.PopItemWidth()
    imgui.EndChild()
end

-- Кнопка вкладки в боковой панели
local function TabButton(label, idx)
    local active = tab == idx
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 32
    if imgui.InvisibleButton('##tab' .. idx, imgui.ImVec2(w, h)) then tab = idx end
    local hovered = imgui.IsItemHovered()
    if active then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), accU(0.14), 5)
        dl:AddRectFilled(p, imgui.ImVec2(p.x + 3, p.y + h), accU(), 2)
    elseif hovered then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), U32(1, 1, 1, 0.04), 5)
    end
    local ts = imgui.CalcTextSize(label)
    local col = active and accU() or (hovered and U32(0.92, 0.93, 0.96) or U32(0.55, 0.58, 0.66))
    dl:AddText(imgui.ImVec2(p.x + 16, p.y + (h - ts.y) * 0.5), col, label)
end

-- Широкая акцентная кнопка
local function AccentButton(label, w)
    imgui.PushStyleColor(imgui.Col.Button, accV(0.8))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, accV(0.95))
    imgui.PushStyleColor(imgui.Col.ButtonActive, accV(0.65))
    local r = imgui.Button(label, imgui.ImVec2(w or -1, 26))
    imgui.PopStyleColor(3)
    return r
end

-- ===================== КОНФИГ =====================
local function saveConfig()
    local t = { settings = {} }
    for k, v in pairs(S) do t.settings[k] = v[0] end
    t.settings.acc_r, t.settings.acc_g, t.settings.acc_b = accent[0], accent[1], accent[2]
    t.settings.wm_text = ffi.string(wm_text)
    inicfg.save(t, CFG_FILE)
end

local function loadConfig()
    local t = inicfg.load(nil, CFG_FILE)
    if not t or not t.settings then return false end
    for k, v in pairs(S) do
        local val = t.settings[k]
        if val ~= nil then v[0] = val end
    end
    if t.settings.acc_r then
        accent[0], accent[1], accent[2] = t.settings.acc_r, t.settings.acc_g, t.settings.acc_b
    end
    if t.settings.wm_text then ffi.copy(wm_text, tostring(t.settings.wm_text):sub(1, 63)) end
    return true
end

local function resetConfig()
    S.time_on[0], S.time_h[0], S.time_m[0] = false, 12, 0
    S.weather_on[0], S.weather_idx[0] = false, 0
    S.wm_on[0], S.wm_nick[0], S.wm_fps[0], S.wm_ping[0], S.wm_time[0] = true, true, true, true, true
    S.info_on[0], S.info_hp[0], S.info_arm[0], S.info_pos[0], S.info_speed[0] = false, true, true, true, true
    S.flist_on[0], S.clock_on[0], S.clock_fmt[0], S.notif_on[0] = true, false, 0, true
    S.widget_alpha[0], S.rounding[0], S.menu_alpha[0], S.anim[0], S.menu_key[0] = 0.85, 6, 0.97, true, 1
    accent[0], accent[1], accent[2], accent[3] = 0.0, 0.63, 1.0, 1.0
    ffi.copy(wm_text, 'rage-mod')
end

-- ===================== ВКЛАДКИ =====================
local function drawWorld(w, h)
    BeginGroup('Время', imgui.ImVec2(w, h))
    Toggle('Своё время##time', S.time_on)
    Hint('Меняет время только у вас на клиенте')
    imgui.SliderInt('##h', S.time_h, 0, 23, 'Час: %d')
    imgui.SliderInt('##m', S.time_m, 0, 59, 'Минуты: %d')
    if imgui.Button('Утро', imgui.ImVec2(-1, 0)) then S.time_h[0], S.time_m[0] = 8, 0 end
    if imgui.Button('День', imgui.ImVec2(-1, 0)) then S.time_h[0], S.time_m[0] = 13, 0 end
    if imgui.Button('Ночь', imgui.ImVec2(-1, 0)) then S.time_h[0], S.time_m[0] = 0, 0 end
    EndGroup()
    imgui.SameLine()
    BeginGroup('Погода', imgui.ImVec2(w, h))
    Toggle('Своя погода##weather', S.weather_on)
    Hint('Клиентская погода, сервер может её перезаписывать')
    imgui.Text('Тип погоды')
    if imgui.Combo('##weather_combo', S.weather_idx, weatherItems, #weatherNames) then
        notify('Погода: ' .. weatherNames[S.weather_idx[0] + 1])
    end
    EndGroup()
end

local function drawWidgets(w, h)
    BeginGroup('Watermark', imgui.ImVec2(w, h * 0.5 - 4))
    Toggle('Включить##wm', S.wm_on)
    imgui.InputText('##wmtext', wm_text, ffi.sizeof(wm_text))
    imgui.Checkbox('Ник', S.wm_nick) imgui.SameLine()
    imgui.Checkbox('FPS', S.wm_fps)
    imgui.Checkbox('Пинг', S.wm_ping) imgui.SameLine()
    imgui.Checkbox('Время', S.wm_time)
    EndGroup()
    imgui.SameLine()
    BeginGroup('Инфо-панель', imgui.ImVec2(w, h * 0.5 - 4))
    Toggle('Включить##info', S.info_on)
    imgui.Checkbox('Здоровье', S.info_hp) imgui.SameLine()
    imgui.Checkbox('Броня', S.info_arm)
    imgui.Checkbox('Позиция', S.info_pos) imgui.SameLine()
    imgui.Checkbox('Скорость', S.info_speed)
    EndGroup()

    BeginGroup('Прочие виджеты', imgui.ImVec2(w, h * 0.5 - 4))
    Toggle('Список функций##flist', S.flist_on)
    Toggle('Уведомления##notif', S.notif_on)
    Toggle('Часы##clock', S.clock_on)
    imgui.RadioButtonIntPtr('24ч', S.clock_fmt, 0) imgui.SameLine()
    imgui.RadioButtonIntPtr('С секундами', S.clock_fmt, 1)
    EndGroup()
    imgui.SameLine()
    BeginGroup('Вид виджетов', imgui.ImVec2(w, h * 0.5 - 4))
    imgui.Text('Прозрачность фона')
    imgui.SliderFloat('##walpha', S.widget_alpha, 0.2, 1.0, '%.2f')
    imgui.TextDisabled('Виджеты можно перетаскивать,')
    imgui.TextDisabled('пока открыто меню.')
    EndGroup()
end

local function drawMenuTab(w, h)
    BeginGroup('Цвета', imgui.ImVec2(w, h))
    imgui.Text('Акцентный цвет')
    if imgui.ColorEdit4('##accent', accent, imgui.ColorEditFlags.NoInputs) then applyTheme() end
    imgui.Text('Пресеты')
    local presets = {
        { 'Синий', 0.0, 0.63, 1.0 }, { 'Фиолет.', 0.58, 0.36, 1.0 },
        { 'Красный', 0.95, 0.25, 0.3 }, { 'Зелёный', 0.3, 0.9, 0.45 },
    }
    for i, pr in ipairs(presets) do
        if imgui.Button(pr[1], imgui.ImVec2((imgui.GetContentRegionAvail().x - 8) / 2, 0)) then
            accent[0], accent[1], accent[2] = pr[2], pr[3], pr[4]
            applyTheme()
        end
        if i % 2 == 1 then imgui.SameLine() end
    end
    EndGroup()
    imgui.SameLine()
    BeginGroup('Интерфейс', imgui.ImVec2(w, h))
    imgui.Text('Скругление')
    if imgui.SliderFloat('##round', S.rounding, 0, 12, '%.0f') then applyTheme() end
    imgui.Text('Прозрачность меню')
    imgui.SliderFloat('##malpha', S.menu_alpha, 0.5, 1.0, '%.2f')
    Toggle('Анимации##anim', S.anim)
    imgui.Text('Клавиша открытия')
    imgui.Combo('##menukey', S.menu_key, keyItems, #keyNames)
    EndGroup()
end

local function drawMisc(w, h)
    BeginGroup('Чат', imgui.ImVec2(w, h))
    if imgui.Button('Очистить чат', imgui.ImVec2(-1, 26)) then
        for _ = 1, 30 do sampAddChatMessage(' ', -1) end
        notify('Чат очищен')
    end
    if imgui.Button('Скопировать координаты', imgui.ImVec2(-1, 26)) then
        local x, y, z = getCharCoordinates(PLAYER_PED)
        setClipboardText(string.format('%.2f, %.2f, %.2f', x, y, z))
        notify('Координаты скопированы')
    end
    if imgui.Button('Тест уведомления', imgui.ImVec2(-1, 26)) then
        notify('Привет от rage-mod!')
    end
    EndGroup()
    imgui.SameLine()
    BeginGroup('Скрипт', imgui.ImVec2(w, h))
    imgui.Text('Версия: ' .. thisScript().version)
    imgui.Text('Команда: /ragemd')
    if imgui.Button('Перезагрузить скрипт', imgui.ImVec2(-1, 26)) then thisScript():reload() end
    if imgui.Button('Выгрузить скрипт', imgui.ImVec2(-1, 26)) then thisScript():unload() end
    EndGroup()
end

local function drawConfig(w, h)
    BeginGroup('Конфигурация', imgui.ImVec2(w, h))
    imgui.TextDisabled('Файл: moonloader/config/' .. CFG_FILE)
    if AccentButton('Сохранить') then saveConfig() notify('Конфиг сохранён') end
    if imgui.Button('Загрузить', imgui.ImVec2(-1, 26)) then
        if loadConfig() then applyTheme() notify('Конфиг загружен') else notify('Конфиг не найден') end
    end
    if imgui.Button('Сбросить', imgui.ImVec2(-1, 26)) then resetConfig() applyTheme() notify('Настройки сброшены') end
    EndGroup()
    imgui.SameLine()
    BeginGroup('О скрипте', imgui.ImVec2(w, h))
    imgui.TextWrapped('rage-mod — меню для SA-MP в стиле CS2-софта: боковая панель, группбоксы, тумблеры и оверлей-виджеты.')
    EndGroup()
end

local tabDraw = { drawWorld, drawWidgets, drawMenuTab, drawMisc, drawConfig }

-- ===================== IMGUI =====================
imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    local glyph = io.Fonts:GetGlyphRangesCyrillic()
    local path = getFolderPath(0x14) .. '\\trebucbd.ttf'
    io.Fonts:Clear()
    font_main = io.Fonts:AddFontFromFileTTF(path, 14.0, nil, glyph)
    font_big  = io.Fonts:AddFontFromFileTTF(path, 22.0, nil, glyph)
    applyTheme()
end)

-- Главное меню
imgui.OnFrame(function() return menu[0] end, function(player)
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(700, 450), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(S.menu_alpha[0])
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    local flags = bit.bor(imgui.WindowFlags.NoTitleBar, imgui.WindowFlags.NoResize,
        imgui.WindowFlags.NoCollapse, imgui.WindowFlags.NoScrollbar)
    imgui.Begin('##ragemod_main', menu, flags)
    imgui.PopStyleVar()

    -- Боковая панель
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0.03, 0.035, 0.06, 1))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 14))
    imgui.BeginChild('##sidebar', imgui.ImVec2(165, 0), false)
    imgui.PushFont(font_big)
    imgui.TextColored(accV(), 'RAGE')
    imgui.SameLine(0, 2)
    imgui.Text('MOD')
    imgui.PopFont()
    imgui.TextDisabled('SA-MP edition')
    imgui.Dummy(imgui.ImVec2(0, 10))
    imgui.TextDisabled('ОСНОВНОЕ')
    for i = 1, 2 do TabButton(tabs[i].name, i) end
    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.TextDisabled('НАСТРОЙКИ')
    for i = 3, #tabs do TabButton(tabs[i].name, i) end
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor()

    -- Разделитель
    local dl = imgui.GetWindowDrawList()
    local wp, ws = imgui.GetWindowPos(), imgui.GetWindowSize()
    dl:AddLine(imgui.ImVec2(wp.x + 165, wp.y), imgui.ImVec2(wp.x + 165, wp.y + ws.y), U32(0.11, 0.13, 0.19), 1)

    -- Контент
    imgui.SameLine(0, 0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 12))
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0, 0, 0, 0))
    imgui.BeginChild('##content', imgui.ImVec2(0, 0), false)
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0.055, 0.065, 0.105, 1))
    imgui.PushFont(font_big)
    imgui.Text(tabs[tab].name)
    imgui.PopFont()
    imgui.SameLine()
    imgui.SetCursorPosX(imgui.GetWindowWidth() - 40)
    if imgui.Button('X##close', imgui.ImVec2(24, 22)) then menu[0] = false end
    imgui.TextDisabled(tabs[tab].desc)
    imgui.Dummy(imgui.ImVec2(0, 4))

    local avail = imgui.GetContentRegionAvail()
    local colW = (avail.x - 8) / 2
    tabDraw[tab](colW, avail.y - 2)

    imgui.PopStyleColor()
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.PopStyleVar()

    imgui.End()
end)

-- Оверлей-виджеты
local function widgetFlags()
    local f = bit.bor(imgui.WindowFlags.NoTitleBar, imgui.WindowFlags.NoResize,
        imgui.WindowFlags.AlwaysAutoResize, imgui.WindowFlags.NoScrollbar,
        imgui.WindowFlags.NoSavedSettings, imgui.WindowFlags.NoFocusOnAppearing,
        imgui.WindowFlags.NoNav, imgui.WindowFlags.NoCollapse)
    if not menu[0] then f = bit.bor(f, imgui.WindowFlags.NoMove, imgui.WindowFlags.NoInputs) end
    return f
end

local function widgetTopBar()
    local dl = imgui.GetWindowDrawList()
    local p, s = imgui.GetWindowPos(), imgui.GetWindowSize()
    dl:AddRectFilled(p, imgui.ImVec2(p.x + s.x, p.y + 2), accU(), S.rounding[0], 3)
end

local function myId()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    return ok and id or nil
end

local function activeFeatures()
    local list = {}
    if S.time_on[0] then list[#list + 1] = { 'Своё время', string.format('%02d:%02d', S.time_h[0], S.time_m[0]) } end
    if S.weather_on[0] then list[#list + 1] = { 'Погода', weatherNames[S.weather_idx[0] + 1] } end
    if S.info_on[0] then list[#list + 1] = { 'Инфо-панель', 'on' } end
    if S.clock_on[0] then list[#list + 1] = { 'Часы', 'on' } end
    return list
end

imgui.OnFrame(function()
    return isSampAvailable() and not isPauseMenuActive()
        and (S.wm_on[0] or S.info_on[0] or S.flist_on[0] or S.clock_on[0] or #notifs > 0)
end, function(player)
    player.HideCursor = true
    local sw, sh = getScreenResolution()
    local flags = widgetFlags()

    -- Watermark
    if S.wm_on[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(sw - 15, 15), imgui.Cond.FirstUseEver, imgui.ImVec2(1, 0))
        imgui.SetNextWindowBgAlpha(S.widget_alpha[0])
        imgui.Begin('##w_watermark', nil, flags)
        widgetTopBar()
        local parts = { ffi.string(wm_text) }
        local id = myId()
        if S.wm_nick[0] and id then parts[#parts + 1] = u8(sampGetPlayerNickname(id)) end
        if S.wm_fps[0] then parts[#parts + 1] = string.format('%d fps', imgui.GetIO().Framerate) end
        if S.wm_ping[0] and id then parts[#parts + 1] = string.format('%d ms', sampGetPlayerPing(id)) end
        if S.wm_time[0] then parts[#parts + 1] = os.date('%H:%M') end
        imgui.TextColored(accV(), parts[1])
        if #parts > 1 then
            imgui.SameLine()
            imgui.Text('| ' .. table.concat(parts, ' | ', 2))
        end
        imgui.End()
    end

    -- Список функций (аналог keybind-list)
    if S.flist_on[0] then
        local list = activeFeatures()
        if #list > 0 or menu[0] then
            imgui.SetNextWindowPos(imgui.ImVec2(15, sh * 0.4), imgui.Cond.FirstUseEver)
            imgui.SetNextWindowBgAlpha(S.widget_alpha[0])
            imgui.Begin('##w_flist', nil, flags)
            widgetTopBar()
            imgui.TextColored(accV(), 'Активные функции')
            imgui.Separator()
            if #list == 0 then imgui.TextDisabled('ничего не включено') end
            for _, it in ipairs(list) do
                imgui.Text(it[1])
                imgui.SameLine(150)
                imgui.TextDisabled('[' .. it[2] .. ']')
            end
            imgui.End()
        end
    end

    -- Инфо-панель
    if S.info_on[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(15, sh * 0.6), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowBgAlpha(S.widget_alpha[0])
        imgui.Begin('##w_info', nil, flags)
        widgetTopBar()
        imgui.TextColored(accV(), 'Информация')
        imgui.Separator()
        if S.info_hp[0] then
            local hp = getCharHealth(PLAYER_PED)
            imgui.PushStyleColor(imgui.Col.PlotHistogram, V4(0.9, 0.25, 0.3, 1))
            imgui.ProgressBar(math.min(hp, 100) / 100, imgui.ImVec2(170, 14), 'HP ' .. hp)
            imgui.PopStyleColor()
        end
        if S.info_arm[0] then
            local arm = getCharArmour(PLAYER_PED)
            imgui.ProgressBar(math.min(arm, 100) / 100, imgui.ImVec2(170, 14), 'Броня ' .. arm)
        end
        if S.info_pos[0] then
            local x, y, z = getCharCoordinates(PLAYER_PED)
            imgui.Text(string.format('X: %.1f  Y: %.1f  Z: %.1f', x, y, z))
        end
        if S.info_speed[0] then
            local spd
            if isCharInAnyCar(PLAYER_PED) then
                spd = getCarSpeed(storeCarCharIsInNoSave(PLAYER_PED))
            else
                spd = getCharSpeed(PLAYER_PED)
            end
            imgui.Text(string.format('Скорость: %d км/ч', spd * 3.6))
        end
        imgui.End()
    end

    -- Часы
    if S.clock_on[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, 15), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0))
        imgui.SetNextWindowBgAlpha(S.widget_alpha[0])
        imgui.Begin('##w_clock', nil, flags)
        widgetTopBar()
        imgui.PushFont(font_big)
        imgui.TextColored(accV(), os.date(S.clock_fmt[0] == 0 and '%H:%M' or '%H:%M:%S'))
        imgui.PopFont()
        imgui.End()
    end

    -- Уведомления
    local now = os.clock()
    for i = #notifs, 1, -1 do
        if now - notifs[i].t > 3.0 then table.remove(notifs, i) end
    end
    for i, n in ipairs(notifs) do
        local age = now - n.t
        local a = 1
        if age < 0.25 then a = age / 0.25 elseif age > 2.6 then a = (3.0 - age) / 0.4 end
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, math.max(0, math.min(1, a)))
        imgui.SetNextWindowPos(imgui.ImVec2(sw - 15, sh - 60 - (i - 1) * 44), imgui.Cond.Always, imgui.ImVec2(1, 1))
        imgui.SetNextWindowBgAlpha(0.95)
        imgui.Begin('##notif' .. i, nil, bit.bor(flags, imgui.WindowFlags.NoMove, imgui.WindowFlags.NoInputs))
        widgetTopBar()
        imgui.TextColored(accV(), 'rage-mod')
        imgui.SameLine()
        imgui.Text(n.text)
        imgui.End()
        imgui.PopStyleVar()
    end
end)

-- ===================== MAIN =====================
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadConfig()
    sampRegisterChatCommand('ragemd', function()
        menu[0] = not menu[0]
    end)
    chat('загружен. Меню: {00A0FF}/ragemd')

    local lastWeather = 0
    while true do
        wait(0)
        local key = keyCodes[S.menu_key[0] + 1]
        if key and key ~= 0 and isKeyJustPressed(key)
            and not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive() then
            menu[0] = not menu[0]
        end
        if S.time_on[0] then setTimeOfDay(S.time_h[0], S.time_m[0]) end
        if S.weather_on[0] and os.clock() - lastWeather > 0.5 then
            forceWeatherNow(weatherIds[S.weather_idx[0] + 1])
            lastWeather = os.clock()
        end
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then saveConfig() end
end
