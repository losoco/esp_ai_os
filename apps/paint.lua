-- paint.lua - Touch drawing pad with color palette

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

local TOOLBAR_H = 70
local CANVAS_TOP = TOOLBAR_H
local CANVAS_H = H - TOOLBAR_H

-- Colors
local BG     = "#1a1a2e"
local CANVAS = "white"
local GRAY   = "#606080"
local DARK   = "#101020"

-- Palette
local COLORS = {
    "#000000",  -- black
    "#ef4444",  -- red
    "#f59e0b",  -- orange
    "#22c55e",  -- green
    "#3b82f6",  -- blue
    "#a855f7",  -- purple
    "#ec4899",  -- pink
    "#ffffff",  -- white (eraser)
}
local COLOR_R = 22
local COLOR_SPACING = 78
local COLOR_START_X = 40

local PALETTE_W = COLOR_START_X * 2 + #COLORS * COLOR_SPACING
local CLEAR_X = W - 50
local CLEAR_Y = TOOLBAR_H // 2
local CLEAR_R = 22

local touch_handle
local current_color = COLORS[1]
local current_color_idx = 1
local segments = {}
local MAX_SEGMENTS = 500
local last_x, last_y
local drawing = false

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[paint] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    segments = {}
    current_color = COLORS[1]
    current_color_idx = 1
    drawing = false
    last_x = nil
    last_y = nil
end

local function hit_color(x, y)
    for i = 1, #COLORS do
        local cx = COLOR_START_X + (i - 1) * COLOR_SPACING
        local cy = TOOLBAR_H // 2
        local dx = x - cx
        local dy = y - cy
        if dx * dx + dy * dy < COLOR_R * COLOR_R then
            return i
        end
    end
    return nil
end

local function hit_clear(x, y)
    local dx = x - CLEAR_X
    local dy = y - CLEAR_Y
    return dx * dx + dy * dy < CLEAR_R * CLEAR_R
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    if t.just_pressed then
        if t.y < TOOLBAR_H then
            -- Toolbar area
            local ci = hit_color(t.x, t.y)
            if ci then
                current_color = COLORS[ci]
                current_color_idx = ci
            elseif hit_clear(t.x, t.y) then
                segments = {}
            end
            drawing = false
            last_x = nil
        else
            -- Canvas area: start drawing
            drawing = true
            last_x = t.x
            last_y = t.y
        end
    elseif t.pressed and t.moved and drawing then
        -- Continue stroke
        if last_x then
            segments[#segments + 1] = {last_x, last_y, t.x, t.y, current_color}
            if #segments > MAX_SEGMENTS then
                table.remove(segments, 1)
            end
        end
        last_x = t.x
        last_y = t.y
    elseif t.just_released then
        drawing = false
        last_x = nil
        -- Long press to exit
        if t.held_ms and t.held_ms > 1500 and t.y < TOOLBAR_H then
            RUNNING = false
        end
    end
end

local function draw_toolbar()
    display.fill_rect(0, 0, W, TOOLBAR_H, BG)

    -- Color palette
    for i, c in ipairs(COLORS) do
        local cx = COLOR_START_X + (i - 1) * COLOR_SPACING
        local cy = TOOLBAR_H // 2
        display.fill_circle(cx, cy, COLOR_R, c)
        if i == current_color_idx then
            display.draw_circle(cx, cy, COLOR_R + 3, "#fbbf24")
            display.draw_circle(cx, cy, COLOR_R + 4, "#fbbf24")
        else
            display.draw_circle(cx, cy, COLOR_R, GRAY)
        end
    end

    -- Eraser label for white
    if current_color_idx == #COLORS then
        display.draw_text(CLEAR_X - 120, TOOLBAR_H // 2 - 12, "ERASER", {font_size = 14, color = GRAY})
    end

    -- Clear button
    display.fill_circle(CLEAR_X, CLEAR_Y, CLEAR_R, "#7f1d1d")
    display.draw_text_aligned(CLEAR_X - 20, CLEAR_Y - 10, 40, 20, "CLR",
        {font_size = 14, color = "white"})
end

local function draw()
    display.begin_frame({clear = true, color = CANVAS})

    -- Canvas background
    display.fill_rect(0, CANVAS_TOP, W, CANVAS_H, CANVAS)

    -- Draw all segments
    for _, s in ipairs(segments) do
        display.draw_line(s[1], s[2], s[3], s[4], s[5])
        -- Draw dots at endpoints for thicker stroke
        display.fill_circle(s[1], s[2], 1, s[5])
        display.fill_circle(s[3], s[4], 1, s[5])
    end

    -- Current stroke preview
    if drawing and last_x then
        display.fill_circle(last_x, last_y, 2, current_color)
    end

    -- Toolbar on top
    draw_toolbar()

    -- Hint
    display.draw_text(10, H - 22, "Long press toolbar to exit", {font_size = 12, color = GRAY})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[paint] Running... long press toolbar to exit")

    while RUNNING do
        handle_touch()
        draw()
        delay.delay_ms(16)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[paint] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[paint] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
