-- compass.lua - Compass app using magnetometer + display
-- Shows a rotating compass needle pointing to magnetic north
local display = require("display")
local board_manager = require("board_manager")
local magnetometer = require("magnetometer")
local delay = require("delay")
local math = math

-- Lua 5.1 compatible atan2
local function atan2(y, x)
    if x > 0 then return math.atan(y / x)
    elseif x < 0 and y >= 0 then return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then return math.pi / 2
    elseif x == 0 and y < 0 then return -math.pi / 2
    else return 0
    end
end

local W, H = 720, 720
local CX, CY = W // 2, H // 2
local RADIUS = 280
local RUNNING = true

-- Colors (display module accepts hex strings or named colors)
local RED    = "red"
local GREEN  = "green"
local WHITE  = "white"
local YELLOW = "yellow"
local BLUE   = "blue"
local GRAY   = "#808080"
local DARK   = "#202020"

local mag_dev
local touch_handle

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[compass] No display device found") end
    W, H = lw or 720, lh or 720
    CX, CY = W // 2, H // 2
    RADIUS = math.min(W, H) // 2 - 80
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    mag_dev = magnetometer.new()
    local cal = mag_dev:calibration_get()
    if not cal.calibrated then
        print("[compass] Calibrating magnetometer...")
        mag_dev:calibration_reset()
        local count = 0
        while count < 30 do
            count = mag_dev:calibration_add_sample()
            delay.delay_ms(100)
        end
        mag_dev:calibration_finish()
        print("[compass] Calibration done")
    else
        print("[compass] Using stored calibration")
    end

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
end

local function draw_compass(heading)
    display.begin_frame({clear = true, color = DARK})

    -- Outer rings
    display.draw_circle(CX, CY, RADIUS, GRAY)
    display.draw_circle(CX, CY, RADIUS - 2, GRAY)
    display.draw_circle(CX, CY, RADIUS - 40, DARK)

    -- Tick marks every 30 degrees
    for i = 0, 11 do
        local angle = math.rad(i * 30 - 90)
        local x1 = math.floor(CX + math.cos(angle) * (RADIUS - 40))
        local y1 = math.floor(CY + math.sin(angle) * (RADIUS - 40))
        local x2 = math.floor(CX + math.cos(angle) * (RADIUS - 10))
        local y2 = math.floor(CY + math.sin(angle) * (RADIUS - 10))
        display.draw_line(x1, y1, x2, y2, GRAY)
    end

    -- Cardinal labels
    display.draw_text_aligned(CX - 30, CY - RADIUS + 5, 60, 40, "N", {font_size = 32, color = RED})
    display.draw_text_aligned(CX - 30, CY + RADIUS - 45, 60, 40, "S", {font_size = 32, color = WHITE})
    display.draw_text_aligned(CX - RADIUS + 5, CY - 20, 60, 40, "W", {font_size = 32, color = WHITE})
    display.draw_text_aligned(CX + RADIUS - 65, CY - 20, 60, 40, "E", {font_size = 32, color = WHITE})

    -- Needle (red = north, blue = south)
    local rad = math.rad(heading - 90)
    local tip_x = math.floor(CX + math.cos(rad) * (RADIUS - 50))
    local tip_y = math.floor(CY + math.sin(rad) * (RADIUS - 50))
    local tail_x = math.floor(CX - math.cos(rad) * (RADIUS - 50))
    local tail_y = math.floor(CY - math.sin(rad) * (RADIUS - 50))

    -- Needle body (triangle for north part)
    local perp = rad + math.pi / 2
    local nw = 12
    local n1x = math.floor(tip_x + math.cos(perp) * nw)
    local n1y = math.floor(tip_y + math.sin(perp) * nw)
    local n2x = math.floor(tip_x - math.cos(perp) * nw)
    local n2y = math.floor(tip_y - math.sin(perp) * nw)
    display.fill_triangle(CX, CY, n1x, n1y, n2x, n2y, RED)

    -- South part
    local s1x = math.floor(tail_x + math.cos(perp) * nw)
    local s1y = math.floor(tail_y + math.sin(perp) * nw)
    local s2x = math.floor(tail_x - math.cos(perp) * nw)
    local s2y = math.floor(tail_y - math.sin(perp) * nw)
    display.fill_triangle(CX, CY, s1x, s1y, s2x, s2y, BLUE)

    -- Center cap
    display.fill_circle(CX, CY, 15, WHITE)
    display.fill_circle(CX, CY, 8, GRAY)

    -- Heading text
    local dir_text = "N"
    local h = heading % 360
    if h < 22.5 or h >= 337.5 then dir_text = "N"
    elseif h < 67.5 then dir_text = "NE"
    elseif h < 112.5 then dir_text = "E"
    elseif h < 157.5 then dir_text = "SE"
    elseif h < 202.5 then dir_text = "S"
    elseif h < 247.5 then dir_text = "SW"
    elseif h < 292.5 then dir_text = "W"
    else dir_text = "NW"
    end
    display.draw_text_aligned(CX - 100, CY + RADIUS + 20, 200, 40,
        string.format("%d  %s", math.floor(h), dir_text),
        {font_size = 28, color = YELLOW})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[compass] Running... touch to exit")

    while RUNNING do
        local data = mag_dev:read()
        if data and data.magnetic then
            local mx = data.magnetic.x
            local my = data.magnetic.y
            local heading = math.deg(atan2(my, mx)) % 360
            draw_compass(heading)
        end

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(50)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(500)
    display.backlight(false)
    display.deinit()
    if mag_dev then mag_dev:close() end
    print("[compass] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[compass] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if mag_dev then mag_dev:close() end end)
end
