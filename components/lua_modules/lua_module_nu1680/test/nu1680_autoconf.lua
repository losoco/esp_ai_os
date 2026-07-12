-- nu1680_autoconf.lua -- NU1680 无线充电自动配置 + 显示通知
-- 后台运行，每 500ms 轮询 I2C 0x60，检测无线充电适配器
-- 适配器接入 → 自动配置 → 显示"开始充电"图标 5 秒
-- 适配器移除或充满 → 显示"充电完成"图标 5 秒
--
-- 用法: esp-claw-cli run nu1680_autoconf.lua
--       或 lua --run --path /sdscard/inbox/nu1680_autoconf.lua

local i2c = require("i2c")
local delay = require("delay")
local bm = require("board_manager")
local display = require("display")

-- ========== 配置 ==========
local I2C_PORT       = 1
local I2C_SDA        = 7
local I2C_SCL        = 8
local NU1680_ADDR    = 0x60
local POLL_INTERVAL  = 500  -- ms
local BANNER_SECONDS = 5    -- 提示显示秒数

-- BQ27220 电量计地址（共享 I2C 总线）
local FUEL_GAUGE_ADDR = 0x55

-- 充满判定: 电流绝对值 < CHARGE_COMPLETE_THRESHOLD mA (电池已满或涓流)
local CHARGE_COMPLETE_THRESHOLD = 10  -- mA

-- ========== 状态机 ==========
-- IDLE      → 等待适配器
-- CHARGING  → 适配器在线，正在充电
-- FULL      → 电池已满（仍在充电板上但电流≈0）
local STATE_IDLE      = 1
local STATE_CHARGING  = 2
local STATE_FULL      = 3

-- ========== I2C 探测 ==========
local function probe_nu1680(i2c_dev)
    local ok, err = pcall(function()
        local data = i2c_dev:read(1, 0x1E)
        -- 能读到数据 = 设备在线
    end)
    return ok
end

-- ========== NU1680 配置（直接 I2C 写，避免 close 冲突）==========
local function configure_nu1680(dev)
    local ok, err = pcall(function()
        dev:write_byte(0x00, 0x1E)  -- MTP_ILIM_SET = 1.4A
        dev:write_byte(0x00, 0x15)  -- 关闭温度保护
    end)
    if ok then
        print("[wxchg] configured NU1680: 1.4A, thermal protection off")
    else
        print("[wxchg] configure failed:", err)
    end
    return ok
end

-- ========== BQ27220 电流读取（直接 I2C 读，避免 close 冲突）==========
local function read_i16le(dev, reg)
    local data = dev:read(2, reg)
    local lo = string.byte(data, 1) or 0
    local hi = string.byte(data, 2) or 0
    local v = lo | (hi << 8)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

local function read_charge_current(fuel_dev)
    local ok, current, soc = pcall(function()
        local cur = read_i16le(fuel_dev, 0x0C)  -- BQ27220 current register
        local s = fuel_dev:read(2, 0x2C)        -- BQ27220 SOC register
        local lo = string.byte(s, 1) or 0
        local hi = string.byte(s, 2) or 0
        return cur, lo | (hi << 8)
    end)
    if not ok then
        print("[wxchg] fuel gauge read failed:", current)
        return nil, nil
    end
    return current, soc
end

-- ========== 显示通知 ==========
local function show_banner(text, bg_r, bg_g, bg_b)
    local panel_handle, io_handle, w, h, panel_if = bm.get_display_lcd_params("display_lcd")
    if not panel_handle then
        print("[wxchg] no display available, skip banner")
        return
    end

    -- 预先计算布局（pcall 外部，确保变量可见）
    local bar_h = 52
    local bar_y = math.floor((h - bar_h) / 2)
    local bar_w = math.min(w - 40, 360)
    local bar_x = math.floor((w - bar_w) / 2)
    local pb_y = bar_y + bar_h - 2
    local title_size = 22

    local ok, err = pcall(function()
        display.init(panel_handle, io_handle, w, h, panel_if)
        display.begin_frame({ clear = true, r = 0, g = 0, b = 0 })

        -- 背景条
        display.fill_round_rect(bar_x, bar_y, bar_w, bar_h, 14, bg_r, bg_g, bg_b)

        -- 标题文字
        local tw, th = display.measure_text(text, { font_size = title_size })
        local tx = math.floor((w - tw) / 2)
        local ty = bar_y + math.floor((bar_h - th) / 2) - 2
        display.draw_text(tx, ty, text, {
            r = 255, g = 255, b = 255,
            font_size = title_size,
        })

        display.present()

        -- 进度条逐帧缩短
        local frame_ms = 100
        local total_frames = math.floor(BANNER_SECONDS * 1000 / frame_ms)
        for i = 1, total_frames do
            local progress = 1.0 - (i / total_frames)
            local pb_w = math.floor(bar_w * progress)
            if pb_w > 0 then
                display.fill_rect(bar_x, pb_y, pb_w, 3, 72, 208, 235)
                display.present()
            end
            delay.delay_ms(frame_ms)
        end

        display.end_frame()
    end)

    if not ok then
        print("[wxchg] banner failed:", err)
    end

    pcall(display.deinit)
end

local function show_charging_started()
    show_banner("Charging Started", 32, 120, 48)
end

local function show_charging_complete()
    show_banner("Charging Complete", 64, 140, 60)
end

-- ========== 主循环 ==========
local function main()
    print("[wxchg] NU1680 wireless charge monitor started")
    print("[wxchg] I2C port=" .. I2C_PORT .. " sda=" .. I2C_SDA .. " scl=" .. I2C_SCL)
    print("[wxchg] poll interval=" .. POLL_INTERVAL .. "ms")

    local bus = i2c.new(I2C_PORT, I2C_SDA, I2C_SCL, 400000)
    local nu1680_dev = bus:device(NU1680_ADDR, 0)
    local fuel_dev = bus:device(FUEL_GAUGE_ADDR, 0)
    local noconfig_count = 0 -- 未配置计数（第一次探测到后立即配置）

    local state = STATE_IDLE
    local nu1680_present = false
    local prev_nu1680_present = false

    while true do
        -- 探测 NU1680 (I2C 0x60)
        nu1680_present = probe_nu1680(nu1680_dev)

        -- 状态转换
        if nu1680_present and not prev_nu1680_present then
            -- 适配器刚接入
            print("[wxchg] wireless charger detected")
            noconfig_count = 0
            if state == STATE_IDLE or state == STATE_FULL then
                configure_nu1680(nu1680_dev)
                state = STATE_CHARGING
                print("[wxchg] STATE: IDLE/FULL → CHARGING")
                show_charging_started()
            end
        elseif not nu1680_present and prev_nu1680_present then
            -- 适配器刚移除
            print("[wxchg] wireless charger removed")
            if state == STATE_CHARGING or state == STATE_FULL then
                state = STATE_IDLE
                print("[wxchg] STATE: CHARGING/FULL → IDLE")
                show_charging_complete()
            end
        end

        -- 充电中: 检测电池是否充满
        if state == STATE_CHARGING and nu1680_present then
            local current, soc = read_charge_current(fuel_dev)
            if current ~= nil then
                -- 电流为正 = 充电中, 电流≈0 = 充满或未充电
                if math.abs(current) < CHARGE_COMPLETE_THRESHOLD then
                    print(string.format("[wxchg] battery full (current=%dmA soc=%d%%)", current, soc or 0))
                    state = STATE_FULL
                    print("[wxchg] STATE: CHARGING → FULL")
                    show_charging_complete()
                end
            end
        end

        prev_nu1680_present = nu1680_present
        delay.delay_ms(POLL_INTERVAL)
    end
end

-- ========== 入口 ==========
local ok, err = pcall(main)
if not ok then
    print("[wxchg] FATAL:", err)
end
