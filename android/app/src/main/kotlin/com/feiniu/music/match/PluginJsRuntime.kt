package com.feiniu.music.match

import androidx.annotation.Keep

/**
 * 插件 JS 运行时抽象（移植自 Lyrico，Apache-2.0）。
 */
interface PluginJsRuntime : AutoCloseable {
    fun eval(script: String, filename: String = "<eval>"): String
    fun call(functionName: String, requestJson: String): String
}
