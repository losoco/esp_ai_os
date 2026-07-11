-- lib_sc7a20h.lua — SC7A20H / LIS2DH12 加速度计 Lua 驱动
-- I2C 地址 0x19, 兼容 LIS2DH12 寄存器映射
-- 参考: MetalioClaw4 sc7a20h_test.cc / level_screen.cc

local i2c = require("i2c")

local M = {}

-- 寄存器
local REG_WHO_AM_I   = 0x0F
local REG_CTRL_REG1  = 0x20
local REG_CTRL_REG4  = 0x23
local REG_OUT_X_L    = 0x28   -- 多字节自增读起始地址

-- 常量
local DEFAULT_ADDR    = 0x19
local DEFAULT_FREQ_HZ = 400000
local AUTO_INC_MASK   = 0x80   -- 多字节读需置 MSB=1
local MG_PER_LSB      = 1.0    -- ±2g 高分辨率模式, 12-bit 右对齐
local VALID_WHO_AM_I  = { [0x11] = true, [0x32] = true, [0x33] = true, [0x44] = true }

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
            assert(opts.port, "sc7a20h.new: missing 'port'"),
            assert(opts.sda, "sc7a20h.new: missing 'sda'"),
            assert(opts.scl, "sc7a20h.new: missing 'scl'"),
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
        _ox = 0, _oy = 0, _oz = 0,  -- 零点校准偏移
    }, mt)

    -- 验证 WHO_AM_I
    local who = self:whoami()
    if not VALID_WHO_AM_I[who] then
        print(string.format("[sc7a20h] WARN: WHO_AM_I=0x%02X (expected 0x11/0x32/0x33/0x44), best-effort continue", who))
    else
        print(string.format("[sc7a20h] detected WHO_AM_I=0x%02X at addr=0x%02X", who, self._addr))
    end

    self:_configure()
    return self
end

--- 写寄存器
function mt:_write_reg(reg, value)
    self._dev:write(reg, string.char(value))
end

--- 读单字节
function mt:_read_reg(reg)
    local data = self._dev:read(1, reg)
    return string.byte(data, 1)
end

--- 多字节读
function mt:_read_regs(reg, len)
    return self._dev:read(len, reg + AUTO_INC_MASK)
end

--- 初始化寄存器
function mt:_configure()
    -- CTRL_REG1 = 0x57: ODR=100Hz, X/Y/Z enable
    self:_write_reg(REG_CTRL_REG1, 0x57)
    -- CTRL_REG4 = 0x88: BDU=1, ±2g, HR mode
    self:_write_reg(REG_CTRL_REG4, 0x88)
end

--- 读取 WHO_AM_I
function mt:whoami()
    return self:_read_reg(REG_WHO_AM_I)
end

--- 读取原始加速度计值（mg）
--- 返回 ax, ay, az（单位: mg）
function mt:read_mg()
    local data = self._read_regs(REG_OUT_X_L, 6)
    local lo = string.byte(data, 1)
    local hi = string.byte(data, 2)
    local rx = (hi << 8) | lo
    lo = string.byte(data, 3)
    hi = string.byte(data, 4)
    local ry = (hi << 8) | lo
    lo = string.byte(data, 5)
    hi = string.byte(data, 6)
    local rz = (hi << 8) | lo

    -- 12-bit 有符号值右对齐, 需右移 4 位
    local function to_s16(v)
        if v >= 0x8000 then v = v - 0x10000 end
        return v
    end

    local ax = (to_s16(rx) >> 4) * MG_PER_LSB
    local ay = (to_s16(ry) >> 4) * MG_PER_LSB
    local az = (to_s16(rz) >> 4) * MG_PER_LSB

    -- 零点偏移校准
    ax = ax - self._ox
    ay = ay - self._oy
    az = az - self._oz

    return ax, ay, az
end

--- 读取加速度（g 单位）
function mt:read_g()
    local ax, ay, az = self:read_mg()
    return ax / 1000.0, ay / 1000.0, az / 1000.0
end

--- 设置零点偏移校准值（mg）
function mt:set_offset(ox, oy, oz)
    self._ox = ox or 0
    self._oy = oy or 0
    self._oz = oz or 0
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
