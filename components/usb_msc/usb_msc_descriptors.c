/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "sdkconfig.h"

#if CONFIG_APP_USB_MSC_ENABLE

#include "usb_msc_descriptors.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "esp_mac.h"

#define USB_MSC_VID 0x303A
#define USB_MSC_PID 0x80A9
#define USB_MSC_BCD 0x0200

#define USB_MSC_CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_MSC_DESC_LEN)

static tusb_desc_device_t const s_device_descriptor = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = USB_MSC_BCD,
    .bDeviceClass = 0x00,
    .bDeviceSubClass = 0x00,
    .bDeviceProtocol = 0x00,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = USB_MSC_VID,
    .idProduct = USB_MSC_PID,
    .bcdDevice = 0x0100,
    .iManufacturer = USB_MSC_STRID_MANUFACTURER,
    .iProduct = USB_MSC_STRID_PRODUCT,
    .iSerialNumber = USB_MSC_STRID_SERIAL,
    .bNumConfigurations = 0x01,
};

static uint8_t const s_full_speed_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, USB_MSC_ITF_NUM_TOTAL, 0, USB_MSC_CONFIG_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 250),
    TUD_MSC_DESCRIPTOR(USB_MSC_ITF_NUM_MSC, USB_MSC_STRID_INTERFACE, USB_MSC_EP_OUT, USB_MSC_EP_IN, 64),
};

#if TUD_OPT_HIGH_SPEED
static uint8_t const s_high_speed_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, USB_MSC_ITF_NUM_TOTAL, 0, USB_MSC_CONFIG_TOTAL_LEN, TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP, 250),
    TUD_MSC_DESCRIPTOR(USB_MSC_ITF_NUM_MSC, USB_MSC_STRID_INTERFACE, USB_MSC_EP_OUT, USB_MSC_EP_IN, 512),
};

static tusb_desc_device_qualifier_t const s_device_qualifier = {
    .bLength = sizeof(tusb_desc_device_qualifier_t),
    .bDescriptorType = TUSB_DESC_DEVICE_QUALIFIER,
    .bcdUSB = USB_MSC_BCD,
    .bDeviceClass = 0x00,
    .bDeviceSubClass = 0x00,
    .bDeviceProtocol = 0x00,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .bNumConfigurations = 0x01,
    .bReserved = 0x00,
};
#endif

static char s_usb_serial[13] = "000000000000";

static const char *const s_string_desc_base[] = {
    (const char[]){0x09, 0x04},
    "Espressif",
    "ESP-Claw SD Card",
    NULL,
    "SD Card",
};

static const char *s_string_desc[sizeof(s_string_desc_base) / sizeof(s_string_desc_base[0])];
static bool s_desc_initialized = false;

void usb_msc_desc_init(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_usb_serial, sizeof(s_usb_serial), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    size_t count = sizeof(s_string_desc_base) / sizeof(s_string_desc_base[0]);
    for (size_t i = 0; i < count; i++) {
        s_string_desc[i] = (i == USB_MSC_STRID_SERIAL) ? s_usb_serial : s_string_desc_base[i];
    }
    s_desc_initialized = true;
}

const tusb_desc_device_t *usb_msc_desc_get_device(void)
{
    return &s_device_descriptor;
}

const uint8_t *usb_msc_desc_get_fs_configuration(void)
{
    return s_full_speed_configuration;
}

const char **usb_msc_desc_get_string_table(size_t *count)
{
    if (!s_desc_initialized) {
        usb_msc_desc_init();
    }
    if (count) {
        *count = sizeof(s_string_desc) / sizeof(s_string_desc[0]);
    }
    return s_string_desc;
}

#if TUD_OPT_HIGH_SPEED
const uint8_t *usb_msc_desc_get_hs_configuration(void)
{
    return s_high_speed_configuration;
}

const tusb_desc_device_qualifier_t *usb_msc_desc_get_qualifier(void)
{
    return &s_device_qualifier;
}
#endif

#endif
