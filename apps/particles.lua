-- particles.lua - Particle fluid simulation controlled by accelerometer
-- Tilt the device to make particles flow like sand/water

local display = require("display")
local board_manager = require("board_manager")
local lib_sc7a20h = require("lib_sc7a20h")
local delay = require("delay")
local i2c = require("i2c")
local math = math

local W, H = 720, 720
local RUNNING = true

local NUM_PARTICLES = 280
local PARTICLE_R = 4
local GRAV = 0.04
local FRICTION = 0.96
local BOUNCE = 0.45
local MAX_V = 10

-- Colors
local BG     = "#0a0a14"
local TEXT_C = "#404060"

local accel
local touch_handle
local particles = {}

local function hsv_to_hex(h, s, v)
    -- h: 0-360, s: 0-1, v: 0-1
    local c = v * s
    local hp = (h % 360) / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b
    if hp < 1 then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x
    end
    local m = v - c
    r = math.floor((r + m) * 255)
    g = math.floor((g + m) * 255)
    b = math.floor((b + m) * 255)
    return string.format("#%02x%02x%02x", r, g, b)
end

local function init()
    local panel, io, lw, lh, pif = board_manager.get_display_lcd_params("display_lcd")
    if not panel then error("[particles] No display device found") end
    W, H = lw or 720, lh or 720
    display.init(panel, io, W, H, pif)
    display.backlight(true)

    local bus = i2c.wrap(1)
    accel = lib_sc7a20h.new({ bus = bus })
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")

    -- Initialize particles in a cluster at center
    particles = {}
    for i = 1, NUM_PARTICLES do
        local angle = math.random() * 2 * math.pi
        local dist = math.random() * 80
        particles[i] = {
            x = W // 2 + math.cos(angle) * dist,
            y = H // 2 + math.sin(angle) * dist,
            vx = 0,
            vy = 0,
            hue = math.random(180, 320),  -- blue-purple range
        }
    end
end

local function update(ax_mg, ay_mg)
    -- Gravity from tilt
    local gx = -ax_mg * GRAV
    local gy = ay_mg * GRAV

    for _, p in ipairs(particles) do
        p.vx = (p.vx + gx) * FRICTION
        p.vy = (p.vy + gy) * FRICTION

        -- Clamp velocity
        local sp = math.sqrt(p.vx * p.vx + p.vy * p.vy)
        if sp > MAX_V then
            p.vx = p.vx / sp * MAX_V
            p.vy = p.vy / sp * MAX_V
        end

        p.x = p.x + p.vx
        p.y = p.y + p.vy

        -- Boundary collision with bounce
        if p.x < PARTICLE_R then
            p.x = PARTICLE_R
            p.vx = -p.vx * BOUNCE
        elseif p.x > W - PARTICLE_R then
            p.x = W - PARTICLE_R
            p.vx = -p.vx * BOUNCE
        end
        if p.y < PARTICLE_R then
            p.y = PARTICLE_R
            p.vy = -p.vy * BOUNCE
        elseif p.y > H - PARTICLE_R then
            p.y = H - PARTICLE_R
            p.vy = -p.vy * BOUNCE
        end
    end

    -- Simple particle-particle collision (spatial hash for performance)
    -- Grid-based neighbor check
    local cell_size = PARTICLE_R * 4
    local grid = {}
    for _, p in ipairs(particles) do
        local gx = math.floor(p.x / cell_size)
        local gy = math.floor(p.y / cell_size)
        local key = gx * 10000 + gy
        if not grid[key] then grid[key] = {} end
        grid[key][#grid[key] + 1] = p
    end

    local min_dist = PARTICLE_R * 2
    local min_dist_sq = min_dist * min_dist
    for _, p in ipairs(particles) do
        local gx = math.floor(p.x / cell_size)
        local gy = math.floor(p.y / cell_size)
        for dx = -1, 1 do
            for dy = -1, 1 do
                local key = (gx + dx) * 10000 + (gy + dy)
                local cell = grid[key]
                if cell then
                    for _, q in ipairs(cell) do
                        if q ~= p then
                            local ddx = p.x - q.x
                            local ddy = p.y - q.y
                            local dist_sq = ddx * ddx + ddy * ddy
                            if dist_sq < min_dist_sq and dist_sq > 0.01 then
                                local dist = math.sqrt(dist_sq)
                                local overlap = (min_dist - dist) * 0.5
                                local nx = ddx / dist
                                local ny = ddy / dist
                                p.x = p.x + nx * overlap
                                p.y = p.y + ny * overlap
                            end
                        end
                    end
                end
            end
        end
    end
end

local function draw()
    display.begin_frame({clear = true, color = BG})

    for _, p in ipairs(particles) do
        local speed = math.sqrt(p.vx * p.vx + p.vy * p.vy)
        -- Shift hue based on speed: fast = warmer
        local h = (p.hue + speed * 20) % 360
        local s = 0.7
        local v = 0.5 + math.min(0.5, speed * 0.08)
        local color = hsv_to_hex(h, s, v)
        display.fill_circle(math.floor(p.x), math.floor(p.y), PARTICLE_R, color)
    end

    display.draw_text_aligned(0, 10, W, 25, "Tilt to flow particles", {font_size = 16, color = TEXT_C})
    display.draw_text_aligned(0, H - 25, W, 20, "Touch to exit", {font_size = 14, color = "#1a1a2e"})

    display.present()
    display.end_frame()
end

local function run()
    init()
    print("[particles] Running... touch to exit")

    while RUNNING do
        local ax, ay, az = accel:read_mg()
        update(ax, ay)
        draw()

        if touch_handle then
            local lcd_touch = require("lcd_touch")
            local t = lcd_touch.poll(touch_handle)
            if t.just_pressed then
                RUNNING = false
            end
        end

        delay.delay_ms(16)
    end

    display.clear(BG)
    display.draw_text_aligned(0, 0, W, H, "Bye!", {font_size = 48, color = TEXT_C})
    display.present()
    delay.delay_ms(400)
    display.backlight(false)
    display.deinit()
    if accel then accel:close() end
    print("[particles] Done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[particles] ERROR: " .. tostring(err))
    pcall(function() display.deinit() end)
    pcall(function() if accel then accel:close() end end)
end
