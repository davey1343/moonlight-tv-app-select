#include "app.h"
#include "app_session.h"
#include "streaming.controller.h"
#include "stream/video/session_video.h"
#include "ui/root.h"
#include "ui/common/progress_dialog.h"
#include "lvgl/lv_ext_utils.h"

#include "util/user_event.h"
#include "util/i18n.h"
#include "logging.h"
#include "app_launch.h"
#include "stream/stats_reporter.h"

#include <stdio.h>
#include <string.h>

static void exit_streaming(lv_event_t *event);

static void suspend_streaming(lv_event_t *event);

static void open_keyboard(lv_event_t *event);

static void toggle_vmouse(lv_event_t *event);

static void hide_overlay(lv_event_t *event);

static bool show_overlay(streaming_controller_t *controller);

static void on_view_created(lv_fragment_t *self, lv_obj_t *view);

static void on_delete_obj(lv_fragment_t *self, lv_obj_t *view);

static void on_obj_deleted(lv_fragment_t *self, lv_obj_t *view);

static bool on_event(lv_fragment_t *self, int code, void *userdata);

static void constructor(lv_fragment_t *self, void *args);

static void controller_dtor(lv_fragment_t *self);

static void overlay_key_cb(lv_event_t *e);

static void update_buttons_layout(streaming_controller_t *controller);

static void pin_toggle(lv_event_t *e);

static void hud_create(streaming_controller_t *controller, lv_obj_t *view);

static void hud_apply_visibility(streaming_controller_t *controller);

static void hud_update(streaming_controller_t *controller);

static void hud_shift_cb(lv_timer_t *timer);

const lv_fragment_class_t streaming_controller_class = {
        .constructor_cb = constructor,
        .destructor_cb = controller_dtor,
        .create_obj_cb = streaming_scene_create,
        .obj_created_cb = on_view_created,
        .obj_will_delete_cb = on_delete_obj,
        .obj_deleted_cb = on_obj_deleted,
        .event_cb = on_event,
        .instance_size = sizeof(streaming_controller_t),
};

static bool overlay_showing = false, overlay_pinned = false;
static bool hud_enabled = false;
static streaming_controller_t *current_controller = NULL;

bool streaming_overlay_shown() {
    return overlay_showing;
}

bool streaming_stats_shown() {
    return overlay_showing || overlay_pinned || hud_enabled || stats_reporter_active();
}

bool streaming_hud_enabled() {
    return hud_enabled;
}

void streaming_hud_set_enabled(bool enabled) {
    hud_enabled = enabled;
    stats_reporter_set_hud(enabled);
    streaming_controller_t *controller = current_controller;
    if (controller != NULL) {
        hud_apply_visibility(controller);
        if (enabled) {
            hud_update(controller);
        }
    }
}

bool streaming_refresh_stats() {
    streaming_controller_t *controller = current_controller;
    if (!controller) { return false; }
    if (!streaming_stats_shown()) {
        return false;
    }
    app_t *app = controller->global;
    const struct VIDEO_STATS *dst = &vdec_summary_stats;
    const struct VIDEO_INFO *info = &vdec_stream_info;
    if (info->width > 0 && info->height > 0) {
        lv_label_set_text_fmt(controller->stats_items.decoder, "%s, %d\u00d7%d (%s)", vdec_stream_info.format, info->width,
                              info->height, SS4S_ModuleInfoGetId(app->ss4s.selection.video_module));
    } else {
        lv_label_set_text_fmt(controller->stats_items.decoder, "%s (%s)", vdec_stream_info.format,
                              SS4S_ModuleInfoGetId(app->ss4s.selection.video_module));
    }
    lv_label_set_text_fmt(controller->stats_items.audio, "%s, %s (%s)", audio_stream_info.format,
                          audio_stream_info.channels, SS4S_ModuleInfoGetId(app->ss4s.selection.audio_module));
    lv_label_set_text_fmt(controller->stats_items.rtt, "%d ms (var. %d ms)", dst->rtt, dst->rttVariance);
    lv_label_set_text_fmt(controller->stats_items.net_fps, "%.2f FPS", dst->receivedFps);

    if (dst->submittedFrames) {
        lv_label_set_text_fmt(controller->stats_items.drop_rate, "%.2f%%",
                              (float) dst->networkDroppedFrames / (float) dst->totalFrames * 100);
        if (vdec_stream_info.has_host_latency) {
            float avgCapLatency = (float) dst->totalCaptureLatency / (float) dst->submittedFrames / 10.0f;
            lv_label_set_text_fmt(controller->stats_items.host_latency, "avg %.2f ms", avgCapLatency);
        } else {
            lv_label_set_text_fmt(controller->stats_items.host_latency, "not available");
        }
        if (vdec_stream_info.has_decoder_latency) {
            float avgSubmitTime = (float) dst->totalSubmitTimeUs / (float) dst->submittedFrames / 1000.0f;
            lv_label_set_text_fmt(controller->stats_items.vdec_latency, "avg %.2f ms",
                                  avgSubmitTime + dst->avgDecoderLatency);
        } else {
            lv_label_set_text_fmt(controller->stats_items.vdec_latency, "not available");
        }
    } else {
        lv_label_set_text(controller->stats_items.drop_rate, "-");
        lv_label_set_text_fmt(controller->stats_items.host_latency, "-");
        lv_label_set_text_fmt(controller->stats_items.vdec_latency, "-");
    }
    hud_update(controller);
    return true;
}

void streaming_notice_show(const char *message) {
    streaming_controller_t *controller = current_controller;
    if (!controller) { return; }
    lv_label_set_text(controller->notice_label, message);
    if (message && message[0]) {
        lv_obj_clear_flag(controller->notice, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(controller->notice, LV_OBJ_FLAG_HIDDEN);
    }
}

static void constructor(lv_fragment_t *self, void *args) {
    streaming_controller_t *controller = (streaming_controller_t *) self;
    current_controller = controller;

    overlay_showing = false;

    streaming_styles_init(controller);

    const streaming_scene_arg_t *arg = (streaming_scene_arg_t *) args;
    controller->global = arg->global;

    hud_enabled = arg->global->settings.stats_hud;
    const app_launch_params_t *params = app_launch_params_current();
    if (params != NULL && params->overlay == APP_LAUNCH_OVERLAY_ON) {
        hud_enabled = true;
    } else if (params != NULL && params->overlay == APP_LAUNCH_OVERLAY_OFF) {
        hud_enabled = false;
    }

    const pclist_t *node = pcmanager_node(pcmanager, &arg->uuid);
    snprintf(controller->host_name, sizeof(controller->host_name), "%s",
             node != NULL && node->server != NULL && node->server->hostname != NULL ? node->server->hostname : "");
    snprintf(controller->app_name, sizeof(controller->app_name), "%s", arg->app.name != NULL ? arg->app.name : "");
    stats_reporter_set_hud(hud_enabled);

    app_session_begin(arg->global, &arg->uuid, &arg->app);
}

static void controller_dtor(lv_fragment_t *self) {
    streaming_controller_t *fragment = (streaming_controller_t *) self;
    // Covers streams that ended without a normal close (errors, decoder failure)
    stats_reporter_stream_stopped("ended");
    streaming_styles_reset(fragment);
    if (current_controller == fragment) {
        current_controller = NULL;
    }
}

static bool on_event(lv_fragment_t *self, int code, void *userdata) {
    LV_UNUSED(userdata);
    streaming_controller_t *controller = (streaming_controller_t *) self;
    switch (code) {
        case USER_STREAM_CONNECTING: {
            controller->progress = progress_dialog_create(locstr("Connecting..."));
            if (lv_obj_check_type(controller->progress->parent, &lv_msgbox_backdrop_class)) {
                lv_obj_set_style_bg_opa(controller->progress->parent, LV_OPA_TRANSP, 0);
            }
            lv_obj_set_width(controller->progress, LV_DPX(300));
            lv_obj_set_height(controller->progress, LV_DPX(100));
            lv_obj_add_flag(controller->overlay, LV_OBJ_FLAG_HIDDEN);
            lv_obj_clear_flag(controller->hint, LV_OBJ_FLAG_HIDDEN);
            return true;
        }
        case USER_STREAM_OPEN: {
            if (controller->progress) {
                lv_msgbox_close(controller->progress);
                controller->progress = NULL;
            }
            lv_obj_add_flag(controller->overlay, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(controller->hint, LV_OBJ_FLAG_HIDDEN);
            controller->stream_open = true;
            hud_apply_visibility(controller);
            stats_reporter_stream_started(controller->host_name, controller->app_name);
            break;
        }
        case USER_STREAM_CLOSE: {
            controller->stream_open = false;
            hud_apply_visibility(controller);
            stats_reporter_stream_stopped("closed");
            controller->progress = progress_dialog_create(locstr("Disconnecting..."));
            lv_obj_add_flag(controller->overlay, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(controller->stats, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(controller->hint, LV_OBJ_FLAG_HIDDEN);
            break;
        }
        case USER_STREAM_FINISHED: {
            if (controller->progress) {
                lv_msgbox_close(controller->progress);
                controller->progress = NULL;
            }
            lv_async_call((lv_async_cb_t) lv_fragment_del, controller);
            break;
        }
        case USER_OPEN_OVERLAY: {
            show_overlay(controller);
            return true;
        }
        case USER_TOGGLE_STATS_HUD: {
            streaming_hud_set_enabled(!hud_enabled);
            return true;
        }
        case USER_SIZE_CHANGED: {
            update_buttons_layout(controller);
            streaming_overlay_resized(controller);
            return false;
        }
        default: {
            break;
        }
    }
    return false;
}

static void on_view_created(lv_fragment_t *self, lv_obj_t *view) {
    streaming_controller_t *controller = (streaming_controller_t *) self;
    app_input_set_group(&controller->global->ui.input, controller->group);
    lv_obj_add_event_cb(controller->quit_btn, exit_streaming, LV_EVENT_CLICKED, self);
    lv_obj_add_event_cb(controller->suspend_btn, suspend_streaming, LV_EVENT_CLICKED, self);
    lv_obj_add_event_cb(controller->kbd_btn, open_keyboard, LV_EVENT_CLICKED, self);
    lv_obj_add_event_cb(controller->vmouse_btn, toggle_vmouse, LV_EVENT_CLICKED, self);
    lv_obj_add_event_cb(controller->base.obj, hide_overlay, LV_EVENT_CLICKED, self);
    lv_obj_add_event_cb(controller->overlay, overlay_key_cb, LV_EVENT_KEY, controller);
    lv_obj_add_event_cb(controller->base.obj, hide_overlay, LV_EVENT_CANCEL, controller);

    lv_obj_t *notice = lv_obj_create(lv_layer_sys());
    lv_obj_set_size(notice, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_align(notice, LV_ALIGN_TOP_RIGHT, -LV_DPX(20), LV_DPX(20));
    lv_obj_set_style_radius(notice, LV_DPX(5), 0);
    lv_obj_set_style_pad_hor(notice, LV_DPX(5), 0);
    lv_obj_set_style_pad_ver(notice, LV_DPX(3), 0);
    lv_obj_set_style_border_opa(notice, LV_OPA_TRANSP, 0);
    lv_obj_set_style_bg_opa(notice, LV_OPA_40, 0);
    lv_obj_set_style_bg_color(notice, lv_color_black(), 0);
    lv_obj_t *notice_label = lv_label_create(notice);
    lv_obj_set_size(notice_label, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_style_text_font(notice_label, lv_theme_get_font_small(view), 0);
    lv_obj_add_flag(notice, LV_OBJ_FLAG_HIDDEN);

    controller->notice = notice;
    controller->notice_label = notice_label;

    hud_create(controller, view);

    lv_obj_add_event_cb(controller->stats_pin, pin_toggle, LV_EVENT_VALUE_CHANGED, controller->stats);

#if !defined(TARGET_WEBOS)
    const app_settings_t *settings = &controller->global->settings;
    if (settings->syskey_capture) {
        SDL_SetWindowGrab(controller->global->ui.window, SDL_TRUE);
    }
#endif
}

static void on_delete_obj(lv_fragment_t *self, lv_obj_t *view) {
    LV_UNUSED(view);
    streaming_controller_t *controller = (streaming_controller_t *) self;
    if (controller->notice) {
        lv_obj_del(controller->notice);
    }
    if (controller->hud_shift_timer) {
        lv_timer_del(controller->hud_shift_timer);
        controller->hud_shift_timer = NULL;
    }
    if (controller->hud) {
        lv_obj_del(controller->hud);
        controller->hud = NULL;
        controller->hud_label = NULL;
    }
    if (controller->stats->parent != controller->overlay) {
        lv_obj_del(controller->stats);
    }
    app_input_set_group(&controller->global->ui.input, NULL);
    lv_group_del(controller->group);

#if !defined(TARGET_WEBOS)
    SDL_SetWindowGrab(controller->global->ui.window, SDL_FALSE);
#endif
}

static void on_obj_deleted(lv_fragment_t *self, lv_obj_t *view) {
    LV_UNUSED(view);
    streaming_controller_t *controller = (streaming_controller_t *) self;
    lv_obj_del(controller->detached_root);
}

static void exit_streaming(lv_event_t *event) {
    streaming_controller_t *self = lv_event_get_user_data(event);
    session_interrupt(self->global->session, true, STREAMING_INTERRUPT_USER);
}

static void suspend_streaming(lv_event_t *event) {
    streaming_controller_t *self = lv_event_get_user_data(event);
    session_interrupt(self->global->session, false, STREAMING_INTERRUPT_USER);
}

static void open_keyboard(lv_event_t *event) {
    streaming_controller_t *controller = lv_event_get_user_data(event);
    hide_overlay(event);
    app_t *app = controller->global;
    app_start_text_input(&app->ui.input, 0, app->ui.height / 2 - 40, app->ui.width, 40);
    session_screen_keyboard_opened(app->session);
}

static void toggle_vmouse(lv_event_t *event) {
    streaming_controller_t *controller = lv_event_get_user_data(event);
    hide_overlay(event);
    app_t *app = controller->global;
    session_toggle_vmouse(app->session);
}

bool show_overlay(streaming_controller_t *controller) {
    if (overlay_showing) {
        return false;
    }
    overlay_showing = true;
    lv_obj_clear_flag(controller->base.obj, LV_OBJ_FLAG_HIDDEN);

    lv_area_t coords = controller->video->coords;
    streaming_enter_overlay(controller->global->session, coords.x1, coords.y1, lv_area_get_width(&coords),
                            lv_area_get_height(&coords));
    streaming_refresh_stats();

    app_stop_text_input(&controller->global->ui.input);

    update_buttons_layout(controller);
    return true;
}

static void hide_overlay(lv_event_t *event) {
    streaming_controller_t *controller = (streaming_controller_t *) lv_event_get_user_data(event);
    app_input_set_button_points(&controller->global->ui.input, NULL);
    lv_obj_add_flag(controller->base.obj, LV_OBJ_FLAG_HIDDEN);
    if (!overlay_showing) {
        return;
    }
    overlay_showing = false;
    app_set_mouse_grab(&global->input, true);
    streaming_enter_fullscreen(controller->global->session);
}

static void overlay_key_cb(lv_event_t *e) {
    streaming_controller_t *controller = lv_event_get_user_data(e);
    lv_group_t *group = controller->group;
    switch (lv_event_get_key(e)) {
        case LV_KEY_LEFT:
            lv_group_focus_prev(group);
            break;
        case LV_KEY_RIGHT:
            lv_group_focus_next(group);
            break;
        default:
            break;
    }
}

static void update_buttons_layout(streaming_controller_t *controller) {
    lv_area_t coords;
    lv_obj_get_coords(controller->quit_btn, &coords);
    lv_area_center(&coords, &controller->button_points[1]);
    lv_obj_get_coords(controller->suspend_btn, &coords);
    lv_area_center(&coords, &controller->button_points[3]);
    lv_obj_get_coords(controller->kbd_btn, &coords);
    lv_area_center(&coords, &controller->button_points[4]);
    app_input_set_button_points(&controller->global->ui.input, controller->button_points);
}

static void pin_toggle(lv_event_t *e) {
    lv_obj_t *toggle_view = lv_event_get_user_data(e);
    lv_fragment_t *fragment = lv_obj_get_user_data(toggle_view);
    bool checked = lv_obj_has_state(lv_event_get_current_target(e), LV_STATE_CHECKED);
    bool pinned = toggle_view->parent != fragment->obj;
    overlay_pinned = checked;
    if (checked == pinned) {
        return;
    }
    if (checked) {
        lv_obj_set_parent(toggle_view, lv_layer_top());
        lv_obj_add_state(toggle_view, LV_STATE_USER_1);
    } else {
        lv_obj_set_parent(toggle_view, fragment->obj);
        lv_obj_clear_state(toggle_view, LV_STATE_USER_1);
    }
}


/* ---- One-line performance bar ---- */

/* Dim colours, chosen to be easy on OLED panels */
#define HUD_TEXT_COLOR 0x8A8A8A
#define HUD_WARN_COLOR "B08A3A"
#define HUD_BAD_COLOR "A84A4A"
/* Move the bar a few pixels every couple of minutes so the same pixels aren't lit for hours */
#define HUD_SHIFT_PERIOD_MS (120 * 1000)

static const lv_point_t hud_shift_offsets[] = {
        {0, 0}, {6, 2}, {-6, 4}, {3, 6}, {-3, 2}, {8, 4}, {-8, 6}, {0, 4},
};

static void hud_create(streaming_controller_t *controller, lv_obj_t *view) {
    lv_obj_t *hud = lv_obj_create(lv_layer_sys());
    lv_obj_remove_style_all(hud);
    lv_obj_set_size(hud, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_clear_flag(hud, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_radius(hud, LV_DPX(4), 0);
    lv_obj_set_style_pad_hor(hud, LV_DPX(8), 0);
    lv_obj_set_style_pad_ver(hud, LV_DPX(2), 0);
    lv_obj_set_style_bg_color(hud, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(hud, LV_OPA_30, 0);
    lv_obj_align(hud, LV_ALIGN_TOP_MID, 0, LV_DPX(6));

    lv_obj_t *label = lv_label_create(hud);
    lv_label_set_recolor(label, true);
    lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(label, lv_theme_get_font_small(view), 0);
    lv_obj_set_style_text_color(label, lv_color_hex(HUD_TEXT_COLOR), 0);
    lv_label_set_text_static(label, "Waiting for stats…");

    controller->hud = hud;
    controller->hud_label = label;
    controller->hud_shift_index = 0;
    controller->hud_shift_timer = lv_timer_create(hud_shift_cb, HUD_SHIFT_PERIOD_MS, controller);
    hud_apply_visibility(controller);
}

static void hud_apply_visibility(streaming_controller_t *controller) {
    if (controller->hud == NULL) {
        return;
    }
    if (hud_enabled && controller->stream_open) {
        lv_obj_clear_flag(controller->hud, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(controller->hud, LV_OBJ_FLAG_HIDDEN);
    }
}

static void hud_shift_cb(lv_timer_t *timer) {
    streaming_controller_t *controller = timer->user_data;
    if (controller->hud == NULL) {
        return;
    }
    int count = (int) (sizeof(hud_shift_offsets) / sizeof(hud_shift_offsets[0]));
    controller->hud_shift_index = (controller->hud_shift_index + 1) % count;
    const lv_point_t *offset = &hud_shift_offsets[controller->hud_shift_index];
    lv_obj_align(controller->hud, LV_ALIGN_TOP_MID, offset->x, LV_DPX(6) + offset->y);
}

static const char *hud_resolution_name(int width, int height) {
    static char buf[16];
    if (height >= 2160) {
        return "4K";
    } else if (height >= 1440) {
        return "1440p";
    } else if (height > 0) {
        snprintf(buf, sizeof(buf), "%dp", height);
        return buf;
    }
    (void) width;
    return NULL;
}

static void hud_update(streaming_controller_t *controller) {
    stream_stats_snapshot_t snap;
    streaming_stats_snapshot(controller->global, &snap);
    stats_reporter_push(&snap);

    if (controller->hud_label == NULL || !hud_enabled) {
        return;
    }

    char latency[48];
    const char *latency_color = NULL;
    if (snap.total_latency_ms >= 80 || snap.drop_rate_pct >= 5) {
        latency_color = HUD_BAD_COLOR;
    } else if (snap.total_latency_ms >= 40 || snap.drop_rate_pct >= 1) {
        latency_color = HUD_WARN_COLOR;
    }
    if (latency_color != NULL) {
        snprintf(latency, sizeof(latency), "#%s ~%.0f ms#", latency_color, snap.total_latency_ms);
    } else {
        snprintf(latency, sizeof(latency), "~%.0f ms", snap.total_latency_ms);
    }

    char host[24], decode[24];
    if (snap.host_latency_ms >= 0) {
        snprintf(host, sizeof(host), "%.1f", snap.host_latency_ms);
    } else {
        snprintf(host, sizeof(host), "-");
    }
    if (snap.decode_latency_ms >= 0) {
        snprintf(decode, sizeof(decode), "%.1f", snap.decode_latency_ms);
    } else {
        snprintf(decode, sizeof(decode), "-");
    }

    const char *res = hud_resolution_name(snap.width, snap.height);
    lv_label_set_text_fmt(controller->hud_label,
                          "%s  ·  %.0f fps  ·  %.0f Mbps  ·  %s%s%s  ·  net %u ms  ·  host %s  ·  dec %s  ·  drops %.1f%%",
                          latency, snap.fps, snap.bitrate_mbps, res ? res : "", res ? " " : "",
                          snap.format ? snap.format : "", snap.rtt_ms, host, decode, snap.drop_rate_pct);
}


void streaming_stats_snapshot(app_t *app, stream_stats_snapshot_t *snap) {
    (void) app;
    const struct VIDEO_STATS *dst = &vdec_summary_stats;
    const struct VIDEO_INFO *info = &vdec_stream_info;
    memset(snap, 0, sizeof(*snap));
    snap->width = info->width;
    snap->height = info->height;
    snap->format = info->format;
    snap->fps = dst->receivedFps;
    snap->bitrate_mbps = dst->bitrateMbps;
    snap->rtt_ms = dst->rtt;
    snap->rtt_variance_ms = dst->rttVariance;
    snap->host_latency_ms = -1;
    snap->decode_latency_ms = -1;
    if (dst->totalFrames > 0) {
        snap->drop_rate_pct = (float) dst->networkDroppedFrames / (float) dst->totalFrames * 100.0f;
    }
    if (dst->submittedFrames > 0) {
        if (info->has_host_latency) {
            snap->host_latency_ms = (float) dst->totalCaptureLatency / (float) dst->submittedFrames / 10.0f;
        }
        if (info->has_decoder_latency) {
            snap->decode_latency_ms = (float) dst->totalSubmitTimeUs / (float) dst->submittedFrames / 1000.0f +
                                      dst->avgDecoderLatency;
        }
    }
    float total = (float) dst->rtt / 2.0f;
    if (snap->host_latency_ms > 0) {
        total += snap->host_latency_ms;
    }
    if (snap->decode_latency_ms > 0) {
        total += snap->decode_latency_ms;
    }
    snap->total_latency_ms = total;
}
