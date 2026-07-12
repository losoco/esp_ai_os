-- nu1680_autoconf.lua -- NU1680 无线充电自动检测
-- 使用 i2c.wrap(1) 复用系统已创建的 I2C 总线
-- 用法: esp-claw-cli run nu1680_autoconf.lua

local i2c = require("i2c")
local delay = require("delay")

local NU1680_ADDR    = 0x60
local FUEL_GAUGE_ADDR = 0x55
local POLL_INTERVAL  = 500

local function main()
    print("[wxchg] starting with i2c.wrap(1)...")
    local bus = i2c.wrap(1)
    local nu_dev = bus:device(NU1680_ADDR)
    local f_dev  = bus:device(FUEL_GAUGE_ADDR)

    -- Verify I2C bus by reading fuel gauge
    local bus_ok = pcall(function() f_dev:read(2, 0x08) end)
    if not bus_ok then
        print("[wxchg] I2C BUS FAIL — check board manager init")
        return
    end
    print("[wxchg] I2C bus OK")

    local was_present = false

    while true do
        local present = pcall(function() nu_dev:read(1, 0x1E) end)

        if present and not was_present then
            print("[wxchg] DETECTED — configuring NU1680")
            pcall(function() nu_dev:write(string.char(0), 0x1E) end)
            pcall(function() nu_dev:write(string.char(0), 0x15) end)

            -- Read battery current
            local cur_str = "?"
            pcall(function()
                local d = f_dev:read(2, 0x0C)
                local lo = string.byte(d, 1) or 0
                local hi = string.byte(d, 2) or 0
                local v = lo | (hi << 8)
                if v >= 0x8000 then v = v - 0x10000 end
                cur_str = tostring(v) .. "mA"
            end)
            print("[wxchg] configured, battery current=" .. cur_str)
        elseif not present and was_present then
            print("[wxchg] REMOVED")
        end

        was_present = present
        delay.delay_ms(POLL_INTERVAL)
    end
end

pcall(main)
