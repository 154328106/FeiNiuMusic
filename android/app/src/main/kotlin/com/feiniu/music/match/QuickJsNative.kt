package com.feiniu.music.match

import androidx.annotation.Keep

/**
 * QuickJS JNI 桥（移植自 Lyrico，Apache-2.0）。
 *
 * 对应 C 层 `quickjs_bridge.cpp`（JNI 函数名已改为本类全限定名）。
 * 插件通过 [QuickJsHostApi] 同步访问宿主能力（globalThis.Platform.*）。
 */
@Keep
object QuickJsNative {
    init {
        System.loadLibrary("quickjs-ng")
    }

    external fun createRuntime(
        memoryLimitBytes: Long,
        stackSizeBytes: Long,
        timeoutMs: Long,
        hostApi: QuickJsHostApi?
    ): Long

    external fun eval(runtimePtr: Long, script: String, filename: String): String

    external fun call(runtimePtr: Long, functionName: String, requestJson: String): String

    external fun closeRuntime(runtimePtr: Long)
}
