-- breakout.lua - Classic Breakout game with touch controls
-- Drag finger to move paddle, release to launch the ball.
-- Long press on Game Over / Win to exit; tap to play again.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Colors
local DARK      = "#0a0a14"
local WALL      = "#1a1a3a"
local PADDLE    = "#e0e0e0"
local PADDLE_HL = "#ffffff"
local BALL_C    = "#ffffff"
local BALL_HL   = "#c0c0ff"
local HUD       = "#a0a0c0"
local GRAY      = "#606080"

-- Brick row colors (top to bottom)
local BRICK_COLORS = {
    "#ef4444",  -- red
    "#f59e0b",  -- orange
    "#facc15",  -- yellow
    "#22c55e",  -- green
    "#06b6d4",  -- cyan
    "#3b82f6",  -- blue
    "#a855f7",  -- purple
    "#ec4899",  -- pink
}

-- Layout
local COLS = 10
local ROWS = #BRICK_COLORS
local BRICK_W = 64
local BRICK_H = 22
local GAP = 4
local BRICK_AREA_W = COLS * BRICK_W + (COLS - 1) * GAP  -- 676
local BRICK_OFFSET_X = (W - BRICK_AREA_W) // 2            -- 22
local BRICK_OFFSET_Y = 70
local TOP_WALL_Y = BRICK_OFFSET_Y - 10                    -- 60
local PADDLE_W = 110
local PADDLE_H = 14
local PADDLE_Y = 640
local BALL_R = 8

-- Game state
local bricks         -- 2D array of bool (alive)
local bricks_left
local paddle_x       -- center x
local ball_x, ball_y
local ball_vx, ball_vy
local state          -- "ready" / "playing" / "game_over" / "won"
local lives
local score
local touch_handle

local function brick_rect(r, c)
    local x = BRICK_OFFSET_X + (c - 1) * (BRICK_W + GAP)
    local y = BRICK_OFFSET_Y + (r - 1) * (BRICK_H + GAP)
    return x, y, BRICK_W, BRICK_H
end

local function init_bricks()
    bricks = {}
    bricks_left = 0
    for r = 1, ROWS do
        bricks[r] = {}
        for c = 1, COLS do
            bricks[r][c] = true
            bricks_left = bricks_left + 1
        end
    end
end

local function reset_ball()
    ball_x = paddle_x
    ball_y = PADDLE_Y - BALL_R - 2
    ball_vx = 0
    ball_vy = 0
    state = "ready"
end

local function clamp_paddle()
    local half = PADDLE_W // 2
    local lo = BRICK_OFFSET_X + half
    local hi = W - BRICK_OFFSET_X - half
    if paddle_x < lo then paddle_x = lo end
    if paddle_x > hi then paddle_x = hi end
end

local function launch_ball()
    local speed = 5
    -- Launch nearly straight up with a small random tilt
    local angle = -math.pi / 2 + (math.random() - 0.5) * 0.6
    ball_vx = speed * math.cos(angle)
    ball_vy = speed * math.sin(angle)
    state = "playing"
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[breakout] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    paddle_x = W // 2
    score = 0
    lives = 3
    init_bricks()
    reset_ball()
end

local function restart()
    score = 0
    lives = 3
    init_bricks()
    paddle_x = W // 2
    reset_ball()
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- Move paddle while pressing (only during active play)
    if t.pressed and (state == "ready" or state == "playing") then
        paddle_x = math.floor(t.x)
        clamp_paddle()
        if state == "ready" then
            ball_x = paddle_x
        end
    end

    if t.just_released then
        if state == "ready" then
            launch_ball()
        elseif state == "game_over" or state == "won" then
            if t.held_ms and t.held_ms > 1500 then
                RUNNING = false
            else
                restart()
            end
        end
    end
end

local function check_brick_collisions()
    for r = 1, ROWS do
        for c = 1, COLS do
            if bricks[r][c] then
                local rx, ry, rw, rh = brick_rect(r, c)
                -- Closest point on brick to ball center
                local cx = math.max(rx, math.min(ball_x, rx + rw))
                local cy = math.max(ry, math.min(ball_y, ry + rh))
                local dx = ball_x - cx
                local dy = ball_y - cy
                if dx * dx + dy * dy < BALL_R * BALL_R then
                    bricks[r][c] = false
                    bricks_left = bricks_left - 1
                    score = score + 10
                    -- Bounce on axis of smaller penetration
                    local overlap_x = BALL_R - math.abs(dx)
                    local overlap_y = BALL_R - math.abs(dy)
                    if overlap_x < overlap_y then
                        ball_vx = -ball_vx
                        if dx > 0 then ball_x = cx + BALL_R
                        elseif dx < 0 then ball_x = cx - BALL_R end
                    else
                        ball_vy = -ball_vy
                        if dy > 0 then ball_y = cy + BALL_R
                        elseif dy < 0 then ball_y = cy - BALL_R end
                    end
                    -- Speed up slightly, capped
                    local sp = math.sqrt(ball_vx * ball_vx + ball_vy * ball_vy)
                    if sp < 8 then
                        local k = 1.03
                        ball_vx = ball_vx * k
                        ball_vy = ball_vy * k
                    end
                    if bricks_left == 0 then
                        state = "won"
                    end
                    return  -- one brick per sub-step
                end
            end
        end
    end
end

local function update_ball()
    if state ~= "playing" then return end

    -- Sub-step to avoid tunneling at higher speeds
    local SUBSTEPS = 4
    for _ = 1, SUBSTEPS do
        ball_x = ball_x + ball_vx / SUBSTEPS
        ball_y = ball_y + ball_vy / SUBSTEPS

        -- Wall bounces (left/right/top of play area)
        if ball_x - BALL_R < BRICK_OFFSET_X then
            ball_x = BRICK_OFFSET_X + BALL_R
            ball_vx = -ball_vx
        elseif ball_x + BALL_R > W - BRICK_OFFSET_X then
            ball_x = W - BRICK_OFFSET_X - BALL_R
            ball_vx = -ball_vx
        end
        if ball_y - BALL_R < TOP_WALL_Y then
            ball_y = TOP_WALL_Y + BALL_R
            ball_vy = -ball_vy
        end

        -- Paddle collision: angle based on hit position
        if ball_vy > 0
            and ball_y + BALL_R >= PADDLE_Y
            and ball_y + BALL_R <= PADDLE_Y + PADDLE_H + 4
            and ball_x >= paddle_x - PADDLE_W / 2 - BALL_R
            and ball_x <= paddle_x + PADDLE_W / 2 + BALL_R then
            local hit = (ball_x - paddle_x) / (PADDLE_W / 2)  -- -1 .. 1
            hit = math.max(-1, math.min(1, hit))
            local speed = math.sqrt(ball_vx * ball_vx + ball_vy * ball_vy)
            -- Center -> straight up; edges -> up to +/- 60 deg
            local angle = -math.pi / 2 + hit * (math.pi / 3)
            ball_vx = speed * math.cos(angle)
            ball_vy = speed * math.sin(angle)
            ball_y = PADDLE_Y - BALL_R - 1
        end

        -- Ball fell below paddle
        if ball_y - BALL_R > H then
            lives = lives - 1
            if lives <= 0 then
                state = "game_over"
            else
                paddle_x = W // 2
                reset_ball()
            end
            return
        end

        -- Brick collisions
        check_brick_collisions()
        if state ~= "playing" then return end
    end
end

local function draw()
    display.begin_frame({clear = true, color = DARK})

    -- Side & top walls (visual frame)
    display.fill_rect(0, 0, BRICK_OFFSET_X, H, WALL)
    display.fill_rect(W - BRICK_OFFSET_X, 0, BRICK_OFFSET_X, H, WALL)
    display.fill_rect(0, 0, W, TOP_WALL_Y, WALL)

    -- Bricks
    for r = 1, ROWS do
        for c = 1, COLS do
            if bricks[r][c] then
                local x, y = brick_rect(r, c)
                display.fill_round_rect(x, y, BRICK_W, BRICK_H, 3, BRICK_COLORS[r])
            end
        end
    end

    -- Paddle (with subtle highlight)
    local px = math.floor(paddle_x - PADDLE_W / 2)
    display.fill_round_rect(px, PADDLE_Y, PADDLE_W, PADDLE_H, 5, PADDLE)
    display.fill_rect(px + 4, PADDLE_Y + 2, PADDLE_W - 8, 3, PADDLE_HL)

    -- Ball
    local bx = math.floor(ball_x)
    local by = math.floor(ball_y)
    display.fill_circle(bx, by, BALL_R, BALL_C)
    display.fill_circle(bx - 2, by - 2, 2, BALL_HL)

    -- HUD
    display.draw_text_aligned(0, 12, W / 2, 30,
        string.format("Score: %d", score), {font_size = 22, color = HUD})
    display.draw_text_aligned(W / 2, 12, W / 2, 30,
        string.format("Lives: %d", lives), {font_size = 22, color = HUD})

    -- State overlays
    if state == "ready" then
        display.draw_text_aligned(0, H - 40, W, 24,
            "Drag to aim, release to launch", {font_size = 16, color = GRAY})
    elseif state == "game_over" then
        display.fill_rect(0, H // 2 - 60, W, 130, "#1a0000")
        display.draw_text_aligned(0, H // 2 - 50, W, 50, "GAME OVER",
            {font_size = 44, color = "#ef4444"})
        display.draw_text_aligned(0, H // 2 + 8, W, 28,
            string.format("Score: %d", score), {font_size = 22, color = HUD})
        display.draw_text_aligned(0, H // 2 + 40, W, 24,
            "Tap to play again  |  Hold to exit", {font_size = 14, color = GRAY})
    elseif state == "won" then
        display.fill_rect(0, H // 2 - 60, W, 130, "#001a00")
        display.draw_text_aligned(0, H // 2 - 50, W, 50, "YOU WIN!",
            {font_size = 44, color = "#4ade80"})
        display.draw_text_aligned(0, H // 2 + 8, W, 28,
            string.format("Score: %d", score), {font_size = 22, color = HUD})
        display.draw_text_aligned(0, H // 2 + 40, W, 24,
            "Tap to play again  |  Hold to exit", {font_size = 14, color = GRAY})
    end

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[breakout] Running... drag to move paddle, release to launch")

    while RUNNING do
        handle_touch()
        update_ball()
        draw()
        delay.delay_ms(16)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[breakout] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[breakout] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
