-- minesweeper.lua - Classic minesweeper with tap-to-reveal and hold-to-flag controls
-- Short tap (<400ms) reveals a cell, hold 500-1500ms toggles a flag, long press (>1500ms) exits.
-- First click is always safe (mines are placed after it, excluding a 3x3 safe zone).

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Grid config
local GRID_SIZE = 10        -- 10x10 cells
local MINES = 15            -- total mines
local CELL = 60             -- cell side in pixels
local GRID_X, GRID_Y = 60, 80
local GRID_PIX = GRID_SIZE * CELL  -- 600

-- Palette
local BG = "#202020"
local WHITE = "white"
local GRAY = "#888888"
local HIDDEN = "#5a5a5a"
local HIDDEN_BORDER = "#3a3a3a"
local REVEALED = "#c0c0c0"
local REVEALED_BORDER = "#909090"
local FLAG_BG = "#e8c547"
local MINE_BG = "#cc2222"
local PANEL_BG = "#1a1a1a"

-- Classic number colors
local NUM_COLORS = {
    [1] = "#0000ff", [2] = "#008000", [3] = "#ff0000", [4] = "#000080",
    [5] = "#800000", [6] = "#008080", [7] = "#000000", [8] = "#808080",
}

-- Game state
local grid            -- grid[r][c] = {is_mine, state, adj}; state in hidden/revealed/flagged
local first_click     -- true until first reveal (mines placed after first click)
local game_over
local won
local flags_placed
local touch_handle

local function cell_pos(r, c)
    local x = GRID_X + (c - 1) * CELL
    local y = GRID_Y + (r - 1) * CELL
    return math.floor(x), math.floor(y)
end

local function pixel_to_cell(px, py)
    if px < GRID_X or px >= GRID_X + GRID_PIX then return nil end
    if py < GRID_Y or py >= GRID_Y + GRID_PIX then return nil end
    local c = math.floor((px - GRID_X) / CELL) + 1
    local r = math.floor((py - GRID_Y) / CELL) + 1
    if r < 1 or r > GRID_SIZE or c < 1 or c > GRID_SIZE then return nil end
    return r, c
end

local function reset_game()
    grid = {}
    for r = 1, GRID_SIZE do
        grid[r] = {}
        for c = 1, GRID_SIZE do
            grid[r][c] = {is_mine = false, state = "hidden", adj = 0}
        end
    end
    first_click = true
    game_over = false
    won = false
    flags_placed = 0
end

-- Place mines excluding (safe_r, safe_c) and its 8 neighbors, then compute adjacency.
local function place_mines(safe_r, safe_c)
    local placed = 0
    while placed < MINES do
        local r = math.random(1, GRID_SIZE)
        local c = math.random(1, GRID_SIZE)
        if math.abs(r - safe_r) <= 1 and math.abs(c - safe_c) <= 1 then
            -- inside safe 3x3 zone, skip
        elseif grid[r][c].is_mine then
            -- already mined, skip
        else
            grid[r][c].is_mine = true
            placed = placed + 1
        end
    end
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            if not grid[r][c].is_mine then
                local count = 0
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        if dr ~= 0 or dc ~= 0 then
                            local nr, nc = r + dr, c + dc
                            if nr >= 1 and nr <= GRID_SIZE and nc >= 1 and nc <= GRID_SIZE then
                                if grid[nr][nc].is_mine then count = count + 1 end
                            end
                        end
                    end
                end
                grid[r][c].adj = count
            end
        end
    end
end

-- Iterative flood-fill reveal (stack-based to avoid deep Lua recursion).
local function reveal_flood(start_r, start_c)
    local stack = {{start_r, start_c}}
    while #stack > 0 do
        local top = table.remove(stack)
        local r, c = top[1], top[2]
        local cell = grid[r][c]
        if cell.state == "hidden" and not cell.is_mine then
            cell.state = "revealed"
            if cell.adj == 0 then
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        if dr ~= 0 or dc ~= 0 then
                            local nr, nc = r + dr, c + dc
                            if nr >= 1 and nr <= GRID_SIZE and nc >= 1 and nc <= GRID_SIZE then
                                local ncell = grid[nr][nc]
                                if ncell.state == "hidden" and not ncell.is_mine then
                                    stack[#stack + 1] = {nr, nc}
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function check_win()
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            local cell = grid[r][c]
            if not cell.is_mine and cell.state ~= "revealed" then
                return false
            end
        end
    end
    won = true
    return true
end

local function reveal_action(r, c)
    local cell = grid[r][c]
    if cell.state ~= "hidden" then return end  -- can't reveal flagged or already revealed
    if first_click then
        place_mines(r, c)
        first_click = false
    end
    if cell.is_mine then
        cell.state = "revealed"
        game_over = true
        for mr = 1, GRID_SIZE do
            for mc = 1, GRID_SIZE do
                if grid[mr][mc].is_mine then
                    grid[mr][mc].state = "revealed"
                end
            end
        end
    else
        reveal_flood(r, c)
        check_win()
    end
end

local function toggle_flag(r, c)
    local cell = grid[r][c]
    if cell.state == "hidden" then
        cell.state = "flagged"
        flags_placed = flags_placed + 1
    elseif cell.state == "flagged" then
        cell.state = "hidden"
        flags_placed = flags_placed - 1
    end
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- Long press to exit (any state, fires while held)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end

    if not t.just_released then return end

    -- Game over/win: any tap restarts
    if game_over or won then
        reset_game()
        return
    end

    local r, c = pixel_to_cell(t.x, t.y)
    if not r then return end

    if t.held_ms < 400 then
        reveal_action(r, c)
    elseif t.held_ms >= 500 and t.held_ms <= 1500 then
        toggle_flag(r, c)
    end
    -- 400-500ms: dead zone, no action (avoid misfires)
end

local function draw()
    display.begin_frame({clear = true, color = BG})

    -- Header
    display.draw_text(20, 18, "MINESWEEPER", {font_size = 28, color = WHITE})
    local mines_left = MINES - flags_placed
    display.draw_text_aligned(W - 180, 18, 160, 30,
        string.format("Mines: %d", mines_left),
        {font_size = 22, color = "#ff5555"})

    -- Status (centered across full width)
    local status, status_col
    if won then status, status_col = "YOU WIN!", "#88ff88"
    elseif game_over then status, status_col = "BOOM!", "#ff5555"
    else status, status_col = "Playing", "#88ccff" end
    display.draw_text_aligned(0, 18, W, 30, status,
        {font_size = 22, color = status_col})

    -- Grid cells
    for r = 1, GRID_SIZE do
        for c = 1, GRID_SIZE do
            local x, y = cell_pos(r, c)
            local cell = grid[r][c]
            if cell.state == "hidden" then
                display.fill_rect(x, y, CELL, CELL, HIDDEN)
                display.draw_rect(x, y, CELL, CELL, HIDDEN_BORDER)
            elseif cell.state == "flagged" then
                display.fill_rect(x, y, CELL, CELL, FLAG_BG)
                display.draw_rect(x, y, CELL, CELL, HIDDEN_BORDER)
                display.draw_text_aligned(x, y, CELL, CELL, "F",
                    {font_size = 34, color = "#202020"})
            elseif cell.state == "revealed" then
                if cell.is_mine then
                    display.fill_rect(x, y, CELL, CELL, MINE_BG)
                    display.draw_rect(x, y, CELL, CELL, "#660000")
                    display.draw_text_aligned(x, y, CELL, CELL, "*",
                        {font_size = 38, color = "white"})
                else
                    display.fill_rect(x, y, CELL, CELL, REVEALED)
                    display.draw_rect(x, y, CELL, CELL, REVEALED_BORDER)
                    if cell.adj > 0 then
                        display.draw_text_aligned(x, y, CELL, CELL, tostring(cell.adj),
                            {font_size = 32, color = NUM_COLORS[cell.adj]})
                    end
                end
            end
        end
    end

    -- End-game overlay panel
    if game_over or won then
        local pw, ph = 460, 200
        local px = (W - pw) // 2
        local py = (H - ph) // 2
        display.fill_round_rect(px, py, pw, ph, 12, PANEL_BG)
        display.draw_round_rect(px, py, pw, ph, 12, GRAY)
        local title = won and "YOU WIN!" or "GAME OVER"
        display.draw_text_aligned(0, py + 36, W, 50, title,
            {font_size = 44, color = won and "#88ff88" or "#ff5555"})
        display.draw_text_aligned(0, py + 108, W, 26,
            string.format("Mines: %d", MINES),
            {font_size = 22, color = "#cccccc"})
        display.draw_text_aligned(0, py + 150, W, 26,
            "Tap to restart  |  Hold to exit",
            {font_size = 16, color = GRAY})
    else
        display.draw_text_aligned(0, H - 28, W, 22,
            "Tap: reveal  |  Hold: flag  |  Long press: exit",
            {font_size = 14, color = GRAY})
    end

    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[minesweeper] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    GRID_X = (W - GRID_PIX) // 2  -- center horizontally
    reset_game()
end

local function run()
    init()
    print("[minesweeper] Running... tap to reveal, hold to flag, long press to exit")
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
    print("[minesweeper] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[minesweeper] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
