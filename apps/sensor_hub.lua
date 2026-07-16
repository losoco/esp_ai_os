-- sensor_hub.lua - Multi-page sensor center for metalio_claw_4
local display = require("display")
local board_manager = require("board_manager")
local lib_fuel_gauge = require("lib_fuel_gauge")
local lib_sc7a20h = require("lib_sc7a20h")
local magnetometer = require("magnetometer")
local i2c = require("i2c")
local delay = require("delay")
local lcd_touch = require("lcd_touch")
local math = math
local string = string
local table = table

local W, H = 720, 720
local RUNNING = true
local FRAME_MS = 16
local FAST_SAMPLE_MS = 100
local BATTERY_SAMPLE_MS = 1000
local HISTORY_SIZE = 120
local CALIBRATION_SAMPLES = 200
local HEADER_H = 64
local TABS_H = 72
local CONTENT_BOTTOM = H - TABS_H

local BG = "#0b1020"
local PANEL = "#151d32"
local GRID = "#30405f"
local MUTED = "#8291ad"
local WHITE = "white"
local RED = "#ff5c6c"
local GREEN = "#45d483"
local BLUE = "#55a7ff"
local CYAN = "#41d9e8"
local YELLOW = "#ffd166"
local ORANGE = "#ff9f43"
local PURPLE = "#bc7cff"

local fg, accel, mag_dev, touch_handle, i2c_bus
local display_ready = false
local page = 1
local page_names = {"Overview", "Motion", "Magnetic"}
local swipe_x, swipe_y
local fast_acc, battery_acc = 0, 0

local battery = {soc = 0, voltage_mv = 0, current_ma = 0, valid = false, errors = 0}
local motion = {ax = 0, ay = 0, az = 0, total = 0, peak = 0, valid = false, errors = 0}
local magnetic = {mx = 0, my = 0, mz = 0, strength = 0, heading = 0, valid = false, errors = 0}
local accel_history = {x = {}, y = {}, z = {}}
local mag_history = {x = {}, y = {}, z = {}}
local calibration = {state = "idle", count = 0, message = "Ready"}

local function atan2(y, x)
    if x > 0 then return math.atan(y / x)
    elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then return math.pi / 2
    elseif x == 0 and y < 0 then return -math.pi / 2
    end
    return 0
end

local function clamp(v, low, high)
    return math.max(low, math.min(high, v))
end

local function push(history, value)
    history[#history + 1] = value
    if #history > HISTORY_SIZE then table.remove(history, 1) end
end

local function direction_for(heading)
    if heading < 22.5 or heading >= 337.5 then return "N"
    elseif heading < 67.5 then return "NE"
    elseif heading < 112.5 then return "E"
    elseif heading < 157.5 then return "SE"
    elseif heading < 202.5 then return "S"
    elseif heading < 247.5 then return "SW"
    elseif heading < 292.5 then return "W"
    end
    return "NW"
end

local function init_display()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[sensor_hub] No display device found") end
    W, H = lw or 720, lh or 720
    CONTENT_BOTTOM = H - TABS_H
    display.init(panel, io, W, H, pif)
    display_ready = true
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
end

local function init_sensors()
    local bus_ok, bus_or_err = pcall(function() return i2c.wrap(1) end)
    if bus_ok then i2c_bus = bus_or_err end

    if i2c_bus then
        local ok, dev = pcall(function()
            return lib_fuel_gauge.new({bus = i2c_bus, chip = "bq27220"})
        end)
        if ok then fg = dev else battery.errors = 1 end

        ok, dev = pcall(function() return lib_sc7a20h.new({bus = i2c_bus}) end)
        if ok then accel = dev else motion.errors = 1 end
    else
        battery.errors = 1
        motion.errors = 1
    end

    local ok, dev = pcall(function() return magnetometer.new() end)
    if ok then
        mag_dev = dev
        local cal_ok, cal = pcall(function() return mag_dev:calibration_get() end)
        if cal_ok and cal and cal.calibrated then
            calibration.state = "calibrated"
            calibration.message = "Stored calibration active"
        end
    else
        magnetic.errors = 1
        calibration.state = "unavailable"
        calibration.message = "Sensor unavailable"
    end
end

local function init()
    init_display()
    init_sensors()
end

local function sample_accel()
    if not accel then return end
    local ok, ax, ay, az = pcall(function() return accel:read_mg() end)
    if not ok or type(ax) ~= "number" or type(ay) ~= "number" or type(az) ~= "number" then
        motion.errors = motion.errors + 1
        return
    end
    motion.ax, motion.ay, motion.az = ax, ay, az
    motion.total = math.sqrt(ax * ax + ay * ay + az * az)
    motion.peak = math.max(motion.peak, motion.total)
    motion.valid = true
    push(accel_history.x, ax)
    push(accel_history.y, ay)
    push(accel_history.z, az)
end

local function cancel_calibration(message)
    calibration.state = "error"
    calibration.message = message
end

local function calibration_sample()
    if calibration.state ~= "collecting" then return end
    local ok = pcall(function() mag_dev:calibration_add_sample() end)
    if not ok then
        cancel_calibration("Calibration sample failed")
        return
    end
    calibration.count = calibration.count + 1
    if calibration.count >= CALIBRATION_SAMPLES then
        local finish_ok, result = pcall(function() return mag_dev:calibration_finish() end)
        if finish_ok and result then
            calibration.state = "calibrated"
            calibration.message = "Calibration complete"
        else
            cancel_calibration("Calibration finish failed")
        end
    end
end

local function sample_magnetometer()
    if not mag_dev then return end
    local ok, sample = pcall(function() return mag_dev:read() end)
    if not ok or not sample or not sample.magnetic then
        magnetic.errors = magnetic.errors + 1
        return
    end
    local m = sample.magnetic
    if type(m.x) ~= "number" or type(m.y) ~= "number" or type(m.z) ~= "number" then
        magnetic.errors = magnetic.errors + 1
        return
    end
    magnetic.mx, magnetic.my, magnetic.mz = m.x, m.y, m.z
    magnetic.strength = math.sqrt(m.x * m.x + m.y * m.y + m.z * m.z)
    magnetic.heading = math.deg(atan2(m.y, m.x)) % 360
    magnetic.valid = true
    push(mag_history.x, m.x)
    push(mag_history.y, m.y)
    push(mag_history.z, m.z)
    calibration_sample()
end

local function sample_battery()
    if not fg then return end
    local ok, sample = pcall(function() return fg:read() end)
    if not ok or not sample then
        battery.errors = battery.errors + 1
        return
    end
    if type(sample.soc) ~= "number" or type(sample.voltage_mv) ~= "number" then
        battery.errors = battery.errors + 1
        return
    end
    battery.soc = sample.soc
    battery.voltage_mv = sample.voltage_mv
    battery.current_ma = sample.current_ma or 0
    battery.valid = true
end

local function update_sampling(dt)
    fast_acc = fast_acc + dt
    battery_acc = battery_acc + dt
    while fast_acc >= FAST_SAMPLE_MS do
        fast_acc = fast_acc - FAST_SAMPLE_MS
        sample_accel()
        sample_magnetometer()
    end
    while battery_acc >= BATTERY_SAMPLE_MS do
        battery_acc = battery_acc - BATTERY_SAMPLE_MS
        sample_battery()
    end
end

local function start_calibration()
    if not mag_dev then
        calibration.state = "unavailable"
        calibration.message = "Sensor unavailable"
        return
    end
    local ok = pcall(function() mag_dev:calibration_reset() end)
    if ok then
        calibration.state = "collecting"
        calibration.count = 0
        calibration.message = "Rotate device in every direction"
    else
        cancel_calibration("Calibration reset failed")
    end
end

local function handle_touch()
    if not touch_handle then return end
    local t = lcd_touch.poll(touch_handle)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end
    if t.just_pressed then
        swipe_x, swipe_y = t.x, t.y
        return
    end
    if not t.just_released or not swipe_x then return end

    local x, y = math.floor(t.x), math.floor(t.y)
    local dx, dy = t.x - swipe_x, t.y - swipe_y
    local start_y = swipe_y
    swipe_x, swipe_y = nil, nil

    if y >= H - TABS_H and math.abs(dx) < 35 then
        page = clamp(math.floor(x * 3 / W) + 1, 1, 3)
        return
    end
    if page == 3 and x >= 450 and x <= 680 and y >= 555 and y <= 615 and math.abs(dx) < 25 then
        start_calibration()
        return
    end
    if start_y >= HEADER_H and start_y < CONTENT_BOTTOM and math.abs(dx) > 70 and math.abs(dx) > math.abs(dy) then
        if dx < 0 then page = math.min(3, page + 1)
        else page = math.max(1, page - 1) end
    end
end

local function draw_card(x, y, w, h, title)
    display.fill_round_rect(x, y, w, h, 16, PANEL)
    display.draw_round_rect(x, y, w, h, 16, GRID)
    display.draw_text(x + 18, y + 12, title, {font_size = 19, color = MUTED})
end

local function draw_unavailable(x, y, w, h, errors)
    display.draw_text_aligned(x, y, w, h - 18, "unavailable", {font_size = 23, color = MUTED})
    display.draw_text_aligned(x, y + h - 36, w, 24, "errors " .. tostring(errors), {font_size = 14, color = RED})
end

local function draw_header()
    display.fill_rect(0, 0, W, HEADER_H, "#10182b")
    display.draw_text(24, 16, "SENSOR CENTER", {font_size = 27, color = CYAN})
    display.draw_text(W - 180, 20, page_names[page], {font_size = 20, color = WHITE})
    display.draw_line(0, HEADER_H - 1, W, HEADER_H - 1, GRID)
end

local function draw_tabs()
    local top = H - TABS_H
    display.fill_rect(0, top, W, TABS_H, "#10182b")
    display.draw_line(0, top, W, top, GRID)
    local tab_w = math.floor(W / 3)
    for i = 1, 3 do
        local x = (i - 1) * tab_w
        local color = i == page and CYAN or MUTED
        if i == page then display.fill_rect(x + 20, top, tab_w - 40, 4, CYAN) end
        display.draw_text_aligned(x, top + 18, tab_w, 30, page_names[i], {font_size = 18, color = color})
    end
    display.draw_text_aligned(0, H - 18, W, 14, "Swipe pages  |  Hold 1.5s to exit", {font_size = 11, color = GRID})
end

local function draw_compass(cx, cy, radius, heading)
    display.draw_circle(cx, cy, radius, GRID)
    display.draw_circle(cx, cy, radius - 2, GRID)
    display.draw_text_aligned(cx - 14, cy - radius - 2, 28, 20, "N", {font_size = 16, color = RED})
    display.draw_text_aligned(cx - 14, cy + radius - 18, 28, 20, "S", {font_size = 14, color = MUTED})
    display.draw_text_aligned(cx + radius - 14, cy - 9, 28, 20, "E", {font_size = 14, color = MUTED})
    display.draw_text_aligned(cx - radius - 14, cy - 9, 28, 20, "W", {font_size = 14, color = MUTED})
    local rad = math.rad(heading - 90)
    local tip_x = math.floor(cx + math.cos(rad) * (radius - 14))
    local tip_y = math.floor(cy + math.sin(rad) * (radius - 14))
    local left_x = math.floor(cx + math.cos(rad + 2.65) * 18)
    local left_y = math.floor(cy + math.sin(rad + 2.65) * 18)
    local right_x = math.floor(cx + math.cos(rad - 2.65) * 18)
    local right_y = math.floor(cy + math.sin(rad - 2.65) * 18)
    display.fill_triangle(tip_x, tip_y, left_x, left_y, right_x, right_y, RED)
    display.fill_circle(cx, cy, 6, WHITE)
end

local function draw_overview()
    draw_card(20, 82, 680, 155, "BATTERY")
    if not fg or not battery.valid then
        draw_unavailable(20, 112, 680, 125, battery.errors)
    else
        local soc = clamp(battery.soc, 0, 100)
        local color = soc > 50 and GREEN or (soc > 20 and YELLOW or RED)
        display.draw_text(42, 126, string.format("%.0f%%", soc), {font_size = 42, color = color})
        display.draw_text(180, 128, string.format("%d mV", battery.voltage_mv), {font_size = 22, color = WHITE})
        display.draw_text(360, 128, string.format("%d mA", battery.current_ma), {font_size = 22, color = WHITE})
        display.fill_round_rect(42, 190, 630, 18, 7, GRID)
        local fill_w = math.floor(630 * soc / 100)
        if fill_w > 0 then display.fill_round_rect(42, 190, fill_w, 18, 7, color) end
        display.draw_text(580, 128, "err " .. tostring(battery.errors), {font_size = 14, color = MUTED})
    end

    draw_card(20, 253, 330, 365, "ACCEL ATTITUDE")
    if not accel or not motion.valid then
        draw_unavailable(20, 300, 330, 300, motion.errors)
    else
        local cx, cy, radius = 185, 410, 108
        display.draw_circle(cx, cy, radius, GRID)
        display.draw_line(cx - radius, cy, cx + radius, cy, GRID)
        display.draw_line(cx, cy - radius, cx, cy + radius, GRID)
        local bx = math.floor(cx + clamp(motion.ax / 1000, -1, 1) * (radius - 12))
        local by = math.floor(cy + clamp(motion.ay / 1000, -1, 1) * (radius - 12))
        display.fill_circle(bx, by, 14, CYAN)
        display.draw_circle(bx, by, 17, WHITE)
        display.draw_text_aligned(38, 540, 294, 24, string.format("X %+.0f  Y %+.0f  Z %+.0f mg", motion.ax, motion.ay, motion.az), {font_size = 16, color = WHITE})
        display.draw_text_aligned(38, 573, 294, 22, string.format("|a| %.0f mg   err %d", motion.total, motion.errors), {font_size = 15, color = YELLOW})
    end

    draw_card(370, 253, 330, 365, "COMPASS")
    if not mag_dev or not magnetic.valid then
        draw_unavailable(370, 300, 330, 300, magnetic.errors)
    else
        draw_compass(535, 414, 112, magnetic.heading)
        display.draw_text_aligned(390, 542, 290, 30, string.format("%03.0f deg  %s", magnetic.heading, direction_for(magnetic.heading)), {font_size = 24, color = YELLOW})
        display.draw_text_aligned(390, 579, 290, 20, string.format("Field %.1f  err %d", magnetic.strength, magnetic.errors), {font_size = 15, color = WHITE})
    end
end

local function graph_range(histories, minimum)
    local max_abs = minimum
    for _, history in ipairs(histories) do
        for i = 1, #history do max_abs = math.max(max_abs, math.abs(history[i])) end
    end
    return max_abs
end

local function draw_graph(x, y, w, h, histories, colors, minimum, unit)
    display.fill_round_rect(x, y, w, h, 12, PANEL)
    local max_abs = graph_range(histories, minimum)
    local center_y = y + math.floor(h / 2)
    for i = 0, 4 do
        local gy = y + math.floor(i * h / 4)
        display.draw_line(x, gy, x + w, gy, i == 2 and MUTED or GRID)
        local value = max_abs * (1 - i / 2)
        display.draw_text(x + 5, gy - 15, string.format("%+.0f", value), {font_size = 12, color = MUTED})
    end
    for i = 0, 6 do
        local gx = x + math.floor(i * w / 6)
        display.draw_line(gx, y, gx, y + h, GRID)
    end
    display.draw_text(x + w - 58, y + 6, unit, {font_size = 13, color = MUTED})
    display.draw_line(x, center_y, x + w, center_y, MUTED)
    for channel = 1, 3 do
        local history = histories[channel]
        if #history > 1 then
            for i = 2, #history do
                local x1 = x + math.floor((i - 2) * w / (HISTORY_SIZE - 1))
                local x2 = x + math.floor((i - 1) * w / (HISTORY_SIZE - 1))
                local y1 = center_y - math.floor(clamp(history[i - 1] / max_abs, -1, 1) * (h / 2 - 4))
                local y2 = center_y - math.floor(clamp(history[i] / max_abs, -1, 1) * (h / 2 - 4))
                display.draw_line(x1, y1, x2, y2, colors[channel])
            end
        end
    end
end

local function draw_motion()
    draw_card(20, 82, 680, 112, "LIVE ACCELERATION")
    if not accel or not motion.valid then
        draw_unavailable(20, 104, 680, 90, motion.errors)
    else
        local values = {motion.ax, motion.ay, motion.az}
        local labels = {"X", "Y", "Z"}
        local colors = {RED, GREEN, BLUE}
        for i = 1, 3 do
            local x = 48 + (i - 1) * 155
            display.draw_text(x, 128, labels[i], {font_size = 18, color = colors[i]})
            display.draw_text(x + 24, 126, string.format("%+.0f", values[i]), {font_size = 22, color = WHITE})
        end
        display.draw_text(520, 112, string.format("|a| %.0f", motion.total), {font_size = 17, color = YELLOW})
        display.draw_text(520, 142, string.format("Peak %.0f", motion.peak), {font_size = 17, color = ORANGE})
        display.draw_text(520, 168, "err " .. tostring(motion.errors), {font_size = 13, color = MUTED})
    end
    draw_graph(20, 213, 680, 405, {accel_history.x, accel_history.y, accel_history.z}, {RED, GREEN, BLUE}, 1200, "mg")
    display.draw_text(42, 590, "X", {font_size = 14, color = RED})
    display.draw_text(75, 590, "Y", {font_size = 14, color = GREEN})
    display.draw_text(108, 590, "Z", {font_size = 14, color = BLUE})
    display.draw_text(565, 590, tostring(#accel_history.x) .. "/" .. HISTORY_SIZE, {font_size = 13, color = MUTED})
end

local function calibration_color()
    if calibration.state == "collecting" then return YELLOW
    elseif calibration.state == "calibrated" then return GREEN
    elseif calibration.state == "error" then return RED
    end
    return MUTED
end

local function draw_magnetic()
    draw_card(20, 82, 280, 300, "COMPASS")
    if not mag_dev or not magnetic.valid then
        draw_unavailable(20, 112, 280, 260, magnetic.errors)
    else
        draw_compass(160, 225, 92, magnetic.heading)
        display.draw_text_aligned(40, 330, 240, 28, string.format("%03.0f deg  %s", magnetic.heading, direction_for(magnetic.heading)), {font_size = 21, color = YELLOW})
    end

    draw_card(320, 82, 380, 300, "MAGNETIC FIELD")
    if not mag_dev or not magnetic.valid then
        draw_unavailable(320, 112, 380, 260, magnetic.errors)
    else
        display.draw_text(346, 135, string.format("X  %+.2f", magnetic.mx), {font_size = 22, color = RED})
        display.draw_text(346, 177, string.format("Y  %+.2f", magnetic.my), {font_size = 22, color = GREEN})
        display.draw_text(346, 219, string.format("Z  %+.2f", magnetic.mz), {font_size = 22, color = BLUE})
        display.draw_text(346, 270, string.format("Strength  %.2f", magnetic.strength), {font_size = 21, color = WHITE})
        display.draw_text(346, 312, "Read errors  " .. tostring(magnetic.errors), {font_size = 15, color = MUTED})
    end

    draw_graph(20, 400, 410, 218, {mag_history.x, mag_history.y, mag_history.z}, {RED, GREEN, BLUE}, 10, "field")
    draw_card(450, 400, 250, 218, "CALIBRATION")
    display.draw_text_aligned(466, 442, 218, 24, calibration.state, {font_size = 19, color = calibration_color()})
    if calibration.state == "collecting" then
        local progress = clamp(calibration.count / CALIBRATION_SAMPLES, 0, 1)
        display.fill_round_rect(470, 484, 210, 14, 6, GRID)
        local progress_w = math.floor(210 * progress)
        if progress_w > 0 then display.fill_round_rect(470, 484, progress_w, 14, 6, YELLOW) end
        display.draw_text_aligned(466, 506, 218, 20, string.format("%d / %d", calibration.count, CALIBRATION_SAMPLES), {font_size = 15, color = WHITE})
        display.draw_text_aligned(466, 529, 218, 20, "Rotate device", {font_size = 14, color = YELLOW})
    else
        display.draw_text_aligned(466, 480, 218, 44, calibration.message, {font_size = 14, color = MUTED})
    end
    display.fill_round_rect(470, 555, 210, 60, 12, calibration.state == "collecting" and GRID or PURPLE)
    display.draw_text_aligned(470, 571, 210, 28, calibration.state == "collecting" and "CALIBRATING..." or "START CALIBRATION", {font_size = 15, color = WHITE})
end

local function draw()
    display.begin_frame({clear = true, color = BG})
    draw_header()
    if page == 1 then draw_overview()
    elseif page == 2 then draw_motion()
    else draw_magnetic() end
    draw_tabs()
    display.present()
    display.end_frame()
end

local function cleanup()
    if fg then pcall(function() fg:close() end); fg = nil end
    if accel then pcall(function() accel:close() end); accel = nil end
    if mag_dev then pcall(function() mag_dev:close() end); mag_dev = nil end
    if display_ready then
        pcall(function() display.backlight(false) end)
        pcall(function() display.deinit() end)
        display_ready = false
    end
end

local function run()
    init()
    sample_accel()
    sample_magnetometer()
    sample_battery()
    print("[sensor_hub] Running... swipe or tap tabs, hold to exit")
    while RUNNING do
        handle_touch()
        update_sampling(FRAME_MS)
        draw()
        delay.delay_ms(FRAME_MS)
    end
    cleanup()
    print("[sensor_hub] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[sensor_hub] ERROR: " .. tostring(err))
    cleanup()
end
