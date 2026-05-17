/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lua_module_runtime.h"

#include "cap_lua.h"
#include "lauxlib.h"

#define LUA_MODULE_RUNTIME_NAME "runtime"

int luaopen_runtime(lua_State *L)
{
    if (runtime_sync_init() != ESP_OK) {
        luaL_error(L, "runtime.sync: failed to create registry lock");
    }

    lua_newtable(L);

    lua_module_runtime_push_thread(L);
    lua_setfield(L, -2, "thread");

    lua_module_runtime_push_sync(L);
    lua_setfield(L, -2, "sync");

    return 1;
}

esp_err_t lua_module_runtime_register(void)
{
    esp_err_t err = runtime_sync_init();

    if (err != ESP_OK) {
        return err;
    }
    return cap_lua_register_module(LUA_MODULE_RUNTIME_NAME, luaopen_runtime);
}
