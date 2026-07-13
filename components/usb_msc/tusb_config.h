/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include "sdkconfig.h"
#include "tusb_option.h"

#ifndef CFG_TUSB_MCU
#if CONFIG_IDF_TARGET_ESP32P4
#define CFG_TUSB_MCU OPT_MCU_ESP32P4
#elif CONFIG_IDF_TARGET_ESP32S3
#define CFG_TUSB_MCU OPT_MCU_ESP32S3
#endif
#endif

#define CFG_TUSB_RHPORT0_MODE OPT_MODE_DEVICE
#define CFG_TUSB_OS           OPT_OS_FREERTOS

#ifndef CFG_TUD_ENDPOINT0_SIZE
#define CFG_TUD_ENDPOINT0_SIZE 64
#endif

#if CONFIG_IDF_TARGET_ESP32P4
#define CFG_TUD_MAX_SPEED OPT_MODE_HIGH_SPEED
#else
#define CFG_TUD_MAX_SPEED OPT_MODE_FULL_SPEED
#endif

#define CFG_TUD_CDC 0
#define CFG_TUD_MSC 1

#define CFG_TUD_MSC_EP_BUFSIZE 512
#define CFG_TUD_MSC_TX_BUFSIZE 512
#define CFG_TUD_MSC_RX_BUFSIZE 512

#define CFG_TUSB_MEM_ALIGN   __attribute__((aligned(16)))
#define CFG_TUSB_MEM_SECTION

#define CFG_TUSB_DEBUG CONFIG_TINYUSB_DEBUG_LEVEL
