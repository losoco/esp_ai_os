-- lib_nt26.lua — NT26 / ML307 4G LTE 模组 AT 命令接口
-- 通过 UART 发送 AT 命令，支持信号强度、IMEI/ICCID 查询、基站定位等。
-- 复位引脚通过 TCA9555 P0-7 控制（高=释放）。
-- ponytail: 仅提供 AT 命令 + 基础查询，完整 PPP/网络栈留给 C 层。

local uart = require("uart")
local delay = require("delay")

local M = {}

local DEFAULT_BAUD = 2000000

local mt = {}
mt.__index = mt

--- Create NT26 interface
--- @param opts {port, tx, rx, baud, expander}
---   expander: optional TCA9555 handle for reset control (P0-7)
function M.new(opts)
    opts = type(opts) == "table" and opts or {}
    local bus
    local owns_bus = false

    if opts.bus then
        bus = opts.bus
    else
        bus = uart.new(
            assert(opts.port, "nt26.new: missing 'port'"),
            assert(opts.tx, "nt26.new: missing 'tx'"),
            assert(opts.rx, "nt26.new: missing 'rx'"),
            opts.baud or DEFAULT_BAUD
        )
        owns_bus = true
    end

    local self = setmetatable({
        _bus = bus,
        _owns_bus = owns_bus,
        _expander = opts.expander, -- IO expander for reset
        _reset_pin = opts.reset_pin or 7, -- P0-7
    }, mt)

    bus:flush_input()
    return self
end

--- Hardware reset: toggle reset pin low -> delay -> high
function mt:reset()
    if not self._expander then
        print("[nt26] WARN: no IO expander, cannot hardware reset")
        return false
    end
    -- ponytail: assume P0-7 is reset, active low pulse
    self._expander:write_pin(self._reset_pin, 0)
    delay.delay_ms(200)
    self._expander:write_pin(self._reset_pin, 1)
    delay.delay_ms(500) -- module boot time
    self._bus:flush_input()
    return true
end

--- Send AT command, collect response lines until OK/ERROR or timeout.
--- @param cmd string AT command (e.g. "AT+CSQ")
--- @param timeout_ms number timeout in ms (default 2000)
--- @return string all response text
function mt:send_at(cmd, timeout_ms)
    timeout_ms = timeout_ms or 2000
    if not self._bus then return nil end

    self._bus:flush_input()
    local sent = self._bus:write(cmd .. "\r\n")
    if not sent or sent == 0 then return nil end

    local deadline = os.time() * 1000 + timeout_ms -- approximation; fine for AT cmds
    local response = ""
    local elapsed = 0

    while elapsed < timeout_ms do
        local avail = self._bus:available()
        if avail > 0 then
            local chunk = self._bus:read(math.min(avail, 256), 0)
            if chunk and #chunk > 0 then
                response = response .. chunk
                -- ponytail: check for termination keywords
                if response:find("OK\r\n", 1, true) or response:find("ERROR\r\n", 1, true) then
                    break
                end
            end
        end
        delay.delay_ms(20)
        elapsed = elapsed + 20
    end
    return response
end

--- Get signal strength (CSQ)
--- @return number|nil csq value 0-31, or nil if failed
function mt:get_signal_strength()
    local resp = self:send_at("AT+CSQ", 1000)
    if not resp then return nil end
    -- Parse "+CSQ: <rssi>,<ber>"
    local rssi = resp:match("+CSQ:%s*(%d+)")
    if rssi then
        local v = tonumber(rssi)
        return (v == 99) and nil or v -- 99 = no signal
    end
    return nil
end

--- Get IMEI
--- @return string|nil
function mt:get_imei()
    local resp = self:send_at("AT+CGSN", 1000)
    if not resp then return nil end
    -- Response: "<imei>\r\nOK"
    for line in resp:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and #trimmed == 15 and tonumber(trimmed) then
            return trimmed
        end
    end
    return nil
end

--- Get ICCID (SIM card ID)
--- @return string|nil
function mt:get_iccid()
    local resp = self:send_at("AT+CCID", 2000)
    if not resp then return nil end
    -- Response: "+CCID: <iccid>" or just "<iccid>\r\nOK"
    local iccid = resp:match("+CCID:%s*(%d+)")
    if not iccid then
        for line in resp:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and #trimmed >= 19 and trimmed:match("^%d+$") then
                return trimmed
            end
        end
    end
    return iccid
end

--- Query network registration status
--- @return number|nil stat (1=registered home, 5=registered roaming, other=not registered)
--- @return number|nil act (access technology: 7=LTE, 9=LTE-M, ...)
function mt:get_network_status()
    local resp = self:send_at("AT+CEREG?", 1000)
    if not resp then return nil end
    -- "+CEREG: <n>,<stat>[,<tac>,<ci>,<act>]"
    local stat, act = resp:match("+CEREG:%s*%d+,(%d+)%s*,.-,.-,(%d*)")
    if stat then
        return tonumber(stat), (act and #act > 0) and tonumber(act) or nil
    end
    return nil
end

--- Cell location (AT+ECBCINFO)
--- @return table|nil {tac, ci, csq}
function mt:get_cell_info()
    local resp = self:send_at("AT+ECBCINFO", 3000)
    if not resp then return nil end
    -- Parse the first cell entry
    -- Response format varies; extract numeric fields
    local nums = {}
    for n in resp:gmatch("(%d+)") do nums[#nums + 1] = tonumber(n) end
    if #nums >= 3 then
        return { tac = nums[1], ci = nums[2], csq = nums[3] }
    end
    return nil
end

--- Make a call (ATD). Returns immediately; use ATH to hang up.
--- @param number string phone number to dial
function mt:dial(number)
    return self:send_at("ATD" .. number .. ";", 2000)
end

--- Hang up call
function mt:hang_up()
    return self:send_at("ATH", 1000)
end

--- Test if modem is responsive
function mt:is_alive()
    local resp = self:send_at("AT", 500)
    return resp and resp:find("OK", 1, true) ~= nil
end

function mt:close()
    if self._owns_bus and self._bus then
        self._bus:close()
        self._bus = nil
    end
end

function mt:__gc()
    pcall(function() self:close() end)
end

return M
