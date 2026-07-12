-- lib_nu1680.lua -- NU1680 无线充电芯片 Lua 驱动
-- I2C 地址 0x60, 过流保护电流限制 + 温度保护配置
-- 参考: MetalioClaw4 metalio-claw-4.cc Wxcho class

local i2c = require("i2c")

local M = {}

-- 寄存器
local REG_ILIM_SET = 0x1E  -- MTP_ILIM_SET: 过流保护电流限制 [2:0]
local REG_THERM     = 0x15  -- 温度保护 (0x00 = 关闭)

-- 常量
local DEFAULT_ADDR    = 0x60
local DEFAULT_FREQ_HZ = 400000

-- 电流限值查找表 [2:0] -> mA
local CURRENT_TABLE = {
    [0] = 1400,
    [1] = 1650,
    [2] = 1100,
    [3] = 740,
    [4] = 365,
    [5] = 450,
    [6] = 290,
    [7] = 215,
}

local mt = {}
mt.__index = mt

--- 构造函数
--- opts 支持: port, sda, scl, freq_hz, addr, bus
function M.new(opts)
    opts = type(opts) == "table" and opts or {}
    local bus
    local owns_bus = false

    if opts.bus ~= nil then
        bus = opts.bus
    else
        bus = i2c.new(
            assert(opts.port, "nu1680.new: missing 'port'"),
            assert(opts.sda, "nu1680.new: missing 'sda'"),
            assert(opts.scl, "nu1680.new: missing 'scl'"),
            opts.freq_hz or opts.frequency or DEFAULT_FREQ_HZ
        )
        owns_bus = true
    end

    local dev = bus:device(opts.addr or DEFAULT_ADDR, 0)

    local self = setmetatable({
        _bus = bus,
        _dev = dev,
        _owns_bus = owns_bus,
        _addr = opts.addr or DEFAULT_ADDR,
    }, mt)

    print(string.format("[nu1680] initialized at addr=0x%02X", self._addr))
    return self
end

--- 写寄存器
function mt:_write_reg(reg, value)
    self._dev:write_byte(value, reg)
end

--- 读单字节
function mt:_read_reg(reg)
    local data = self._dev:read(1, reg)
    return string.byte(data, 1)
end

--- 配置无线充电参数（标准初始化）
--- 调用后设置 1.4A 电流限制并关闭温度保护
function mt:configure()
    -- 设置过流保护电流限制为 1.4A
    self:_write_reg(REG_ILIM_SET, 0x00)
    print("[nu1680] write 0x1E reg: 0x00 (1.4A)")
    -- 关闭温度保护
    self:_write_reg(REG_THERM, 0x00)
    print("[nu1680] write 0x15 reg: 0x00 (thermal protection disabled)")
end

--- 设置过流保护电流限制
--- @param ilim_code number [0-7] 电流限制码
---   0: 1.4A, 1: 1.65A, 2: 1.1A, 3: 0.74A,
---   4: 0.365A, 5: 0.45A, 6: 0.29A, 7: 0.215A
function mt:set_current_limit(ilim_code)
    if ilim_code < 0 or ilim_code > 7 then
        print(string.format("[nu1680] ERROR: ilim_code must be 0-7, got %d", ilim_code))
        return
    end
    local current_val = self:_read_reg(REG_ILIM_SET)
    -- 保留高 5 位，修改低 3 位
    current_val = (current_val & 0xF8) | (ilim_code & 0x07)
    self:_write_reg(REG_ILIM_SET, current_val)
    local ma = CURRENT_TABLE[ilim_code] or 0
    print(string.format("[nu1680] set current limit: %dmA (ilim=%d)", ma, ilim_code))
end

--- 读取过流保护电流限制设置 (mA)
function mt:get_current_limit()
    local val = self:_read_reg(REG_ILIM_SET) & 0x07
    return CURRENT_TABLE[val] or 0
end

--- 读取寄存器 0x1E 原始值
function mt:read_ilim_reg()
    local val = self:_read_reg(REG_ILIM_SET)
    print(string.format("[nu1680] read 0x1E reg: 0x%02X", val))
    return val
end

--- 读取寄存器 0x15 原始值
function mt:read_therm_reg()
    local val = self:_read_reg(REG_THERM)
    print(string.format("[nu1680] read 0x15 reg: 0x%02X", val))
    return val
end

--- 开启温度保护（写入非零值）
function mt:enable_thermal_protection()
    self:_write_reg(REG_THERM, 0xFF)
    print("[nu1680] thermal protection enabled")
end

--- 关闭温度保护
function mt:disable_thermal_protection()
    self:_write_reg(REG_THERM, 0x00)
    print("[nu1680] thermal protection disabled")
end

function mt:close()
    if self._dev then
        self._dev:close()
        self._dev = nil
    end
    if self._owns_bus and self._bus then
        self._bus:close()
        self._bus = nil
    end
end

function mt:__gc()
    pcall(function() self:close() end)
end

return M
