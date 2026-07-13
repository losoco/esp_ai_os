-- gps_read.lua — GPS NMEA parser test
-- Polls GPS for NMEA sentences and prints snapshot every second.
-- Usage: lua --run --path /system/scripts/builtin/test/gps_read.lua

local gps = require("lib_gps")
local delay = require("delay")

local a = type(args) == "table" and args or {}
local function int_arg(k, default)
    local v = a[k]
    if type(v) == "number" then return math.floor(v) end
    return default
end

local PORT = int_arg("port", 0)
local TX = int_arg("tx", 38)
local RX = int_arg("rx", 37)
local BAUD = int_arg("baud", 9600)
local DURATION_S = int_arg("duration_s", 30)

local g

local function cleanup()
    if g then pcall(function() g:close() end); g = nil end
end

local function run()
    print(string.format("[gps] Opening UART%d tx=%d rx=%d baud=%d", PORT, TX, RX, BAUD))
    g = gps.new({ port = PORT, tx = TX, rx = RX, baud = BAUD })
    print("[gps] Polling for NMEA data...")

    local start_s = os.time()
    while os.time() - start_s < DURATION_S do
        local n = g:poll()
        if n > 0 then
            local s = g:get_snapshot()
            print(string.format(
                "[gps] fix=%s lat=%.6f lon=%.6f alt=%.1fm spd=%.1fkm/h sats=%d/%d hdop=%.1f time=%s date=%s sent=%d bytes=%d",
                s.fix_valid and "YES" or "NO",
                s.latitude_deg, s.longitude_deg, s.altitude_m, s.speed_kmh,
                s.satellites_used, s.satellites_view, s.hdop,
                s.utc_time, s.utc_date,
                s.sentence_count, s.bytes_received))
        end
        delay.delay_ms(1000)
    end

    print("[gps] Test complete")
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
