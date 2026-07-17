// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 p3a Contributors

/**
 * @file slave_ota.c
 * @brief ESP32-C5 slave OTA update via ESP-Hosted
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "slave_ota.h"

#include "esp_app_desc.h"
#include "esp_err.h"
#include "esp_hosted.h"
#include "esp_image_format.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "slave_ota";

#define SLAVE_FW_PARTITION_LABEL "slave_fw"
#define OTA_CHUNK_SIZE 1400

static const uint32_t ESP32C5_SLAVE_FW_VERSION_MAJOR = 2;
static const uint32_t ESP32C5_SLAVE_FW_VERSION_MINOR = 12;
static const uint32_t ESP32C5_SLAVE_FW_VERSION_PATCH = 3;

/* esp-hosted 2.7.0 has a confirmed slave-side OTA validation bug. */
static const uint32_t LOCKED_VERSION_MAJOR = 2;
static const uint32_t LOCKED_VERSION_MINOR = 7;
static const uint32_t LOCKED_VERSION_PATCH = 0;

static volatile bool s_slave_ota_in_progress = false;
static slave_ota_usb_busy_fn_t s_usb_busy_check = NULL;

bool slave_ota_is_in_progress(void)
{
    return s_slave_ota_in_progress;
}

void slave_ota_set_usb_busy_check(slave_ota_usb_busy_fn_t fn)
{
    s_usb_busy_check = fn;
}

esp_err_t slave_ota_get_embedded_version(uint32_t *major, uint32_t *minor, uint32_t *patch)
{
    if (major) {
        *major = ESP32C5_SLAVE_FW_VERSION_MAJOR;
    }
    if (minor) {
        *minor = ESP32C5_SLAVE_FW_VERSION_MINOR;
    }
    if (patch) {
        *patch = ESP32C5_SLAVE_FW_VERSION_PATCH;
    }
    return ESP_OK;
}

static bool usb_gate_blocks(void)
{
    if (!s_usb_busy_check) {
        return false;
    }
    vTaskDelay(pdMS_TO_TICKS(500));
    return s_usb_busy_check();
}

static void ota_log_progress(int percent, const char *status)
{
    ESP_LOGI(TAG, "ESP32-C5 OTA %d%%: %s", percent, status ? status : "");
}

static esp_err_t ota_finish_failure(esp_err_t err)
{
    ESP_LOGE(TAG, "ESP32-C5 slave OTA failed: %s", esp_err_to_name(err));
    s_slave_ota_in_progress = false;
    return err;
}

static void ota_finish_success_and_reboot(void)
{
    for (int i = 5; i >= 1; i--) {
        ESP_LOGW(TAG, "ESP32-C5 slave update complete, rebooting in %d...", i);
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    esp_restart();
}

#if CONFIG_APP_SLAVE_OTA_MOCK
esp_err_t slave_ota_run_mock(void)
{
    ESP_LOGW(TAG, "Mock ESP32-C5 slave OTA: duration %d ms", CONFIG_APP_SLAVE_OTA_MOCK_DURATION_MS);
    const int total_ms = CONFIG_APP_SLAVE_OTA_MOCK_DURATION_MS;
    const int step_ms = total_ms / 100;
    for (int pct = 1; pct <= 100; pct++) {
        ota_log_progress(pct, "Updating ESP32-C5 slave...");
        vTaskDelay(pdMS_TO_TICKS(step_ms));
    }
    ota_log_progress(100, "Verifying...");
    vTaskDelay(pdMS_TO_TICKS(500));
    ota_finish_success_and_reboot();
    return ESP_OK;
}
#endif

static bool slave_version_needs_update(const esp_hosted_coprocessor_fwver_t *current_ver)
{
    if (current_ver->major1 == 0 && current_ver->minor1 == 0 && current_ver->patch1 == 0) {
        return true;
    }
    if (current_ver->major1 < ESP32C5_SLAVE_FW_VERSION_MAJOR) {
        return true;
    }
    if (current_ver->major1 > ESP32C5_SLAVE_FW_VERSION_MAJOR) {
        return false;
    }
    if (current_ver->minor1 < ESP32C5_SLAVE_FW_VERSION_MINOR) {
        return true;
    }
    if (current_ver->minor1 > ESP32C5_SLAVE_FW_VERSION_MINOR) {
        return false;
    }
    return current_ver->patch1 < ESP32C5_SLAVE_FW_VERSION_PATCH;
}

static esp_err_t slave_ota_get_image_size(const esp_partition_t *partition, size_t *out_size)
{
    esp_image_header_t img_header;
    esp_err_t err = esp_partition_read(partition, 0, &img_header, sizeof(img_header));
    if (err != ESP_OK) {
        return err;
    }

    size_t fw_size = sizeof(esp_image_header_t);
    size_t offset = sizeof(esp_image_header_t);
    for (int i = 0; i < img_header.segment_count; i++) {
        esp_image_segment_header_t seg_header;
        err = esp_partition_read(partition, offset, &seg_header, sizeof(seg_header));
        if (err != ESP_OK) {
            return err;
        }
        fw_size += sizeof(seg_header) + seg_header.data_len;
        offset += sizeof(seg_header) + seg_header.data_len;
    }

    fw_size = ((fw_size + 1) + 15) & ~15;
    if (img_header.hash_appended == 1) {
        fw_size += 32;
    }

    *out_size = fw_size;
    return ESP_OK;
}

esp_err_t slave_ota_check_and_update(void)
{
    ESP_LOGI(TAG, "Checking ESP32-C5 slave firmware...");

    esp_hosted_coprocessor_fwver_t current_ver = {0};
    esp_err_t err = esp_hosted_get_coprocessor_fwversion(&current_ver);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Could not get ESP32-C5 slave version: %s (link not up yet, will retry next boot)", esp_err_to_name(err));
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Current ESP32-C5 slave firmware: %lu.%lu.%lu",
             current_ver.major1, current_ver.minor1, current_ver.patch1);
    ESP_LOGI(TAG, "Embedded ESP32-C5 slave firmware: %lu.%lu.%lu",
             ESP32C5_SLAVE_FW_VERSION_MAJOR,
             ESP32C5_SLAVE_FW_VERSION_MINOR,
             ESP32C5_SLAVE_FW_VERSION_PATCH);

    if (current_ver.major1 == LOCKED_VERSION_MAJOR &&
        current_ver.minor1 == LOCKED_VERSION_MINOR &&
        current_ver.patch1 == LOCKED_VERSION_PATCH) {
        ESP_LOGW(TAG, "Detected esp-hosted 2.7.0 on ESP32-C5 slave; OTA is not possible");
        return ESP_OK;
    }

#if CONFIG_APP_SLAVE_OTA_MOCK
    if (usb_gate_blocks()) {
        ESP_LOGW(TAG, "USB-HS active - skipping mock ESP32-C5 slave OTA");
        return ESP_OK;
    }
    s_slave_ota_in_progress = true;
    return slave_ota_run_mock();
#endif

    if (!slave_version_needs_update(&current_ver)) {
        ESP_LOGI(TAG, "ESP32-C5 slave firmware is up to date");
        return ESP_OK;
    }

    if (usb_gate_blocks()) {
        ESP_LOGW(TAG, "USB-HS active - skipping ESP32-C5 slave OTA to avoid SDIO conflict");
        return ESP_OK;
    }

    const esp_partition_t *slave_partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, 0x40, SLAVE_FW_PARTITION_LABEL);
    if (!slave_partition) {
        ESP_LOGW(TAG, "ESP32-C5 slave firmware partition '%s' not found", SLAVE_FW_PARTITION_LABEL);
        return ESP_ERR_NOT_FOUND;
    }

    esp_app_desc_t app_desc;
    err = esp_partition_read(slave_partition,
                             sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t),
                             &app_desc,
                             sizeof(app_desc));
    if (err != ESP_OK) {
        return err;
    }
    if (app_desc.magic_word != ESP_APP_DESC_MAGIC_WORD) {
        ESP_LOGE(TAG, "Invalid ESP32-C5 slave app descriptor magic: 0x%lx", app_desc.magic_word);
        return ESP_ERR_INVALID_STATE;
    }

    size_t fw_size = 0;
    err = slave_ota_get_image_size(slave_partition, &fw_size);
    if (err != ESP_OK) {
        return err;
    }

    ESP_LOGW(TAG, "Updating ESP32-C5 slave to %lu.%lu.%lu (%zu bytes, image %s v%s)",
             ESP32C5_SLAVE_FW_VERSION_MAJOR,
             ESP32C5_SLAVE_FW_VERSION_MINOR,
             ESP32C5_SLAVE_FW_VERSION_PATCH,
             fw_size,
             app_desc.project_name,
             app_desc.version);

    s_slave_ota_in_progress = true;
    ota_log_progress(0, "Preparing...");

    err = esp_hosted_slave_ota_begin();
    if (err != ESP_OK) {
        return ota_finish_failure(err);
    }

    uint8_t *buffer = malloc(OTA_CHUNK_SIZE);
    if (!buffer) {
        esp_hosted_slave_ota_end();
        return ota_finish_failure(ESP_ERR_NO_MEM);
    }

    size_t xfer_offset = 0;
    size_t bytes_written = 0;
    int progress_pct = 0;
    while (xfer_offset < fw_size) {
        size_t chunk_size = (fw_size - xfer_offset) > OTA_CHUNK_SIZE ? OTA_CHUNK_SIZE : (fw_size - xfer_offset);

        err = esp_partition_read(slave_partition, xfer_offset, buffer, chunk_size);
        if (err != ESP_OK) {
            break;
        }

        err = esp_hosted_slave_ota_write(buffer, chunk_size);
        if (err != ESP_OK) {
            break;
        }

        xfer_offset += chunk_size;
        bytes_written += chunk_size;

        int new_pct = (bytes_written * 100) / fw_size;
        if (new_pct != progress_pct) {
            progress_pct = new_pct;
            if (progress_pct % 10 == 0 || progress_pct == 100) {
                ota_log_progress(progress_pct, "Updating ESP32-C5 slave...");
            }
        }
    }

    free(buffer);

    if (err != ESP_OK) {
        esp_hosted_slave_ota_end();
        return ota_finish_failure(err);
    }

    ota_log_progress(100, "Verifying...");
    err = esp_hosted_slave_ota_end();
    if (err != ESP_OK) {
        return ota_finish_failure(err);
    }

    bool activate_supported = (current_ver.major1 > 2) ||
                              (current_ver.major1 == 2 && current_ver.minor1 >= 6);
    if (activate_supported) {
        err = esp_hosted_slave_ota_activate();
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "ESP32-C5 slave OTA activate failed: %s; firmware should activate after reboot",
                     esp_err_to_name(err));
        }
    }

    ota_finish_success_and_reboot();
    return ESP_OK;
}
