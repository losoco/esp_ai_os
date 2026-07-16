-- slide_puzzle.lua - Classic 15-puzzle (digital Klotski) slide puzzle
-- Tap a tile adjacent to the empty slot to slide it. Long press to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Colors
local DARK = "#202020"
local WHITE = "white"
local GRAY = "#9aa0a6"
local BOARD_BG = "#0f0f17"
local EMPTY_CELL = "#1a1a2e"
local TILE_DONE = "#22c55e"   -- tile in correct position
local TILE_MOVE = "#3b82f6"   -- tile not yet in position
local PANEL_BG = "#2a2a3e"

-- Layout
local CELL = 140
local GAP = 4
local BOARD_SIZE, BOARD_X, BOARD_Y

-- Game state
local grid              -- grid[r][c], r/c = 1..4, 0 = empty, 1..15 = tiles
local empty_r, empty_c  -- current empty slot position
local moves
local solved
local elapsed_ms        -- accumulated play time (ms), frozen once solved
local touch_handle

local FRAME_MS = 16

-- Neighbors: up, down, left, right as (dr, dc)
local NEIGHBORS = {
    {-1, 0}, {1, 0}, {0, -1}, {0, 1},
}

local function cell_pos(r, c)
    -- No outer padding: board background spans exactly cells + internal gaps.
    local x = BOARD_X + (c - 1) * (CELL + GAP)
    local y = BOARD_Y + (r - 1) * (CELL + GAP)
    return math.floor(x), math.floor(y)
end

-- Is tile at (r,c) in its solved position?
-- Tile value v belongs at row = (v-1)//4 + 1, col = (v-1)%4 + 1
local function in_place(r, c, v)
    if v == 0 then return false end
    local tr = (v - 1) // 4 + 1
    local tc = (v - 1) % 4 + 1
    return r == tr and c == tc
end

local function is_solved()
    for r = 1, 4 do
        for c = 1, 4 do
            local v = grid[r][c]
            if r == 4 and c == 4 then
                if v ~= 0 then return false end
            else
                if v ~= (r - 1) * 4 + c then return false end
            end
        end
    end
    return true
end

-- Swap empty slot with tile at (r, c). Caller ensures adjacency.
local function swap_with_empty(r, c)
    grid[empty_r][empty_c] = grid[r][c]
    grid[r][c] = 0
    empty_r, empty_c = r, c
end

-- Shuffle by moving the empty slot randomly N times from solved state.
-- Guarantees solvability (only reachable states are produced).
local function shuffle()
    -- start from solved: 1..15 then empty at (4,4)
    for r = 1, 4 do
        grid[r] = {}
        for c = 1, 4 do
            if r == 4 and c == 4 then
                grid[r][c] = 0
            else
                grid[r][c] = (r - 1) * 4 + c
            end
        end
    end
    empty_r, empty_c = 4, 4

    local last = nil  -- avoid immediately undoing the previous move
    for _ = 1, 200 do
        local opts = {}
        for _, d in ipairs(NEIGHBORS) do
            local nr, nc = empty_r + d[1], empty_c + d[2]
            if nr >= 1 and nr <= 4 and nc >= 1 and nc <= 4 then
                if not last or (nr ~= last.r or nc ~= last.c) then
                    opts[#opts + 1] = {r = nr, c = nc}
                end
            end
        end
        if #opts == 0 then break end
        local pick = opts[math.random(1, #opts)]
        local prev_r, prev_c = empty_r, empty_c
        swap_with_empty(pick.r, pick.c)
        last = {r = prev_r, c = prev_c}  -- don't move back here next step
    end
end

local function reset_game()
    grid = {}
    shuffle()
    moves = 0
    solved = false
    elapsed_ms = 0
end

-- Try to move the tile at (r, c) into the empty slot. Returns true if moved.
local function try_move(r, c)
    if solved then return false end
    if r < 1 or r > 4 or c < 1 or c > 4 then return false end
    if grid[r][c] == 0 then return false end
    -- must be adjacent to empty
    local dr = math.abs(r - empty_r)
    local dc = math.abs(c - empty_c)
    if dr + dc ~= 1 then return false end
    swap_with_empty(r, c)
    moves = moves + 1
    if is_solved() then
        solved = true
        -- elapsed_ms is frozen at its current accumulated value
    end
    return true
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- Long press to exit (only meaningful while pressed; just_released held_ms == 0)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end

    if not t.just_pressed then return end

    -- Tap to restart when solved
    if solved then
        reset_game()
        return
    end

    -- Map tap to a board cell
    local x, y = t.x, t.y
    if x < BOARD_X or y < BOARD_Y then return end
    local lx = x - BOARD_X
    local ly = y - BOARD_Y
    local total = 4 * CELL + 3 * GAP
    if lx > total or ly > total then return end
    local c = (lx // (CELL + GAP)) + 1
    local r = (ly // (CELL + GAP)) + 1
    if r < 1 or r > 4 or c < 1 or c > 4 then return end
    -- reject taps inside the gap gutters
    local in_x = lx - (c - 1) * (CELL + GAP)
    local in_y = ly - (r - 1) * (CELL + GAP)
    if in_x > CELL or in_y > CELL then return end
    try_move(r, c)
end

local function format_time(ms)
    local s = ms // 1000
    local m = s // 60
    s = s % 60
    return string.format("%d:%02d", m, s)
end

-- Advance play-time accumulator while the puzzle is still in progress.
local function update(dt_ms)
    if not solved then
        elapsed_ms = elapsed_ms + dt_ms
    end
end

local function draw()
    display.begin_frame({clear = true, color = DARK})

    -- Title + moves
    display.draw_text(30, 22, "SLIDE PUZZLE", {font_size = 32, color = WHITE})
    display.draw_text_aligned(W - 170, 22, 140, 36,
        string.format("Moves: %d", moves),
        {font_size = 20, color = GRAY})

    -- Board background
    display.fill_round_rect(BOARD_X, BOARD_Y, BOARD_SIZE, BOARD_SIZE, 8, BOARD_BG)

    -- Cells
    for r = 1, 4 do
        for c = 1, 4 do
            local x, y = cell_pos(r, c)
            local v = grid[r][c]
            if v == 0 then
                display.fill_round_rect(x, y, CELL, CELL, 8, EMPTY_CELL)
            else
                local col = in_place(r, c, v) and TILE_DONE or TILE_MOVE
                display.fill_round_rect(x, y, CELL, CELL, 8, col)
                display.draw_text_aligned(x, y, CELL, CELL, tostring(v),
                    {font_size = 52, color = WHITE})
            end
        end
    end

    -- Solved panel or hint
    if solved then
        local pw, ph = 460, 220
        local px = (W - pw) // 2
        local py = (H - ph) // 2
        display.fill_round_rect(px, py, pw, ph, 12, PANEL_BG)
        display.draw_text_aligned(0, py + 30, W, 54, "Solved!",
            {font_size = 48, color = TILE_DONE})
        display.draw_text_aligned(0, py + 100, W, 34,
            string.format("Moves: %d", moves),
            {font_size = 26, color = WHITE})
        display.draw_text_aligned(0, py + 140, W, 30,
            string.format("Time: %s", format_time(elapsed_ms)),
            {font_size = 24, color = WHITE})
        display.draw_text_aligned(0, py + 180, W, 24,
            "Tap to play again  |  Hold to exit",
            {font_size = 16, color = GRAY})
    else
        display.draw_text_aligned(0, H - 28, W, 22,
            "Tap adjacent tile to slide, long press to exit",
            {font_size = 15, color = GRAY})
    end

    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[slide] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    BOARD_SIZE = 4 * CELL + 3 * GAP   -- 572
    BOARD_X = (W - BOARD_SIZE) // 2
    BOARD_Y = 90

    reset_game()
end

local function run()
    init()
    print("[slide] Running... tap adjacent tile to slide")

    while RUNNING do
        handle_touch()
        update(FRAME_MS)
        draw()
        delay.delay_ms(FRAME_MS)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = GRAY})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[slide] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[slide] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
