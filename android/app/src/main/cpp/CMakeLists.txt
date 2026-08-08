cmake_minimum_required(VERSION 3.22.1)

# FeiNiuMusic — 移植自 Lyrico (Apache-2.0) 的 QuickJS 嵌入式 JS 引擎。
# 数据源插件（Lyrico 搜索源，JavaScript）由 quickjs-ng 0.14.0 运行，
# JNI 桥 (quickjs_bridge.cpp) 与 Kotlin 侧 QuickJsNative/QuickJsRuntime/
# QuickJsHostApi 对接，插件通过 globalThis.Platform 同步访问宿主能力。

project("quickjs_engine")

# --- QuickJS 核心静态库 ---
# quickjs-ng 0.14.0：JS 引擎核心 + 正则 + Unicode + 数字转换。
add_library(quickjs STATIC
    quickjs-ng/quickjs.c
    quickjs-ng/libregexp.c
    quickjs-ng/libunicode.c
    quickjs-ng/dtoa.c
)

target_include_directories(quickjs PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/quickjs-ng
)

target_compile_definitions(quickjs PRIVATE
    CONFIG_VERSION="0.14.0")

set_target_properties(quickjs PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON)

# --- QuickJS JNI 桥接动态库 ---
add_library(quickjs-ng SHARED
    quickjs_bridge.cpp
)

target_link_libraries(quickjs-ng PRIVATE
    quickjs
    android
    log
)
