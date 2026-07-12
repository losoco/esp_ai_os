-- nu1680_read.lua -- NU1680 无线充电芯片测试脚本
-- 用法: lua --run --path /system/lib/lib_nu1680_test.lua
--       或 esp-claw-cli run lib_nu1680_test.lua

local nu1680 = require("lib_nu1680")

print("=== NU1680 Wireless Charger Test ===")

local dev = nu1680.new({ port = 1, sda = 7, scl = 8 })

-- 1. 读取寄存器
print("\n[1] Read registers before configure:")
dev:read_ilim_reg()
dev:read_therm_reg()

-- 2. 标准初始化
print("\n[2] Standard configure (1.4A, thermal protection off):")
dev:configure()

-- 3. 验证
print("\n[3] Verify after configure:")
dev:read_ilim_reg()
dev:read_therm_reg()

-- 4. 读取当前限制
local limit = dev:get_current_limit()
print(string.format("\n[4] Current limit: %dmA", limit))

-- 5. 切换电流限制
print("\n[5] Switch to 1.1A (ilim=2):")
dev:set_current_limit(2)
limit = dev:get_current_limit()
print(string.format("    Current limit now: %dmA", limit))

-- 6. 恢复默认
print("\n[6] Restore to 1.4A:")
dev:set_current_limit(0)

dev:close()
print("\n=== Test Done ===")
