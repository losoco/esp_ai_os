/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include <stdbool.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t usb_msc_init(void);

bool usb_msc_is_active(void);
bool usb_msc_is_sdcard_exported(void);
bool usb_msc_is_storage_write_locked(void);
bool usb_msc_take_sdcard_changed(void);

#ifdef __cplusplus
}
#endif
