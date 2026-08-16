// Native crash probe for ArkDeck's GJ-5 bounded debug loop (added 2026-07-31).
//
// The harness measures crashes by scanning bounded HiLog for the documented
// OpenHarmony cppcrash fault block. Producing one needs a native fault: an
// unhandled ArkTS error is logged in a different shape entirely. So this module
// exposes one function that aborts inside a *named* frame, so the fault block
// carries a symbol a criterion can declare and match on:
//
//     Reason:Signal:SIGABRT(SI_TKILL)@...
//     #NN pc ... libcrashprobe.so(WaterFlowCrashProbe_RecoverBack+NN)
//
// Nothing else in the application calls it except the launch probe in
// CrashProbe.ets, which is guarded by a single flag.

#include <cstdlib>
#include <napi/native_api.h>

#include "hilog/log.h"

#define PROBE_LOG_DOMAIN 0x0000
#define PROBE_LOG_TAG "ArkDeckCrashProbe"

// Deliberately not static and not inlined: the symbol has to survive into the
// fault frame, because the frame is the evidence.
extern "C" __attribute__((noinline)) void WaterFlowCrashProbe_RecoverBack() {
  OH_LOG_Print(LOG_APP, LOG_FATAL, PROBE_LOG_DOMAIN, PROBE_LOG_TAG,
               "crash probe: aborting inside WaterFlowCrashProbe_RecoverBack");
  std::abort();
}

static napi_value TriggerNativeCrash(napi_env env, napi_callback_info info) {
  WaterFlowCrashProbe_RecoverBack();
  return nullptr;  // unreachable
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"triggerNativeCrash", nullptr, TriggerNativeCrash, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "crashprobe",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterCrashProbeModule() {
  napi_module_register(&demoModule);
}
