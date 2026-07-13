/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "usb_msc.h"

#include "sdkconfig.h"

#if CONFIG_APP_USB_MSC_ENABLE

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "class/msc/msc_device.h"
#include "display_arbiter.h"
#include "esp_board_manager_includes.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"
#include "tinyusb.h"
#include "tusb.h"
#include "usb_msc_descriptors.h"

#ifndef CONFIG_APP_USB_MSC_READONLY
#define CONFIG_APP_USB_MSC_READONLY 0
#endif

#define USB_MSC_SDCARD_DEVICE_NAME "fs_sdcard"
#define USB_MSC_REMOUNT_DEBOUNCE_US (1500 * 1000)
#define USB_MSC_MOUNT_RECOVERY_SLACK_US (200 * 1000)
#define USB_MSC_BOOT_DEFER_INTERVAL_US (500 * 1000)
#define USB_MSC_BOOT_DEFER_MAX_RETRIES  10
#define USB_MSC_UI_STRIP_H 24

static const char *TAG = "usb_msc";

static SemaphoreHandle_t s_msc_mutex;
static uint8_t *s_sector_buffer;
static size_t s_sector_buffer_size;
static uint16_t s_block_size = 512;
static uint32_t s_block_count;
static bool s_usb_active;
static bool s_sdcard_exported;
static bool s_sdcard_changed;
static bool s_display_locked;
static int64_t s_last_unmount_us;
static esp_timer_handle_t s_mount_recovery_timer;
static esp_timer_handle_t s_boot_defer_timer;
static int s_boot_defer_retries;
static sdmmc_card_t *s_sdcard;

static esp_lcd_panel_handle_t s_ui_panel;
static uint16_t s_ui_width;
static uint16_t s_ui_height;

static sdmmc_card_t *resolve_sdcard(void)
{
#if defined(CONFIG_ESP_BOARD_DEV_FS_FAT_SUPPORT)
    dev_fs_fat_handle_t *handle = NULL;
    esp_err_t err = esp_board_device_get_handle(USB_MSC_SDCARD_DEVICE_NAME, (void **)&handle);
    if (err != ESP_OK || handle == NULL || handle->card == NULL) {
        return NULL;
    }
    return handle->card;
#else
    return NULL;
#endif
}

static esp_err_t update_card_capacity(void)
{
    sdmmc_card_t *card = s_sdcard;
    ESP_RETURN_ON_FALSE(card, ESP_ERR_INVALID_STATE, TAG, "SD card not mounted");

    s_block_size = (uint16_t)card->csd.sector_size;
    if (s_block_size == 0) {
        s_block_size = 512;
    }
    s_block_count = (uint32_t)card->csd.capacity;

    if (s_sector_buffer_size < s_block_size) {
        uint8_t *new_buffer = realloc(s_sector_buffer, s_block_size);
        ESP_RETURN_ON_FALSE(new_buffer, ESP_ERR_NO_MEM, TAG, "Failed to allocate sector buffer");
        s_sector_buffer = new_buffer;
        s_sector_buffer_size = s_block_size;
    }

    ESP_LOGI(TAG, "SD capacity: %u blocks x %u bytes", (unsigned)s_block_count, (unsigned)s_block_size);
    return ESP_OK;
}

static const uint8_t *font5x7(char c)
{
    static const uint8_t space[5] = {0, 0, 0, 0, 0};
    static const uint8_t a[5] = {0x7E, 0x11, 0x11, 0x11, 0x7E};
    static const uint8_t b[5] = {0x7F, 0x49, 0x49, 0x49, 0x36};
    static const uint8_t c_[5] = {0x3E, 0x41, 0x41, 0x41, 0x22};
    static const uint8_t d[5] = {0x7F, 0x41, 0x41, 0x22, 0x1C};
    static const uint8_t e[5] = {0x7F, 0x49, 0x49, 0x49, 0x41};
    static const uint8_t i[5] = {0x00, 0x41, 0x7F, 0x41, 0x00};
    static const uint8_t n[5] = {0x7F, 0x02, 0x04, 0x08, 0x7F};
    static const uint8_t o[5] = {0x3E, 0x41, 0x41, 0x41, 0x3E};
    static const uint8_t p[5] = {0x7F, 0x09, 0x09, 0x09, 0x06};
    static const uint8_t r[5] = {0x7F, 0x09, 0x19, 0x29, 0x46};
    static const uint8_t s[5] = {0x46, 0x49, 0x49, 0x49, 0x31};
    static const uint8_t t[5] = {0x01, 0x01, 0x7F, 0x01, 0x01};
    static const uint8_t u[5] = {0x3F, 0x40, 0x40, 0x40, 0x3F};
    static const uint8_t v[5] = {0x1F, 0x20, 0x40, 0x20, 0x1F};
    static const uint8_t x[5] = {0x63, 0x14, 0x08, 0x14, 0x63};
    switch (c) {
    case 'A': return a;
    case 'B': return b;
    case 'C': return c_;
    case 'D': return d;
    case 'E': return e;
    case 'I': return i;
    case 'N': return n;
    case 'O': return o;
    case 'P': return p;
    case 'R': return r;
    case 'S': return s;
    case 'T': return t;
    case 'U': return u;
    case 'V': return v;
    case 'X': return x;
    default: return space;
    }
}

static void draw_text_to_strip(uint16_t *buf, int strip_y, int strip_h, int width,
                               const char *text, int x, int y, int scale, uint16_t color)
{
    int char_w = 6 * scale;
    for (int idx = 0; text[idx] != '\0'; idx++) {
        const uint8_t *glyph = font5x7(text[idx]);
        int base_x = x + idx * char_w;
        for (int col = 0; col < 5; col++) {
            for (int row = 0; row < 7; row++) {
                if ((glyph[col] & (1U << row)) == 0) {
                    continue;
                }
                int px0 = base_x + col * scale;
                int py0 = y + row * scale;
                for (int sy = 0; sy < scale; sy++) {
                    int py = py0 + sy;
                    if (py < strip_y || py >= strip_y + strip_h) {
                        continue;
                    }
                    for (int sx = 0; sx < scale; sx++) {
                        int px = px0 + sx;
                        if (px >= 0 && px < width) {
                            buf[(py - strip_y) * width + px] = color;
                        }
                    }
                }
            }
        }
    }
}

static esp_err_t usb_msc_ui_load_display(void)
{
    if (s_ui_panel != NULL) {
        return ESP_OK;
    }

    void *lcd_handle = NULL;
    void *lcd_config = NULL;
    ESP_RETURN_ON_ERROR(esp_board_manager_get_device_handle(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_handle),
                        TAG, "get display handle failed");
    ESP_RETURN_ON_ERROR(esp_board_manager_get_device_config(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_config),
                        TAG, "get display config failed");

    dev_display_lcd_handles_t *lcd_handles = (dev_display_lcd_handles_t *)lcd_handle;
    dev_display_lcd_config_t *lcd_cfg = (dev_display_lcd_config_t *)lcd_config;
    ESP_RETURN_ON_FALSE(lcd_handles && lcd_handles->panel_handle && lcd_cfg,
                        ESP_ERR_INVALID_STATE, TAG, "display handle/config missing");

    s_ui_panel = lcd_handles->panel_handle;
    s_ui_width = lcd_cfg->lcd_width;
    s_ui_height = lcd_cfg->lcd_height;
    return ESP_OK;
}

static void usb_msc_ui_show(void)
{
    if (usb_msc_ui_load_display() != ESP_OK || s_ui_width == 0 || s_ui_height == 0) {
        return;
    }

    size_t pixels = (size_t)s_ui_width * USB_MSC_UI_STRIP_H;
    uint16_t *strip = heap_caps_malloc(pixels * sizeof(uint16_t), MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (strip == NULL) {
        strip = heap_caps_malloc(pixels * sizeof(uint16_t), MALLOC_CAP_8BIT);
    }
    if (strip == NULL) {
        ESP_LOGW(TAG, "USB MSC UI buffer allocation failed");
        return;
    }

    const uint16_t bg = 0x1084;
    const uint16_t fg = 0xFFFF;
    const int scale = (s_ui_width >= 600) ? 5 : 3;
    const char *line1 = "SD CARD EXPORTED";
    const char *line2 = "OVER USB";
    const char *line3 = "DO NOT OPERATE DEVICE";
    int char_w = 6 * scale;
    int line_h = 10 * scale;
    int start_y = ((int)s_ui_height - line_h * 3) / 2;
    int x1 = ((int)s_ui_width - (int)strlen(line1) * char_w) / 2;
    int x2 = ((int)s_ui_width - (int)strlen(line2) * char_w) / 2;
    int x3 = ((int)s_ui_width - (int)strlen(line3) * char_w) / 2;

    for (int y = 0; y < s_ui_height; y += USB_MSC_UI_STRIP_H) {
        int strip_h = s_ui_height - y;
        if (strip_h > USB_MSC_UI_STRIP_H) {
            strip_h = USB_MSC_UI_STRIP_H;
        }
        for (int i = 0; i < s_ui_width * strip_h; i++) {
            strip[i] = bg;
        }
        draw_text_to_strip(strip, y, strip_h, s_ui_width, line1, x1, start_y, scale, fg);
        draw_text_to_strip(strip, y, strip_h, s_ui_width, line2, x2, start_y + line_h, scale, fg);
        draw_text_to_strip(strip, y, strip_h, s_ui_width, line3, x3, start_y + line_h * 2, scale, fg);
        esp_lcd_panel_draw_bitmap(s_ui_panel, 0, y, s_ui_width, y + strip_h, strip);
    }

    free(strip);
}

static esp_err_t acquire_usb_display_lock(void)
{
    if (s_display_locked) {
        return ESP_OK;
    }
    esp_err_t err = display_arbiter_acquire(DISPLAY_ARBITER_OWNER_USB_MSC);
    if (err == ESP_OK) {
        s_display_locked = true;
        usb_msc_ui_show();
    }
    return err;
}

static void release_usb_display_lock(void)
{
    if (!s_display_locked) {
        return;
    }
    esp_err_t err = display_arbiter_release(DISPLAY_ARBITER_OWNER_USB_MSC);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "release USB MSC display lock failed: %s", esp_err_to_name(err));
    }
    s_display_locked = false;
}

static void perform_mount_activation(void)
{
    if (update_card_capacity() != ESP_OK) {
        return;
    }
    s_usb_active = true;
    s_sdcard_exported = true;
    ESP_LOGI(TAG, "USB host mounted SD card %s", CONFIG_APP_USB_MSC_READONLY ? "read-only" : "read-write");

    /* Defer display lock until the launcher (LUA owner) is ready.
     * If USB is connected at boot, the launcher hasn't acquired LUA
     * ownership yet — acquiring USB_MSC now would block lvgl.init(). */
    if (!s_display_locked) {
        display_arbiter_owner_t owner = display_arbiter_get_owner();
        if (owner == DISPLAY_ARBITER_OWNER_LUA) {
            acquire_usb_display_lock();
        } else {
            ESP_LOGI(TAG, "Launcher not ready (owner=%s), deferring display lock",
                     owner == DISPLAY_ARBITER_OWNER_EMOTE_GFX ? "emote_gfx" : "none");
            s_boot_defer_retries = 0;
            if (s_boot_defer_timer) {
                esp_timer_start_once(s_boot_defer_timer, USB_MSC_BOOT_DEFER_INTERVAL_US);
            }
        }
    }
}

static void boot_defer_timer_cb(void *arg)
{
    (void)arg;
    if (s_display_locked || !s_usb_active) {
        return;
    }

    s_boot_defer_retries++;
    display_arbiter_owner_t owner = display_arbiter_get_owner();
    if (owner == DISPLAY_ARBITER_OWNER_LUA) {
        ESP_LOGI(TAG, "Boot defer: launcher ready, acquiring USB MSC display lock");
        acquire_usb_display_lock();
        s_boot_defer_retries = 0;
    } else if (s_boot_defer_retries >= USB_MSC_BOOT_DEFER_MAX_RETRIES) {
        ESP_LOGW(TAG, "Boot defer: launcher not ready after %d retries, acquiring display lock anyway",
                 s_boot_defer_retries);
        acquire_usb_display_lock();
        s_boot_defer_retries = 0;
    } else {
        esp_timer_start_once(s_boot_defer_timer, USB_MSC_BOOT_DEFER_INTERVAL_US);
    }
}

static void mount_recovery_worker(void *arg)
{
    (void)arg;
    if (tud_ready() && tud_mounted() && !s_usb_active) {
        ESP_LOGW(TAG, "Mount recovery: re-activating MSC after debounced mount");
        s_last_unmount_us = 0;
        perform_mount_activation();
    }
    vTaskDelete(NULL);
}

static void mount_recovery_timer_cb(void *arg)
{
    (void)arg;
    if (s_usb_active || !tud_ready() || !tud_mounted()) {
        return;
    }
    BaseType_t r = xTaskCreate(mount_recovery_worker, "usb_msc_recv", 4096, NULL, tskIDLE_PRIORITY + 5, NULL);
    if (r != pdPASS) {
        ESP_LOGE(TAG, "Mount recovery: failed to spawn worker");
    }
}

esp_err_t usb_msc_init(void)
{
    if (s_msc_mutex) {
        return ESP_OK;
    }

    s_sdcard = resolve_sdcard();
    if (!s_sdcard) {
        ESP_LOGI(TAG, "No mounted SD card, USB MSC disabled");
        return ESP_OK;
    }

    s_msc_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_msc_mutex, ESP_ERR_NO_MEM, TAG, "Failed to create MSC mutex");

    const esp_timer_create_args_t recovery_timer_args = {
        .callback = mount_recovery_timer_cb,
        .name = "usb_msc_recover",
    };
    esp_err_t timer_err = esp_timer_create(&recovery_timer_args, &s_mount_recovery_timer);
    if (timer_err != ESP_OK) {
        ESP_LOGW(TAG, "Mount recovery timer unavailable: %s", esp_err_to_name(timer_err));
        s_mount_recovery_timer = NULL;
    }

    const esp_timer_create_args_t boot_defer_timer_args = {
        .callback = boot_defer_timer_cb,
        .name = "usb_msc_boot_defer",
    };
    timer_err = esp_timer_create(&boot_defer_timer_args, &s_boot_defer_timer);
    if (timer_err != ESP_OK) {
        ESP_LOGW(TAG, "Boot defer timer unavailable: %s", esp_err_to_name(timer_err));
        s_boot_defer_timer = NULL;
    }

    ESP_RETURN_ON_ERROR(update_card_capacity(), TAG, "Failed to read SD card capacity");

    size_t string_count = 0;
    const char **string_table = usb_msc_desc_get_string_table(&string_count);

    const tinyusb_config_t tusb_cfg = {
        .device_descriptor = usb_msc_desc_get_device(),
        .string_descriptor = string_table,
        .string_descriptor_count = string_count,
        .external_phy = false,
#if TUD_OPT_HIGH_SPEED
        .fs_configuration_descriptor = usb_msc_desc_get_fs_configuration(),
        .hs_configuration_descriptor = usb_msc_desc_get_hs_configuration(),
        .qualifier_descriptor = usb_msc_desc_get_qualifier(),
#else
        .configuration_descriptor = usb_msc_desc_get_fs_configuration(),
#endif
        .self_powered = true,
        .vbus_monitor_io = -1,
    };

    esp_log_level_t prev_phy_level = esp_log_level_get("usb_phy");
    esp_log_level_set("usb_phy", ESP_LOG_ERROR);
    esp_err_t err = tinyusb_driver_install(&tusb_cfg);
    esp_log_level_set("usb_phy", prev_phy_level);
    ESP_RETURN_ON_ERROR(err, TAG, "Failed to install TinyUSB");

    ESP_LOGI(TAG, "USB MSC initialized");
    return ESP_OK;
}

bool usb_msc_is_active(void)
{
    return s_usb_active && tud_ready();
}

bool usb_msc_is_sdcard_exported(void)
{
    return s_sdcard_exported;
}

bool usb_msc_is_storage_write_locked(void)
{
    return s_sdcard_exported;
}

bool usb_msc_take_sdcard_changed(void)
{
    bool changed = s_sdcard_changed;
    s_sdcard_changed = false;
    return changed;
}

static int32_t msc_handle_transfer(bool write, uint32_t lba, uint32_t offset, uint8_t *buffer, uint32_t bufsize)
{
    sdmmc_card_t *card = s_sdcard;
    if (!s_usb_active || !card || !buffer || bufsize == 0 || !s_sector_buffer) {
        return -1;
    }
    if (offset >= s_block_size) {
        return -1;
    }
    if (xSemaphoreTake(s_msc_mutex, portMAX_DELAY) != pdTRUE) {
        return -1;
    }

    esp_err_t err = ESP_OK;
    const size_t block_size = s_block_size;
    size_t remaining = bufsize;
    uint8_t *buf_ptr = buffer;
    uint32_t current_lba = lba;
    size_t sector_offset = offset;

    while (remaining > 0 && err == ESP_OK) {
        if (sector_offset == 0 && remaining >= block_size) {
            size_t whole_blocks = remaining / block_size;
            size_t block_bytes = whole_blocks * block_size;
            err = write ? sdmmc_write_sectors(card, buf_ptr, current_lba, whole_blocks)
                        : sdmmc_read_sectors(card, buf_ptr, current_lba, whole_blocks);
            if (err != ESP_OK) {
                break;
            }
            buf_ptr += block_bytes;
            remaining -= block_bytes;
            current_lba += whole_blocks;
            continue;
        }

        const size_t sector_space = block_size - sector_offset;
        size_t chunk = (remaining < sector_space) ? remaining : sector_space;
        if (!write) {
            err = sdmmc_read_sectors(card, s_sector_buffer, current_lba, 1);
            if (err == ESP_OK) {
                memcpy(buf_ptr, s_sector_buffer + sector_offset, chunk);
            }
        } else {
            err = sdmmc_read_sectors(card, s_sector_buffer, current_lba, 1);
            if (err == ESP_OK) {
                memcpy(s_sector_buffer + sector_offset, buf_ptr, chunk);
                err = sdmmc_write_sectors(card, s_sector_buffer, current_lba, 1);
            }
        }

        if (err != ESP_OK) {
            break;
        }
        buf_ptr += chunk;
        remaining -= chunk;
        sector_offset += chunk;
        if (sector_offset >= block_size) {
            sector_offset -= block_size;
            current_lba++;
        }
    }

    xSemaphoreGive(s_msc_mutex);
    return (err == ESP_OK) ? (int32_t)bufsize : -1;
}

void tud_mount_cb(void)
{
    int64_t now_us = esp_timer_get_time();
    if (s_last_unmount_us != 0 && (now_us - s_last_unmount_us) < USB_MSC_REMOUNT_DEBOUNCE_US) {
        ESP_LOGI(TAG, "Ignoring USB mount bounce %lld ms after unmount",
                 (long long)((now_us - s_last_unmount_us) / 1000));
        if (s_mount_recovery_timer) {
            esp_timer_stop(s_mount_recovery_timer);
            esp_timer_start_once(s_mount_recovery_timer,
                                 USB_MSC_REMOUNT_DEBOUNCE_US + USB_MSC_MOUNT_RECOVERY_SLACK_US);
        }
        return;
    }
    s_last_unmount_us = 0;
    perform_mount_activation();
}

void tud_umount_cb(void)
{
    if (s_mount_recovery_timer) {
        esp_timer_stop(s_mount_recovery_timer);
    }
    if (s_boot_defer_timer) {
        esp_timer_stop(s_boot_defer_timer);
    }
    s_boot_defer_retries = 0;
    s_last_unmount_us = esp_timer_get_time();
    s_usb_active = false;
    if (s_sdcard_exported) {
        s_sdcard_changed = true;
    }
    s_sdcard_exported = false;
    release_usb_display_lock();
    ESP_LOGI(TAG, "USB host disconnected");
}

void tud_suspend_cb(bool remote_wakeup_en)
{
    (void)remote_wakeup_en;
    if (s_mount_recovery_timer) {
        esp_timer_stop(s_mount_recovery_timer);
    }
    if (s_boot_defer_timer) {
        esp_timer_stop(s_boot_defer_timer);
    }
    s_boot_defer_retries = 0;
    s_usb_active = false;
    if (s_sdcard_exported) {
        s_sdcard_changed = true;
    }
    s_sdcard_exported = false;
    release_usb_display_lock();
}

void tud_resume_cb(void)
{
    s_last_unmount_us = 0;
}

bool tud_msc_is_writable_cb(uint8_t lun)
{
    (void)lun;
    return !CONFIG_APP_USB_MSC_READONLY;
}

void tud_msc_inquiry_cb(uint8_t lun, uint8_t vendor_id[8], uint8_t product_id[16], uint8_t product_rev[4])
{
    (void)lun;
    memset(vendor_id, ' ', 8);
    memcpy(vendor_id, "ESP32", 5);
    memset(product_id, ' ', 16);
    memcpy(product_id, "ESP-Claw SD", 11);
    memset(product_rev, ' ', 4);
    memcpy(product_rev, "1.0", 3);
}

void tud_msc_capacity_cb(uint8_t lun, uint32_t *block_count, uint16_t *block_size)
{
    (void)lun;
    *block_count = s_block_count;
    *block_size = s_block_size;
}

bool tud_msc_test_unit_ready_cb(uint8_t lun)
{
    if (!s_usb_active || !s_sdcard) {
        tud_msc_set_sense(lun, SCSI_SENSE_NOT_READY, 0x3A, 0x00);
        return false;
    }
    return true;
}

int32_t tud_msc_read10_cb(uint8_t lun, uint32_t lba, uint32_t offset, void *buffer, uint32_t bufsize)
{
    (void)lun;
    return msc_handle_transfer(false, lba, offset, (uint8_t *)buffer, bufsize);
}

int32_t tud_msc_write10_cb(uint8_t lun, uint32_t lba, uint32_t offset, uint8_t *buffer, uint32_t bufsize)
{
    if (CONFIG_APP_USB_MSC_READONLY) {
        tud_msc_set_sense(lun, SCSI_SENSE_DATA_PROTECT, 0x27, 0x00);
        return -1;
    }
    (void)lun;
    s_sdcard_changed = true;
    return msc_handle_transfer(true, lba, offset, buffer, bufsize);
}

bool tud_msc_start_stop_cb(uint8_t lun, uint8_t power_condition, bool start, bool load_eject)
{
    (void)lun;
    (void)power_condition;
    (void)start;
    (void)load_eject;
    return true;
}

int32_t tud_msc_scsi_cb(uint8_t lun, uint8_t const scsi_cmd[16], void *buffer, uint16_t bufsize)
{
    (void)lun;
    (void)scsi_cmd;
    (void)buffer;
    (void)bufsize;
    tud_msc_set_sense(lun, SCSI_SENSE_ILLEGAL_REQUEST, 0x20, 0x00);
    return -1;
}

#else

esp_err_t usb_msc_init(void)
{
    return ESP_OK;
}

bool usb_msc_is_active(void)
{
    return false;
}

bool usb_msc_is_sdcard_exported(void)
{
    return false;
}

bool usb_msc_is_storage_write_locked(void)
{
    return false;
}

bool usb_msc_take_sdcard_changed(void)
{
    return false;
}

#endif
