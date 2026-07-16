-- tetris.lua - Classic Tetris with touch-zone controls
--
-- Touch zones (720x720 screen):
--   Top half            (y <  H*0.5)             : hard drop
--   Bottom-left corner  (x <  W/3, y > H*0.6)    : move left
--   Bottom-right corner (x >  W*2/3, y > H*0.6)  : move right
--   Bottom-center       (W/3..W*2/3, y > H*0.6)  : rotate
--   Hold anywhere > 1500ms                       : exit
-- Game Over: tap to restart, hold to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true

-- Colors
local DARK    = "#0e0e18"
local GRID_BG = "#16161f"
local GRID_LN = "#26263a"
local BORDER  = "#3a3a55"
local PANEL   = "#1a1a26"
local TEXT    = "#e0e0f0"
local HUD     = "#a0a0c0"
local GRAY    = "#606080"
local GHOST   = "#3a3a55"
local ACCENT  = "#f5f5f5"

-- Tetromino definitions (square matrices; rotate = transpose + reverse rows)
local SHAPES = {
    { name = "I", color = "#06b6d4", matrix = {
        { 0, 0, 0, 0 },
        { 1, 1, 1, 1 },
        { 0, 0, 0, 0 },
        { 0, 0, 0, 0 },
    } },
    { name = "O", color = "#facc15", matrix = {
        { 1, 1 },
        { 1, 1 },
    } },
    { name = "T", color = "#a855f7", matrix = {
        { 0, 1, 0 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    } },
    { name = "S", color = "#22c55e", matrix = {
        { 0, 1, 1 },
        { 1, 1, 0 },
        { 0, 0, 0 },
    } },
    { name = "Z", color = "#ef4444", matrix = {
        { 1, 1, 0 },
        { 0, 1, 1 },
        { 0, 0, 0 },
    } },
    { name = "J", color = "#3b82f6", matrix = {
        { 1, 0, 0 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    } },
    { name = "L", color = "#f59e0b", matrix = {
        { 0, 0, 1 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    } },
}

-- Layout
local COLS = 10
local ROWS = 20
local CELL = 28
local FIELD_W = COLS * CELL       -- 280
local FIELD_H = ROWS * CELL        -- 560
local FIELD_X = 40
local FIELD_Y = 80
local FIELD_EX = FIELD_X + FIELD_W
local FIELD_EY = FIELD_Y + FIELD_H

-- Right info panel
local PANEL_X = 360
local PANEL_W = 320
local NEXT_BOX = 120
local NEXT_X = PANEL_X + 20
local NEXT_Y = 90

-- Touch zones (computed once as integers)
local ZONE_TOP_Y    = 360      -- y < ZONE_TOP_Y        -> hard drop
local ZONE_BOT_Y    = 432      -- y > ZONE_BOT_Y        -> bottom zone active
local ZONE_LEFT_X   = 240      -- x < ZONE_LEFT_X       -> move left
local ZONE_RIGHT_X  = 480      -- x > ZONE_RIGHT_X      -> move right
                            -- in between             -> rotate

-- Scoring
local SCORE_TABLE = { 0, 100, 300, 500, 800 }
local FRAME_MS = 16  -- approximate frame time used for drop accumulation

-- Game state
local grid               -- grid[r][c] = false | color string
local cur                -- current piece { name, color, matrix, row, col }
local nxt                -- next piece shape table (with fresh matrix)
local bag                -- 7-bag randomizer queue
local bag_idx
local score
local level
local lines
local drop_acc           -- drop timer accumulator (ms)
local drop_int           -- current drop interval (ms)
local state              -- "playing" | "game_over"
local touch_handle
local flash_t            -- line-clear flash countdown (frames)

---------------------------------------------------------------------------
-- 7-bag randomizer (avoids long runs of the same piece)
---------------------------------------------------------------------------
local function refill_bag()
    bag = {}
    for i = 1, 7 do bag[i] = i end
    for i = 7, 2, -1 do
        local j = math.random(1, i)
        bag[i], bag[j] = bag[j], bag[i]
    end
    bag_idx = 1
end

local function copy_matrix(m)
    local c = {}
    for i = 1, #m do
        c[i] = {}
        for j = 1, #m[i] do c[i][j] = m[i][j] end
    end
    return c
end

local function next_shape()
    if not bag or bag_idx > 7 then refill_bag() end
    local s = SHAPES[bag[bag_idx]]
    bag_idx = bag_idx + 1
    return { name = s.name, color = s.color, matrix = copy_matrix(s.matrix) }
end

local function spawn_piece(shape)
    shape = shape or next_shape()
    local n = #shape.matrix
    shape.col = math.floor((COLS - n) / 2) + 1
    shape.row = 0  -- start above the visible top; rows <= 0 are non-colliding
    return shape
end

-- Rotate matrix clockwise: new[i][j] = old[n-j+1][i]
local function rotate_matrix(m)
    local n = #m
    local r = {}
    for i = 1, n do
        r[i] = {}
        for j = 1, n do
            r[i][j] = m[n - j + 1][i]
        end
    end
    return r
end

---------------------------------------------------------------------------
-- Collision / lock / line clearing
---------------------------------------------------------------------------
local function collides(piece, dr, dc, matrix)
    matrix = matrix or piece.matrix
    local r0 = piece.row + dr
    local c0 = piece.col + dc
    for i = 1, #matrix do
        local row = matrix[i]
        for j = 1, #row do
            if row[j] ~= 0 then
                local gr = r0 + i - 1
                local gc = c0 + j - 1
                if gc < 1 or gc > COLS then return true end
                if gr > ROWS then return true end
                if gr >= 1 and grid[gr][gc] then return true end
            end
        end
    end
    return false
end

local function lock_piece(piece)
    for i = 1, #piece.matrix do
        local row = piece.matrix[i]
        for j = 1, #row do
            if row[j] ~= 0 then
                local gr = piece.row + i - 1
                local gc = piece.col + j - 1
                if gr >= 1 and gr <= ROWS and gc >= 1 and gc <= COLS then
                    grid[gr][gc] = piece.color
                end
            end
        end
    end
end

local function clear_lines()
    local cleared_rows = {}
    local r = ROWS
    while r >= 1 do
        local full = true
        for c = 1, COLS do
            if not grid[r][c] then full = false break end
        end
        if full then
            cleared_rows[#cleared_rows + 1] = r
            table.remove(grid, r)
            local newrow = {}
            for c = 1, COLS do newrow[c] = false end
            table.insert(grid, 1, newrow)
            -- don't decrement r; row that was at r+1 is now at r
        else
            r = r - 1
        end
    end
    return cleared_rows
end

local function drop_interval_for_level(lv)
    return math.max(80, 800 - (lv - 1) * 70)
end

local function ghost_row_offset(piece)
    local dr = 0
    while not collides(piece, dr + 1, 0) do
        dr = dr + 1
    end
    return dr
end

local function try_move(dc)
    if not collides(cur, 0, dc) then
        cur.col = cur.col + dc
        return true
    end
    return false
end

local function try_rotate()
    local m = rotate_matrix(cur.matrix)
    -- simple wall kicks: 0, -1, +1, -2, +2 column offset
    local kicks = { 0, -1, 1, -2, 2 }
    for _, dc in ipairs(kicks) do
        if not collides(cur, 0, dc, m) then
            cur.matrix = m
            cur.col = cur.col + dc
            return true
        end
    end
    return false
end

local function hard_drop()
    local dr = ghost_row_offset(cur)
    cur.row = cur.row + dr
    score = score + dr * 2  -- 2 points per cell hard-dropped
end

local function lock_and_spawn()
    lock_piece(cur)
    local cleared = clear_lines()
    if #cleared > 0 then
        score = score + SCORE_TABLE[#cleared + 1]
        lines = lines + #cleared
        local new_level = math.floor(lines / 10) + 1
        if new_level > level then
            level = new_level
            drop_int = drop_interval_for_level(level)
        end
        flash_t = 6  -- brief flash frames
    end
    cur = spawn_piece(nxt)
    nxt = next_shape()
    if collides(cur, 0, 0) then
        state = "game_over"
    end
end

---------------------------------------------------------------------------
-- Game state init / reset
---------------------------------------------------------------------------
local function init_grid()
    grid = {}
    for r = 1, ROWS do
        grid[r] = {}
        for c = 1, COLS do grid[r][c] = false end
    end
end

local function reset_game()
    init_grid()
    bag = nil
    refill_bag()
    cur = spawn_piece(next_shape())
    nxt = next_shape()
    score = 0
    level = 1
    lines = 0
    drop_acc = 0
    drop_int = drop_interval_for_level(1)
    state = "playing"
    flash_t = 0
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[tetris] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    reset_game()
end

---------------------------------------------------------------------------
-- Touch handling
---------------------------------------------------------------------------
local function handle_touch_playing(t)
    if t.just_released then
        local x, y = math.floor(t.x), math.floor(t.y)
        if y > ZONE_BOT_Y then
            if x < ZONE_LEFT_X then
                try_move(-1)
            elseif x > ZONE_RIGHT_X then
                try_move(1)
            else
                try_rotate()
            end
        elseif y < ZONE_TOP_Y then
            hard_drop()
            lock_and_spawn()
        end
    end
end

local function handle_touch_game_over(t)
    -- short tap to restart (long-press exit is handled centrally in handle_touch)
    if t.just_released then
        reset_game()
    end
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)

    -- long-press anywhere exits, regardless of game state.
    -- held_ms is only meaningful while pressed (it is 0 on release).
    if t.pressed and (t.held_ms or 0) > 1500 then
        RUNNING = false
        return
    end

    if state == "playing" then
        handle_touch_playing(t)
    elseif state == "game_over" then
        handle_touch_game_over(t)
    end
end

---------------------------------------------------------------------------
-- Update logic
---------------------------------------------------------------------------
local function update()
    if state ~= "playing" then return end
    if flash_t > 0 then
        flash_t = flash_t - 1
        return
    end
    drop_acc = drop_acc + FRAME_MS
    while drop_acc >= drop_int do
        drop_acc = drop_acc - drop_int
        if not collides(cur, 1, 0) then
            cur.row = cur.row + 1
        else
            lock_and_spawn()
            if state ~= "playing" then return end
        end
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function cell_to_xy(gr, gc)
    return FIELD_X + (gc - 1) * CELL, FIELD_Y + (gr - 1) * CELL
end

-- Draws a filled cell with a 1px dark separator.
local function draw_cell(x, y, color)
    display.fill_rect(x, y, CELL, CELL, color)
    display.draw_rect(x, y, CELL, CELL, "#000000")
end

local function draw_field()
    -- background
    display.fill_rect(FIELD_X - 4, FIELD_Y - 4, FIELD_W + 8, FIELD_H + 8, BORDER)
    display.fill_rect(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, GRID_BG)

    -- grid lines
    for c = 1, COLS - 1 do
        local x = FIELD_X + c * CELL
        display.draw_line(x, FIELD_Y, x, FIELD_EY, GRID_LN)
    end
    for r = 1, ROWS - 1 do
        local y = FIELD_Y + r * CELL
        display.draw_line(FIELD_X, y, FIELD_EX, y, GRID_LN)
    end

    -- locked cells
    for r = 1, ROWS do
        for c = 1, COLS do
            if grid[r][c] then
                local x, y = cell_to_xy(r, c)
                draw_cell(x, y, grid[r][c])
            end
        end
    end

    -- flash overlay on line clears (already removed; just brighten field briefly)
    if flash_t > 0 then
        display.fill_rect(FIELD_X, FIELD_Y, FIELD_W, FIELD_H, "#ffffff")
    end

    -- ghost piece
    if state == "playing" and cur then
        local dr = ghost_row_offset(cur)
        local m = cur.matrix
        for i = 1, #m do
            for j = 1, #m[i] do
                if m[i][j] ~= 0 then
                    local gr = cur.row + dr + i - 1
                    local gc = cur.col + j - 1
                    if gr >= 1 and gr <= ROWS then
                        local x, y = cell_to_xy(gr, gc)
                        display.draw_rect(x + 1, y + 1, CELL - 2, CELL - 2, GHOST)
                    end
                end
            end
        end
    end

    -- current piece
    if cur then
        local m = cur.matrix
        for i = 1, #m do
            for j = 1, #m[i] do
                if m[i][j] ~= 0 then
                    local gr = cur.row + i - 1
                    local gc = cur.col + j - 1
                    if gr >= 1 and gr <= ROWS then
                        local x, y = cell_to_xy(gr, gc)
                        draw_cell(x, y, cur.color)
                    end
                end
            end
        end
    end
end

local function draw_next_box()
    -- "NEXT" label and preview box
    local box_x, box_y, box_w, box_h = NEXT_X, NEXT_Y, NEXT_BOX, NEXT_BOX
    display.fill_rect(box_x - 2, box_y - 2, box_w + 4, box_h + 4, BORDER)
    display.fill_rect(box_x, box_y, box_w, box_h, GRID_BG)

    if nxt then
        -- center the piece in the preview box
        local m = nxt.matrix
        local n = #m
        -- find bounding box of filled cells
        local min_i, max_i, min_j, max_j = n, 1, n, 1
        for i = 1, n do
            for j = 1, n do
                if m[i][j] ~= 0 then
                    if i < min_i then min_i = i end
                    if i > max_i then max_i = i end
                    if j < min_j then min_j = j end
                    if j > max_j then max_j = j end
                end
            end
        end
        local pw = (max_j - min_j + 1) * CELL
        local ph = (max_i - min_i + 1) * CELL
        local off_x = box_x + (box_w - pw) // 2 - (min_j - 1) * CELL
        local off_y = box_y + (box_h - ph) // 2 - (min_i - 1) * CELL
        for i = 1, n do
            for j = 1, n do
                if m[i][j] ~= 0 then
                    local x = off_x + (j - 1) * CELL
                    local y = off_y + (i - 1) * CELL
                    draw_cell(x, y, nxt.color)
                end
            end
        end
    end

    -- label above
    display.draw_text_aligned(box_x, box_y - 26, box_w, 20, "NEXT",
        { font_size = 18, color = HUD, align = "center", valign = "middle" })
end

local function draw_panel()
    -- panel background
    display.fill_rect(PANEL_X, FIELD_Y - 4, PANEL_W, FIELD_H + 8, BORDER)
    display.fill_rect(PANEL_X + 2, FIELD_Y - 2, PANEL_W - 4, FIELD_H + 4, PANEL)

    draw_next_box()

    -- stats
    local stat_x = PANEL_X + 20
    local stat_w = PANEL_W - 40
    local y = NEXT_Y + NEXT_BOX + 30

    display.draw_text(stat_x, y, "SCORE", { font_size = 16, color = HUD })
    display.draw_text_aligned(stat_x, y + 18, stat_w, 28,
        string.format("%d", score), { font_size = 26, color = TEXT, align = "left", valign = "middle" })

    y = y + 60
    display.draw_text(stat_x, y, "LEVEL", { font_size = 16, color = HUD })
    display.draw_text_aligned(stat_x, y + 18, stat_w, 28,
        string.format("%d", level), { font_size = 26, color = TEXT, align = "left", valign = "middle" })

    y = y + 60
    display.draw_text(stat_x, y, "LINES", { font_size = 16, color = HUD })
    display.draw_text_aligned(stat_x, y + 18, stat_w, 28,
        string.format("%d", lines), { font_size = 26, color = TEXT, align = "left", valign = "middle" })

    -- controls hint
    y = y + 70
    display.draw_text(stat_x, y, "CONTROLS", { font_size = 16, color = HUD })
    y = y + 22
    local hints = {
        "Top tap    : Hard drop",
        "Bottom-L   : Move left",
        "Bottom-C   : Rotate",
        "Bottom-R   : Move right",
        "Hold 1.5s  : Exit",
    }
    for _, h in ipairs(hints) do
        display.draw_text(stat_x, y, h, { font_size = 14, color = GRAY })
        y = y + 18
    end
end

local function draw_touch_zones_hint()
    -- Faint dividers and small labels at the bottom for left/rotate/right zones.
    -- The field is drawn on top of these lines, so they only show in the
    -- areas below the field (y > FIELD_EY) and outside the panel.
    local hint_color = "#2a2a3a"
    local label_y = H - 30
    local label_h = 20

    -- horizontal divider at ZONE_BOT_Y (visible only outside the field/panel)
    display.draw_line(0, ZONE_BOT_Y, W, ZONE_BOT_Y, hint_color)
    -- vertical dividers between the three bottom zones
    display.draw_line(ZONE_LEFT_X, ZONE_BOT_Y, ZONE_LEFT_X, H, hint_color)
    display.draw_line(ZONE_RIGHT_X, ZONE_BOT_Y, ZONE_RIGHT_X, H, hint_color)

    -- "<"  in bottom-left zone, only drawn in the slice below the field
    display.draw_text_aligned(0, label_y, ZONE_LEFT_X, label_h, "<",
        { font_size = 28, color = hint_color, align = "center", valign = "middle" })
    -- "ROT" in bottom-center zone
    display.draw_text_aligned(ZONE_LEFT_X, label_y,
        ZONE_RIGHT_X - ZONE_LEFT_X, label_h, "ROT",
        { font_size = 16, color = hint_color, align = "center", valign = "middle" })
    -- ">" in bottom-right zone
    display.draw_text_aligned(ZONE_RIGHT_X, label_y,
        W - ZONE_RIGHT_X, label_h, ">",
        { font_size = 28, color = hint_color, align = "center", valign = "middle" })
end

local function draw()
    display.begin_frame({ clear = true, color = DARK })

    -- title
    display.draw_text_aligned(0, 16, W, 40, "TETRIS",
        { font_size = 32, color = ACCENT, align = "center", valign = "middle" })

    draw_touch_zones_hint()
    draw_field()
    draw_panel()

    if state == "game_over" then
        display.fill_rect(0, H // 2 - 80, W, 160, "#000000")
        display.draw_text_aligned(0, H // 2 - 60, W, 50, "GAME OVER",
            { font_size = 44, color = "#ef4444", align = "center", valign = "middle" })
        display.draw_text_aligned(0, H // 2 + 4, W, 28,
            string.format("Score %d  Lv %d  Lines %d", score, level, lines),
            { font_size = 20, color = HUD, align = "center", valign = "middle" })
        display.draw_text_aligned(0, H // 2 + 40, W, 24,
            "Tap to restart  |  Hold to exit",
            { font_size = 16, color = GRAY, align = "center", valign = "middle" })
    end

    display.present()
    display.end_frame()
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function run()
    init()
    print("[tetris] Running... top=drop, bottom L/C/R = move/rotate/move, hold to exit")

    while RUNNING do
        handle_touch()
        update()
        draw()
        delay.delay_ms(FRAME_MS)
    end

    display.clear(DARK)
    display.draw_text_aligned(0, 0, W, H, "Bye!",
        { font_size = 48, color = GRAY, align = "center", valign = "middle" })
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[tetris] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[tetris] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
