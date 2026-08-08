package com.feiniu.music.match

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import java.io.File

/**
 * 插件脚本加载器（移植自 Lyrico，Apache-2.0）。
 *
 * 把插件的 `includeDirs` 下所有 .js（按相对路径排序）与入口 `entry` 拼接成
 * 单个脚本单元，供 QuickJS `eval` 加载。同时注入 `include()` 兼容函数
 * （声明过的路径视为已加载，非法路径抛错）。
 */
object PluginScriptLoader {
    private const val MANIFEST_FILE = "manifest.json"

    fun buildScript(
        pluginDir: File,
        entryFile: File,
        includeDirs: List<String>,
        entry: String
    ): String {
        val includeSources = includeDirs
            .asSequence()
            .map { includeDir -> includeDir to File(pluginDir, includeDir) }
            .filter { (_, dir) -> dir.isDirectory }
            .flatMap { (includeDir, dir) ->
                dir.walkTopDown()
                    .filter { it.isFile && it.extension.equals("js", ignoreCase = true) }
                    .sortedBy { it.relativeTo(dir).invariantSeparatorsPath }
                    .map { file -> includeDir to file }
            }
            .map { (includeDir, file) ->
                val relativePath =
                    file.relativeTo(File(pluginDir, includeDir)).invariantSeparatorsPath
                IncludedScript(
                    path = "$includeDir/$relativePath",
                    content = file.readText()
                )
            }
            .toList()

        val includePathSetJson = Json.encodeToString(
            JsonArray.serializer(),
            buildJsonArray {
                includeSources.map { it.path }.distinct().forEach { path ->
                    add(JsonPrimitive(path))
                }
            }
        )

        val includeBootstrap = """
        (function() {
          var __lyricoDeclaredIncludes = $includePathSetJson;
          var __lyricoDeclaredIncludeMap = Object.create(null);

          __lyricoDeclaredIncludes.forEach(function(path) {
            __lyricoDeclaredIncludeMap[path] = true;
          });

          /*
           * All declared include files have already been concatenated into the same
           * script unit before entry file.
           *
           * Keep include(path) for compatibility with plugins that call it manually.
           * It validates the path, then becomes a no-op.
           */
          globalThis.include = function(path) {
            path = String(path || "");
            if (!Object.prototype.hasOwnProperty.call(__lyricoDeclaredIncludeMap, path)) {
              throw new Error("Include path is not declared in includeDirs: " + path);
            }
          };
        })();
    """.trimIndent()

        return buildString {
            append(includeBootstrap)
            append('\n')

            includeSources.forEach { source ->
                append("\n;")
                append("\n// ===== Platform include: ")
                append(source.path)
                append(" =====\n")
                append(source.content)
                append("\n//# sourceURL=")
                append(source.path)
                append('\n')
            }

            append("\n;")
            append("\n// ===== Platform entry: ")
            append(entry)
            append(" =====\n")
            append(entryFile.readText())
            append("\n//# sourceURL=")
            append(entry)
            append('\n')
        }
    }

    private data class IncludedScript(
        val path: String,
        val content: String
    )
}
