/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lua_driver_i2c.h"

#include <stdint.h>
#include <string.h>

#include "cap_lua.h"
#include "driver/i2c_master.h"
#include "esp_err.h"
#include "lauxlib.h"

#define LUA_DRIVER_I2C_BUS_METATABLE    "i2c.bus"
#define LUA_DRIVER_I2C_DEVICE_METATABLE "i2c.device"
#define LUA_DRIVER_I2C_DEFAULT_FREQ_HZ  400000U
#define LUA_DRIVER_I2C_SCAN_MAX         128
#define LUA_DRIVER_I2C_RW_MAX_LEN       1024

typedef struct {
    i2c_master_bus_handle_t bus;
    int port;
    bool external_owned;  /* bus was created outside (board manager) */
} lua_driver_i2c_bus_ud_t;

typedef struct {
    i2c_master_dev_handle_t dev;
    uint8_t addr;
    int bus_ref;  /* Lua registry ref to keep bus alive */
} lua_driver_i2c_device_ud_t;

static lua_driver_i2c_bus_ud_t *lua_driver_i2c_bus_get_ud(lua_State *L, int idx)
{
    lua_driver_i2c_bus_ud_t *ud = (lua_driver_i2c_bus_ud_t *)luaL_checkudata(
        L, idx, LUA_DRIVER_I2C_BUS_METATABLE);
    if (!ud || !ud->bus) {
        luaL_error(L, "i2c bus: invalid or closed handle");
    }
    return ud;
}

static lua_driver_i2c_device_ud_t *lua_driver_i2c_device_get_ud(lua_State *L, int idx)
{
    lua_driver_i2c_device_ud_t *ud = (lua_driver_i2c_device_ud_t *)luaL_checkudata(
        L, idx, LUA_DRIVER_I2C_DEVICE_METATABLE);
    if (!ud || !ud->dev) {
        luaL_error(L, "i2c device: invalid or closed handle");
    }
    return ud;
}

/* Create or reuse an I2C master bus. Returns NULL on failure, sets external_owned. */
static i2c_master_bus_handle_t i2c_bus_get_or_create(int port, int sda, int scl,
                                                     uint32_t freq, bool *external_owned)
{
    i2c_master_bus_handle_t bus = NULL;
    if (i2c_master_get_bus_handle((i2c_port_t)port, &bus) == ESP_OK) {
        *external_owned = true;
        return bus;
    }

    i2c_master_bus_config_t cfg = {
        .i2c_port = (i2c_port_t)port,
        .sda_io_num = sda,
        .scl_io_num = scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags = {
            .enable_internal_pullup = true,
        },
    };
    /* The new API only supports standard-mode and fast-mode clock config name */
    i2c_clock_source_t clk_src = I2C_CLK_SRC_DEFAULT;

    esp_err_t err = i2c_new_master_bus(&cfg, &bus);
    if (err != ESP_OK) {
        return NULL;
    }
    *external_owned = false;
    return bus;
}

static esp_err_t i2c_bus_release(lua_driver_i2c_bus_ud_t *ud)
{
    if (ud == NULL || ud->bus == NULL) {
        return ESP_OK;
    }
    if (ud->external_owned) {
        ud->bus = NULL;
        return ESP_OK;
    }
    esp_err_t err = i2c_del_master_bus(ud->bus);
    ud->bus = NULL;
    return err;
}

/* --- bus:close / __gc --- */
static int lua_driver_i2c_bus_gc(lua_State *L)
{
    lua_driver_i2c_bus_ud_t *ud = (lua_driver_i2c_bus_ud_t *)luaL_testudata(
        L, 1, LUA_DRIVER_I2C_BUS_METATABLE);
    if (ud && ud->bus) {
        (void)i2c_bus_release(ud);
    }
    return 0;
}

static int lua_driver_i2c_bus_close(lua_State *L)
{
    lua_driver_i2c_bus_ud_t *ud = lua_driver_i2c_bus_get_ud(L, 1);
    esp_err_t err = i2c_bus_release(ud);
    if (err != ESP_OK) {
        return luaL_error(L, "i2c bus close failed: %s", esp_err_to_name(err));
    }
    return 0;
}

/* --- bus:device(addr) --- */
static int lua_driver_i2c_bus_device(lua_State *L)
{
    lua_driver_i2c_bus_ud_t *bus_ud = lua_driver_i2c_bus_get_ud(L, 1);
    lua_Integer addr = luaL_checkinteger(L, 2);

    if (addr < 0 || addr > 0x7F) {
        return luaL_error(L, "i2c device address must be 0-127");
    }

    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = (uint16_t)addr,
        .scl_speed_hz = LUA_DRIVER_I2C_DEFAULT_FREQ_HZ,
    };
    i2c_master_dev_handle_t dev = NULL;
    esp_err_t err = i2c_master_bus_add_device(bus_ud->bus, &dev_cfg, &dev);
    if (err != ESP_OK) {
        return luaL_error(L, "i2c bus add device failed: %s", esp_err_to_name(err));
    }

    lua_driver_i2c_device_ud_t *dev_ud =
        (lua_driver_i2c_device_ud_t *)lua_newuserdata(L, sizeof(*dev_ud));
    dev_ud->dev = dev;
    dev_ud->addr = (uint8_t)addr;

    /* Hold a reference to the bus so it doesn't get GC'd before devices */
    lua_pushvalue(L, 1);
    dev_ud->bus_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    luaL_getmetatable(L, LUA_DRIVER_I2C_DEVICE_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

/* --- device:close / __gc --- */
static int lua_driver_i2c_device_close(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = lua_driver_i2c_device_get_ud(L, 1);
    if (ud->dev) {
        i2c_master_bus_rm_device(ud->dev);
        ud->dev = NULL;
    }
    if (ud->bus_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, ud->bus_ref);
        ud->bus_ref = LUA_NOREF;
    }
    return 0;
}

static int lua_driver_i2c_device_gc(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = (lua_driver_i2c_device_ud_t *)luaL_testudata(
        L, 1, LUA_DRIVER_I2C_DEVICE_METATABLE);
    if (ud && ud->dev) {
        i2c_master_bus_rm_device(ud->dev);
        ud->dev = NULL;
    }
    return 0;
}

static int lua_driver_i2c_device_address(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = lua_driver_i2c_device_get_ud(L, 1);
    lua_pushinteger(L, ud->addr);
    return 1;
}

/* --- device:write_byte(value, mem_addr) --- */
static int lua_driver_i2c_device_write_byte(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = lua_driver_i2c_device_get_ud(L, 1);
    lua_Integer value = luaL_checkinteger(L, 2);

    if (value < 0 || value > 0xFF) {
        return luaL_error(L, "i2c write_byte value must be 0-255");
    }

    uint8_t buf[2];
    size_t len;

    if (lua_isnoneornil(L, 3)) {
        /* No register address — raw write */
        buf[0] = (uint8_t)value;
        len = 1;
    } else {
        lua_Integer mem_addr = luaL_checkinteger(L, 3);
        if (mem_addr < 0 || mem_addr > 0xFF) {
            return luaL_error(L, "mem_addr must be in range 0-255");
        }
        buf[0] = (uint8_t)mem_addr;
        buf[1] = (uint8_t)value;
        len = 2;
    }

    esp_err_t err = i2c_master_transmit(ud->dev, buf, len, -1);
    if (err != ESP_OK) {
        return luaL_error(L, "i2c write_byte failed: %s", esp_err_to_name(err));
    }
    return 0;
}

/* --- device:write(data, mem_addr) --- */
static int lua_driver_i2c_device_write(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = lua_driver_i2c_device_get_ud(L, 1);

    uint8_t mem_addr_buf = 0;
    bool has_mem_addr = !lua_isnoneornil(L, 3);
    if (has_mem_addr) {
        lua_Integer v = luaL_checkinteger(L, 3);
        if (v < 0 || v > 0xFF) {
            return luaL_error(L, "mem_addr must be 0-255");
        }
        mem_addr_buf = (uint8_t)v;
    }

    /* Build write buffer: [mem_addr?] data */
    size_t data_len = 0;
    const uint8_t *data_ptr = NULL;
    uint8_t *tmp_buf = NULL;

    int type = lua_type(L, 2);
    if (type == LUA_TSTRING) {
        data_ptr = (const uint8_t *)lua_tolstring(L, 2, &data_len);
    } else if (type == LUA_TTABLE) {
        lua_Integer n = luaL_len(L, 2);
        if (n < 0 || n > LUA_DRIVER_I2C_RW_MAX_LEN) {
            return luaL_error(L, "i2c write table length must be 0-%d",
                              LUA_DRIVER_I2C_RW_MAX_LEN);
        }
        size_t alloc = (size_t)n + (has_mem_addr ? 1 : 0);
        tmp_buf = (uint8_t *)lua_newuserdata(L, alloc);
        for (lua_Integer i = 0; i < n; i++) {
            lua_rawgeti(L, 2, i + 1);
            lua_Integer byte = luaL_checkinteger(L, -1);
            if (byte < 0 || byte > 0xFF) {
                return luaL_error(L, "i2c write byte #%d out of range", (int)(i + 1));
            }
            tmp_buf[(has_mem_addr ? 1 : 0) + i] = (uint8_t)byte;
            lua_pop(L, 1);
        }
        if (has_mem_addr) {
            tmp_buf[0] = mem_addr_buf;
        }
        data_ptr = tmp_buf;
        data_len = (size_t)n + (has_mem_addr ? 1 : 0);
    } else {
        return luaL_error(L, "i2c write: arg #2 must be string or table");
    }

    esp_err_t err = i2c_master_transmit(ud->dev, data_ptr, data_len, -1);
    if (err != ESP_OK) {
        return luaL_error(L, "i2c write failed: %s", esp_err_to_name(err));
    }
    return 0;
}

/* --- device:read(len, mem_addr) --- */
static int lua_driver_i2c_device_read(lua_State *L)
{
    lua_driver_i2c_device_ud_t *ud = lua_driver_i2c_device_get_ud(L, 1);
    lua_Integer len = luaL_checkinteger(L, 2);

    if (len <= 0 || len > LUA_DRIVER_I2C_RW_MAX_LEN) {
        return luaL_error(L, "i2c read length must be 1-%d", LUA_DRIVER_I2C_RW_MAX_LEN);
    }

    uint8_t *buf = (uint8_t *)lua_newuserdata(L, (size_t)len);
    esp_err_t err;

    if (lua_isnoneornil(L, 3)) {
        /* Raw read — no register address */
        err = i2c_master_receive(ud->dev, buf, (size_t)len, -1);
    } else {
        lua_Integer mem_addr = luaL_checkinteger(L, 3);
        if (mem_addr < 0 || mem_addr > 0xFF) {
            return luaL_error(L, "mem_addr must be 0-255");
        }
        uint8_t reg = (uint8_t)mem_addr;
        err = i2c_master_transmit_receive(ud->dev, &reg, 1, buf, (size_t)len, -1);
    }

    if (err != ESP_OK) {
        return luaL_error(L, "i2c read failed: %s", esp_err_to_name(err));
    }

    lua_pushlstring(L, (const char *)buf, (size_t)len);
    return 1;
}

/* --- i2c.new(port, sda, scl[, freq]) --- */
static int lua_driver_i2c_new(lua_State *L)
{
    lua_Integer port = luaL_checkinteger(L, 1);
    lua_Integer sda  = luaL_checkinteger(L, 2);
    lua_Integer scl  = luaL_checkinteger(L, 3);
    lua_Integer freq = luaL_optinteger(L, 4, LUA_DRIVER_I2C_DEFAULT_FREQ_HZ);

    if (freq <= 0) {
        return luaL_error(L, "i2c freq must be positive");
    }

    bool external_owned = false;
    i2c_master_bus_handle_t bus = i2c_bus_get_or_create(
        (int)port, (int)sda, (int)scl, (uint32_t)freq, &external_owned);

    if (!bus) {
        return luaL_error(L, "i2c bus create failed on port %d", (int)port);
    }

    lua_driver_i2c_bus_ud_t *ud =
        (lua_driver_i2c_bus_ud_t *)lua_newuserdata(L, sizeof(*ud));
    ud->bus = bus;
    ud->port = (int)port;
    ud->external_owned = external_owned;
    luaL_getmetatable(L, LUA_DRIVER_I2C_BUS_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

/* --- i2c.wrap(port) — reuse existing I2C bus (created by board manager) --- */
static int lua_driver_i2c_wrap(lua_State *L)
{
    lua_Integer port = luaL_checkinteger(L, 1);

    i2c_master_bus_handle_t bus = NULL;
    esp_err_t err = i2c_master_get_bus_handle((i2c_port_t)port, &bus);
    if (err != ESP_OK || !bus) {
        return luaL_error(L, "i2c.wrap: no bus on port %d", (int)port);
    }

    lua_driver_i2c_bus_ud_t *ud =
        (lua_driver_i2c_bus_ud_t *)lua_newuserdata(L, sizeof(*ud));
    ud->bus = bus;
    ud->port = (int)port;
    ud->external_owned = true;
    luaL_getmetatable(L, LUA_DRIVER_I2C_BUS_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

/* --- bus:scan() --- */
static int lua_driver_i2c_bus_scan(lua_State *L)
{
    lua_driver_i2c_bus_ud_t *ud = lua_driver_i2c_bus_get_ud(L, 1);

    lua_newtable(L);
    int idx = 1;

    for (uint8_t addr = 1; addr < 127; addr++) {
        esp_err_t err = i2c_master_probe(ud->bus, addr, -1);
        if (err == ESP_OK) {
            lua_pushinteger(L, addr);
            lua_rawseti(L, -2, idx++);
        }
    }
    return 1;
}

/* --- module open --- */
int luaopen_i2c(lua_State *L)
{
    /* Bus metatable */
    if (luaL_newmetatable(L, LUA_DRIVER_I2C_BUS_METATABLE)) {
        lua_pushcfunction(L, lua_driver_i2c_bus_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, lua_driver_i2c_bus_scan);
        lua_setfield(L, -2, "scan");
        lua_pushcfunction(L, lua_driver_i2c_bus_device);
        lua_setfield(L, -2, "device");
        lua_pushcfunction(L, lua_driver_i2c_bus_close);
        lua_setfield(L, -2, "close");
    }
    lua_pop(L, 1);

    /* Device metatable */
    if (luaL_newmetatable(L, LUA_DRIVER_I2C_DEVICE_METATABLE)) {
        lua_pushcfunction(L, lua_driver_i2c_device_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, lua_driver_i2c_device_read);
        lua_setfield(L, -2, "read");
        lua_pushcfunction(L, lua_driver_i2c_device_write);
        lua_setfield(L, -2, "write");
        lua_pushcfunction(L, lua_driver_i2c_device_write_byte);
        lua_setfield(L, -2, "write_byte");
        lua_pushcfunction(L, lua_driver_i2c_device_address);
        lua_setfield(L, -2, "address");
        lua_pushcfunction(L, lua_driver_i2c_device_close);
        lua_setfield(L, -2, "close");
    }
    lua_pop(L, 1);

    /* Module table */
    lua_newtable(L);
    lua_pushcfunction(L, lua_driver_i2c_new);
    lua_setfield(L, -2, "new");
    lua_pushcfunction(L, lua_driver_i2c_wrap);
    lua_setfield(L, -2, "wrap");
    return 1;
}

esp_err_t lua_driver_i2c_register(void)
{
    return cap_lua_register_module("i2c", luaopen_i2c);
}
