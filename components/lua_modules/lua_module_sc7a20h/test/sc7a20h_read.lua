-- sc7a20h test — 读取 SC7A20H 加速度计并持续输出 3 轴数据
local sc7a20h = require("lib_sc7a20h")
local delay = require("delay")
local i2c = require("i2c")

local a = type(args) == "table" and args or {}
local function int_arg(k, default)
    local v = a[k]
    if type(v) == "number" then return math.floor(v) end
    return default
end

local PORT = int_arg("port", 1)
local SDA = int_arg("sda", 7)
local SCL = int_arg("scl", 8)
local ADDR = int_arg("addr", 0x19)
local FREQ = int_arg("freq_hz", 400000)
local COUNT = int_arg("count", 20)
local INTERVAL_MS = int_arg("interval_ms", 500)

local accel
local bus

local function cleanup()
    if accel then pcall(function() accel:close() end); accel = nil end
    if bus then pcall(function() bus:close() end); bus = nil end
end

local function run()
    bus = a.bus or i2c.new(PORT, SDA, SCL, FREQ)
    accel = sc7a20h.new({ bus = bus, addr = ADDR, freq_hz = FREQ })

    local who = accel:whoami()
    print(string.format("[sc7a20h] WHO_AM_I=0x%02X port=%d sda=%d scl=%d", who, PORT, SDA, SCL))

    for i = 1, COUNT do
        local ax, ay, az = accel:read_mg()
        local gx, gy, gz = ax / 1000, ay / 1000, az / 1000
        print(string.format("[sc7a20h] #%d X=%+.3fg (%+dmg) Y=%+.3fg (%+dmg) Z=%+.3fg (%+dmg)",
            i, gx, ax, gy, ay, gz, az))
        delay.delay_ms(INTERVAL_MS)
    end

    print("[sc7a20h] Test complete")
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
