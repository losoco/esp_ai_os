#include <string.h>
#include <stdbool.h>
#include "esp_log.h"
#include "dev_display_lcd.h"
#include "esp_lcd_nv3051f.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_io_expander_tca95xx_16bit.h"
#include "esp_io_expander.h"
#include "esp_board_device.h"
#include "esp_board_periph.h"
#include "esp_cam_sensor_xclk.h"
#include "driver/i2c_master.h"
#include "driver/uart.h"
#include "esp_board_entry.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "METALIO_CLAW_4";

#define BT_UART_NUM      UART_NUM_2
#define BT_UART_TX_PIN   GPIO_NUM_26
#define BT_UART_RX_PIN   GPIO_NUM_27
#define BT_UART_BAUD_RATE 115200

static uart_port_t s_bt_uart_num = BT_UART_NUM;
static bool s_bt_uart_released = false;

/**
 * BT module init task.
 *
 * The BT audio chip is the I2S clock master (provides BCLK/WS).
 * After power-on it needs AT commands to enter Mode 1 (receive mode),
 * which activates the I2S clock output so the ESP32-P4 I2S slave can
 * exchange audio data.
 *
 * Mode 1 sequence (matching the reference firmware):
 *   1. AT+RX=2   - set receive mode
 *   2. wait 700ms
 *   3. AT+MODE=1 - apply mode
 *
 * After sending the commands the UART driver is released so that Lua
 * scripts can re-open UART2 to switch modes later.
 */
static void bt_module_mode_init_task(void *param)
{
    /* Allow the BT chip to finish booting after BT_POWER goes high */
    vTaskDelay(pdMS_TO_TICKS(500));

    const char *cmd_rx   = "AT+RX=2\r\n";
    const char *cmd_mode = "AT+MODE=1\r\n";

    ESP_LOGI(TAG, "BT module: TX %s", "AT+RX=2");
    uart_write_bytes(BT_UART_NUM, cmd_rx, strlen(cmd_rx));

    vTaskDelay(pdMS_TO_TICKS(700));

    ESP_LOGI(TAG, "BT module: TX %s", "AT+MODE=1");
    uart_write_bytes(BT_UART_NUM, cmd_mode, strlen(cmd_mode));

    /* Give the BT chip time to apply the mode before releasing UART */
    vTaskDelay(pdMS_TO_TICKS(200));

    /* Release UART so Lua scripts can re-open it for mode switching */
    uart_driver_delete(BT_UART_NUM);
    s_bt_uart_released = true;

    ESP_LOGI(TAG, "BT module mode init complete (Mode 1), UART2 released");
    vTaskDelete(NULL);
}

static int bt_module_init(void *cfg, int cfg_size, void **device_handle)
{
    ESP_LOGI(TAG, "Initializing BT module UART (TX:%d, RX:%d, baud:%d)",
             BT_UART_TX_PIN, BT_UART_RX_PIN, BT_UART_BAUD_RATE);

    uart_config_t uart_config = {
        .baud_rate = BT_UART_BAUD_RATE,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(BT_UART_NUM, 2048, 2048, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(BT_UART_NUM, &uart_config));
    ESP_ERROR_CHECK(uart_set_pin(BT_UART_NUM, BT_UART_TX_PIN, BT_UART_RX_PIN,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

    ESP_LOGI(TAG, "BT module UART initialized, starting mode init task");

    /* Launch async task to send AT commands, then release UART */
    xTaskCreate(bt_module_mode_init_task, "bt_mode_init", 4096, NULL, 5, NULL);

    *device_handle = (void *)(uintptr_t)BT_UART_NUM;
    return 0;
}

static int bt_module_deinit(void *device_handle)
{
    /* UART is already released by the init task; nothing to do here */
    if (!s_bt_uart_released) {
        ESP_LOGI(TAG, "Deinitializing BT module UART");
        uart_driver_delete((uart_port_t)(uintptr_t)device_handle);
    }
    return 0;
}

ESP_BOARD_ENTRY_IMPLEMENT(bt_module, bt_module_init, bt_module_deinit);

/* ── Camera Power Control (PWDN toggle) ───────────────────────────────
 *
 * OV2710 boot sequence: XCLK must be running BEFORE PWDN goes low.
 * The sensor initializes internal registers only when XCLK is present.
 *
 * Sequence (matching MetalioClaw4):
 * 1. Start XCLK (GPIO32, 24MHz)
 * 2. Wait 50ms for internal PLL to lock
 * 3. Toggle PWDN: HIGH (off) → LOW (on)
 * 4. Wait 200ms for sensor to initialize
 * 5. Camera driver probes SCCB (already ready)
 */
static int camera_pwr_init(void *cfg, int cfg_size, void **device_handle)
{
    esp_io_expander_handle_t *io_expander_ptr = NULL;
    esp_err_t ret = esp_board_device_get_handle("gpio_expander_tca9555",
                                                 (void **)&io_expander_ptr);
    if (ret != ESP_OK || io_expander_ptr == NULL || *io_expander_ptr == NULL) {
        ESP_LOGE(TAG, "camera_pwr: failed to get IO expander handle");
        return -1;
    }

    esp_io_expander_handle_t io_expander = *io_expander_ptr;

    /* Step 1: Start XCLK first - OV2710 needs clock to initialize */
    ESP_LOGI(TAG, "camera_pwr: starting XCLK on GPIO32 @ 24MHz");
    esp_cam_sensor_xclk_handle_t xclk_handle = NULL;
    ret = esp_cam_sensor_xclk_allocate(ESP_CAM_SENSOR_XCLK_ESP_CLOCK_ROUTER, &xclk_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "camera_pwr: failed to allocate XCLK handle");
        return -1;
    }

    esp_cam_sensor_xclk_config_t xclk_config = {
        .esp_clock_router_cfg = {
            .xclk_pin = 32,
            .xclk_freq_hz = 24000000,
        },
    };
    ret = esp_cam_sensor_xclk_start(xclk_handle, &xclk_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "camera_pwr: failed to start XCLK");
        esp_cam_sensor_xclk_free(xclk_handle);
        return -1;
    }

    /* Step 2: Wait 50ms for sensor internal PLL to lock onto XCLK */
    vTaskDelay(pdMS_TO_TICKS(50));

    /* Step 3: Toggle PWDN (P0-2): HIGH (off) → LOW (on) */
    ESP_LOGI(TAG, "camera_pwr: power-cycling CAM_PWDN (P0-2)");
    esp_io_expander_set_level(io_expander, BIT(2), 1);  /* HIGH = off */
    vTaskDelay(pdMS_TO_TICKS(50));
    esp_io_expander_set_level(io_expander, BIT(2), 0);  /* LOW  = on */

    /* Step 4: Wait 200ms for sensor initialization */
    vTaskDelay(pdMS_TO_TICKS(200));

    ESP_LOGI(TAG, "camera_pwr: sensor ready (XCLK running, PWDN low)");

    /* Diagnostic: probe OV2710 on shared I2C bus (7-bit addr 0x36) */
    void *i2c_handle = NULL;
    ret = esp_board_periph_ref_handle("i2c_master", &i2c_handle);
    if (ret == ESP_OK && i2c_handle != NULL) {
        esp_err_t probe = i2c_master_probe((i2c_master_bus_handle_t)i2c_handle,
                                           0x36, 200);
        if (probe == ESP_OK) {
            ESP_LOGI(TAG, "camera_pwr: OV2710 detected on I2C addr 0x36");
        } else {
            ESP_LOGE(TAG, "camera_pwr: OV2710 NOT found on I2C addr 0x36 (err: %s)",
                     esp_err_to_name(probe));
        }
        esp_board_periph_unref_handle("i2c_master");
    } else {
        ESP_LOGE(TAG, "camera_pwr: failed to get I2C handle for probe");
    }

    *device_handle = (void *)xclk_handle;
    return 0;
}

static int camera_pwr_deinit(void *device_handle)
{
    esp_cam_sensor_xclk_handle_t xclk_handle = (esp_cam_sensor_xclk_handle_t)device_handle;
    if (xclk_handle != NULL) {
        esp_cam_sensor_xclk_stop(xclk_handle);
        esp_cam_sensor_xclk_free(xclk_handle);
    }
    return 0;
}

ESP_BOARD_ENTRY_IMPLEMENT(camera_pwr, camera_pwr_init, camera_pwr_deinit);

esp_err_t lcd_dsi_panel_factory_entry_t(esp_lcd_dsi_bus_handle_t dsi_handle, dev_display_lcd_config_t *lcd_cfg, dev_display_lcd_handles_t *lcd_handles)
{
    nv3051f_vendor_config_t vendor_config = {
        .mipi_config = {
            .dsi_bus = dsi_handle,
            .dpi_config = &lcd_cfg->sub_cfg.dsi.dpi_config,
        },
    };

    const esp_lcd_panel_dev_config_t lcd_dev_config = {
        .reset_gpio_num = lcd_cfg->sub_cfg.dsi.reset_gpio_num,
        .rgb_ele_order = lcd_cfg->rgb_ele_order,
        .bits_per_pixel = lcd_cfg->bits_per_pixel,
        .flags = {
            .reset_active_high = lcd_cfg->sub_cfg.dsi.reset_active_high,
        },
        .vendor_config = &vendor_config,
    };

    esp_err_t ret = esp_lcd_new_panel_nv3051f(lcd_handles->io_handle, &lcd_dev_config, &lcd_handles->panel_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create NV3051F panel: %s", esp_err_to_name(ret));
        return ESP_FAIL;
    }

    return ESP_OK;
}

esp_err_t io_expander_factory_entry_t(i2c_master_bus_handle_t i2c_handle,
                                      const uint16_t dev_addr,
                                      esp_io_expander_handle_t *handle_ret)
{
    esp_err_t ret = esp_io_expander_new_i2c_tca95xx_16bit(i2c_handle, dev_addr, handle_ret);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create TCA9555 IO expander: %s", esp_err_to_name(ret));
    }
    return ret;
}

esp_err_t lcd_touch_factory_entry_t(esp_lcd_panel_io_handle_t io, const esp_lcd_touch_config_t *touch_dev_config, esp_lcd_touch_handle_t *ret_touch)
{
    esp_err_t ret = esp_lcd_touch_new_i2c_gt911(io, touch_dev_config, ret_touch);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create GT911 touch driver: %s", esp_err_to_name(ret));
        return ret;
    }

    return ESP_OK;
}
