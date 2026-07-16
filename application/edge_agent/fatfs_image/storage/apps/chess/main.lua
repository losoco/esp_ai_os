-- chess.lua - Two-player touch chess for a 720x720 display
-- Tap a piece, then tap a highlighted destination. Long press to exit.

local display = require("display")
local board_manager = require("board_manager")
local delay = require("delay")
local math = math

local W, H = 720, 720
local RUNNING = true
local CELL = 80
local BOARD_SIZE = 640
local BOARD_X, BOARD_Y = 40, 76

local BG = "#18212b"
local STATUS_BG = "#243241"
local LIGHT_SQUARE = "#d8c7a5"
local DARK_SQUARE = "#769176"
local SELECTED = "#f4d35e"
local LEGAL = "#50c878"
local LAST_MOVE = "#8db7d8"
local CHECK = "#e55353"
local GRID = "#34495e"
local WHITE_PIECE = "#f5f1e8"
local WHITE_TEXT = "#18212b"
local BLACK_PIECE = "#273746"
local BLACK_TEXT = "#f5f1e8"
local TEXT = "#f5f5f5"
local MUTED = "#aeb9c4"
local END_PANEL = "#17202a"

local board
local turn
local selected_r, selected_c
local selected_moves
local last_move
local en_passant
local castle_rights
local game_over
local result
local in_check
local ply_count
local touch_handle

local function other(color)
    return color == "w" and "b" or "w"
end

local function inside(r, c)
    return r >= 1 and r <= 8 and c >= 1 and c <= 8
end

local function piece(color, kind)
    return {color = color, kind = kind}
end

local function copy_board(src)
    local dst = {}
    for r = 1, 8 do
        dst[r] = {}
        for c = 1, 8 do
            local p = src[r][c]
            if p then dst[r][c] = {color = p.color, kind = p.kind} end
        end
    end
    return dst
end

local function reset_game()
    board = {}
    for r = 1, 8 do board[r] = {} end
    local order = {"R", "N", "B", "Q", "K", "B", "N", "R"}
    for c = 1, 8 do
        board[1][c] = piece("b", order[c])
        board[2][c] = piece("b", "P")
        board[7][c] = piece("w", "P")
        board[8][c] = piece("w", order[c])
    end
    turn = "w"
    selected_r, selected_c = nil, nil
    selected_moves = {}
    last_move = nil
    en_passant = nil
    castle_rights = {wK = true, wQ = true, bK = true, bQ = true}
    game_over = false
    result = ""
    in_check = false
    ply_count = 0
end

local function find_king(b, color)
    for r = 1, 8 do
        for c = 1, 8 do
            local p = b[r][c]
            if p and p.color == color and p.kind == "K" then return r, c end
        end
    end
    return nil, nil
end

local function is_square_attacked(b, r, c, by_color)
    local pawn_dir = by_color == "w" and -1 or 1
    local pawn_row = r - pawn_dir
    for _, dc in ipairs({-1, 1}) do
        local pc = c - dc
        if inside(pawn_row, pc) then
            local p = b[pawn_row][pc]
            if p and p.color == by_color and p.kind == "P" then return true end
        end
    end

    local knight_steps = {
        {-2, -1}, {-2, 1}, {-1, -2}, {-1, 2},
        {1, -2}, {1, 2}, {2, -1}, {2, 1},
    }
    for _, d in ipairs(knight_steps) do
        local nr, nc = r + d[1], c + d[2]
        if inside(nr, nc) then
            local p = b[nr][nc]
            if p and p.color == by_color and p.kind == "N" then return true end
        end
    end

    for dr = -1, 1 do
        for dc = -1, 1 do
            if dr ~= 0 or dc ~= 0 then
                local nr, nc = r + dr, c + dc
                if inside(nr, nc) then
                    local p = b[nr][nc]
                    if p and p.color == by_color and p.kind == "K" then return true end
                end
            end
        end
    end

    local directions = {
        {-1, 0}, {1, 0}, {0, -1}, {0, 1},
        {-1, -1}, {-1, 1}, {1, -1}, {1, 1},
    }
    for i, d in ipairs(directions) do
        local nr, nc = r + d[1], c + d[2]
        while inside(nr, nc) do
            local p = b[nr][nc]
            if p then
                if p.color == by_color then
                    local straight = i <= 4
                    if p.kind == "Q" or (straight and p.kind == "R") or
                       (not straight and p.kind == "B") then
                        return true
                    end
                end
                break
            end
            nr, nc = nr + d[1], nc + d[2]
        end
    end
    return false
end

local function king_in_check(b, color)
    local r, c = find_king(b, color)
    return r and is_square_attacked(b, r, c, other(color)) or false
end

local function add_move(moves, r, c, extra)
    local m = {r = r, c = c}
    if extra then
        for k, v in pairs(extra) do m[k] = v end
    end
    moves[#moves + 1] = m
end

local function add_sliding_moves(b, moves, r, c, color, directions)
    for _, d in ipairs(directions) do
        local nr, nc = r + d[1], c + d[2]
        while inside(nr, nc) do
            local target = b[nr][nc]
            if not target then
                add_move(moves, nr, nc)
            else
                if target.color ~= color then add_move(moves, nr, nc) end
                break
            end
            nr, nc = nr + d[1], nc + d[2]
        end
    end
end

local function pseudo_moves(b, r, c, rights, ep)
    local p = b[r][c]
    local moves = {}
    if not p then return moves end

    if p.kind == "P" then
        local dir = p.color == "w" and -1 or 1
        local start_row = p.color == "w" and 7 or 2
        local nr = r + dir
        if inside(nr, c) and not b[nr][c] then
            add_move(moves, nr, c)
            if r == start_row and not b[r + 2 * dir][c] then
                add_move(moves, r + 2 * dir, c, {double_pawn = true})
            end
        end
        for _, dc in ipairs({-1, 1}) do
            local nc = c + dc
            if inside(nr, nc) then
                local target = b[nr][nc]
                if target and target.color ~= p.color then
                    add_move(moves, nr, nc)
                elseif ep and ep.r == nr and ep.c == nc and ep.color ~= p.color then
                    add_move(moves, nr, nc, {en_passant = true})
                end
            end
        end
    elseif p.kind == "N" then
        local steps = {
            {-2, -1}, {-2, 1}, {-1, -2}, {-1, 2},
            {1, -2}, {1, 2}, {2, -1}, {2, 1},
        }
        for _, d in ipairs(steps) do
            local nr, nc = r + d[1], c + d[2]
            if inside(nr, nc) and (not b[nr][nc] or b[nr][nc].color ~= p.color) then
                add_move(moves, nr, nc)
            end
        end
    elseif p.kind == "B" then
        add_sliding_moves(b, moves, r, c, p.color,
            {{-1, -1}, {-1, 1}, {1, -1}, {1, 1}})
    elseif p.kind == "R" then
        add_sliding_moves(b, moves, r, c, p.color,
            {{-1, 0}, {1, 0}, {0, -1}, {0, 1}})
    elseif p.kind == "Q" then
        add_sliding_moves(b, moves, r, c, p.color, {
            {-1, 0}, {1, 0}, {0, -1}, {0, 1},
            {-1, -1}, {-1, 1}, {1, -1}, {1, 1},
        })
    elseif p.kind == "K" then
        for dr = -1, 1 do
            for dc = -1, 1 do
                if dr ~= 0 or dc ~= 0 then
                    local nr, nc = r + dr, c + dc
                    if inside(nr, nc) and (not b[nr][nc] or b[nr][nc].color ~= p.color) then
                        add_move(moves, nr, nc)
                    end
                end
            end
        end

        local home_row = p.color == "w" and 8 or 1
        local enemy = other(p.color)
        if r == home_row and c == 5 and not is_square_attacked(b, r, 5, enemy) then
            local king_key = p.color .. "K"
            local queen_key = p.color .. "Q"
            local rook = b[home_row][8]
            if rights[king_key] and rook and rook.color == p.color and rook.kind == "R" and
               not b[home_row][6] and not b[home_row][7] and
               not is_square_attacked(b, home_row, 6, enemy) and
               not is_square_attacked(b, home_row, 7, enemy) then
                add_move(moves, home_row, 7, {castle = "K"})
            end
            rook = b[home_row][1]
            if rights[queen_key] and rook and rook.color == p.color and rook.kind == "R" and
               not b[home_row][2] and not b[home_row][3] and not b[home_row][4] and
               not is_square_attacked(b, home_row, 4, enemy) and
               not is_square_attacked(b, home_row, 3, enemy) then
                add_move(moves, home_row, 3, {castle = "Q"})
            end
        end
    end
    return moves
end

local function apply_to_board(b, from_r, from_c, move)
    local p = b[from_r][from_c]
    b[from_r][from_c] = nil
    if move.en_passant then b[from_r][move.c] = nil end
    b[move.r][move.c] = p
    if move.castle == "K" then
        b[move.r][6] = b[move.r][8]
        b[move.r][8] = nil
    elseif move.castle == "Q" then
        b[move.r][4] = b[move.r][1]
        b[move.r][1] = nil
    end
    if p.kind == "P" and (move.r == 1 or move.r == 8) then p.kind = "Q" end
end

local function legal_moves_for(b, r, c, rights, ep)
    local p = b[r][c]
    local legal = {}
    if not p then return legal end
    for _, move in ipairs(pseudo_moves(b, r, c, rights, ep)) do
        local test = copy_board(b)
        apply_to_board(test, r, c, move)
        if not king_in_check(test, p.color) then legal[#legal + 1] = move end
    end
    return legal
end

local function side_has_legal_move(color)
    for r = 1, 8 do
        for c = 1, 8 do
            local p = board[r][c]
            if p and p.color == color and #legal_moves_for(board, r, c, castle_rights, en_passant) > 0 then
                return true
            end
        end
    end
    return false
end

local function disable_rook_right(color, r, c)
    local home_row = color == "w" and 8 or 1
    if r == home_row and c == 1 then castle_rights[color .. "Q"] = false end
    if r == home_row and c == 8 then castle_rights[color .. "K"] = false end
end

local function update_castle_rights(p, from_r, from_c, captured, to_r, to_c)
    if p.kind == "K" then
        castle_rights[p.color .. "K"] = false
        castle_rights[p.color .. "Q"] = false
    elseif p.kind == "R" then
        disable_rook_right(p.color, from_r, from_c)
    end
    if captured and captured.kind == "R" then
        disable_rook_right(captured.color, to_r, to_c)
    end
end

local function finish_turn()
    turn = other(turn)
    in_check = king_in_check(board, turn)
    if not side_has_legal_move(turn) then
        game_over = true
        if in_check then
            result = (turn == "w" and "White" or "Black") .. " checkmated"
        else
            result = "Stalemate"
        end
    end
end

local function make_move(from_r, from_c, move)
    local p = board[from_r][from_c]
    local captured = board[move.r][move.c]
    update_castle_rights(p, from_r, from_c, captured, move.r, move.c)
    apply_to_board(board, from_r, from_c, move)
    if move.double_pawn then
        en_passant = {r = (from_r + move.r) // 2, c = from_c, color = p.color}
    else
        en_passant = nil
    end
    last_move = {from_r = from_r, from_c = from_c, to_r = move.r, to_c = move.c}
    ply_count = ply_count + 1
    selected_r, selected_c = nil, nil
    selected_moves = {}
    finish_turn()
end

local function move_at(r, c)
    for _, move in ipairs(selected_moves) do
        if move.r == r and move.c == c then return move end
    end
    return nil
end

local function tap_cell(r, c)
    if selected_r then
        local move = move_at(r, c)
        if move then
            make_move(selected_r, selected_c, move)
            return
        end
    end
    local p = board[r][c]
    if p and p.color == turn then
        selected_r, selected_c = r, c
        selected_moves = legal_moves_for(board, r, c, castle_rights, en_passant)
    else
        selected_r, selected_c = nil, nil
        selected_moves = {}
    end
end

local function pixel_to_cell(x, y)
    if x < BOARD_X or x >= BOARD_X + BOARD_SIZE then return nil end
    if y < BOARD_Y or y >= BOARD_Y + BOARD_SIZE then return nil end
    return math.floor((y - BOARD_Y) / CELL) + 1,
           math.floor((x - BOARD_X) / CELL) + 1
end

local function handle_touch()
    if not touch_handle then return end
    local lcd_touch = require("lcd_touch")
    local t = lcd_touch.poll(touch_handle)
    if t.pressed and t.held_ms and t.held_ms > 1500 then
        RUNNING = false
        return
    end
    if not t.just_released then return end
    if game_over then
        reset_game()
        return
    end
    local r, c = pixel_to_cell(t.x, t.y)
    if r then tap_cell(r, c) end
end

local function cell_xy(r, c)
    return BOARD_X + (c - 1) * CELL, BOARD_Y + (r - 1) * CELL
end

local function is_last_square(r, c)
    return last_move and
        ((last_move.from_r == r and last_move.from_c == c) or
         (last_move.to_r == r and last_move.to_c == c))
end

local function draw_piece(x, y, p)
    local cx, cy = x + CELL // 2, y + CELL // 2
    local fill = p.color == "w" and WHITE_PIECE or BLACK_PIECE
    local text_color = p.color == "w" and WHITE_TEXT or BLACK_TEXT
    display.fill_circle(cx, cy, 29, fill)
    display.draw_circle(cx, cy, 29, GRID)
    display.draw_text_aligned(x, y, CELL, CELL, p.kind,
        {font_size = 34, color = text_color})
end

local function status_text()
    local side = turn == "w" and "White" or "Black"
    local moves = ply_count // 2 + 1
    if game_over then return result .. "  |  Moves: " .. tostring(moves) end
    if in_check then return side .. " to move - CHECK  |  Moves: " .. tostring(moves) end
    return side .. " to move  |  Moves: " .. tostring(moves)
end

local function draw()
    display.begin_frame({clear = true, color = BG})
    display.fill_rect(0, 0, W, BOARD_Y, STATUS_BG)
    display.draw_text(18, 14, "CHESS", {font_size = 28, color = TEXT})
    display.draw_text_aligned(145, 10, W - 160, 36, status_text(),
        {font_size = 20, color = in_check and CHECK or TEXT})
    display.draw_text_aligned(0, 48, W, 20,
        game_over and "Tap to restart  |  Hold to exit" or "Tap piece, then destination  |  Hold to exit",
        {font_size = 14, color = MUTED})

    local check_r, check_c
    if in_check then check_r, check_c = find_king(board, turn) end
    for r = 1, 8 do
        for c = 1, 8 do
            local x, y = cell_xy(r, c)
            local color = ((r + c) % 2 == 0) and LIGHT_SQUARE or DARK_SQUARE
            if is_last_square(r, c) then color = LAST_MOVE end
            if selected_r == r and selected_c == c then color = SELECTED end
            if check_r == r and check_c == c then color = CHECK end
            display.fill_rect(x, y, CELL, CELL, color)
            display.draw_rect(x, y, CELL, CELL, GRID)
        end
    end

    for _, move in ipairs(selected_moves) do
        local x, y = cell_xy(move.r, move.c)
        local cx, cy = x + CELL // 2, y + CELL // 2
        if board[move.r][move.c] or move.en_passant then
            display.draw_circle(cx, cy, 34, LEGAL)
            display.draw_circle(cx, cy, 33, LEGAL)
        else
            display.fill_circle(cx, cy, 8, LEGAL)
        end
    end

    for r = 1, 8 do
        for c = 1, 8 do
            if board[r][c] then
                local x, y = cell_xy(r, c)
                draw_piece(x, y, board[r][c])
            end
        end
    end

    if game_over then
        local pw, ph = 500, 160
        local px, py = (W - pw) // 2, (H - ph) // 2
        display.fill_round_rect(px, py, pw, ph, 12, END_PANEL)
        display.draw_round_rect(px, py, pw, ph, 12, MUTED)
        display.draw_text_aligned(px, py + 28, pw, 45, result,
            {font_size = 34, color = result == "Stalemate" and MUTED or CHECK})
        display.draw_text_aligned(px, py + 94, pw, 28, "Tap to restart  |  Hold to exit",
            {font_size = 18, color = TEXT})
    end

    display.present()
    display.end_frame()
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[chess] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    BOARD_X = (W - BOARD_SIZE) // 2
    BOARD_Y = H - BOARD_SIZE - 4
    reset_game()
end

local function run()
    init()
    print("[chess] Running... tap piece and destination, long press to exit")
    while RUNNING do
        handle_touch()
        draw()
        delay.delay_ms(16)
    end
    display.clear(BG)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = MUTED})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    print("[chess] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[chess] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
end
