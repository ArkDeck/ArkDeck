# Native crash probe for ArkDeck's GJ-5 window (added 2026-07-31).
#
# Its only reason to exist: give the bounded debug loop a *real* OpenHarmony
# cppcrash to find. The harness scans hilog for the documented fault-block
# shape (`Reason:Signal:SIG...`, `Fault thread info:`, `#NN pc ... (symbol+off)`),
# which only a native fault produces - an ArkTS exception logs a different way.
#
# Delete this directory and the `externalNativeBuild` block in
# entry/build-profile.json5 to remove it again.

cmake_minimum_required(VERSION 3.5.0)
project(WaterFlowLayoutDemo)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(crashprobe SHARED crashprobe.cpp)
target_link_libraries(crashprobe PUBLIC libace_napi.z.so libhilog_ndk.z.so)
