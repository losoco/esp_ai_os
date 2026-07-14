-- simon.lua - Simon Says memory game
-- Watch the sequence of colored buttons light up, then tap them back in order.
-- Each round adds one more step. Long press on idle / game over to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Colors
local DARK  = "#0a0a14"
local WHITE = "white"
local GRAY  = "#606080"
local HUD   = "#a0a0c0"

-- 4 buttons: 1=green(TL), 2=red(TR), 3=blue(BL), 4=yellow(BR)
local BTN_COLOR = {"#22c55e", "#ef4444", "#3b82f6", "#facc15"}
local BTN_DARK  = {"#166534", "#7f1d1d", "#1e3a8a", "#713f12"}

-- 2x2 grid layout with a cross gap in the middle for the status hub
local BTN   = 270
local GAP   = 40
local ORIGIN_X = (720 - 2 * BTN - GAP) // 2  -- 70
local ORIGIN_Y = (720 - 2 * BTN - GAP) // 2  -- 70

-- button index -> {x, y}
local BTN_POS = {
    {ORIGIN_X,           ORIGIN_Y},            -- 1 green top-left
    {ORIGIN_X + BTN + GAP, ORIGIN_Y},           -- 2 red top-right
    {ORIGIN_X,           ORIGIN_Y + BTN + GAP}, -- 3 blue bottom-left
    {ORIGIN_X + BTN + GAP, ORIGIN_Y + BTN + GAP}, -- 4 yellow bottom-right
}

local CENTER_X = 360
local CENTER_Y = 360
local HUB_R = 95

-- Timing (ms)
local SHOW_ON_MS    = 400   -- button lit during demo
local SHOW_GAP_MS   = 150   -- gap between demo buttons
local INPUT_FLASH_MS = 200  -- flash on correct player tap
local WRONG_FLASH_MS = 500  -- flash on wrong player tap
local EXIT_HOLD_MS   = 1500 -- long-press to exit

-- Game state
local state          -- "idle" / "showing" / "input" / "game_over"
local sequence       -- array of button indices {1..4}
local input_idx      -- next expected position in sequence (1-based)
local level          -- current sequence length
local high_score     -- best rounds completed
local lit            -- currently lit button (0 = none)
local show_idx       -- sequence position being demonstrated
local show_phase     -- "gap" or "on"
local show_timer     -- ms elapsed in current demo phase
local flash_timer    -- ms remaining for input/wrong flash
local pending_next   -- start next round once flash ends
local touch_handle

local function btn_at(x, y)
    for i = 1, 4 do
        local bx, by = BTN_POS[i][1], BTN_POS[i][2]
        if x >= bx and x < bx + BTN and y >= by and y < by + BTN then
            return i
        end
    end
    return nil
end

local function start_new_round()
    sequence[#sequence + 1] = math.random(1, 4)
    level = #sequence
    show_idx = 1
    show_phase = "gap"
    show_timer = 0
    lit = 0
    state = "showing"
end

local function start_game()
    sequence = {}
    input_idx = 1
    level = 0
    lit = 0
    flash_timer = 0
    pending_next = false
    start_new_round()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[simon] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    state = "idle"
    sequence = {}
    input_idx = 1
    level = 0
    high_score = 0
    lit = 0
    show_idx = 1
    show_phase = "gap"
    show_timer = 0
    flash_timer = 0
    pending_next = false
    -- Seed PRNG if os.time is available
    pcall(function() math.randomseed(os.time()) end)
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)
    if not t.just_released then return end

    if state == "idle" then
        if t.held_ms and t.held_ms > EXIT_HOLD_MS then
            RUNNING = false
        else
            start_game()
        end
    elseif state == "input" then
        local idx = btn_at(math.floor(t.x), math.floor(t.y))
        if not idx then return end
        if idx == sequence[input_idx] then
            -- correct: brief flash, advance
            input_idx = input_idx + 1
            lit = idx
            flash_timer = INPUT_FLASH_MS
            if input_idx > #sequence then
                pending_next = true  -- start next round after flash
            end
        else
            -- wrong: game over, flash the wrong button
            state = "game_over"
            lit = idx
            flash_timer = WRONG_FLASH_MS
            if (level - 1) > high_score then
                high_score = level - 1
            end
        end
    elseif state == "game_over" then
        if t.held_ms and t.held_ms > EXIT_HOLD_MS then
            RUNNING = false
        else
            start_game()
        end
    end
end

local function update(dt)
    if state == "showing" then
        show_timer = show_timer + dt
        if show_phase == "gap" then
            lit = 0
            if show_timer >= SHOW_GAP_MS then
                show_phase = "on"
                show_timer = 0
                lit = sequence[show_idx]
            end
        else  -- "on"
            lit = sequence[show_idx]
            if show_timer >= SHOW_ON_MS then
                show_phase = "gap"
                show_timer = 0
                lit = 0
                show_idx = show_idx + 1
                if show_idx > #sequence then
                    state = "input"
                    input_idx = 1
                end
            end
        end
    else
        -- flash timer (input / game_over / idle)
        if flash_timer > 0 then
            flash_timer = flash_timer - dt
            if flash_timer <= 0 then
                flash_timer = 0
                lit = 0
                if pending_next then
                    pending_next = false
                    start_new_round()
                end
            end
        end
    end
end

local function draw()
    display.begin_frame({clear = true, color = DARK})

    -- 4 buttons
    for i = 1, 4 do
        local bx, by = BTN_POS[i][1], BTN_POS[i][2]
        local color = (lit == i) and BTN_COLOR[i] or BTN_DARK[i]
        display.fill_round_rect(bx, by, BTN, BTN, 18, color)
        if lit == i then
            display.draw_round_rect(bx, by, BTN, BTN, 18, WHITE)
        end
    end

    -- Central hub covering the cross gap (dark disc + outline)
    display.fill_circle(CENTER_X, CENTER_Y, HUB_R, DARK)
    display.draw_circle(CENTER_X, CENTER_Y, HUB_R, GRAY)

    -- Status text in the hub
    local title, sub
    if state == "idle" then
        title = "SIMON"
        sub = "Tap to start"
    elseif state == "showing" then
        title = string.format("LEVEL %d", level)
        sub = "Watch..."
    elseif state == "input" then
        title = string.format("LEVEL %d", level)
        sub = string.format("%d / %d", input_idx - 1, #sequence)
    else  -- game_over
        title = "GAME OVER"
        sub = "Tap to restart"
    end
    display.draw_text_aligned(0, CENTER_Y - 30, W, 28, title,
        {font_size = 22, color = WHITE})
    display.draw_text_aligned(0, CENTER_Y + 4, W, 20, sub,
        {font_size = 14, color = HUD})

    -- High score (top)
    display.draw_text_aligned(0, 16, W, 22,
        string.format("High: %d", high_score), {font_size = 18, color = HUD})

    -- Bottom hint
    display.draw_text_aligned(0, H - 26, W, 18,
        "Long press to exit", {font_size = 13, color = GRAY})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[simon] Running... tap to start, long press to exit")

    while RUNNING do
        handle_touch()
        update(16)
        draw()
        delay.delay_ms(16)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[simon] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[simon] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
