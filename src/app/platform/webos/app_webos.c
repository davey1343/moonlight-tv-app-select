#include "app.h"
#include "app_webos.h"
#include "app_launch.h"

#include <pbnjson.h>

#include "logging.h"
#include "util/path.h"
#include "util/i18n.h"

#include "lunasynccall.h"

static char locale_system[16];

void app_open_url(const char *url) {
    SDL_OpenURL(url);
}

void app_init_locale() {
    if (app_configuration->language[0] && strcmp(app_configuration->language, "auto") != 0) {
        commons_log_debug("APP", "Override language to %s", app_configuration->language);
        i18n_setlocale(app_configuration->language);
        return;
    }
    SDL_Locale *locales = SDL_GetPreferredLocales();
    if (locales) {
        for (int i = 0; locales[i].language; i++) {
            if (locales[i].country) {
                snprintf(locale_system, sizeof(locale_system), "%s-%s", locales[i].language, locales[i].country);
            } else {
                strncpy(locale_system, locales[i].language, sizeof(locale_system));
            }
            i18n_setlocale(locale_system);
        }
        SDL_free(locales);
    }
}

static char *launch_param_dup_string(jvalue_ref obj, const char *key) {
    jvalue_ref value = jobject_get(obj, j_cstr_to_buffer(key));
    if (!jis_string(value)) {
        return NULL;
    }
    raw_buffer buf = jstring_get(value);
    char *result = NULL;
    if (buf.m_str != NULL && buf.m_len > 0) {
        result = strndup(buf.m_str, buf.m_len);
    }
    jstring_free_buffer(buf);
    return result;
}

app_launch_params_t *app_handle_launch(app_t *app, int argc, char *argv[]) {
    (void) app;
    if (argc < 2) {
        return NULL;
    }
    commons_log_info("APP", "Launched with parameters %s", argv[1]);
    JSchemaInfo schema_info;
    jschema_info_init(&schema_info, jschema_all(), NULL, NULL);
    jdomparser_ref parser = jdomparser_create(&schema_info, 0);
    if (!jdomparser_feed(parser, argv[1], (int) strlen(argv[1]))) {
        jdomparser_release(&parser);
        return NULL;
    }
    if (!jdomparser_end(parser)) {
        jdomparser_release(&parser);
        return NULL;
    }
    jvalue_ref params_obj = jdomparser_get_result(parser);
    if (!jis_valid(params_obj)) {
        jdomparser_release(&parser);
        return NULL;
    }
    app_launch_params_t *params = calloc(1, sizeof(app_launch_params_t));
    jvalue_ref host_uuid = jobject_get(params_obj, J_CSTR_TO_BUF("host_uuid"));
    if (jis_string(host_uuid)) {
        raw_buffer buf = jstring_get(host_uuid);
        uuidstr_fromchars(&params->default_host_uuid, buf.m_len, buf.m_str);
        jstring_free_buffer(buf);
    }
    params->default_host_name = launch_param_dup_string(params_obj, "host");
    jvalue_ref host_app_id = jobject_get(params_obj, J_CSTR_TO_BUF("host_app_id"));
    if (jis_number(host_app_id)) {
        if (jnumber_get_i32(host_app_id, &params->default_app_id) != CONV_OK) {
            params->default_app_id = 0;
        }
    } else if (jis_string(host_app_id)) {
        raw_buffer buf = jstring_get(host_app_id);
        char *id_str = strndup(buf.m_str, buf.m_len);
        jstring_free_buffer(buf);
        params->default_app_id = strtol(id_str, NULL, 10);
        if (params->default_app_id < 0) {
            params->default_app_id = 0;
        }
        free(id_str);
    }
    params->default_app_name = launch_param_dup_string(params_obj, "app");
    jvalue_ref overlay = jobject_get(params_obj, J_CSTR_TO_BUF("overlay"));
    if (jis_boolean(overlay)) {
        bool value = false;
        if (jboolean_get(overlay, &value) == CONV_OK) {
            params->overlay = value ? APP_LAUNCH_OVERLAY_ON : APP_LAUNCH_OVERLAY_OFF;
        }
    }
    params->report_url = launch_param_dup_string(params_obj, "report_url");
    commons_log_info("APP", "Launch params: host=%s, app=%s, app_id=%d, overlay=%d, report=%s",
                     params->default_host_name ? params->default_host_name : "(uuid/none)",
                     params->default_app_name ? params->default_app_name : "(none)",
                     params->default_app_id, params->overlay, params->report_url ? "yes" : "no");
    jdomparser_release(&parser);
    return params;
}

void app_webos_open_ribbon() {
    static const char *payload = "{\"id\":\"com.webos.app.home\",\"params\":{\"launchType\":\"homeKey\"}}";
    HLunaServiceCallSync("luna://com.webos.applicationManager/launch", payload, true, NULL);
}