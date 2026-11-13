#pragma once

#include <stdbool.h>

/**
 * Sends stream status to a URL given in the launch params ("report_url"), e.g. a Home Assistant webhook.
 *
 * Every message is a JSON POST with an "event" field:
 *   - "start": stream opened (host, app)
 *   - "stats": every few seconds while streaming (latency, fps, bitrate, ...)
 *   - "stop":  stream closed
 *
 * Requests run on a background thread, so a slow or offline receiver never blocks the stream.
 */

typedef struct stream_stats_snapshot_t {
    int width, height;
    const char *format;
    float fps;
    float bitrate_mbps;
    /** Rough end-to-end estimate: host processing + half the network round trip + decode */
    float total_latency_ms;
    /** -1 if not available */
    float host_latency_ms;
    /** -1 if not available */
    float decode_latency_ms;
    float drop_rate_pct;
    unsigned int rtt_ms, rtt_variance_ms;
} stream_stats_snapshot_t;

/**
 * @return true if a report URL was given and a stream is open
 */
bool stats_reporter_active();

void stats_reporter_stream_started(const char *host, const char *app);

void stats_reporter_stream_stopped(const char *reason);

/**
 * Called about once a second with fresh stats; only every few seconds are actually sent.
 */
void stats_reporter_push(const stream_stats_snapshot_t *snapshot);

/**
 * Tell the receiver whether the performance bar is on, so a dashboard switch can show it.
 */
void stats_reporter_set_hud(bool enabled);
