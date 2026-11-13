#pragma once

#include <lvgl.h>

#include "client.h"
#include "stream/session.h"

typedef struct app_t app_t;

typedef struct {
    lv_fragment_t base;
    app_t *global;
    lv_obj_t *detached_root;
    lv_obj_t *hint;
    lv_obj_t *overlay;
    lv_group_t *group;
    lv_obj_t *progress;
    lv_obj_t *video;
    lv_obj_t *actions;
    lv_obj_t *kbd_btn, *vmouse_btn;
    lv_obj_t *suspend_btn, *quit_btn;
    lv_obj_t *stats;
    struct {
        lv_obj_t *decoder;
        lv_obj_t *audio;
        lv_obj_t *rtt;
        lv_obj_t *net_fps;
        lv_obj_t *drop_rate;
        lv_obj_t *host_latency;
        lv_obj_t *vdec_latency;
    } stats_items;
    lv_obj_t *stats_pin;
    lv_obj_t *notice, *notice_label;
    /** One-line performance bar (top centre) */
    lv_obj_t *hud, *hud_label;
    lv_timer_t *hud_shift_timer;
    int hud_shift_index;
    bool stream_open;
    char host_name[128];
    char app_name[256];
    lv_style_t overlay_button_style;
    lv_style_t overlay_button_style_focused;
    lv_style_t overlay_button_label_style;
    lv_point_t button_points[5];
} streaming_controller_t;

/* Usually references to SERVER_DATA and APP_LIST should not be kept, but in this struct, they will only be used once */
typedef struct {
    app_t *global;
    uuidstr_t uuid;
    APP_LIST app;
} streaming_scene_arg_t;

extern const lv_fragment_class_t streaming_controller_class;

lv_obj_t *streaming_scene_create(lv_fragment_t *self, lv_obj_t *parent);

void streaming_styles_init(streaming_controller_t *controller);

void streaming_styles_reset(streaming_controller_t *controller);

void streaming_overlay_resized(streaming_controller_t *controller);

bool streaming_overlay_shown();

bool streaming_stats_shown();

bool streaming_refresh_stats();

/** Whether the one-line performance bar is switched on for this session */
bool streaming_hud_enabled();

struct stream_stats_snapshot_t;

/** Collect the current stream stats in one place, for the bar and Home Assistant reports */
void streaming_stats_snapshot(app_t *app, struct stream_stats_snapshot_t *snapshot);

void streaming_hud_set_enabled(bool enabled);

void streaming_notice_show(const char *message);