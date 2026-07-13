/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "sdkconfig.h"

#if CONFIG_APP_USB_MSC_ENABLE
#include "tusb.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if CONFIG_APP_USB_MSC_ENABLE

enum {
    USB_MSC_ITF_NUM_MSC = 0,
    USB_MSC_ITF_NUM_TOTAL,
};

#define USB_MSC_EP_OUT 0x01
#define USB_MSC_EP_IN  0x81

enum {
    USB_MSC_STRID_LANGID = 0,
    USB_MSC_STRID_MANUFACTURER,
    USB_MSC_STRID_PRODUCT,
    USB_MSC_STRID_SERIAL,
    USB_MSC_STRID_INTERFACE,
};

void usb_msc_desc_init(void);
const tusb_desc_device_t *usb_msc_desc_get_device(void);
const uint8_t *usb_msc_desc_get_fs_configuration(void);
const char **usb_msc_desc_get_string_table(size_t *count);
#if TUD_OPT_HIGH_SPEED
const uint8_t *usb_msc_desc_get_hs_configuration(void);
const tusb_desc_device_qualifier_t *usb_msc_desc_get_qualifier(void);
#endif

#endif

#ifdef __cplusplus
}
#endif
