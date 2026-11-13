#include "app_launch.h"

#include <stddef.h>
#include <stdlib.h>

static const app_launch_params_t *current_params = NULL;

void app_launch_param_free(app_launch_params_t *param) {
    if (param == NULL) {
        return;
    }
    if (current_params == param) {
        current_params = NULL;
    }
    free(param->default_host_name);
    free(param->default_app_name);
    free(param->report_url);
    free(param);
}

bool app_launch_params_has_host(const app_launch_params_t *params) {
    if (params == NULL) {
        return false;
    }
    return !uuidstr_is_empty(&params->default_host_uuid) ||
           (params->default_host_name != NULL && params->default_host_name[0] != '\0');
}

bool app_launch_params_has_app(const app_launch_params_t *params) {
    if (params == NULL) {
        return false;
    }
    return params->default_app_id > 0 ||
           (params->default_app_name != NULL && params->default_app_name[0] != '\0');
}

const app_launch_params_t *app_launch_params_current() {
    return current_params;
}

void app_launch_params_set_current(const app_launch_params_t *params) {
    current_params = params;
}
