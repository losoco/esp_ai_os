/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t boot_launcher_start(void);

void motion_swipe_up(int16_t dx, int16_t dy);
void motion_swipe_down(int16_t dx, int16_t dy);
void motion_swipe_left(int16_t dx, int16_t dy);
void motion_swipe_right(int16_t dx, int16_t dy);

#ifdef __cplusplus
}
#endif
