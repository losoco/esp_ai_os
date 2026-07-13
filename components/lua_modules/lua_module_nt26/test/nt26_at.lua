-- nt26_at.lua — NT26 4G modem AT command test
-- Tests basic AT communication, signal strength, IMEI, ICCID queries.
-- Usage: lua --run --path /system/scripts/builtin/test/nt26_at.lua

local nt26 = require("lib_nt26")
local delay = require("delay")

local a = type(args) == "table" and args or {}
local function int_arg(k, default)
    local v = a[k]
    if type(v) == "number" then return math.floor(v) end
    return default
end

local PORT = int_arg("port", 2)
local TX = int_arg("tx", 28)
local RX = int_arg("rx", 29)
local BAUD = int_arg("baud", 2000000)

local m

local function cleanup()
    if m then pcall(function() m:close() end); m = nil end
end

local function run()
    print(string.format("[nt26] Opening UART%d tx=%d rx=%d baud=%d", PORT, TX, RX, BAUD))
    m = nt26.new({ port = PORT, tx = TX, rx = RX, baud = BAUD })

    -- Test 1: basic AT
    print("[nt26] Test 1: AT")
    local alive = m:is_alive()
    print(string.format("[nt26] Modem alive: %s", alive and "YES" or "NO"))

    if not alive then
        print("[nt26] Modem not responding, trying hardware reset...")
        -- ponytail: skip reset if no expander; user must provide it via args
        if a.expander then
            m._expander = a.expander
            m._reset_pin = int_arg("reset_pin", 7)
            m:reset()
            alive = m:is_alive()
            print(string.format("[nt26] After reset: %s", alive and "YES" or "NO"))
        end
    end

    if not alive then
        print("[nt26] ABORT: modem unreachable")
        return
    end

    -- Test 2: Signal strength
    print("[nt26] Test 2: Signal Strength")
    local csq = m:get_signal_strength()
    print(string.format("[nt26] CSQ=%s", csq or "N/A"))

    -- Test 3: IMEI
    print("[nt26] Test 3: IMEI")
    local imei = m:get_imei()
    print(string.format("[nt26] IMEI=%s", imei or "N/A"))

    -- Test 4: ICCID
    print("[nt26] Test 4: ICCID")
    local iccid = m:get_iccid()
    print(string.format("[nt26] ICCID=%s", iccid or "N/A"))

    -- Test 5: Network status
    print("[nt26] Test 5: Network Registration")
    local stat, act = m:get_network_status()
    local stat_names = { [0]="not_registered", [1]="registered_home", [2]="searching", [3]="denied", [5]="registered_roaming" }
    local act_names = { [7]="LTE", [9]="LTE-M" }
    print(string.format("[nt26] CEREG stat=%d(%s) act=%d(%s)",
        stat or -1, stat_names[stat or -1] or "unknown",
        act or -1, act_names[act or -1] or "unknown"))

    -- Test 6: Cell info
    print("[nt26] Test 6: Cell Info")
    local cell = m:get_cell_info()
    if cell then
        print(string.format("[nt26] Cell: tac=%d ci=%d csq=%d", cell.tac or 0, cell.ci or 0, cell.csq or 0))
    else
        print("[nt26] Cell info: N/A")
    end

    print("[nt26] Test complete")
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then error(err) end
