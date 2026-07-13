-- nt26_device_test.lua - NT26 4G 模组设备端测试脚本
-- 通过 IO 扩展器复位 4G 模组，发送 AT 命令，输出结果到文件。
local nt26 = require("lib_nt26")
local delay = require("delay")
local i2c = require("i2c")
local storage = require("storage")

local PORT = 1
local TX = 28
local RX = 29
local BAUD = 2000000

local m

local function cleanup()
    if m then pcall(function() m:close() end); m = nil end
end

local function run()
    -- IO 扩展器 (TCA9555 0x20)
    local i2c_bus = i2c.wrap(1)
    local expander = i2c_bus:device(0x20)

    -- 复位 4G 模组: P0-7 (RST_4G) 低->高
    local cur = expander:read(1, 0x02)
    local cur_val = string.byte(cur, 1) or 0
    print(string.format("[nt26] Reset 4G modem (P0-7: 0x%02X)", cur_val))
    expander:write_byte(cur_val & ~0x80, 0x02) -- RST low
    delay.delay_ms(200)
    expander:write_byte(cur_val | 0x80, 0x02)  -- RST high (release)
    delay.delay_ms(2000) -- 模组启动

    -- 打开 UART
    m = nt26.new({ port = PORT, tx = TX, rx = RX, baud = BAUD })
    print(string.format("[nt26] UART%d tx=%d rx=%d baud=%d opened", PORT, TX, RX, BAUD))

    -- 日志文件
    local log_path = storage.join_path(storage.get_root_dir(), "inbox", "nt26_test.log")
    local f = io.open(log_path, "w")
    if f then f:write("[nt26] Test started\n") end

    local function log(msg)
        print(msg)
        if f then f:write(msg .. "\n") end
    end

    -- Test 1: AT
    log("[nt26] Test 1: AT")
    local alive = m:is_alive()
    log(string.format("[nt26] Modem alive: %s", alive and "YES" or "NO"))

    if not alive then
        log("[nt26] ABORT: modem unreachable")
        if f then f:close() end
        return
    end

    -- Test 2: Signal
    log("[nt26] Test 2: Signal Strength")
    local csq = m:get_signal_strength()
    log(string.format("[nt26] CSQ=%s", csq ~= nil and tostring(csq) or "N/A"))

    -- Test 3: IMEI
    log("[nt26] Test 3: IMEI")
    local imei = m:get_imei()
    log(string.format("[nt26] IMEI=%s", imei or "N/A"))

    -- Test 4: ICCID
    log("[nt26] Test 4: ICCID")
    local iccid = m:get_iccid()
    log(string.format("[nt26] ICCID=%s", iccid or "N/A"))

    -- Test 5: Network status
    log("[nt26] Test 5: Network Registration")
    local stat, act = m:get_network_status()
    log(string.format("[nt26] CEREG stat=%s act=%s",
        stat ~= nil and tostring(stat) or "N/A",
        act ~= nil and tostring(act) or "N/A"))

    -- Test 6: Cell info
    log("[nt26] Test 6: Cell Info")
    local cell = m:get_cell_info()
    if cell then
        log(string.format("[nt26] Cell: tac=%s ci=%s csq=%s",
            tostring(cell.tac), tostring(cell.ci), tostring(cell.csq)))
    else
        log("[nt26] Cell info: N/A")
    end

    if f then f:close() end
    log("[nt26] Test complete, log at " .. log_path)
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
