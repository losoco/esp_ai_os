-- g2048.lua - Classic 2048 merge puzzle with touch swipe controls
-- Swipe up/down/left/right to move tiles. Long press to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Layout (BOARD_* computed in init for actual W/H)
local CELL = 140
local GAP = 8
local BOARD_SIZE, BOARD_X, BOARD_Y

-- Colors
local BG = "#faf8ef"
local BOARD_BG = "#bbada0"
local EMPTY_CELL = "#cdc1b4"
local TEXT_DARK = "#776e65"
local TEXT_LIGHT = "#f9f6f2"
local GRAY = "#8a7f70"
local PANEL_BG = "#5a4f40"

-- Tile colors [value] = {bg, fg}
local TILE_COLORS = {
    [2]    = {bg = "#eee4da", fg = "#776e65"},
    [4]    = {bg = "#ede0c8", fg = "#776e65"},
    [8]    = {bg = "#f2b179", fg = "#f9f6f2"},
    [16]   = {bg = "#f59563", fg = "#f9f6f2"},
    [32]   = {bg = "#f67c5f", fg = "#f9f6f2"},
    [64]   = {bg = "#f65e3b", fg = "#f9f6f2"},
    [128]  = {bg = "#edcf72", fg = "#f9f6f2"},
    [256]  = {bg = "#edcc61", fg = "#f9f6f2"},
    [512]  = {bg = "#edc850", fg = "#f9f6f2"},
    [1024] = {bg = "#edc53f", fg = "#f9f6f2"},
    [2048] = {bg = "#edc22e", fg = "#f9f6f2"},
}
local TILE_BIG = {bg = "#3c3a32", fg = "#f9f6f2"}

-- Game state
local grid          -- grid[r][c], r/c = 1..4, 0 = empty
local score
local best = 0      -- best score, persists for process lifetime
local game_over
local won           -- reached 2048 at least once (keep playing)
local touch_handle
local swipe_start_x, swipe_start_y

local function font_for(v)
    if v < 100 then return 44
    elseif v < 1000 then return 36
    elseif v < 10000 then return 28
    else return 22 end
end

local function empty_cells()
    local cells = {}
    for r = 1, 4 do
        for c = 1, 4 do
            if grid[r][c] == 0 then cells[#cells + 1] = {r = r, c = c} end
        end
    end
    return cells
end

local function spawn_tile()
    local cells = empty_cells()
    if #cells == 0 then return end
    local cell = cells[math.random(1, #cells)]
    -- 90% -> 2, 10% -> 4
    grid[cell.r][cell.c] = (math.random(1, 10) <= 9) and 2 or 4
end

local function reset_game()
    grid = {}
    for r = 1, 4 do
        grid[r] = {0, 0, 0, 0}
    end
    score = 0
    game_over = false
    won = false
    spawn_tile()
    spawn_tile()
end

-- Compress + merge a line of 4. Returns (new_line, gained_score, changed)
local function process_line(line)
    -- compress: drop zeros
    local comp = {}
    for i = 1, 4 do
        if line[i] ~= 0 then comp[#comp + 1] = line[i] end
    end
    -- merge adjacent equal (each tile merges at most once)
    local merged = {}
    local gained = 0
    local i = 1
    while i <= #comp do
        if i < #comp and comp[i] == comp[i + 1] then
            local v = comp[i] * 2
            merged[#merged + 1] = v
            gained = gained + v
            if v == 2048 then won = true end
            i = i + 2
        else
            merged[#merged + 1] = comp[i]
            i = i + 1
        end
    end
    while #merged < 4 do merged[#merged + 1] = 0 end
    local changed = false
    for k = 1, 4 do
        if merged[k] ~= line[k] then changed = true; break end
    end
    return merged, gained, changed
end

local function has_moves()
    for r = 1, 4 do
        for c = 1, 4 do
            if grid[r][c] == 0 then return true end
            if c < 4 and grid[r][c] == grid[r][c + 1] then return true end
            if r < 4 and grid[r][c] == grid[r + 1][c] then return true end
        end
    end
    return false
end

local function move(dir)
    if game_over then return end
    local moved = false
    local gained = 0
    for i = 1, 4 do
        -- build line based on direction (index 1 = destination side)
        local line = {}
        for j = 1, 4 do
            local r, c
            if dir == "left" then r, c = i, j
            elseif dir == "right" then r, c = i, 5 - j
            elseif dir == "up" then r, c = j, i
            else r, c = 5 - j, i end  -- down
            line[j] = grid[r][c]
        end
        local new_line, g, changed = process_line(line)
        gained = gained + g
        if changed then moved = true end
        for j = 1, 4 do
            local r, c
            if dir == "left" then r, c = i, j
            elseif dir == "right" then r, c = i, 5 - j
            elseif dir == "up" then r, c = j, i
            else r, c = 5 - j, i end  -- down
            grid[r][c] = new_line[j]
        end
    end
    if moved then
        score = score + gained
        if score > best then best = score end
        spawn_tile()
        if not has_moves() then game_over = true end
    end
end

local function cell_pos(r, c)
    local x = BOARD_X + GAP + (c - 1) * (CELL + GAP)
    local y = BOARD_Y + GAP + (r - 1) * (CELL + GAP)
    return math.floor(x), math.floor(y)
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- Long press to exit (any state)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end

    if t.just_pressed then
        swipe_start_x = t.x
        swipe_start_y = t.y
    elseif t.just_released and swipe_start_x then
        local dx = t.x - swipe_start_x
        local dy = t.y - swipe_start_y
        local abs_dx = math.abs(dx)
        local abs_dy = math.abs(dy)
        if game_over then
            reset_game()
        elseif abs_dx > 30 or abs_dy > 30 then
            if abs_dx > abs_dy then
                move(dx > 0 and "right" or "left")
            else
                move(dy > 0 and "down" or "up")
            end
        end
        swipe_start_x = nil
        swipe_start_y = nil
    end
end

local function draw()
    display.begin_frame({clear = true, color = BG})

    -- Title
    display.draw_text(40, 22, "2048", {font_size = 44, color = TEXT_DARK})

    -- Score & Best boxes
    local box_w = 130
    local box_h = 56
    local bx = W - box_w - 10
    local sx = bx - box_w - 10
    display.fill_round_rect(sx, 18, box_w, box_h, 6, BOARD_BG)
    display.draw_text_aligned(sx, 24, box_w, 18, "SCORE",
        {font_size = 12, color = "#eee4da"})
    display.draw_text_aligned(sx, 42, box_w, 28, tostring(score),
        {font_size = 24, color = TEXT_LIGHT})
    display.fill_round_rect(bx, 18, box_w, box_h, 6, BOARD_BG)
    display.draw_text_aligned(bx, 24, box_w, 18, "BEST",
        {font_size = 12, color = "#eee4da"})
    display.draw_text_aligned(bx, 42, box_w, 28, tostring(best),
        {font_size = 24, color = TEXT_LIGHT})

    -- Win indicator (persistent, non-blocking)
    if won then
        display.draw_text(40, 72, ">> 2048 reached! Keep going",
            {font_size = 14, color = "#edc22e"})
    end

    -- Board background
    display.fill_round_rect(BOARD_X, BOARD_Y, BOARD_SIZE, BOARD_SIZE, 8, BOARD_BG)

    -- Cells
    for r = 1, 4 do
        for c = 1, 4 do
            local x, y = cell_pos(r, c)
            local v = grid[r][c]
            if v == 0 then
                display.fill_round_rect(x, y, CELL, CELL, 6, EMPTY_CELL)
            else
                local col = TILE_COLORS[v] or TILE_BIG
                display.fill_round_rect(x, y, CELL, CELL, 6, col.bg)
                display.draw_text_aligned(x, y, CELL, CELL, tostring(v),
                    {font_size = font_for(v), color = col.fg})
            end
        end
    end

    -- Game over panel or hint
    if game_over then
        local pw, ph = 440, 200
        local px = (W - pw) // 2
        local py = (H - ph) // 2
        display.fill_round_rect(px, py, pw, ph, 12, PANEL_BG)
        display.draw_text_aligned(0, py + 30, W, 50, "GAME OVER",
            {font_size = 44, color = TEXT_LIGHT})
        display.draw_text_aligned(0, py + 90, W, 34,
            string.format("Score: %d   Best: %d", score, best),
            {font_size = 24, color = "#eee4da"})
        display.draw_text_aligned(0, py + 150, W, 26,
            "Tap to restart  |  Hold to exit",
            {font_size = 16, color = "#cdc1b4"})
    else
        display.draw_text_aligned(0, H - 28, W, 22,
            "Swipe to move  |  Long press to exit",
            {font_size = 15, color = GRAY})
    end

    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[2048] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    BOARD_SIZE = 4 * CELL + 5 * GAP  -- 600
    BOARD_X = (W - BOARD_SIZE) // 2
    BOARD_Y = math.max(90, (H - BOARD_SIZE) // 2)

    reset_game()
end

local function run()
    init()
    print("[2048] Running... swipe to move, long press to exit")

    while RUNNING do
        handle_touch()
        draw()
        delay.delay_ms(16)
    end

    display.clear(BG)
    display.draw_text_aligned(0, 0, W, H, "Bye!",
        {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[2048] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[2048] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
