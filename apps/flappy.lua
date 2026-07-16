-- flappy.lua - Flappy Bird game with tap-to-flap controls
-- Tap anywhere to flap / start / restart. Long press to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Colors
local SKY       = "#4ec0ca"
local GROUND_C  = "#ded895"
local GROUND_DK = "#c9b86a"
local PIPE_C    = "#5fb836"
local PIPE_DK   = "#3f8a24"
local PIPE_HL   = "#9be36f"
local BIRD_YEL  = "#f7d51d"
local BIRD_LT   = "#f7e758"
local BIRD_DK   = "#d9a80a"
local BEAK_C    = "#f6a300"
local BEAK_DK   = "#d88500"
local WHITE     = "white"
local BLACK     = "black"
local DARK      = "#202020"
local GRAY      = "#9aa0a6"
local RED       = "#ef4444"

-- Layout & physics
local BIRD_X       = 180
local BIRD_R       = 15
local GROUND_H     = 80
local GRAVITY      = 0.4
local FLAP_V       = -7
local PIPE_SPEED   = 3
local PIPE_W       = 70
local PIPE_GAP     = 180
local PIPE_SPACING = 220
local CAP_H        = 22

local GROUND_Y  -- set in init (= H - GROUND_H)
local gap_min   -- set in init (gap center bounds)
local gap_max   -- set in init

-- State
local state        -- "ready" / "playing" / "game_over"
local bird_y, bird_vy
local pipes        -- array of {x, gap_y, scored}
local score, best
local frame        -- animation clock
local ground_scroll
local touch_handle

local function spawn_pipe(x)
    local gy = math.random(gap_min, gap_max)
    table.insert(pipes, {x = x, gap_y = gy, scored = false})
end

local function reset_game()
    bird_y = GROUND_Y / 2 - 40
    bird_vy = 0
    pipes = {}
    score = 0
    ground_scroll = 0
    for i = 0, 2 do
        spawn_pipe(W + 80 + i * PIPE_SPACING)
    end
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[flappy] No display device found") end
    W, H = lw or 720, lh or 720
    GROUND_Y = H - GROUND_H
    gap_min = PIPE_GAP / 2 + 60              -- keep gap_top > 60
    gap_max = GROUND_Y - PIPE_GAP / 2 - 40   -- keep gap_bot < ground
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    best = 0
    frame = 0
    state = "ready"
    reset_game()
end

local function flap()
    bird_vy = FLAP_V
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- Long-press exit: must be checked while pressed (held_ms is 0 on release)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end

    if t.just_pressed then
        if state == "ready" then
            state = "playing"
            flap()
        elseif state == "playing" then
            flap()
        elseif state == "game_over" then
            state = "ready"
            reset_game()
        end
    end
end

-- Circle vs axis-aligned rectangle collision
local function circle_rect_hit(cx, cy, r, rx, ry, rw, rh)
    local nx = math.max(rx, math.min(cx, rx + rw))
    local ny = math.max(ry, math.min(cy, ry + rh))
    local dx = cx - nx
    local dy = cy - ny
    return dx * dx + dy * dy < r * r
end

local function end_game()
    state = "game_over"
    if score > best then best = score end
end

local function update()
    frame = frame + 1

    if state == "ready" then
        -- Gentle floating bob in the upper-middle area
        bird_y = (GROUND_Y / 2 - 40) + math.sin(frame * 0.06) * 12
        bird_vy = 0
        return
    end

    if state == "playing" then
        bird_vy = bird_vy + GRAVITY
        bird_y = bird_y + bird_vy
        ground_scroll = ground_scroll + PIPE_SPEED

        -- Move pipes, score passes, recycle off-screen ones
        for i = #pipes, 1, -1 do
            local p = pipes[i]
            p.x = p.x - PIPE_SPEED
            if not p.scored and BIRD_X > p.x + PIPE_W then
                p.scored = true
                score = score + 1
            end
            if p.x + PIPE_W < 0 then
                table.remove(pipes, i)
            end
        end
        if #pipes == 0 or pipes[#pipes].x < W - PIPE_SPACING then
            spawn_pipe(W + 40)
        end

        -- Ceiling
        if bird_y - BIRD_R < 0 then
            bird_y = BIRD_R
            end_game()
            return
        end
        -- Ground
        if bird_y + BIRD_R >= GROUND_Y then
            bird_y = GROUND_Y - BIRD_R
            end_game()
            return
        end
        -- Pipes (circle vs rectangle on top and bottom segments)
        for _, p in ipairs(pipes) do
            local gt = p.gap_y - PIPE_GAP / 2
            local gb = p.gap_y + PIPE_GAP / 2
            if circle_rect_hit(BIRD_X, bird_y, BIRD_R, p.x, 0,  PIPE_W, gt) or
               circle_rect_hit(BIRD_X, bird_y, BIRD_R, p.x, gb, PIPE_W, GROUND_Y - gb) then
                end_game()
                return
            end
        end
    elseif state == "game_over" then
        -- Let the bird drop to the ground after death
        if bird_y + BIRD_R < GROUND_Y then
            bird_vy = bird_vy + GRAVITY
            bird_y = bird_y + bird_vy
            if bird_y + BIRD_R > GROUND_Y then
                bird_y = GROUND_Y - BIRD_R
            end
        end
    end
end

local function draw_pipe(p)
    local x  = math.floor(p.x)
    local gt = p.gap_y - PIPE_GAP / 2
    local gb = p.gap_y + PIPE_GAP / 2
    -- Bodies
    display.fill_rect(x, 0,  PIPE_W, gt,                 PIPE_C)
    display.fill_rect(x, gb, PIPE_W, GROUND_Y - gb,      PIPE_C)
    -- Caps (slightly wider for the classic look)
    local cx = x - 4
    local cw = PIPE_W + 8
    display.fill_rect(cx, gt - CAP_H, cw, CAP_H, PIPE_C)
    display.fill_rect(cx, gb,         cw, CAP_H, PIPE_C)
    -- Edge shading: left highlight, right shadow
    display.fill_rect(x,              0, 4, gt,            PIPE_HL)
    display.fill_rect(x,              gb, 4, GROUND_Y - gb, PIPE_HL)
    display.fill_rect(x + PIPE_W - 4, 0, 4, gt,            PIPE_DK)
    display.fill_rect(x + PIPE_W - 4, gb, 4, GROUND_Y - gb, PIPE_DK)
end

local function draw_bird()
    local bx = BIRD_X
    local by = math.floor(bird_y)
    -- Tilt proxy: shift features by vy (nose up when rising, down when falling)
    local tilt = math.max(-7, math.min(11, bird_vy * 0.9))

    -- Body + belly highlight
    display.fill_circle(bx, by, BIRD_R, BIRD_YEL)
    display.fill_circle(bx - 2, by + 5, 6, BIRD_LT)
    -- Wing (rides higher when flapping up)
    local wy = math.floor(by + 3 + math.max(-3, math.min(4, bird_vy * 0.4)))
    display.fill_circle(bx - 4, wy, 6, BIRD_DK)
    -- Eye
    display.fill_circle(bx + 5, by - 5, 5, WHITE)
    display.fill_circle(bx + 7, by - 5 + math.floor(tilt * 0.2), 2, BLACK)
    -- Beak (offset by tilt for nose up/down feel)
    local bky = by + math.floor(tilt * 0.3)
    display.fill_rect(bx + BIRD_R - 3, bky - 2, 9, 4, BEAK_C)
    display.fill_rect(bx + BIRD_R - 3, bky + 1, 6, 3, BEAK_DK)
end

local function draw()
    display.begin_frame({clear = true, color = SKY})

    -- Pipes
    for _, p in ipairs(pipes) do draw_pipe(p) end

    -- Ground
    display.fill_rect(0, GROUND_Y, W, GROUND_H, GROUND_C)
    display.fill_rect(0, GROUND_Y, W, 6, GROUND_DK)
    local off = ground_scroll % 40
    for x = -off, W, 40 do
        display.fill_rect(math.floor(x), GROUND_Y + 12, 22, 6, GROUND_DK)
    end

    -- Bird
    draw_bird()

    -- Score (top center, large)
    display.draw_text_aligned(0, 18, W, 60,
        string.format("%d", score), {font_size = 56, color = WHITE})
    -- Best (top-right, small)
    display.draw_text_aligned(W - 200, 22, 200, 26,
        string.format("Best %d", best), {font_size = 18, color = WHITE})

    -- State overlays
    if state == "ready" then
        display.draw_text_aligned(0, math.floor(H / 2) + 110, W, 36,
            "Tap to start", {font_size = 30, color = WHITE})
        display.draw_text_aligned(0, math.floor(H / 2) + 152, W, 24,
            "Long press to exit", {font_size = 16, color = GRAY})
    elseif state == "game_over" then
        local cy = math.floor(H / 2)
        display.fill_rect(0, cy - 90, W, 200, DARK)
        display.draw_text_aligned(0, cy - 74, W, 50, "GAME OVER",
            {font_size = 44, color = RED})
        display.draw_text_aligned(0, cy - 16, W, 30,
            string.format("Score: %d", score), {font_size = 26, color = WHITE})
        display.draw_text_aligned(0, cy + 18, W, 30,
            string.format("Best: %d", best), {font_size = 22, color = GRAY})
        display.draw_text_aligned(0, cy + 60, W, 24,
            "Tap to restart  |  Hold to exit", {font_size = 16, color = GRAY})
    end

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[flappy] Running... tap to flap")
    while RUNNING do
        handle_touch()
        update()
        draw()
        delay.delay_ms(16)
    end
    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[flappy] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[flappy] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
