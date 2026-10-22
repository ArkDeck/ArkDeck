// Genuine OpenHarmony NAPI module for a separately reviewed paired HAP.
// No Runtime, transport, target identity, signing material or device access.
#include "napi/native_api.h"

#ifndef ARKDECK_GJ_MARKER
#error ARKDECK_GJ_MARKER must identify this independently built variant
#endif

extern "C" __attribute__((visibility("default"))) const char *arkdeck_gj_marker()
{
    return ARKDECK_GJ_MARKER;
}

static napi_value Marker(napi_env env, napi_callback_info)
{
    napi_value value = nullptr;
    if (napi_create_string_utf8(env, arkdeck_gj_marker(), NAPI_AUTO_LENGTH, &value) != napi_ok) {
        return nullptr;
    }
    return value;
}

static napi_value Add(napi_env env, napi_callback_info info)
{
    size_t count = 2;
    napi_value values[2] = {nullptr, nullptr};
    double left = 0, right = 0;
    napi_value result = nullptr;
    if (napi_get_cb_info(env, info, &count, values, nullptr, nullptr) != napi_ok || count != 2 ||
        napi_get_value_double(env, values[0], &left) != napi_ok ||
        napi_get_value_double(env, values[1], &right) != napi_ok) {
        napi_throw_type_error(env, nullptr, "add requires two numbers");
        return nullptr;
    }
    if (napi_create_double(env, left + right, &result) != napi_ok) {
        return nullptr;
    }
    return result;
}

static napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor properties[] = {
        {"marker", nullptr, Marker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return nullptr;
    }
    return exports;
}

static napi_module Module = {1, 0, nullptr, Init, "arkdeck_gj", nullptr, {0}};

extern "C" __attribute__((constructor)) void RegisterArkDeckGjModule()
{
    napi_module_register(&Module);
}
