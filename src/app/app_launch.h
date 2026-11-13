#pragma once

#include <stdbool.h>

#include "uuidstr.h"

typedef struct app_t app_t;

typedef enum app_launch_overlay_t {
    /** Launch params didn't say anything, use the saved setting */
    APP_LAUNCH_OVERLAY_DEFAULT = 0,
    APP_LAUNCH_OVERLAY_ON,
    APP_LAUNCH_OVERLAY_OFF,
} app_launch_overlay_t;

/**
 * Parameters passed when the app is launched, e.g. from Home Assistant:
 *
 * luna://com.webos.applicationManager/launch
 * {"id":"com.limelight.webos","params":{
 *     "host":"BEAST",                 // host name (case-insensitive), or
 *     "host_uuid":"...",              // host UUID
 *     "app":"Steam Big Picture",      // app name (case-insensitive), or
 *     "host_app_id":123,              // app ID
 *     "overlay":true,                 // force the one-line stats overlay on/off for this session
 *     "report_url":"http://192.168.1.133:8123/api/webhook/xxxx" // POST stream status here
 * }}
 */
typedef struct app_launch_params_t {
    uuidstr_t default_host_uuid;
    int default_app_id;
    /** Allocated, may be NULL */
    char *default_host_name;
    /** Allocated, may be NULL */
    char *default_app_name;
    app_launch_overlay_t overlay;
    /** Allocated, may be NULL */
    char *report_url;
} app_launch_params_t;

app_launch_params_t *app_handle_launch(app_t *app, int argc, char *argv[]);

void app_launch_param_free(app_launch_params_t *param);

/**
 * @return true if launch params asked for a specific host (by UUID or name)
 */
bool app_launch_params_has_host(const app_launch_params_t *params);

/**
 * @return true if launch params asked for a specific app (by ID or name)
 */
bool app_launch_params_has_app(const app_launch_params_t *params);

/**
 * Launch params of the current process, or NULL. Set once at startup.
 */
const app_launch_params_t *app_launch_params_current();

void app_launch_params_set_current(const app_launch_params_t *params);
