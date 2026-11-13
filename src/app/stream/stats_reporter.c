#include "stats_reporter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL.h>
#include <curl/curl.h>

#include "app_launch.h"
#include "logging.h"

#define REPORT_QUEUE_SIZE 16
#define REPORT_STATS_INTERVAL_MS 5000
#define REPORT_TIMEOUT_MS 3000

static SDL_mutex *queue_lock = NULL;
static SDL_cond *queue_cond = NULL;
static char *queue[REPORT_QUEUE_SIZE];
static int queue_len = 0;
static bool worker_started = false;

static bool streaming = false;
static bool hud_on = false;
static Uint32 last_stats_ticks = 0;
static char current_host[128];
static char current_app[256];

static const char *report_url() {
    const app_launch_params_t *params = app_launch_params_current();
    if (params == NULL || params->report_url == NULL || params->report_url[0] == '\0') {
        return NULL;
    }
    return params->report_url;
}

static size_t discard_body(void *ptr, size_t size, size_t nmemb, void *userdata) {
    (void) ptr;
    (void) userdata;
    return size * nmemb;
}

static int report_worker(void *arg) {
    (void) arg;
    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        commons_log_error("Reporter", "curl_easy_init failed");
        return -1;
    }
    struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
    while (true) {
        SDL_LockMutex(queue_lock);
        while (queue_len == 0) {
            SDL_CondWait(queue_cond, queue_lock);
        }
        char *payload = queue[0];
        memmove(&queue[0], &queue[1], sizeof(char *) * (queue_len - 1));
        queue_len--;
        SDL_UnlockMutex(queue_lock);

        const char *url = report_url();
        if (url != NULL) {
            curl_easy_reset(curl);
            curl_easy_setopt(curl, CURLOPT_URL, url);
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
            curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long) REPORT_TIMEOUT_MS);
            curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long) REPORT_TIMEOUT_MS);
            curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discard_body);
            CURLcode res = curl_easy_perform(curl);
            if (res != CURLE_OK) {
                commons_log_warn("Reporter", "Report failed: %s", curl_easy_strerror(res));
            }
        }
        free(payload);
    }
    // Never reached, the worker lives as long as the app
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return 0;
}

static bool ensure_worker() {
    if (worker_started) {
        return true;
    }
    queue_lock = SDL_CreateMutex();
    queue_cond = SDL_CreateCond();
    SDL_Thread *thread = SDL_CreateThread(report_worker, "stats-report", NULL);
    if (thread == NULL) {
        commons_log_error("Reporter", "Failed to start reporter thread: %s", SDL_GetError());
        return false;
    }
    SDL_DetachThread(thread);
    worker_started = true;
    return true;
}

/** Takes ownership of payload */
static void enqueue(char *payload, bool droppable) {
    if (payload == NULL) {
        return;
    }
    if (report_url() == NULL || !ensure_worker()) {
        free(payload);
        return;
    }
    SDL_LockMutex(queue_lock);
    if (queue_len >= REPORT_QUEUE_SIZE) {
        if (droppable) {
            // Receiver is too slow; stats are only useful when fresh
            SDL_UnlockMutex(queue_lock);
            free(payload);
            return;
        }
        // Make room for start/stop events by dropping the oldest message
        free(queue[0]);
        memmove(&queue[0], &queue[1], sizeof(char *) * (queue_len - 1));
        queue_len--;
    }
    queue[queue_len++] = payload;
    SDL_CondSignal(queue_cond);
    SDL_UnlockMutex(queue_lock);
}

/** Copies src into dst as a JSON string body (without quotes) */
static void json_escape(char *dst, size_t dst_size, const char *src) {
    size_t j = 0;
    for (size_t i = 0; src != NULL && src[i] != '\0' && j + 7 < dst_size; i++) {
        unsigned char c = (unsigned char) src[i];
        if (c == '"' || c == '\\') {
            dst[j++] = '\\';
            dst[j++] = (char) c;
        } else if (c < 0x20) {
            j += snprintf(dst + j, dst_size - j, "\\u%04x", c);
        } else {
            dst[j++] = (char) c;
        }
    }
    dst[j] = '\0';
}

static char *format_event(const char *event, const char *extra) {
    char host[256], app[512];
    json_escape(host, sizeof(host), current_host);
    json_escape(app, sizeof(app), current_app);
    size_t len = strlen(event) + strlen(host) + strlen(app) + (extra ? strlen(extra) : 0) + 96;
    char *buf = malloc(len);
    if (buf == NULL) {
        return NULL;
    }
    snprintf(buf, len, "{\"event\":\"%s\",\"host\":\"%s\",\"app\":\"%s\",\"hud\":%s%s%s}", event, host, app,
             hud_on ? "true" : "false", extra ? "," : "", extra ? extra : "");
    return buf;
}

bool stats_reporter_active() {
    return streaming && report_url() != NULL;
}

void stats_reporter_stream_started(const char *host, const char *app) {
    snprintf(current_host, sizeof(current_host), "%s", host ? host : "");
    snprintf(current_app, sizeof(current_app), "%s", app ? app : "");
    streaming = true;
    last_stats_ticks = 0;
    if (report_url() == NULL) {
        return;
    }
    commons_log_info("Reporter", "Stream started: %s / %s", current_host, current_app);
    enqueue(format_event("start", NULL), false);
}

void stats_reporter_stream_stopped(const char *reason) {
    if (!streaming) {
        return;
    }
    streaming = false;
    if (report_url() == NULL) {
        return;
    }
    char extra[128], escaped[96];
    json_escape(escaped, sizeof(escaped), reason ? reason : "");
    snprintf(extra, sizeof(extra), "\"reason\":\"%s\"", escaped);
    enqueue(format_event("stop", extra), false);
}

void stats_reporter_set_hud(bool enabled) {
    bool changed = hud_on != enabled;
    hud_on = enabled;
    if (changed && stats_reporter_active()) {
        // Send stats right away so the dashboard reflects the change
        last_stats_ticks = 0;
    }
}

void stats_reporter_push(const stream_stats_snapshot_t *s) {
    if (!stats_reporter_active() || s == NULL) {
        return;
    }
    Uint32 now = SDL_GetTicks();
    if (last_stats_ticks != 0 && now - last_stats_ticks < REPORT_STATS_INTERVAL_MS) {
        return;
    }
    last_stats_ticks = now;
    char format[64];
    json_escape(format, sizeof(format), s->format ? s->format : "");
    char extra[512];
    snprintf(extra, sizeof(extra),
             "\"width\":%d,\"height\":%d,\"format\":\"%s\",\"fps\":%.1f,\"bitrate_mbps\":%.1f,"
             "\"latency_ms\":%.1f,\"rtt_ms\":%u,\"rtt_variance_ms\":%u,\"host_ms\":%.1f,\"decode_ms\":%.1f,"
             "\"drops_pct\":%.2f",
             s->width, s->height, format, s->fps, s->bitrate_mbps, s->total_latency_ms, s->rtt_ms,
             s->rtt_variance_ms, s->host_latency_ms, s->decode_latency_ms, s->drop_rate_pct);
    enqueue(format_event("stats", extra), true);
}
