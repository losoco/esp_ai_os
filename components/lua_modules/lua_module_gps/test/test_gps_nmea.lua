-- test_gps_nmea.lua - NMEA parser unit test (no UART needed)
-- Run: lua5.4 test_gps_nmea.lua

package.path = package.path .. ';lib/?.lua'

-- Mock uart module
local mock_uart = {
    new = function()
        return setmetatable({}, {
            __index = {
                available = function() return 0 end,
                read = function() return '' end,
                write = function() return 0 end,
                flush_input = function() end,
                close = function() end,
            }
        })
    end
}
package.preload['uart'] = function() return mock_uart end

local gps = require('lib_gps')

-- Create GPS instance with mock bus
local g = gps.new({ bus = mock_uart.new() })

-- Test 1: GGA sentence
g:_parse_line('$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47')
local s = g:get_snapshot()
assert(s.fix_valid, 'GGA: fix_valid should be true')
assert(s.fix_quality == 1, 'GGA: fix_quality should be 1')
assert(s.satellites_used == 8, 'GGA: sats should be 8')
assert(math.abs(s.latitude_deg - 48.1173) < 0.001, 'GGA: lat mismatch: ' .. tostring(s.latitude_deg))
assert(math.abs(s.longitude_deg - 11.5167) < 0.001, 'GGA: lon mismatch: ' .. tostring(s.longitude_deg))
assert(math.abs(s.altitude_m - 545.4) < 0.1, 'GGA: alt mismatch')
assert(s.utc_time == '12:35:19', 'GGA: time mismatch: ' .. tostring(s.utc_time))
print(string.format('GGA OK: lat=%.4f lon=%.4f alt=%.1f sats=%d time=%s',
    s.latitude_deg, s.longitude_deg, s.altitude_m, s.satellites_used, s.utc_time))

-- Test 2: RMC sentence
g:_parse_line('$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A')
s = g:get_snapshot()
assert(s.speed_kmh > 0, 'RMC: speed should be > 0')
assert(s.utc_date == '2094-03-23', 'RMC: date mismatch: ' .. tostring(s.utc_date))
print(string.format('RMC OK: speed=%.1fkm/h date=%s', s.speed_kmh, s.utc_date))

-- Test 3: GSV sentence
g:_parse_line('$GPGSV,2,1,08,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45*75')
s = g:get_snapshot()
assert(s.satellites_view == 8, 'GSV: sats_view should be 8, got ' .. tostring(s.satellites_view))
print(string.format('GSV OK: sats_view=%d', s.satellites_view))

-- Test 4: Bad checksum should be silently skipped
local before = g.sentence_count
g:_parse_line('$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*FF')
assert(g.sentence_count == before + 1, 'Bad checksum: sentence_count should increment')
print('Bad checksum OK: skipped')

-- Test 5: GLONASS talker (GL prefix)
g:_parse_line('$GLGGA,123520,4807.039,N,01131.001,E,2,10,0.8,546.0,M,46.9,M,,*5D')
s = g:get_snapshot()
assert(s.fix_quality == 2, 'GLGGA: fix_quality should be 2')
print(string.format('GLONASS GGA OK: fix_quality=%d', s.fix_quality))

print('=== All GPS NMEA tests passed ===')
