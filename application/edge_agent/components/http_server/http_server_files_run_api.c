/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "http_server_priv.h"

#include <string.h>

#include "cap_lua.h"

static esp_err_t files_run_handler(httpd_req_t *req)
{
    cJSON *root = NULL;
    if (http_server_parse_json_body(req, &root) != ESP_OK) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid JSON body");
    }

    cJSON *path_item = cJSON_GetObjectItemCaseSensitive(root, "path");
    if (!cJSON_IsString(path_item)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing path");
    }

    /* Resolve relative path through the storage resolver (handles / → /sdcard prefix) */
    char resolved_path[256] = {0};
    if (http_server_resolve_storage_path(path_item->valuestring, resolved_path, sizeof(resolved_path)) != ESP_OK) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid path");
    }

    cJSON *timeout_item = cJSON_GetObjectItemCaseSensitive(root, "timeout_ms");
    const uint32_t timeout_ms = cJSON_IsNumber(timeout_item) && timeout_item->valueint > 0
        ? (uint32_t)timeout_item->valueint : 0;

    cJSON *args_item = cJSON_GetObjectItemCaseSensitive(root, "args_json");
    const char *args_json = cJSON_IsString(args_item) ? args_item->valuestring : NULL;
    cJSON_Delete(root);

    char output[1024] = {0};
    esp_err_t err = cap_lua_run_script_async(resolved_path, args_json, timeout_ms,
                                             NULL, NULL, false, output, sizeof(output));
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store, max-age=0");

    if (err != ESP_OK) {
        char body[1100];
        snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}", output);
        httpd_resp_set_status(req, "400 Bad Request");
        return httpd_resp_send(req, body, strlen(body));
    }

    /* Parse job_id from cap_lua output ("Started Lua job <id> ...") */
    cJSON *resp = cJSON_CreateObject();
    if (resp) {
        cJSON_AddBoolToObject(resp, "ok", true);
        /* cap_lua_run_script_async writes "Started Lua job <hex_id> (name=...)
         * ... with job_id=<hex_id> to read ..." */
        const char *id_start = strstr(output, "job_id=");
        if (!id_start) {
            /* Fallback: try "Lua job " prefix */
            id_start = strstr(output, "Lua job ");
            if (id_start) id_start += 8; /* skip "Lua job " */
        } else {
            id_start += 7; /* skip "job_id=" */
        }
        if (id_start) {
            char job_id[32] = {0};
            const char *end = id_start;
            while (*end && *end != ' ' && *end != '.' && *end != '\n') {
                end++;
            }
            size_t len = (size_t)(end - id_start);
            if (len < sizeof(job_id)) {
                memcpy(job_id, id_start, len);
                job_id[len] = '\0';
                cJSON_AddStringToObject(resp, "job_id", job_id);
            }
        }
        char *json_str = cJSON_PrintUnformatted(resp);
        if (json_str) {
            httpd_resp_sendstr(req, json_str);
            free(json_str);
        } else {
            httpd_resp_sendstr(req, "{\"ok\":true}");
        }
        cJSON_Delete(resp);
    } else {
        return httpd_resp_sendstr(req, "{\"ok\":true}");
    }
    return ESP_OK;
}

static esp_err_t files_run_status_handler(httpd_req_t *req)
{
    /* URI: /api/files/run/<job_id> → extract job_id after the prefix */
    const char *prefix = "/api/files/run/";
    size_t prefix_len = strlen(prefix);
    if (strncmp(req->uri, prefix, prefix_len) != 0) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid URI");
    }
    const char *job_id = req->uri + prefix_len;
    if (!job_id[0]) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing job id");
    }

    char output[1024] = {0};
    esp_err_t err = cap_lua_get_job(job_id, output, sizeof(output));
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store, max-age=0");
    if (err != ESP_OK) {
        char body[1100];
        snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}", output);
        httpd_resp_set_status(req, "404 Not Found");
        return httpd_resp_send(req, body, strlen(body));
    }

    /* Convert key=value text to JSON */
    cJSON *resp = cJSON_CreateObject();
    if (!resp) {
        return httpd_resp_sendstr(req, "{\"ok\":true}");
    }
    cJSON_AddBoolToObject(resp, "ok", true);
    cJSON_AddStringToObject(resp, "job_id", job_id);

    char *kv = output;
    while (kv && *kv) {
        char *line_end = strchr(kv, '\n');
        if (line_end) *line_end = '\0';
        char *eq = strchr(kv, '=');
        if (eq) {
            *eq = '\0';
            char *key = kv;
            char *value = eq + 1;
            /* Skip empty lines */
            if (key[0]) {
                cJSON_AddStringToObject(resp, key, value);
            }
        }
        kv = line_end ? line_end + 1 : NULL;
    }

    char *json_str = cJSON_PrintUnformatted(resp);
    if (json_str) {
        httpd_resp_sendstr(req, json_str);
        free(json_str);
    } else {
        httpd_resp_sendstr(req, "{\"ok\":true}");
    }
    cJSON_Delete(resp);
    return ESP_OK;
}

static esp_err_t files_run_stop_handler(httpd_req_t *req)
{
    /* URI: /api/files/run/<job_id>/stop */
    const char *prefix = "/api/files/run/";
    size_t prefix_len = strlen(prefix);
    if (strncmp(req->uri, prefix, prefix_len) != 0) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid URI");
    }
    const char *suffix = req->uri + prefix_len;
    const char *stop_suffix = "/stop";
    size_t job_id_len = strlen(suffix);
    if (job_id_len <= strlen(stop_suffix) ||
        strcmp(suffix + job_id_len - strlen(stop_suffix), stop_suffix) != 0) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid URI");
    }

    char job_id[64];
    size_t copy_len = job_id_len - strlen(stop_suffix);
    if (copy_len >= sizeof(job_id)) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Job id too long");
    }
    memcpy(job_id, suffix, copy_len);
    job_id[copy_len] = '\0';

    char output[1024] = {0};
    esp_err_t err = cap_lua_stop_job(job_id, 2000, output, sizeof(output));
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store, max-age=0");
    if (err != ESP_OK) {
        char body[1100];
        snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}", output);
        httpd_resp_set_status(req, "400 Bad Request");
        return httpd_resp_send(req, body, strlen(body));
    }
    return httpd_resp_sendstr(req, "{\"ok\":true,\"status\":\"stopped\"}");
}

static esp_err_t files_run_list_handler(httpd_req_t *req)
{
    char output[4096] = {0};
    esp_err_t err = cap_lua_list_jobs(NULL, output, sizeof(output));
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store, max-age=0");

    /* cap_lua_list_jobs returns key=value text blocks separated by blank lines.
     * Convert to JSON array of job objects. */
    cJSON *root = cJSON_CreateObject();
    cJSON *jobs_array = cJSON_CreateArray();
    if (!root || !jobs_array) {
        cJSON_Delete(root);
        cJSON_Delete(jobs_array);
        return httpd_resp_sendstr(req, "{\"jobs\":[]}");
    }
    cJSON_AddItemToObject(root, "jobs", jobs_array);

    if (err == ESP_OK && output[0]) {
        char *block = output;
        cJSON *job_obj = cJSON_CreateObject();
        while (block && *block) {
            char *line_end = strchr(block, '\n');
            if (line_end) *line_end = '\0';

            if (block[0] == '\0') {
                /* Blank line = end of job block */
                if (cJSON_GetArraySize(job_obj) > 0) {
                    cJSON_AddItemToArray(jobs_array, job_obj);
                    job_obj = cJSON_CreateObject();
                }
            } else {
                char *eq = strchr(block, '=');
                if (eq) {
                    *eq = '\0';
                    cJSON_AddStringToObject(job_obj, block, eq + 1);
                }
            }

            block = line_end ? line_end + 1 : NULL;
        }
        if (cJSON_GetArraySize(job_obj) > 0) {
            cJSON_AddItemToArray(jobs_array, job_obj);
        } else {
            cJSON_Delete(job_obj);
        }
    }

    char *json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        httpd_resp_sendstr(req, json_str);
        free(json_str);
    } else {
        httpd_resp_sendstr(req, "{\"jobs\":[]}");
    }
    cJSON_Delete(root);
    return ESP_OK;
}

esp_err_t http_server_register_files_run_routes(httpd_handle_t server)
{
    const httpd_uri_t handlers[] = {
        { .uri = "/api/files/run", .method = HTTP_POST, .handler = files_run_handler },
        { .uri = "/api/files/run/list", .method = HTTP_GET, .handler = files_run_list_handler },
        { .uri = "/api/files/run/*", .method = HTTP_GET, .handler = files_run_status_handler },
        { .uri = "/api/files/run/*", .method = HTTP_POST, .handler = files_run_stop_handler },
    };

    for (size_t i = 0; i < sizeof(handlers) / sizeof(handlers[0]); ++i) {
        esp_err_t err = httpd_register_uri_handler(server, &handlers[i]);
        if (err != ESP_OK) {
            return err;
        }
    }
    return ESP_OK;
}
