-- launcher.lua - ESP-Claw LVGL app launcher

local VERSION = "1.0.0"

local board_manager = require("board_manager")
local lvgl = require("lvgl")
local storage = require("storage")
local json = require("json")
local thread = require("thread")
local delay = require("delay")
local lcd_touch = require("lcd_touch")

local SYSTEM_APPS = "/system/apps"
local DATA_ROOT = storage.get_root_dir()
local DATA_APPS = storage.join_path(DATA_ROOT, "apps")
local STATE_DIR = storage.join_path(DATA_ROOT, "launcher")
local SETTINGS_PATH = storage.join_path(STATE_DIR, "settings.json")
local HISTORY_PATH = storage.join_path(STATE_DIR, "history.json")

local POLL_MS = 50
local RESTORE_DELAY_MS = 200
local GRID_COLS = 4
local GRID_ROWS = 3
local DOCK_SLOTS = 4
local APP_PAGE_SIZE = GRID_COLS * GRID_ROWS

local panel, io, W, H, panel_if
local touch_handle
local screen
local current_view = "desktop"
local current_page = 1
local selected_app
local apps = {}
local invalid_apps = {}
local history = {}
local settings = {
    theme = "dark",
    show_system = true,
    dock = {},
}
local pending_launch
local should_exit
local last_error
local swipe_start_x
local swipe_start_y

local COLORS = {
    bg = "#f0f4f8",
    panel = "#ffffff",
    card = "#ffffff",
    card2 = "#e8edf2",
    text = "#1a2332",
    sub = "#7b8794",
    accent = "#4facfe",
    accent2 = "#667eea",
    danger = "#fc5c65",
    ok = "#2ecc71",
    warn = "#f39c12",
    system = "#d0d7e0",
    data = "#a8d8ea",
}

local function starts_with(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
end

local function contains_parent(path)
    return type(path) ~= "string" or path:find("..", 1, true) ~= nil
end

local function basename(path)
    return tostring(path):match("([^/]+)$") or tostring(path)
end

local function safe_listdir(path)
    local ok, result = pcall(storage.listdir, path)
    if ok and type(result) == "table" then return result end
    return {}
end

local function safe_read_json(path)
    local ok, text = pcall(storage.read_file, path)
    if not ok or type(text) ~= "string" then return nil, tostring(text) end
    local ok_json, data = pcall(json.decode, text)
    if not ok_json or type(data) ~= "table" then return nil, tostring(data) end
    return data
end

local function write_json(path, value)
    pcall(storage.mkdir, STATE_DIR)
    pcall(storage.write_file, path, json.encode(value))
end

local function load_state()
    local data = safe_read_json(SETTINGS_PATH)
    if type(data) == "table" then
        for k, v in pairs(data) do settings[k] = v end
    end
    local hist = safe_read_json(HISTORY_PATH)
    if type(hist) == "table" then history = hist end
end

local function save_history()
    write_json(HISTORY_PATH, history)
end

local function validate_manifest(root, dir_name, source)
    local app_dir = storage.join_path(root, dir_name)
    local manifest_path = storage.join_path(app_dir, "manifest.json")
    local manifest, err = safe_read_json(manifest_path)
    if not manifest then return nil, "manifest: " .. tostring(err) end

    if manifest.schema_version ~= 1 then return nil, "unsupported schema" end
    if manifest.id ~= dir_name then return nil, "id mismatch" end
    if type(manifest.name) ~= "string" or manifest.name == "" then return nil, "missing name" end
    if type(manifest.entry) ~= "string" or manifest.entry == "" then return nil, "missing entry" end
    if starts_with(manifest.entry, "/") or contains_parent(manifest.entry) then return nil, "bad entry" end
    if not manifest.entry:match("%.lua$") then return nil, "entry is not lua" end
    if manifest.icon and (starts_with(manifest.icon, "/") or contains_parent(manifest.icon)) then return nil, "bad icon" end

    local entry_path = storage.join_path(app_dir, manifest.entry)
    if not storage.exists(entry_path) then return nil, "entry not found" end

    return {
        id = manifest.id,
        name = manifest.name,
        version = manifest.version or "",
        description = manifest.description or "",
        entry = entry_path,
        dir = app_dir,
        icon = manifest.icon and storage.join_path(app_dir, manifest.icon) or nil,
        category = manifest.category or {},
        requires = manifest.requires or {},
        launch = manifest.launch or {},
        source = source,
        overrides_system = false,
    }
end

local function scan_root(root, source, app_map, order)
    for _, e in ipairs(safe_listdir(root)) do
        if e.type == "directory" or e.type == "dir" then
            local app, err = validate_manifest(root, e.name, source)
            if app then
                if source == "data" and app_map[app.id] then
                    app.overrides_system = app_map[app.id].source == "system"
                end
                if not app_map[app.id] then table.insert(order, app.id) end
                app_map[app.id] = app
            else
                invalid_apps[#invalid_apps + 1] = { source = source, path = storage.join_path(root, e.name), error = err }
            end
        end
    end
end

local function scan_apps()
    invalid_apps = {}
    local app_map = {}
    local order = {}
    scan_root(SYSTEM_APPS, "system", app_map, order)
    scan_root(DATA_APPS, "data", app_map, order)

    apps = {}
    for _, id in ipairs(order) do
        if app_map[id] and (settings.show_system or app_map[id].source ~= "system") then
            apps[#apps + 1] = app_map[id]
        end
    end
    table.sort(apps, function(a, b) return a.name:lower() < b.name:lower() end)
end

local function init_lvgl()
    panel, io, W, H, panel_if = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("display_lcd not found") end
    local buf_lines = 20
    if panel_if == 2 then  -- MIPI_DSI: larger buffer reduces DMA flush count
        buf_lines = math.min(H, 120)
    end
    lvgl.init(panel, io, W, H, panel_if, { buffer_lines = buf_lines, tick_ms = 5, task_period_ms = 10 })
    local ok, h = pcall(board_manager.get_lcd_touch_handle, "lcd_touch")
    if ok and h then
        touch_handle = h
        lvgl.indev_register("touch", touch_handle)
    end
end

local function deinit_lvgl()
    pcall(lvgl.deinit)
    screen = nil
end

local function clear_screen()
    if not screen then
        screen = lvgl.create_screen()
        screen:set_scroll({ dir = "none", scrollbar = "off" })
    else
        screen:clean()
    end
    screen:set_style({ bg_color = COLORS.bg })
    screen:load()
end

local function text(parent, value, x, y, w, h, size, color, align)
    return lvgl.label(parent, {
        text = value,
        x = x, y = y, w = w, h = h,
        text_color = color or COLORS.text,
        align = align or "left_mid",
    })
end

local function button(parent, value, x, y, w, h, bg, cb)
    local b = lvgl.button(parent, {
        text = value,
        x = x, y = y, w = w, h = h,
        bg_color = bg or COLORS.card,
        text_color = COLORS.text,
        radius = 12,
        border_width = 1,
        border_color = "#dce1e8",
    })
    b:set_scroll({ dir = "none", scrollbar = "off" })
    if cb then b:on("clicked", cb) end
    return b
end

local function icon_letter(app)
    return (app.name or app.id or "?"):sub(1, 1):upper()
end

local render

local function show_error(message)
    last_error = message
    current_view = "error"
    render()
end

local function add_history(app, status, detail)
    table.insert(history, 1, {
        id = app.id,
        name = app.name,
        source = app.source,
        status = status,
        detail = detail or "",
    })
    while #history > 20 do table.remove(history) end
    save_history()
end

local function run_app(app)
    add_history(app, "running", app.entry)
    deinit_lvgl()
    delay.delay_ms(RESTORE_DELAY_MS)

    local ok, result = thread.start(app.entry, {}, {
        name = app.id,
        timeout_ms = app.launch.timeout_ms or 0,
        exclusive = app.launch.exclusive or "display",
        replace = true,
    })

    if ok then
        print("launcher: started " .. app.name .. " as independent app, exiting")
        should_exit = true
    else
        print("launcher: failed to start " .. app.name .. ": " .. tostring(result))
        init_lvgl()
        add_history(app, "failed", tostring(result))
        last_error = app.name .. " failed: " .. tostring(result)
        current_view = "error"
        render()
    end
end

local function draw_statusbar(title)
    button(screen, "Apps", 8, 8, 82, 40, current_view == "drawer" and COLORS.accent2 or COLORS.panel, function()
        current_view = "drawer"
        render()
    end)
    button(screen, "Home", 98, 8, 82, 40, current_view == "desktop" and COLORS.accent2 or COLORS.panel, function()
        current_view = "desktop"
        render()
    end)
    button(screen, "Recent", 188, 8, 104, 40, current_view == "recents" and COLORS.accent2 or COLORS.panel, function()
        current_view = "recents"
        render()
    end)
    button(screen, "Settings", W - 120, 8, 112, 40, current_view == "settings" and COLORS.accent2 or COLORS.panel, function()
        current_view = "settings"
        render()
    end)
    -- text(screen, title, 306, 10, W - 440, 36, 24, COLORS.text, "center")
end

local function draw_app_icon(app, x, y, w, h)
    local bg = app.source == "data" and COLORS.data or COLORS.system
    local b = button(screen, "", x, y, w, h, bg, function()
        selected_app = app
        current_view = "detail"
        render()
    end)
    text(b, app.name, 0, 0, w, h, 16, COLORS.text, "center")
end

local function desktop_page_count()
    return math.max(1, (#apps + APP_PAGE_SIZE - 1) // APP_PAGE_SIZE)
end

local function draw_desktop()
    draw_statusbar("Launcher")
    local start = (current_page - 1) * APP_PAGE_SIZE + 1
    local area_y = 70
    local cell_w = (W - 40) // GRID_COLS
    local cell_h = 128
    for i = 0, APP_PAGE_SIZE - 1 do
        local app = apps[start + i]
        if app then
            local col = i % GRID_COLS
            local row = i // GRID_COLS
            draw_app_icon(app, 20 + col * cell_w + 6, area_y + row * cell_h, cell_w - 12, 112)
        end
    end

    local page_count = desktop_page_count()
    button(screen, "<", 20, H - 86, 82, 58, COLORS.panel, function()
        if current_page > 1 then current_page = current_page - 1; render() end
    end)
    text(screen, string.format("%d / %d", current_page, page_count), 120, H - 78, W - 240, 42, 20, COLORS.sub, "center")
    button(screen, ">", W - 102, H - 86, 82, 58, COLORS.panel, function()
        if current_page < page_count then current_page = current_page + 1; render() end
    end)
end

local function draw_drawer()
    draw_statusbar("App Drawer")
    local list = lvgl.container(screen, {
        x = 0, y = 62, w = W - 32, h = H - 74,
        bg_color = COLORS.bg,
        radius = 0,
        border_width = 0,
    })
    list:set_scroll({ dir = "ver", scrollbar = "on" })

    for i, app in ipairs(apps) do
        local label = app.name .. "  " .. (app.source == "data" and "SD" or "SYSTEM")
        local bw = W - 56
        button(list, label, 8, (i - 1) * 62, bw, 54, app.source == "data" and COLORS.data or COLORS.card, function()
            selected_app = app
            current_view = "detail"
            render()
        end)
    end
    if #apps == 0 then
        text(screen, "No app packages found", 0, H // 2 - 20, W, 40, 24, COLORS.warn, "center")
    end
end

local function draw_detail()
    local app = selected_app
    draw_statusbar(app and app.name or "App Detail")
    if not app then return end
    text(screen, app.name, 34, 62, W - 68, 42, 34, COLORS.text, "left_mid")
    text(screen, app.description ~= "" and app.description or app.id, 34, 110, W - 68, 60, 20, COLORS.sub, "left_mid")
    text(screen, "Version: " .. app.version, 34, 130, W - 68, 28, 18, COLORS.sub, "left_mid")
    text(screen, "Source: " .. app.source .. (app.overrides_system and " (overrides system)" or ""), 34, 156, W - 68, 28, 18, COLORS.sub, "left_mid")
    text(screen, "Entry: " .. app.entry, 34, 192, W - 68, 60, 16, COLORS.sub, "left_mid")
    button(screen, "Launch", 34, H - 180, W - 68, 58, COLORS.ok, function()
        pending_launch = app
    end)
    button(screen, "Back", 34, H - 108, W - 68, 58, COLORS.panel, function()
        current_view = "desktop"
        render()
    end)
end

local function draw_recents()
    draw_statusbar("Recents")
    local y = 76
    for i, item in ipairs(history) do
        if y > H - 70 then break end
        local color = item.status == "failed" and COLORS.danger or COLORS.card
        text(screen, item.name .. " - " .. item.status, 34, y, W - 68, 26, 20, COLORS.text, "left_mid")
        text(screen, item.detail or "", 34, y + 28, W - 68, 22, 14, COLORS.sub, "left_mid")
        y = y + 62
        if i >= 8 then break end
    end
    if #history == 0 then
        text(screen, "No recent apps", 0, H // 2 - 20, W, 40, 24, COLORS.sub, "center")
    end
end

local function draw_settings()
    draw_statusbar("Settings")
    text(screen, "Apps: " .. tostring(#apps), 34, 88, W - 68, 28, 22, COLORS.text, "left_mid")
    text(screen, "Invalid packages: " .. tostring(#invalid_apps), 34, 124, W - 68, 28, 22, COLORS.text, "left_mid")
    text(screen, "Data root: " .. DATA_ROOT, 34, 160, W - 68, 28, 18, COLORS.sub, "left_mid")
    button(screen, "Refresh app list", 34, 220, W - 68, 58, COLORS.accent2, function()
        scan_apps()
        current_page = 1
        render()
    end)
    button(screen, settings.show_system and "Hide system apps" or "Show system apps", 34, 292, W - 68, 58, COLORS.panel, function()
        settings.show_system = not settings.show_system
        write_json(SETTINGS_PATH, settings)
        scan_apps()
        current_page = 1
        render()
    end)
    button(screen, "Reboot", 34, 364, W - 68, 58, COLORS.danger, function()
        local cap = require("capability")
        local ok, out = cap.call("restart_device")
        if not ok then
            print("reboot failed: " .. tostring(out))
        end
    end)
end

local function draw_error()
    draw_statusbar("Error")
    text(screen, last_error or "Unknown error", 36, 120, W - 72, 180, 22, COLORS.danger, "center")
    button(screen, "Back to desktop", 36, H - 120, W - 72, 60, COLORS.panel, function()
        current_view = "desktop"
        render()
    end)
end

local function handle_home_swipe()
    if current_view ~= "desktop" or not touch_handle then return end

    local ok, t = pcall(lcd_touch.poll, touch_handle)
    if not ok or type(t) ~= "table" then return end

    if t.just_pressed then
        swipe_start_x = t.x
        swipe_start_y = t.y
    elseif t.just_released and swipe_start_x then
        local dx = t.x - swipe_start_x
        local dy = t.y - swipe_start_y
        local abs_dx = math.abs(dx)
        local abs_dy = math.abs(dy)
        local threshold = 80
        local page_count = desktop_page_count()

        if abs_dx > threshold and abs_dx > abs_dy * 2 then
            if dx < 0 and current_page < page_count then
                current_page = current_page + 1
                render()
            elseif dx > 0 and current_page > 1 then
                current_page = current_page - 1
                render()
            end
        end
        swipe_start_x = nil
        swipe_start_y = nil
    end
end

render = function()
    clear_screen()
    if current_view == "drawer" then draw_drawer()
    elseif current_view == "detail" then draw_detail()
    elseif current_view == "recents" then draw_recents()
    elseif current_view == "settings" then draw_settings()
    elseif current_view == "error" then draw_error()
    else draw_desktop()
    end
end

local function main()
    print("launcher v" .. VERSION .. " starting")
    load_state()
    scan_apps()
    init_lvgl()
    render()
    print("launcher ready")

    while true do
        if pending_launch then
            local app = pending_launch
            pending_launch = nil
            pcall(lvgl.process_events, 1)
            run_app(app)
        end
        if should_exit then
            break
        end
        local ok, err = pcall(lvgl.process_events, POLL_MS)
        if not ok then
            print("launcher process_events error: " .. tostring(err))
            break
        end
        handle_home_swipe()
    end

    deinit_lvgl()
    print("launcher exited")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("launcher fatal: " .. tostring(err))
    pcall(lvgl.deinit)
end
