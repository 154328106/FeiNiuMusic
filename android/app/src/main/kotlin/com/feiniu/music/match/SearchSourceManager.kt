package com.feiniu.music.match

import android.util.Log
import androidx.annotation.Keep
import java.io.File
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 插件搜索源调度（移植自 Lyrico，Apache-2.0）。
 *
 * Dart 层负责插件文件/清单解析与结果解析；本类负责真正的 JS 执行：
 * - [runScript] 在独立后台线程上创建 QuickJS 运行时 → eval 脚本 →
 *   调用 `searchSongs`/`getLyrics`/`searchCovers` → 返回原始 JSON 字符串。
 * - 每次调用创建/销毁运行时（脚本短、插件数量少，避免缓存带来的生命周期问题）。
 * - QuickJS 单线程模型：所有执行经单线程 executor 串行化。
 */
@Keep
object SearchSourceManager {
    private const val TAG = "SearchSourceManager"

    private val executor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(null, runnable, "FeiNiuSearchSource", 8L * 1024L * 1024L)
        }

    /**
     * 执行一次插件函数调用。
     *
     * @param script 由 Dart 层拼接好的完整脚本（include 脚本 + 入口）。
     * @param pluginId 插件 id（用于缓存目录隔离）。
     * @param cacheRootDir 插件缓存根目录（可为 null，cache.* 走空实现）。
     * @param functionName searchSongs / getLyrics / searchCovers。
     * @param requestJson 传给插件函数的请求 JSON。
     * @return 插件返回值序列化后的 JSON 字符串。
     * @throws Exception 脚本 eval / 调用失败、超时等。
     */
    @Throws(Exception::class)
    fun runScript(
        script: String,
        pluginId: String,
        cacheRootDir: String?,
        functionName: String,
        requestJson: String
    ): String {
        return try {
            executor.submit<String> {
                val hostApi = QuickJsHostApi(
                    pluginId = pluginId,
                    cacheRootDir = cacheRootDir?.let { File(it) }
                )
                val runtime = QuickJsRuntime(hostApi = hostApi)
                try {
                    runtime.eval(script, "<plugin-$pluginId>")
                    val raw = runtime.call(functionName, requestJson)
                    Log.d(
                        TAG,
                        "plugin=$pluginId fn=$functionName rawLen=${raw.length} raw=${raw.take(500)}"
                    )
                    raw
                } finally {
                    runtime.close()
                }
            }.get()
        } catch (e: ExecutionException) {
            throw (e.cause ?: e) as Exception
        }
    }
}
