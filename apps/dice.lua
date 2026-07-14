-- dice.lua - Shake-to-roll dice using accelerometer + display
-- Detects shake via accel magnitude deviation from gravity, plays a 2D-simulated
-- 3D tumble animation (scale + yaw compression + face cycling), then shows the
-- result. Tap to roll manually, long-press to exit.

local display = require("display")
local board_manager = require("board_manager")
local lib_sc7a20h = require("lib_sc7a20h")
local delay = require("delay")
local i2c = require("i2c")
local math = math

local W, H = 720, 720
local CX, CY = 360, 360
local RUNNING = true

-- Colors
local DARK   = "#202020"
local WHITE  = "white"
local PIP    = "#101010"
local GRAY   = "#808080"
local HISTBG = "#2a2a2a"
local HINT   = "#505060"
local SHADOW = "#0a0a0a"
local EDGE   = "#404040"
local HI     = "#a0a0a0"

local accel
local touch_handle

-- State machine: "idle" | "rolling"
local state = "idle"
local roll_elapsed = 0
local ROLL_DURATION       = 1500  -- ms, total tumble time
local FACE_SWITCH_INTERVAL = 80   -- ms between random face switches
local FINAL_LOCK_MS       = 220   -- last ms: lock to final face
local face_switch_timer = 0
local final_face = 1
local current_face = 1
local history = {}  -- newest at end, max 5

-- Shake detection
local SHAKE_THRESHOLD     = 800   -- mg deviation from 1g
local SHAKE_COUNT_NEEDED  = 3     -- consecutive over-threshold samples
local SHAKE_COOLDOWN      = 600   -- ms after a roll before shake re-arms
local shake_count = 0
local cooldown = 0

-- Touch state
local press_active = false

local FRAME_MS = 30

-- Dice face layouts (positions 1..9 in a 3x3 grid)
-- 1=TL 2=TC 3=TR / 4=ML 5=MC 6=MR / 7=BL 8=BC 9=BR
local FACES = {
    {5},                   -- 1: center
    {1, 9},                -- 2: TL + BR
    {1, 5, 9},             -- 3: TL + center + BR
    {1, 3, 7, 9},          -- 4: four corners
    {1, 3, 5, 7, 9},       -- 5: four corners + center
    {1, 4, 7, 3, 6, 9},    -- 6: two columns of three
}

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[dice] No display device found") end
    W, H = lw or 720, lh or 720
    CX, CY = W // 2, H // 2
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    local bus = i2c.wrap(1)
    accel = lib_sc7a20h.new({ bus = bus })
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
end

-- Center (x, y) of pip `pos` (1..9) inside a die of `size` px (unrotated).
local function pip_pos(pos, size)
    local step = size / 4
    local col = (pos - 1) % 3
    local row = math.floor((pos - 1) / 3)
    return step + col * step, step + row * step
end

-- Draw a die centered at (cx, cy). face 1..6 draws pips; 0/nil draws empty body.
-- `yaw` rotates around the vertical axis (compresses width via cos), simulating
-- a 3D tumble in 2D. `scale` multiplies the base size.
local function draw_die(cx, cy, base_size, face, yaw, scale)
    local compress = math.abs(math.cos(yaw or 0))
    if compress < 0.15 then compress = 0.15 end
    local s = math.floor(base_size * (scale or 1.0))
    local w = math.floor(s * compress)
    local h = s
    if w < 20 then w = 20 end
    local r = math.max(4, math.floor(h * 0.16))
    local x = math.floor(cx - w / 2)
    local y = math.floor(cy - h / 2)

    -- Drop shadow
    display.fill_round_rect(x + 6, y + 10, w, h, r, SHADOW)
    -- Body
    display.fill_round_rect(x, y, w, h, r, WHITE)
    display.draw_round_rect(x, y, w, h, r, EDGE)

    if face and face >= 1 and face <= 6 then
        local pip_r = math.max(3, math.floor(h / 12))
        local layout = FACES[face]
        for _, p in ipairs(layout) do
            local px, py = pip_pos(p, h)
            -- compress pip x-offset around die center to match body
            local cxp = math.floor(cx + (px - h / 2) * compress)
            local cyp = math.floor(cy + py - h / 2)
            display.fill_circle(cxp, cyp, pip_r, PIP)
            -- tiny highlight for a 3D bead look
            display.fill_circle(cxp - pip_r // 3, cyp - pip_r // 3,
                math.max(1, pip_r // 4), HI)
        end
    end
end

local function start_roll()
    state = "rolling"
    roll_elapsed = 0
    face_switch_timer = 0
    final_face = math.random(1, 6)
    current_face = math.random(1, 6)
    cooldown = SHAKE_COOLDOWN
    shake_count = 0
end

local function finish_roll()
    state = "idle"
    current_face = final_face
    table.insert(history, final_face)
    if #history > 5 then table.remove(history, 1) end
end

local function draw_history()
    local n = #history
    if n == 0 then return end
    local mini = 56
    local gap = 16
    local total_w = n * mini + (n - 1) * gap
    local start_x = (W - total_w) // 2
    local y = H - 110
    for i = 1, n do
        local x = start_x + (i - 1) * (mini + gap)
        display.fill_round_rect(x, y, mini, mini, 10, HISTBG)
        display.draw_round_rect(x, y, mini, mini, 10, "#3a3a3a")
        local pip_r = math.max(2, mini // 12)
        local layout = FACES[history[i]] or FACES[1]
        for _, p in ipairs(layout) do
            local px, py = pip_pos(p, mini)
            display.fill_circle(x + math.floor(px), y + math.floor(py), pip_r, PIP)
        end
        if i == n then
            -- highlight the newest result with a white border
            display.draw_round_rect(x - 2, y - 2, mini + 4, mini + 4, 12, WHITE)
        end
    end
end

local function draw()
    display.begin_frame({clear = true, color = DARK})

    if state == "rolling" then
        local t = roll_elapsed / ROLL_DURATION  -- 0..1 progress
        -- bouncy scale, decaying to 1.0
        local scale = 1.0 + 0.30 * math.sin(roll_elapsed * 0.022) * (1 - t)
        -- yaw spin, slowing toward the end
        local yaw = roll_elapsed * 0.014 * (1 - t * 0.6)
        -- vertical bob, decaying
        local bob = math.sin(roll_elapsed * 0.018) * 18 * (1 - t)
        draw_die(CX, math.floor(CY + bob), 300, current_face, yaw, scale)
        display.draw_text_aligned(0, 40, W, 40, "Rolling...",
            {font_size = 30, color = GRAY})
    else
        if #history > 0 then
            draw_die(CX, CY, 300, current_face, 0, 1.0)
            display.draw_text_aligned(0, 70, W, 30,
                string.format("You rolled: %d", current_face),
                {font_size = 22, color = HINT})
        else
            -- empty die with "?" before first roll
            draw_die(CX, CY, 300, 0, 0, 1.0)
            display.draw_text_aligned(CX - 150, CY - 150, 300, 300, "?",
                {font_size = 140, color = GRAY})
        end
        local prompt = (#history == 0) and "Shake me!" or "Shake again or tap"
        display.draw_text_aligned(0, 40, W, 40, prompt,
            {font_size = 28, color = HINT})
        display.draw_text_aligned(0, H - 30, W, 24, "Long-press to exit",
            {font_size = 16, color = "#2a2a30"})
    end

    draw_history()
    display.present()
    display.end_frame()
end

local function handle_shake()
    if state ~= "idle" or cooldown > 0 then return end
    local ax, ay, az = accel:read_mg()
    local mag = math.sqrt(ax * ax + ay * ay + az * az)
    local dev = math.abs(mag - 1000)  -- deviation from 1g gravity
    if dev > SHAKE_THRESHOLD then
        shake_count = shake_count + 1
    else
        shake_count = 0  -- reset on calm sample
    end
    if shake_count >= SHAKE_COUNT_NEEDED then
        shake_count = 0
        start_roll()
    end
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)
    if t.just_pressed then
        press_active = true
    end
    -- long-press exits regardless of state
    if press_active and t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        press_active = false
        return
    end
    -- tap (press + release under 1500ms) triggers a roll when idle
    if t.just_released and press_active then
        press_active = false
        if state == "idle" then
            start_roll()
        end
    end
end

local function run()
    init()
    print("[dice] Running... shake or tap to roll, long-press to exit")

    while RUNNING do
        -- decay post-roll cooldown
        if cooldown > 0 then
            cooldown = cooldown - FRAME_MS
            if cooldown < 0 then cooldown = 0 end
        end

        if state == "rolling" then
            roll_elapsed = roll_elapsed + FRAME_MS
            local remaining = ROLL_DURATION - roll_elapsed
            if remaining <= FINAL_LOCK_MS then
                -- lock to final face for the last stretch
                current_face = final_face
            else
                face_switch_timer = face_switch_timer + FRAME_MS
                if face_switch_timer >= FACE_SWITCH_INTERVAL then
                    face_switch_timer = 0
                    current_face = math.random(1, 6)
                end
            end
            if roll_elapsed >= ROLL_DURATION then
                finish_roll()
            end
        else
            handle_shake()
        end

        handle_touch()
        draw()
        delay.delay_ms(FRAME_MS)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    if accel then accel:close() end
    print("[dice] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[dice] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if accel then accel:close() end end)
end
