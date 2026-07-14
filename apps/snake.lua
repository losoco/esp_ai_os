-- snake.lua - Classic Snake game with touch swipe controls

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Grid
local CELL = 36
local GRID_W = 20
local GRID_H = 20
local OFFSET_X = (W - GRID_W * CELL) // 2
local OFFSET_Y = (H - GRID_H * CELL) // 2

-- Colors
local DARK   = "#0a0a14"
local GRID_C = "#141428"
local SNAKE  = "#22c55e"
local SNAKE_HD = "#4ade80"
local FOOD   = "#ef4444"
local FOOD_HL = "#fca5a5"
local WHITE  = "white"
local GRAY   = "#606080"
local GAMEOVER_BG = "#1a0000"

-- Game state
local snake      -- array of {col, row}
local dir        -- "up" / "down" / "left" / "right"
local next_dir
local food       -- {col, row}
local score
local game_over
local step_ms    -- speed: ms per step
local last_step_time
local touch_handle
local swipe_start_x, swipe_start_y

local function place_food()
    local pos
    repeat
        pos = {
            col = math.random(1, GRID_W),
            row = math.random(1, GRID_H),
        }
        local on_snake = false
        for _, s in ipairs(snake) do
            if s.col == pos.col and s.row == pos.row then
                on_snake = true
                break
            end
        end
    until not on_snake
    food = pos
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[snake] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    -- Initial snake: 3 segments in center, moving right
    local cx, cy = GRID_W // 2, GRID_H // 2
    snake = {
        {col = cx,     row = cy},
        {col = cx - 1, row = cy},
        {col = cx - 2, row = cy},
    }
    dir = "right"
    next_dir = "right"
    score = 0
    game_over = false
    step_ms = 150
    last_step_time = 0
    swipe_start_x = nil
    swipe_start_y = nil

    place_food()
end

local function set_dir(new_dir)
    -- Prevent 180-degree turns
    local opposites = {up = "down", down = "up", left = "right", right = "left"}
    if new_dir ~= opposites[dir] then
        next_dir = new_dir
    end
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    if t.just_pressed then
        swipe_start_x = t.x
        swipe_start_y = t.y
    elseif t.just_released and swipe_start_x then
        local dx = t.x - swipe_start_x
        local dy = t.y - swipe_start_y
        local abs_dx = math.abs(dx)
        local abs_dy = math.abs(dy)
        local threshold = 20
        if abs_dx > threshold or abs_dy > threshold then
            if abs_dx > abs_dy then
                set_dir(dx > 0 and "right" or "left")
            else
                set_dir(dy > 0 and "down" or "up")
            end
        end
        swipe_start_x = nil
        swipe_start_y = nil
    end

    -- Exit on long press (hold > 1.5s) when game over
    if game_over and t.just_released and t.held_ms and t.held_ms > 800 then
        RUNNING = false
    end
end

local function step()
    dir = next_dir

    local head = snake[1]
    local nh = {col = head.col, row = head.row}
    if dir == "up" then nh.row = nh.row - 1
    elseif dir == "down" then nh.row = nh.row + 1
    elseif dir == "left" then nh.col = nh.col - 1
    elseif dir == "right" then nh.col = nh.col + 1
    end

    -- Wall collision
    if nh.col < 1 or nh.col > GRID_W or nh.row < 1 or nh.row > GRID_H then
        game_over = true
        return
    end

    -- Self collision (skip tail since it will move)
    for i = 1, #snake - 1 do
        if snake[i].col == nh.col and snake[i].row == nh.row then
            game_over = true
            return
        end
    end

    table.insert(snake, 1, nh)

    -- Eat food
    if nh.col == food.col and nh.row == food.row then
        score = score + 10
        step_ms = math.max(60, step_ms - 3)  -- speed up
        place_food()
    else
        table.remove(snake)  -- remove tail
    end
end

local function draw()
    display.begin_frame({clear = true, color = DARK})

    -- Grid background
    for row = 1, GRID_H do
        local y = OFFSET_Y + (row - 1) * CELL
        for col = 1, GRID_W do
            local x = OFFSET_X + (col - 1) * CELL
            if (row + col) % 2 == 0 then
                display.fill_rect(x, y, CELL, CELL, GRID_C)
            end
        end
    end

    -- Border
    display.draw_rect(OFFSET_X - 2, OFFSET_Y - 2,
                      GRID_W * CELL + 4, GRID_H * CELL + 4, GRAY)

    -- Food
    local fx = OFFSET_X + (food.col - 1) * CELL + CELL // 2
    local fy = OFFSET_Y + (food.row - 1) * CELL + CELL // 2
    display.fill_circle(fx, fy, CELL // 2 - 4, FOOD)
    display.fill_circle(fx - 3, fy - 3, 4, FOOD_HL)

    -- Snake
    for i, s in ipairs(snake) do
        local x = OFFSET_X + (s.col - 1) * CELL
        local y = OFFSET_Y + (s.row - 1) * CELL
        local color = (i == 1) and SNAKE_HD or SNAKE
        display.fill_round_rect(x + 2, y + 2, CELL - 4, CELL - 4, 5, color)
    end

    -- Score
    display.draw_text_aligned(0, 5, W, 30,
        string.format("Score: %d", score), {font_size = 22, color = WHITE})

    if game_over then
        display.fill_rect(0, H // 2 - 60, W, 120, GAMEOVER_BG)
        display.draw_text_aligned(0, H // 2 - 50, W, 50, "GAME OVER",
            {font_size = 42, color = FOOD})
        display.draw_text_aligned(0, H // 2 + 10, W, 30,
            string.format("Score: %d  -  Long press to exit", score),
            {font_size = 18, color = GRAY})
    else
        display.draw_text_aligned(0, H - 25, W, 20,
            "Swipe to steer  |  Long press to exit", {font_size = 14, color = "#2a2a3e"})
    end

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[snake] Running... swipe to steer, long press to exit")

    while RUNNING do
        handle_touch()

        if not game_over then
            last_step_time = last_step_time + 16
            if last_step_time >= step_ms then
                step()
                last_step_time = 0
            end
        end

        draw()
        delay.delay_ms(16)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[snake] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[snake] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
