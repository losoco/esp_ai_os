-- lib_gps.lua — NMEA-0183 GPS parser (UART-based)
-- Supports GGA (position), RMC (speed/date), GSV (satellites) from any talker (GP/GL/GA/BD/GN).
-- Polling model: call poll() periodically to drain UART and update snapshot.

local uart = require("uart")

local M = {}

-- NMEA checksum: XOR bytes between '$' and '*', compare with hex after '*'
local function checksum_ok(line)
    local star = line:find("*", 2, true)
    if not star or #line - star < 2 then return false end
    local expected = tonumber(line:sub(star + 1, star + 2), 16)
    if not expected then return false end
    local xor_val = 0
    for i = 2, star - 1 do
        xor_val = xor_val ~ line:byte(i)
    end
    return xor_val == expected
end

-- Parse coordinate "DDMM.mmmm" or "DDDMM.mmmm" to decimal degrees
local function parse_coord(raw, hemi, deg_digits)
    if not raw or #raw == 0 then return 0.0 end
    local deg = tonumber(raw:sub(1, deg_digits)) or 0
    local min = tonumber(raw:sub(deg_digits + 1)) or 0
    local val = deg + min / 60.0
    if hemi == "S" or hemi == "W" then val = -val end
    return val
end

-- Snap time from "HHMMSS.sss"
local function snap_time(utc)
    if not utc or #utc < 6 then return nil end
    return string.format("%s:%s:%s", utc:sub(1, 2), utc:sub(3, 4), utc:sub(5, 6))
end

-- Snap date from "DDMMYY"
local function snap_date(dmy)
    if not dmy or #dmy < 6 then return nil end
    return string.format("20%s-%s-%s", dmy:sub(5, 6), dmy:sub(3, 4), dmy:sub(1, 2))
end

local mt = {}
mt.__index = mt

--- Create GPS parser
--- @param opts table {port, tx, rx, baud, bus}
function M.new(opts)
    opts = type(opts) == "table" and opts or {}
    local bus
    local owns_bus = false

    if opts.bus then
        bus = opts.bus
    else
        bus = uart.new(
            assert(opts.port, "gps.new: missing 'port'"),
            assert(opts.tx, "gps.new: missing 'tx'"),
            assert(opts.rx, "gps.new: missing 'rx'"),
            opts.baud or 9600
        )
        owns_bus = true
    end

    local self = setmetatable({
        _bus = bus,
        _owns_bus = owns_bus,
        -- Snapshot state
        fix_valid = false, fix_quality = 0,
        latitude_deg = 0, longitude_deg = 0, altitude_m = 0,
        speed_kmh = 0,
        satellites_used = 0, satellites_view = 0, hdop = 0,
        utc_time = "", utc_date = "",
        sentence_count = 0, bytes_received = 0,
        -- Internal
        _line_buf = "",
        _sats_per_talker = {}, -- {GP=0, GL=0, GA=0, BD=0, GN=0}
    }, mt)

    return self
end

--- Parse a single NMEA line
function mt:_parse_line(line)
    self.sentence_count = self.sentence_count + 1

    if #line < 6 or line:sub(1, 1) ~= "$" then return end
    if not checksum_ok(line) then return end

    -- Strip checksum for field splitting
    local body = line:sub(2, line:find("*", 2, true) - 1)
    -- Split by comma, preserving empty fields (gmatch [^,]+ skips them)
    local fields = {}
    for f in (body .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
    if #fields == 0 then return end

    local talker_id = fields[1]
    if #talker_id < 5 then return end  -- "GPGGA" = 5 chars (no $ prefix)
    local talker = talker_id:sub(1, 2)
    local stype = talker_id:sub(3) -- "GGA", "RMC", "GSV", ... (no $ prefix)

    if stype == "GGA" and #fields >= 11 then
        self:_handle_gga(fields, talker)
    elseif stype == "RMC" and #fields >= 11 then
        self:_handle_rmc(fields, talker)
    elseif stype == "GSV" and #fields >= 4 then
        self:_handle_gsv(fields, talker)
    end
end

function mt:_handle_gga(fields, talker)
    -- fields[1]=talker, [2]=utc, [3]=lat, [4]=N/S, [5]=lon, [6]=E/W,
    -- [7]=fix_q, [8]=sats, [9]=hdop, [10]=alt, [11]=geoid...
    local fix_q = tonumber(fields[7]) or 0
    self.fix_quality = fix_q
    self.satellites_used = tonumber(fields[8]) or 0
    self.hdop = tonumber(fields[9]) or 0
    self.altitude_m = tonumber(fields[10]) or 0
    self.utc_time = snap_time(fields[2]) or self.utc_time

    if fix_q > 0 then
        self.fix_valid = true
        self.latitude_deg = parse_coord(fields[3], fields[4], 2)
        self.longitude_deg = parse_coord(fields[5], fields[6], 3)
    end
end

function mt:_handle_rmc(fields, talker)
    -- fields[1]=talker, [2]=utc, [3]=status, [4]=lat, [5]=N/S, [6]=lon,
    -- [7]=E/W, [8]=knots, [9]=track, [10]=date, ...
    local active = fields[3] ~= nil and fields[3] == "A"
    local knots = tonumber(fields[8]) or 0
    self.speed_kmh = knots * 1.852
    self.utc_time = snap_time(fields[2]) or self.utc_time
    self.utc_date = snap_date(fields[10]) or self.utc_date

    if active then
        self.fix_valid = true
        self.latitude_deg = parse_coord(fields[4], fields[5], 2)
        self.longitude_deg = parse_coord(fields[6], fields[7], 3)
    end
end

function mt:_handle_gsv(fields, talker)
    if #fields < 4 then return end
    -- fields[1]=talker, [2]=total_msgs, [3]=msg_num, [4]=sats_in_view
    local sats_view = tonumber(fields[4]) or 0
    if sats_view < 0 or sats_view > 64 then return end

    self._sats_per_talker[talker] = sats_view
    local total = 0
    for _, n in pairs(self._sats_per_talker) do total = total + n end
    self.satellites_view = math.min(total, 255)
end

--- Poll UART for incoming NMEA data. Call this periodically.
--- Returns number of bytes processed since last poll (0 = no data).
function mt:poll()
    if not self._bus then return 0 end

    local processed = 0
    while true do
        local avail = self._bus:available()
        if avail == 0 then break end

        local chunk = self._bus:read(math.min(avail, 256), 0)
        if not chunk or #chunk == 0 then break end

        self.bytes_received = self.bytes_received + #chunk
        self._line_buf = self._line_buf .. chunk

        -- Extract complete lines
        while true do
            local cr = self._line_buf:find("\r", 1, true)
            local lf = self._line_buf:find("\n", 1, true)
            local eol
            if cr and lf then
                eol = math.min(cr, lf)
            else
                eol = cr or lf
            end
            if not eol then break end

            local line = self._line_buf:sub(1, eol - 1)
            self._line_buf = self._line_buf:sub(eol + 1)
            -- skip leading \n if we split on \r from a \r\n pair
            if self._line_buf:sub(1, 1) == "\n" then
                self._line_buf = self._line_buf:sub(2)
            end

            if #line > 0 then
                local ok, err = pcall(self._parse_line, self, line)
                if not ok then
                    -- ponytail: silently skip corrupted lines
                end
                processed = processed + 1
            end
        end

        -- ponytail: prevent runaway if data floods in
        if processed > 100 then break end
    end
    return processed
end

--- Get current GPS snapshot
function mt:get_snapshot()
    return {
        fix_valid       = self.fix_valid,
        fix_quality     = self.fix_quality,
        latitude_deg    = self.latitude_deg,
        longitude_deg   = self.longitude_deg,
        altitude_m      = self.altitude_m,
        speed_kmh       = self.speed_kmh,
        satellites_used = self.satellites_used,
        satellites_view = self.satellites_view,
        hdop            = self.hdop,
        utc_time        = self.utc_time,
        utc_date        = self.utc_date,
        sentence_count  = self.sentence_count,
        bytes_received  = self.bytes_received,
    }
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
