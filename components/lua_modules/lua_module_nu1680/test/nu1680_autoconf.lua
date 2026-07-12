-- nu1680_autoconf.lua -- NU1680 无线充电自动检测 + 振动通知
local i2c = require("i2c")
local delay = require("delay")
local bm    = require("board_manager")

local NU1680_ADDR     = 0x60
local FUEL_GAUGE_ADDR = 0x55
local POLL_INTERVAL   = 500

local function vibrate(ms)
    bm.set_ledc_duty("vibration_motor", 80)
    delay.delay_ms(ms)
    bm.set_ledc_duty("vibration_motor", 0)
end

local function main()
    print("[wxchg] starting with i2c.wrap(1)...")
    local bus = i2c.wrap(1)
    local nu_dev = bus:device(NU1680_ADDR)
    local f_dev  = bus:device(FUEL_GAUGE_ADDR)

    local bus_ok = pcall(function() f_dev:read(2, 0x08) end)
    if not bus_ok then
        print("[wxchg] I2C BUS FAIL")
        return
    end
    print("[wxchg] I2C bus OK")

    local was_present = false

    while true do
        local present = pcall(function() nu_dev:read(1, 0x1E) end)

        if present and not was_present then
            print("[wxchg] DETECTED — configuring")
            pcall(function() nu_dev:write(string.char(0), 0x1E) end)
            pcall(function() nu_dev:write(string.char(0), 0x15) end)
            -- 长振动 = 充电开始
            vibrate(400)
            print("[wxchg] configured")
        elseif not present and was_present then
            print("[wxchg] REMOVED")
            -- 短振动 2 次 = 充电移除
            vibrate(100) delay.delay_ms(100) vibrate(100)
        end

        was_present = present
        delay.delay_ms(POLL_INTERVAL)
    end
end

pcall(main)
