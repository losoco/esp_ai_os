-- nu1680_autoconf.lua -- NU1680 无线充电自动配置 + 显示通知
-- 后台运行，每 500ms 轮询 I2C 0x60，检测无线充电适配器
-- 适配器接入 → 自动配置 → 显示"开始充电"图标 5 秒
-- 适配器移除或充满 → 显示"充电完成"图标 5 秒
--
-- 用法: esp-claw-cli run nu1680_autoconf.lua
--       或 lua --run --path /sdscard/inbox/nu1680_autoconf.lua

local i2c = require("i2c")
local delay = require("delay")
local gpio = require("gpio")

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
    if not ok then
        print("[wxchg] probe failed: " .. tostring(err):sub(1,60))
    end
    return ok
end

-- ========== NU1680 配置（直接 I2C 写，避免 close 冲突）==========
local function configure_nu1680(dev)
    local ok, err = pcall(function()
        dev:write(string.char(0x00), 0x1E)  -- MTP_ILIM_SET = 1.4A
        dev:write(string.char(0x00), 0x15)  -- 关闭温度保护
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

-- ========== 振动通知（避开显示抢占问题）==========
local VIBRATE_GPIO = 22  -- MetalioClaw4 振动马达 GPIO

local function vibrate_ms(ms)
    pcall(function()
        local motor = gpio.new_out(VIBRATE_GPIO)
        motor:set(1)
        delay.delay_ms(ms)
        motor:set(0)
    end)
end

local function show_charging_started()
    print("[wxchg] >>> CHARGING STARTED <<<")
    vibrate_ms(200)
end

local function show_charging_complete()
    print("[wxchg] >>> CHARGING COMPLETE <<<")
    vibrate_ms(100)
    delay.delay_ms(100)
    vibrate_ms(100)
end

-- ========== 主循环 ==========
local function main()
    print("[wxchg] NU1680 wireless charge monitor started")
    print("[wxchg] I2C port=" .. I2C_PORT .. " sda=" .. I2C_SDA .. " scl=" .. I2C_SCL)
    print("[wxchg] poll interval=" .. POLL_INTERVAL .. "ms")

    local bus = i2c.new(I2C_PORT, I2C_SDA, I2C_SCL, 400000)
    local nu1680_dev = bus:device(NU1680_ADDR, 0)
    local fuel_dev = bus:device(FUEL_GAUGE_ADDR, 0)

    -- 验证 I2C 总线可用
    local test_ok = pcall(function() fuel_dev:read(2, 0x08) end)
    print("[wxchg] I2C bus test: " .. (test_ok and "OK" or "FAIL"))
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
