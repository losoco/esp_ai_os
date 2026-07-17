// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 p3a Contributors

/**
 * @file slave_ota.h
 * @brief ESP32-C5 slave OTA update via ESP-Hosted
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "sdkconfig.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t slave_ota_check_and_update(void);
esp_err_t slave_ota_get_embedded_version(uint32_t *major, uint32_t *minor, uint32_t *patch);
bool slave_ota_is_in_progress(void);

typedef bool (*slave_ota_usb_busy_fn_t)(void);
void slave_ota_set_usb_busy_check(slave_ota_usb_busy_fn_t fn);

#if CONFIG_APP_SLAVE_OTA_MOCK
esp_err_t slave_ota_run_mock(void);
#endif

#ifdef __cplusplus
}
#endif
