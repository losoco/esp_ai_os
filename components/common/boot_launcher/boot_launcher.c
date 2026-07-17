/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "boot_launcher.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "cap_lua.h"
#include "claw_paths.h"
#include "display_arbiter.h"
#if CONFIG_ESP_BOARD_DEV_LCD_TOUCH_SUPPORT
#include "esp_board_manager_includes.h"
#endif
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "boot_launcher";

#define LAUNCHER_JOB_NAME       "boot_launcher"
#define SCANNER_JOB_NAME        "launcher_scanner"
#define LAUNCHER_ARGS           "{\"__launcher_worker\":true}"
#define SCRIPT_STOP_WAIT_MS     500
#define LAUNCHER_RESTART_DELAY_MS 300

#if CONFIG_ESP_BOARD_DEV_LCD_TOUCH_SUPPORT
#define TOUCH_POLL_MS     50
#define LONG_PRESS_MS     3000

typedef enum {
    TOUCH_EVENT_NONE = 0,
    TOUCH_EVENT_DOWN,
    TOUCH_EVENT_MOVE,
    TOUCH_EVENT_UP,
} touch_event_t;

typedef struct {
    uint16_t screen_width;
    uint16_t screen_height;
} touch_monitor_args_t;

static esp_lcd_touch_handle_t s_touch_handle;
static TaskHandle_t s_touch_task;
static TaskHandle_t s_stop_task;
#endif

static void stop_all_scripts_except_launcher(void)
{
    char output[128] = {0};
    esp_err_t err = cap_lua_stop_all_jobs("display", SCRIPT_STOP_WAIT_MS, output, sizeof(output));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Stop display jobs failed: %s (output: %s)", esp_err_to_name(err), output);
        return;
    }
    ESP_LOGI(TAG, "%s", output);
}

static bool file_exists(const char *path)
{
    struct stat st;
    return path != NULL && stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static esp_err_t resolve_launcher_path(char *launcher_path, size_t launcher_path_size)
{
    char data_launcher[128] = {0};
    esp_err_t err = claw_paths_join(CLAW_PATH_DATA, "launcher.lua", data_launcher, sizeof(data_launcher));
    if (err == ESP_OK && file_exists(data_launcher)) {
        ESP_LOGI(TAG, "Using developer launcher: %s", data_launcher);
        strlcpy(launcher_path, data_launcher, launcher_path_size);
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Developer launcher not found, using system launcher");
    return claw_paths_join(CLAW_PATH_SYSTEM, "launcher.lua", launcher_path, launcher_path_size);
}

static esp_err_t launcher_run(void)
{
    char launcher_path[128] = {0};
    char *output = calloc(1, 256);
    if (!output) {
        return ESP_ERR_NO_MEM;
    }

    esp_err_t err = resolve_launcher_path(launcher_path, sizeof(launcher_path));
    if (err != ESP_OK) {
        free(output);
        ESP_LOGE(TAG, "Failed to resolve launcher path: %s", esp_err_to_name(err));
        return err;
    }

    err = cap_lua_run_script_async(launcher_path,
                                   LAUNCHER_ARGS,
                                   0,
                                   LAUNCHER_JOB_NAME,
                                   NULL,
                                   true,
                                   output,
                                   256);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Launcher start failed: %s (output: %s)", esp_err_to_name(err), output);
    }
    free(output);
    return err;
}

#if CONFIG_ESP_BOARD_DEV_LCD_TOUCH_SUPPORT
static void stop_scripts_task(void *arg)
{
    (void)arg;
    stop_all_scripts_except_launcher();
    s_stop_task = NULL;
    vTaskDelete(NULL);
}

static void stop_all_scripts_except_launcher_async(void)
{
    if (s_stop_task) {
        ESP_LOGI(TAG, "Stop scripts task already running");
        return;
    }

    BaseType_t task_ok = xTaskCreate(stop_scripts_task, "boot_stop_scripts", 4096, NULL, 5, &s_stop_task);
    if (task_ok != pdPASS) {
        s_stop_task = NULL;
        ESP_LOGW(TAG, "Failed to create stop scripts task, stopping synchronously");
        stop_all_scripts_except_launcher();
    }
}
#else
static void stop_all_scripts_except_launcher_async(void)
{
    stop_all_scripts_except_launcher();
}
#endif

__attribute__((weak)) void motion_swipe_up(int16_t dx, int16_t dy)
{
    ESP_LOGI(TAG, "Swipe UP (dx=%d, dy=%d), stopping scripts", dx, dy);
    stop_all_scripts_except_launcher_async();
}

__attribute__((weak)) void motion_swipe_down(int16_t dx, int16_t dy)
{
    ESP_LOGI(TAG, "Swipe DOWN (dx=%d, dy=%d)", dx, dy);
}

__attribute__((weak)) void motion_swipe_left(int16_t dx, int16_t dy)
{
    ESP_LOGI(TAG, "Swipe LEFT (dx=%d, dy=%d)", dx, dy);
}

__attribute__((weak)) void motion_swipe_right(int16_t dx, int16_t dy)
{
    ESP_LOGI(TAG, "Swipe RIGHT (dx=%d, dy=%d)", dx, dy);
}

#if CONFIG_ESP_BOARD_DEV_LCD_TOUCH_SUPPORT
static void handle_touch_event(touch_event_t event, uint16_t x, uint16_t y, uint16_t screen_width, uint16_t screen_height)
{
    static bool pressed;
    static uint32_t press_tick_ms;
    static uint16_t down_x;
    static uint16_t down_y;
    static uint16_t last_x;
    static uint16_t last_y;

    switch (event) {
    case TOUCH_EVENT_DOWN:
        pressed = true;
        press_tick_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;
        down_x = x;
        down_y = y;
        last_x = x;
        last_y = y;
        break;

    case TOUCH_EVENT_MOVE: {
        last_x = x;
        last_y = y;
        uint32_t now_ms = xTaskGetTickCount() * portTICK_PERIOD_MS;
        if ((now_ms - press_tick_ms) >= LONG_PRESS_MS) {
            ESP_LOGI(TAG, "Touch long-press detected");
            pressed = false;
            press_tick_ms = 0;
        }
        break;
    }

    case TOUCH_EVENT_UP: {
        if (!pressed) {
            break;
        }
        int16_t dx = (int16_t)last_x - (int16_t)down_x;
        int16_t dy = (int16_t)last_y - (int16_t)down_y;
        int16_t abs_dx = dx < 0 ? -dx : dx;
        int16_t abs_dy = dy < 0 ? -dy : dy;
        uint16_t min_dim = screen_width < screen_height ? screen_width : screen_height;
        uint16_t swipe_threshold = min_dim / 8;
        uint16_t edge_margin = min_dim / 6;

        if (abs_dx >= swipe_threshold || abs_dy >= swipe_threshold) {
            bool from_left = down_x < edge_margin;
            bool from_right = down_x > (uint16_t)(screen_width - edge_margin);
            bool from_top = down_y < edge_margin;
            bool from_bottom = down_y > (uint16_t)(screen_height - edge_margin);

            if (abs_dx >= abs_dy) {
                if (dx > 0 && from_left) {
                    motion_swipe_right(dx, dy);
                } else if (dx < 0 && from_right) {
                    motion_swipe_left(dx, dy);
                }
            } else {
                if (dy > 0 && from_top) {
                    motion_swipe_down(dx, dy);
                } else if (dy < 0 && from_bottom) {
                    motion_swipe_up(dx, dy);
                }
            }
        }
        pressed = false;
        press_tick_ms = 0;
        break;
    }

    default:
        break;
    }
}

static void touch_monitor_task(void *arg)
{
    touch_monitor_args_t *args = (touch_monitor_args_t *)arg;
    uint16_t screen_width = args->screen_width;
    uint16_t screen_height = args->screen_height;
    bool pressed = false;
    TickType_t last_wake = xTaskGetTickCount();
    free(arg);

    ESP_LOGI(TAG, "Touch monitor started");
    while (1) {
        uint16_t x = 0;
        uint16_t y = 0;
        uint16_t strength = 0;
        uint8_t point_num = 0;

        esp_lcd_touch_read_data(s_touch_handle);
        bool touching = esp_lcd_touch_get_coordinates(s_touch_handle, &x, &y, &strength, &point_num, 1);

        if (touching && point_num > 0) {
            handle_touch_event(pressed ? TOUCH_EVENT_MOVE : TOUCH_EVENT_DOWN, x, y, screen_width, screen_height);
            pressed = true;
        } else if (pressed) {
            handle_touch_event(TOUCH_EVENT_UP, x, y, screen_width, screen_height);
            pressed = false;
        }

        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(TOUCH_POLL_MS));
    }
}

static esp_err_t boot_launcher_start_touch_monitor(void)
{
    void *touch_handle = NULL;
    esp_err_t err = esp_board_manager_get_device_handle(ESP_BOARD_DEVICE_NAME_LCD_TOUCH, &touch_handle);
    if (err != ESP_OK || !touch_handle) {
        ESP_LOGI(TAG, "No touch device, gesture detection disabled");
        return ESP_OK;
    }

    dev_lcd_touch_handles_t *touch_handles = (dev_lcd_touch_handles_t *)touch_handle;
    if (!touch_handles->touch_handle) {
        ESP_LOGI(TAG, "LCD touch handle is NULL, gesture detection disabled");
        return ESP_OK;
    }
    s_touch_handle = touch_handles->touch_handle;

    uint16_t screen_width = 720;
    uint16_t screen_height = 720;
    void *lcd_config = NULL;
    if (esp_board_manager_get_device_config(ESP_BOARD_DEVICE_NAME_DISPLAY_LCD, &lcd_config) == ESP_OK && lcd_config) {
        dev_display_lcd_config_t *cfg = (dev_display_lcd_config_t *)lcd_config;
        screen_width = cfg->lcd_width;
        screen_height = cfg->lcd_height;
    }

    touch_monitor_args_t *args = malloc(sizeof(touch_monitor_args_t));
    if (!args) {
        return ESP_ERR_NO_MEM;
    }
    args->screen_width = screen_width;
    args->screen_height = screen_height;

    BaseType_t task_ok = xTaskCreate(touch_monitor_task, "boot_touch", 4096, args, 5, &s_touch_task);
    if (task_ok != pdPASS) {
        free(args);
        s_touch_handle = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
#else
static esp_err_t boot_launcher_start_touch_monitor(void)
{
    ESP_LOGI(TAG, "Touch support not compiled in, gesture detection disabled");
    return ESP_OK;
}
#endif

static void restart_launcher_deferred(void *arg)
{
    (void)arg;

    /* Wait for the exiting script's Lua state to fully destroy and its
     * job to reach a terminal state. The callback fires synchronously
     * inside lvgl.deinit → display_arbiter_release, but the async job
     * runner hasn't finalized the job status yet. Racing with the
     * cleanup can also cause display hardware conflicts (especially on
     * MIPI DSI panels where the DMA engine may still be flushing). */
    vTaskDelay(pdMS_TO_TICKS(LAUNCHER_RESTART_DELAY_MS));

    size_t active_count = cap_lua_get_active_async_job_count();
    ESP_LOGI(TAG, "Deferred restart: active_count=%u display_owner=%d",
             (unsigned)active_count, (int)display_arbiter_get_owner());
    if (active_count == 0) {
        ESP_LOGI(TAG, "No active scripts, restarting launcher (deferred)");
        (void)launcher_run();
    } else {
        ESP_LOGI(TAG, "Scripts still active after delay, skipping launcher restart");
    }

    vTaskDelete(NULL);
}

static void on_display_owner_changed(display_arbiter_owner_t owner, void *user_ctx)
{
    (void)user_ctx;

    if (owner != DISPLAY_ARBITER_OWNER_EMOTE) {
        return;
    }

    /* Only skip restart if the launcher itself is currently running
     * (e.g. during the app-launch transition when the launcher briefly
     * releases the display before handing it to the app). */
    char *jobs = calloc(1, 1024);
    if (jobs) {
        esp_err_t err = cap_lua_list_jobs("running", jobs, 1024);
        if (err == ESP_OK) {
            char tag[64];
            int written = snprintf(tag, sizeof(tag), "name=%s", LAUNCHER_JOB_NAME);
            if (written > 0 && (size_t)written < sizeof(tag) && strstr(jobs, tag)) {
                ESP_LOGI(TAG, "Launcher is running, skipping restart");
                free(jobs);
                return;
            }
        }
        free(jobs);
    }

    /* Defer launcher restart so the exiting script's cleanup (lvgl,
     * display DMA, job status) can fully settle before we spin up a
     * new LVGL instance on the same panel hardware. */
    ESP_LOGI(TAG, "Display returned to emote, scheduling deferred launcher restart (%lu ms)",
             (unsigned long)LAUNCHER_RESTART_DELAY_MS);
    if (xTaskCreate(restart_launcher_deferred, "launch_rst", 8192, NULL, 1, NULL) != pdPASS) {
        ESP_LOGW(TAG, "Failed to create deferred restart task, launcher will not restart this cycle");
    }
}

esp_err_t boot_launcher_start(void)
{
    ESP_RETURN_ON_ERROR(launcher_run(), TAG, "Failed to start launcher");
    ESP_RETURN_ON_ERROR(display_arbiter_set_owner_changed_callback(on_display_owner_changed, NULL),
                        TAG, "Failed to register display owner callback");
    ESP_RETURN_ON_ERROR(boot_launcher_start_touch_monitor(), TAG, "Failed to start touch monitor");
    return ESP_OK;
}
