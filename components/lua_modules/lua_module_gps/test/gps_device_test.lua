-- gps_device_test.lua - GPS 设备端测试脚本
-- 通过 IO 扩展器打开 GPS 电源，轮询 NMEA 数据，输出快照到文件。
local gps = require("lib_gps")
local delay = require("delay")
local i2c = require("i2c")
local storage = require("storage")

local PORT = 0
local TX = 38
local RX = 37
local BAUD = 9600
local DURATION_S = 30
local POLL_INTERVAL_MS = 1000

local g
local bus

local function cleanup()
    if g then pcall(function() g:close() end); g = nil end
end

local function run()
    -- 打开 GPS 电源 (TCA9555 P0-0, 高有效)
    -- ponytail: 直接用 i2c 操作 TCA9555, 地址 0x20, 输出端口寄存器 0x02
    local i2c_bus = i2c.wrap(1)
    local expander = i2c_bus:device(0x20)

    -- 读当前输出端口 0x02, 置位 P0-0
    local cur = expander:read(1, 0x02)
    local cur_val = string.byte(cur, 1) or 0
    expander:write_byte(cur_val | 0x01, 0x02)
    print(string.format("[gps] GPS power ON (P0-0: 0x%02X -> 0x%02X)", cur_val, cur_val | 0x01))

    delay.delay_ms(500) -- GPS 模组上电稳定

    -- 打开 GPS UART
    g = gps.new({ port = PORT, tx = TX, rx = RX, baud = BAUD })
    print(string.format("[gps] UART%d tx=%d rx=%d baud=%d opened", PORT, TX, RX, BAUD))

    -- 写日志到文件
    local log_path = storage.join_path(storage.get_root_dir(), "inbox", "gps_test.log")
    local f = io.open(log_path, "w")
    if f then f:write(string.format("[gps] Test started, duration=%ds\n", DURATION_S)) end

    local start_s = os.time()
    while os.time() - start_s < DURATION_S do
        local n = g:poll()
        local s = g:get_snapshot()
        local line = string.format(
            "[gps] fix=%s lat=%.6f lon=%.6f alt=%.1fm spd=%.1fkm/h sats=%d/%d hdop=%.1f time=%s date=%s sent=%d bytes=%d",
            s.fix_valid and "YES" or "NO",
            s.latitude_deg, s.longitude_deg, s.altitude_m, s.speed_kmh,
            s.satellites_used, s.satellites_view, s.hdop,
            s.utc_time, s.utc_date,
            s.sentence_count, s.bytes_received)
        print(line)
        if f then f:write(line .. "\n") end
        delay.delay_ms(POLL_INTERVAL_MS)
    end

    if f then f:close() end
    print("[gps] Test complete, log at " .. log_path)

    -- 关闭 GPS 电源
    cur = expander:read(1, 0x02)
    cur_val = string.byte(cur, 1) or 0
    expander:write_byte(cur_val & ~0x01, 0x02)
    print("[gps] GPS power OFF")
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
