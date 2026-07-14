-- starfield.lua - 3D starfield animation on display
-- Classic starfield effect with perspective projection
local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local CX, CY = W // 2, H // 2
local RUNNING = true
local NUM_STARS = 120

-- Colors (display module accepts hex strings or named colors)
local DARK   = "black"
local WHITE  = "white"
local GRAY   = "#808080"
local DIM    = "#202020"

local stars = {}
local touch_handle

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[stars] No display device found") end
    W, H = lw or 720, lh or 720
    CX, CY = W // 2, H // 2
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    for i = 1, NUM_STARS do
        stars[i] = {
            x = (math.random() - 0.5) * 2000,
            y = (math.random() - 0.5) * 2000,
            z = math.random() * 1000 + 1,
        }
    end
end

local function star_color(z)
    local t = 1 - z / 1000
    if t > 0.8 then return WHITE
    elseif t > 0.5 then return GRAY
    else return DIM
    end
end

local function update_and_draw()
    display.begin_frame({clear = true, color = DARK})

    for i = 1, NUM_STARS do
        local s = stars[i]
        local prev_z = s.z
        local prev_scale = 256 / prev_z
        local prev_px = CX + s.x * prev_scale
        local prev_py = CY + s.y * prev_scale

        s.z = s.z - 15
        if s.z <= 1 then
            s.z = 1000
            s.x = (math.random() - 0.5) * 2000
            s.y = (math.random() - 0.5) * 2000
        end

        local scale = 256 / s.z
        local px = CX + s.x * scale
        local py = CY + s.y * scale

        if px >= 0 and px < W and py >= 0 and py < H then
            local col = star_color(s.z)
            if prev_px >= 0 and prev_px < W and prev_py >= 0 and prev_py < H then
                display.draw_line(math.floor(prev_px), math.floor(prev_py),
                                   math.floor(px), math.floor(py), col)
            end
            local size = math.floor((1 - s.z / 1000) * 3)
            if size > 1 then
                display.fill_rect(math.floor(px) - 1, math.floor(py) - 1, 3, 3, col)
            else
                display.draw_pixel(math.floor(px), math.floor(py), col)
            end
        end
    end

    display.draw_text_aligned(0, 10, W, 30, "Starfield", {font_size = 20, color = GRAY})
    display.draw_text_aligned(0, H - 30, W, 20, "Touch to exit", {font_size = 16, color = DIM})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[stars] Running... touch to exit")

    while RUNNING do
        update_and_draw()

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(30)
    end

    display.clear(DARK)
    display.backlight(false)
    display.deinit()
    print("[stars] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[stars] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
