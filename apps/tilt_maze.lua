-- tilt_maze.lua - Tilt maze game using accelerometer
-- Tilt the device to roll a ball through the maze to the goal

local display = require("display")
local board_manager = require("board_manager")
local lib_sc7a20h = require("lib_sc7a20h")
local delay = require("delay")
local i2c = require("i2c")
local math = math

local W, H = 720, 720
local RUNNING = true
local WON = false

-- Maze layout: 1=wall, 0=path, 2=goal
local MAZE = {
    {1,1,1,1,1,1,1,1,1,1},
    {1,0,0,0,1,0,0,0,0,1},
    {1,1,1,0,1,0,1,1,0,1},
    {1,0,0,0,0,0,1,0,0,1},
    {1,0,1,1,1,1,1,0,1,1},
    {1,0,0,0,0,0,0,0,0,1},
    {1,1,1,0,1,1,1,1,0,1},
    {1,0,0,0,1,0,0,0,0,1},
    {1,0,1,1,1,0,1,1,0,2},
    {1,1,1,1,1,1,1,1,1,1},
}
local MAZE_W = 10
local MAZE_H = 10
local CELL = 60
local OFFSET_X = (W - MAZE_W * CELL) // 2
local OFFSET_Y = (H - MAZE_H * CELL) // 2
local BALL_R = 12

-- Colors
local DARK   = "#101018"
local WALL   = "#3a3a5e"
local PATH   = "#1a1a2e"
local GOAL   = "#2d5a2d"
local BALL   = "#e0e0e0"
local BALL_HL = "#ffffff"
local GOAL_C = "#4ade80"
local TEXT_C = "#a0a0c0"

local accel
local touch_handle
local ball_x, ball_y, ball_vx, ball_vy

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[maze] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    local bus = i2c.wrap(1)
    accel = lib_sc7a20h.new({ bus = bus })
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    -- Start position: center of cell (1,1)
    ball_x = OFFSET_X + 1 * CELL + CELL // 2
    ball_y = OFFSET_Y + 1 * CELL + CELL // 2
    ball_vx = 0
    ball_vy = 0
    WON = false
end

local function cell_at(px, py)
    local cx = math.floor((px - OFFSET_X) / CELL) + 1
    local cy = math.floor((py - OFFSET_Y) / CELL) + 1
    if cx < 1 or cx > MAZE_W or cy < 1 or cy > MAZE_H then return 1 end
    return MAZE[cy][cx]
end

local function collides(px, py, r)
    return cell_at(px - r, py) == 1 or cell_at(px + r, py) == 1 or
           cell_at(px, py - r) == 1 or cell_at(px, py + r) == 1 or
           cell_at(px - r*0.7, py - r*0.7) == 1 or
           cell_at(px + r*0.7, py - r*0.7) == 1 or
           cell_at(px - r*0.7, py + r*0.7) == 1 or
           cell_at(px + r*0.7, py + r*0.7) == 1
end

local function update_ball(ax_mg, ay_mg)
    if WON then return end

    -- Gravity from tilt (mg -> px/frame^2)
    -- Direction derived from bubble_level calibration:
    --   ax > 0 -> ball goes left; ay > 0 -> ball goes down
    local GRAV = 0.018
    local gx = -ax_mg * GRAV
    local gy = ay_mg * GRAV

    local FRICTION = 0.95
    local BOUNCE = 0.3
    local MAX_V = 8

    ball_vx = ball_vx * FRICTION + gx
    ball_vy = ball_vy * FRICTION + gy
    ball_vx = math.max(-MAX_V, math.min(MAX_V, ball_vx))
    ball_vy = math.max(-MAX_V, math.min(MAX_V, ball_vy))

    -- Move X axis
    local new_x = ball_x + ball_vx
    if not collides(new_x, ball_y, BALL_R) then
        ball_x = new_x
    else
        ball_vx = -ball_vx * BOUNCE
    end

    -- Move Y axis
    local new_y = ball_y + ball_vy
    if not collides(ball_x, new_y, BALL_R) then
        ball_y = new_y
    else
        ball_vy = -ball_vy * BOUNCE
    end

    -- Check goal
    if cell_at(ball_x, ball_y) == 2 then
        WON = true
        ball_vx = 0
        ball_vy = 0
    end
end

local function draw_maze()
    display.begin_frame({clear = true, color = DARK})

    -- Draw maze cells
    for row = 1, MAZE_H do
        for col = 1, MAZE_W do
            local x = OFFSET_X + (col - 1) * CELL
            local y = OFFSET_Y + (row - 1) * CELL
            local cell = MAZE[row][col]
            if cell == 1 then
                display.fill_rect(x, y, CELL, CELL, WALL)
            elseif cell == 2 then
                display.fill_rect(x, y, CELL, CELL, GOAL)
                -- Goal marker
                local cx, cy = x + CELL // 2, y + CELL // 2
                display.draw_circle(cx, cy, CELL // 3, GOAL_C)
                display.fill_circle(cx, cy, 6, GOAL_C)
            else
                display.fill_rect(x, y, CELL, CELL, PATH)
            end
        end
    end

    -- Grid lines on path
    for row = 1, MAZE_H do
        for col = 1, MAZE_W do
            if MAZE[row][col] == 0 or MAZE[row][col] == 2 then
                local x = OFFSET_X + (col - 1) * CELL
                local y = OFFSET_Y + (row - 1) * CELL
                display.draw_line(x, y, x + CELL, y, "#252540")
                display.draw_line(x, y, x, y + CELL, "#252540")
            end
        end
    end

    -- Ball
    local bx = math.floor(ball_x)
    local by = math.floor(ball_y)
    display.fill_circle(bx, by, BALL_R, BALL)
    display.fill_circle(bx - 4, by - 4, 4, BALL_HL)

    -- Status
    if WON then
        display.fill_rect(0, H // 2 - 50, W, 100, "#000080")
        display.draw_text_aligned(0, H // 2 - 40, W, 50, "YOU WIN!", {font_size = 48, color = GOAL_C})
        display.draw_text_aligned(0, H // 2 + 15, W, 30, "Touch to exit", {font_size = 20, color = TEXT_C})
    else
        display.draw_text_aligned(0, 8, W, 25, "Tilt to roll the ball to the goal", {font_size = 18, color = TEXT_C})
        display.draw_text_aligned(0, H - 30, W, 25, "Touch to exit", {font_size = 16, color = "#2a2a3e"})
    end

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[maze] Running... touch to exit")

    while RUNNING do
        local ax, ay, az = accel:read_mg()
        update_ball(ax, ay)
        draw_maze()

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(16)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = TEXT_C})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    if accel then accel:close() end
    print("[maze] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[maze] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if accel then accel:close() end end)
end
