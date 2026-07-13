/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "http_server_priv.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#include "esp_log.h"
#include "esp_console.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

static const char *TAG = "http_term";

#define TERM_WS_MAX_CLIENTS  4
#define TERM_RING_BUF_SIZE   8192
#define TERM_LOG_MAX_LEN     512
#define TERM_CMD_MAX_LEN     1024

static httpd_handle_t    s_httpd;
static SemaphoreHandle_t s_ws_mx;
static int               s_ws_fds[TERM_WS_MAX_CLIENTS];
static size_t            s_ws_count;

/* Ring buffer for log backlog (sent to clients on connect) */
static char             *s_ring_buf;
static size_t            s_ring_write;
static size_t            s_ring_len;
static SemaphoreHandle_t s_ring_mx;

/* Log hook - lazily installed when first client connects */
static vprintf_like_t    s_orig_vprintf;
static volatile bool     s_hook_active;

/* Command execution mutex (serializes stdout redirect) */
static SemaphoreHandle_t s_cmd_mx;

/* ---- Hook install / uninstall ---- */

static int term_log_vprintf(const char *fmt, va_list args);

static void term_hook_install(void)
{
    if (s_hook_active) {
        return;
    }
    if (!s_ring_buf) {
        s_ring_buf = malloc(TERM_RING_BUF_SIZE);
        if (!s_ring_buf) {
            ESP_LOGE(TAG, "failed to allocate ring buffer");
            return;
        }
    }
    s_orig_vprintf = esp_log_set_vprintf(term_log_vprintf);
    s_hook_active = true;
    ESP_LOGI(TAG, "log vprintf hook installed");
}

static void term_hook_uninstall(void)
{
    if (!s_hook_active) {
        return;
    }
    esp_log_set_vprintf(s_orig_vprintf);
    s_hook_active = false;
    ESP_LOGI(TAG, "log vprintf hook removed");
}

/* ---- WS fd management ---- */

static void term_ws_fd_add(int fd)
{
    xSemaphoreTake(s_ws_mx, portMAX_DELAY);
    for (size_t i = 0; i < s_ws_count; i++) {
        if (s_ws_fds[i] == fd) {
            xSemaphoreGive(s_ws_mx);
            return;
        }
    }
    if (s_ws_count < TERM_WS_MAX_CLIENTS) {
        s_ws_fds[s_ws_count++] = fd;
    }
    xSemaphoreGive(s_ws_mx);

    /* Install log hook when first client connects */
    if (s_ws_count == 1) {
        term_hook_install();
    }
}

void http_server_terminal_ws_fd_remove(int fd)
{
    if (!s_ws_mx) {
        return;
    }
    xSemaphoreTake(s_ws_mx, portMAX_DELAY);
    size_t w = 0;
    for (size_t i = 0; i < s_ws_count; i++) {
        if (s_ws_fds[i] != fd) {
            s_ws_fds[w++] = s_ws_fds[i];
        }
    }
    s_ws_count = w;
    xSemaphoreGive(s_ws_mx);

    /* Uninstall log hook when last client disconnects */
    if (s_ws_count == 0) {
        term_hook_uninstall();
    }
}

static size_t term_collect_fds(int *out_fds)
{
    if (!s_ws_mx) {
        return 0;
    }
    xSemaphoreTake(s_ws_mx, portMAX_DELAY);
    size_t count = 0;
    if (s_httpd) {
        for (size_t i = 0; i < s_ws_count && count < TERM_WS_MAX_CLIENTS; i++) {
            httpd_ws_client_info_t info = httpd_ws_get_fd_info(s_httpd, s_ws_fds[i]);
            if (info == HTTPD_WS_CLIENT_WEBSOCKET) {
                out_fds[count++] = s_ws_fds[i];
            }
        }
    }
    /* Compact in-place */
    s_ws_count = count;
    for (size_t i = 0; i < count; i++) {
        s_ws_fds[i] = out_fds[i];
    }
    xSemaphoreGive(s_ws_mx);
    return count;
}

/* ---- Ring buffer ---- */

static void term_ring_write(const char *data, size_t len)
{
    if (!s_ring_buf || len == 0) {
        return;
    }
    if (len > TERM_RING_BUF_SIZE) {
        data += len - TERM_RING_BUF_SIZE;
        len = TERM_RING_BUF_SIZE;
    }
    xSemaphoreTake(s_ring_mx, portMAX_DELAY);
    size_t first = TERM_RING_BUF_SIZE - s_ring_write;
    if (first > len) {
        first = len;
    }
    memcpy(s_ring_buf + s_ring_write, data, first);
    if (len > first) {
        memcpy(s_ring_buf, data + first, len - first);
    }
    s_ring_write = (s_ring_write + len) % TERM_RING_BUF_SIZE;
    if (s_ring_len + len > TERM_RING_BUF_SIZE) {
        s_ring_len = TERM_RING_BUF_SIZE;
    } else {
        s_ring_len += len;
    }
    xSemaphoreGive(s_ring_mx);
}

/* ---- Broadcast ---- */

typedef struct {
    char *text;
    size_t len;
    int fds[TERM_WS_MAX_CLIENTS];
    size_t fd_count;
} term_broadcast_job_t;

static void term_broadcast_job_run(void *arg)
{
    term_broadcast_job_t *job = arg;
    if (!job) {
        return;
    }
    httpd_ws_frame_t pkt = {
        .type = HTTPD_WS_TYPE_TEXT,
        .payload = (uint8_t *)job->text,
        .len = job->len,
    };
    for (size_t i = 0; i < job->fd_count; i++) {
        if (httpd_ws_send_frame_async(s_httpd, job->fds[i], &pkt) != ESP_OK) {
            http_server_terminal_ws_fd_remove(job->fds[i]);
        }
    }
    free(job->text);
    free(job);
}

static void term_broadcast_text(const char *text, size_t len)
{
    if (!s_httpd || len == 0) {
        return;
    }
    int fds[TERM_WS_MAX_CLIENTS];
    size_t fd_count = term_collect_fds(fds);
    if (fd_count == 0) {
        return;
    }

    term_broadcast_job_t *job = calloc(1, sizeof(term_broadcast_job_t));
    if (!job) {
        return;
    }
    job->text = malloc(len);
    if (!job->text) {
        free(job);
        return;
    }
    memcpy(job->text, text, len);
    job->len = len;
    memcpy(job->fds, fds, fd_count * sizeof(int));
    job->fd_count = fd_count;

    if (httpd_queue_work(s_httpd, term_broadcast_job_run, job) != ESP_OK) {
        free(job->text);
        free(job);
    }
}

/* ---- Log hook ---- */

static int term_log_vprintf(const char *fmt, va_list args)
{
    /* Call original to keep UART output */
    va_list args_copy;
    va_copy(args_copy, args);
    int ret = s_orig_vprintf ? s_orig_vprintf(fmt, args_copy) : 0;
    va_end(args_copy);

    if (!s_hook_active) {
        return ret;
    }

    /* Format into heap buffer (avoids 512B on stack) */
    char *buf = malloc(TERM_LOG_MAX_LEN);
    if (!buf) {
        return ret;
    }
    int len = vsnprintf(buf, TERM_LOG_MAX_LEN, fmt, args);
    if (len > 0) {
        term_ring_write(buf, (size_t)len);
        term_broadcast_text(buf, (size_t)len);
    }
    free(buf);
    return ret;
}

/* ---- Command execution ---- */

static void term_run_command(const char *cmdline)
{
    if (!s_cmd_mx || !cmdline || !cmdline[0]) {
        return;
    }

    xSemaphoreTake(s_cmd_mx, portMAX_DELAY);

    char *buffer = NULL;
    size_t buffer_len = 0;
    FILE *capture = open_memstream(&buffer, &buffer_len);
    if (capture) {
        fflush(stdout);
        FILE *saved = stdout;
        stdout = capture;

        int cmd_ret = -1;
        esp_err_t run_err = esp_console_run(cmdline, &cmd_ret);

        fflush(stdout);
        stdout = saved;
        fclose(capture);

        if (buffer && buffer_len > 0) {
            term_broadcast_text(buffer, buffer_len);
        }
        free(buffer);

        if (run_err != ESP_OK) {
            char err_msg[128];
            const char *err_str = (run_err == ESP_ERR_NOT_FOUND)
                ? "Command not found"
                : esp_err_to_name(run_err);
            snprintf(err_msg, sizeof(err_msg), "\r\n[error: %s]\r\n", err_str);
            term_broadcast_text(err_msg, strlen(err_msg));
        } else if (cmd_ret != 0) {
            char ret_msg[64];
            snprintf(ret_msg, sizeof(ret_msg), "\r\n[exit code: %d]\r\n", cmd_ret);
            term_broadcast_text(ret_msg, strlen(ret_msg));
        }
    }

    xSemaphoreGive(s_cmd_mx);
}

/* ---- WebSocket handler ---- */

static esp_err_t term_ws_handler(httpd_req_t *req)
{
    int fd = httpd_req_to_sockfd(req);

    /* First invocation is the HTTP GET upgrade handshake */
    if (req->method == HTTP_GET) {
        term_ws_fd_add(fd);
        ESP_LOGI(TAG, "terminal client connected fd=%d", fd);
        return ESP_OK;
    }

    term_ws_fd_add(fd);

    /* Receive WebSocket frame */
    httpd_ws_frame_t ws_pkt;
    memset(&ws_pkt, 0, sizeof(ws_pkt));
    esp_err_t ret = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (ret != ESP_OK) {
        http_server_terminal_ws_fd_remove(fd);
        return ret;
    }

    if (ws_pkt.type == HTTPD_WS_TYPE_CLOSE) {
        http_server_terminal_ws_fd_remove(fd);
        return ESP_OK;
    }

    if (ws_pkt.type == HTTPD_WS_TYPE_PING) {
        httpd_ws_frame_t pong = { .type = HTTPD_WS_TYPE_PONG };
        return httpd_ws_send_frame(req, &pong);
    }

    if (ws_pkt.type != HTTPD_WS_TYPE_TEXT || ws_pkt.len == 0) {
        return ESP_OK;
    }

    if (ws_pkt.len > TERM_CMD_MAX_LEN) {
        const char *msg = "\r\n[error: command too long]\r\n";
        httpd_ws_frame_t err = {
            .type = HTTPD_WS_TYPE_TEXT,
            .payload = (uint8_t *)msg,
            .len = strlen(msg),
        };
        httpd_ws_send_frame(req, &err);
        return ESP_OK;
    }

    char *cmd = malloc(ws_pkt.len + 1);
    if (!cmd) {
        return ESP_ERR_NO_MEM;
    }
    ws_pkt.payload = (uint8_t *)cmd;
    ret = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
    if (ret != ESP_OK) {
        free(cmd);
        return ret;
    }
    cmd[ws_pkt.len] = '\0';

    /* Execute the command (output goes through log hook + stdout capture) */
    term_run_command(cmd);
    free(cmd);

    return ESP_OK;
}

/* ---- Route registration ---- */

esp_err_t http_server_register_terminal_routes(httpd_handle_t server)
{
    s_httpd = server;

    if (!s_ws_mx) {
        s_ws_mx = xSemaphoreCreateMutex();
    }
    if (!s_ring_mx) {
        s_ring_mx = xSemaphoreCreateMutex();
    }
    if (!s_cmd_mx) {
        s_cmd_mx = xSemaphoreCreateMutex();
    }
    if (!s_ws_mx || !s_ring_mx || !s_cmd_mx) {
        return ESP_ERR_NO_MEM;
    }

    /* Log hook is NOT installed here - deferred to first WS client connect */

    const httpd_uri_t handlers[] = {
        {
            .uri = "/ws/terminal",
            .method = HTTP_GET,
            .handler = term_ws_handler,
            .is_websocket = true,
        },
    };

    for (size_t i = 0; i < sizeof(handlers) / sizeof(handlers[0]); ++i) {
        esp_err_t err = httpd_register_uri_handler(server, &handlers[i]);
        if (err != ESP_OK) {
            return err;
        }
    }
    return ESP_OK;
}
