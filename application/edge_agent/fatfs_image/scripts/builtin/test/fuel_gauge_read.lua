-- Quick fuel gauge test for BQ27220
local fuel_gauge = require("lib_fuel_gauge")
local gauge = fuel_gauge.new({port = 1, sda = 7, scl = 8, addr = 0x55})
local s = gauge:read()
print(string.format("GAUGE: %dmV, %dmA, SOC=%d%%", s.voltage_mv, s.current_ma or 0, s.soc))
gauge:close()
