-- gps_full_test.lua - GPS full test (120s, with raw NMEA capture)
-- Upload to /inbox/ and run via Web UI or API
local gps = require("lib_gps")
local delay = require("delay")
local i2c = require("i2c")
local storage = require("storage")

local PORT = 0
local TX = 38
local RX = 37
local BAUD = 9600
local DURATION_S = 120
local POLL_INTERVAL_MS = 1000

local g
local log_file
local nmea_file

local function cleanup()
    if g then pcall(function() g:close() end); g = nil end
    if log_file then pcall(function() log_file:close() end); log_file = nil end
    if nmea_file then pcall(function() nmea_file:close() end); nmea_file = nil end
end

local function run()
    -- GPS power on (TCA9555 P0-0)
    local i2c_bus = i2c.wrap(1)
    local expander = i2c_bus:device(0x20)
    local cur = expander:read(1, 0x02)
    local cur_val = string.byte(cur, 1) or 0
    if cur_val & 0x01 == 0 then
        expander:write_byte(cur_val | 0x01, 0x02)
        print(string.format("[gps] GPS power ON (0x%02X -> 0x%02X)", cur_val, cur_val | 0x01))
    else
        print(string.format("[gps] GPS power already ON (0x%02X)", cur_val))
    end
    delay.delay_ms(500)

    -- Open log file
    local log_path = storage.join_path(storage.get_root_dir(), "inbox", "gps_full_test.log")
    log_file = io.open(log_path, "w")
    if log_file then log_file:write(string.format("[gps] Full test started, duration=%ds\n", DURATION_S)) end

    -- Open raw NMEA capture file (first 10s only)
    local nmea_path = storage.join_path(storage.get_root_dir(), "inbox", "gps_nmea_raw.txt")
    nmea_file = io.open(nmea_path, "w")

    -- Open UART, use bus reuse mode for raw data access
    local bus = uart.new(PORT, TX, RX, BAUD)
    g = gps.new({ bus = bus })
    print(string.format("[gps] UART%d tx=%d rx=%d baud=%d, polling %ds", PORT, TX, RX, BAUD, DURATION_S))

    local start_s = os.time()
    local first_fix_s = nil

    while os.time() - start_s < DURATION_S do
        local elapsed = os.time() - start_s

        -- Capture raw NMEA for first 10s
        if nmea_file and elapsed < 10 then
            local avail = bus:available()
            if avail > 0 then
                local raw = bus:read(math.min(avail, 512), 0)
                if raw and #raw > 0 then
                    nmea_file:write(raw)
                end
            end
        elseif nmea_file and elapsed >= 10 then
            nmea_file:close()
            nmea_file = nil
            print("[gps] Raw NMEA capture done (first 10s)")
        end

        -- Normal poll + snapshot
        local n = g:poll()
        local s = g:get_snapshot()

        if s.fix_valid and not first_fix_s then
            first_fix_s = elapsed
            print(string.format("[gps] *** FIRST FIX at %ds! ***", elapsed))
        end

        local line = string.format(
            "[%3ds] fix=%s q=%d lat=%.6f lon=%.6f alt=%.1fm spd=%.1fkm/h sats=%d/%d hdop=%.1f time=%s date=%s sent=%d bytes=%d",
            elapsed,
            s.fix_valid and "YES" or "NO ",
            s.fix_quality,
            s.latitude_deg, s.longitude_deg, s.altitude_m, s.speed_kmh,
            s.satellites_used, s.satellites_view, s.hdop,
            s.utc_time, s.utc_date,
            s.sentence_count, s.bytes_received)
        print(line)
        if log_file then log_file:write(line .. "\n") end

        delay.delay_ms(POLL_INTERVAL_MS)
    end

    if log_file then log_file:close() end
    print(string.format("[gps] Test complete. First fix: %s", first_fix_s and (first_fix_s .. "s") or "NONE"))
    print(string.format("[gps] Log: %s", log_path))
    print(string.format("[gps] NMEA raw: %s", nmea_path))

    -- GPS power off
    cur = expander:read(1, 0x02)
    cur_val = string.byte(cur, 1) or 0
    expander:write_byte(cur_val & ~0x01, 0x02)
    print("[gps] GPS power OFF")
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
