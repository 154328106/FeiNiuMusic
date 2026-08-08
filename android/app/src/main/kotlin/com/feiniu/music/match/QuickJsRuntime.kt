package com.feiniu.music.match

import androidx.annotation.Keep

/**
 * QuickJS 运行时封装（移植自 Lyrico，Apache-2.0）。
 *
 * 创建 QuickJS 引擎实例并注入 `globalThis.Platform`（宿主能力，由
 * [QuickJsHostApi] 提供）。插件脚本经 [eval] 加载后，通过 [call] 调用其
 * `searchSongs` / `getLyrics` / `searchCovers` 全局函数。
 */
@Keep
class QuickJsRuntime(
    memoryLimitBytes: Long = DEFAULT_MEMORY_LIMIT_BYTES,
    stackSizeBytes: Long = DEFAULT_STACK_SIZE_BYTES,
    timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    hostApi: QuickJsHostApi? = QuickJsHostApi()
) : PluginJsRuntime {
    private var runtimePtr: Long = QuickJsNative.createRuntime(
        memoryLimitBytes = memoryLimitBytes,
        stackSizeBytes = stackSizeBytes,
        timeoutMs = timeoutMs,
        hostApi = hostApi
    ).also { ptr ->
        if (hostApi != null) {
            QuickJsNative.eval(ptr, HOST_API_BOOTSTRAP, "<feiniu-host>")
        }
    }

    fun eval(script: String): String = eval(script, "<eval>")

    override fun eval(script: String, filename: String): String {
        val ptr = runtimePtr
        check(ptr != 0L) { "QuickJS runtime is closed" }
        return QuickJsNative.eval(ptr, script, filename)
    }

    override fun call(functionName: String, requestJson: String): String {
        val ptr = runtimePtr
        check(ptr != 0L) { "QuickJS runtime is closed" }
        return QuickJsNative.call(ptr, functionName, requestJson)
    }

    override fun close() {
        val ptr = runtimePtr
        if (ptr != 0L) {
            runtimePtr = 0L
            QuickJsNative.closeRuntime(ptr)
        }
    }

    private companion object {
        const val DEFAULT_MEMORY_LIMIT_BYTES = 64L * 1024L * 1024L
        const val DEFAULT_STACK_SIZE_BYTES = 2L * 1024L * 1024L
        const val DEFAULT_TIMEOUT_MS = 15_000L

        val HOST_API_BOOTSTRAP = """
            (function() {
              function hostCall(name, payload) {
                return JSON.parse(__lyricoHostCall(name, JSON.stringify(payload || {}))).value;
              }

              function normalizeOptions(options) {
                options = options || {};
                return {
                  headers: options.headers || {},
                  contentType: options.contentType,
                  connectTimeoutMs: options.connectTimeoutMs,
                  readTimeoutMs: options.readTimeoutMs,
                  followRedirects: options.followRedirects
                };
              }

              function normalizeBodyPayload(url, body, options) {
                options = normalizeOptions(options);
                return {
                  url: String(url || ""),
                  body: body == null ? "" : String(body),
                  bodyBase64: options.bodyBase64 || "",
                  bodyBytes: options.bodyBytes || null,
                  contentType: options.contentType || "application/json; charset=utf-8",
                  headers: options.headers || {},
                  connectTimeoutMs: options.connectTimeoutMs,
                  readTimeoutMs: options.readTimeoutMs,
                  followRedirects: options.followRedirects
                };
              }

              globalThis.app = {
                getInfo: function() {
                  return hostCall("app.info", {});
                },
                getUserAgent: function() {
                  return hostCall("app.userAgent", {});
                }
              };

              globalThis.runtime = {
                getInfo: function() {
                  return hostCall("runtime.info", {});
                }
              };

              globalThis.Platform = {
                app: globalThis.app,
                runtime: globalThis.runtime,

                cache: {
                  get: function(key) {
                    return hostCall("cache.get", {
                      key: String(key || "")
                    });
                  },
                  set: function(key, value, ttlMs) {
                    return hostCall("cache.set", {
                      key: String(key || ""),
                      value: value == null ? "" : String(value),
                      ttlMs: Number(ttlMs || 0)
                    });
                  },
                  remove: function(key) {
                    return hostCall("cache.remove", {
                      key: String(key || "")
                    });
                  },
                  clear: function() {
                    return hostCall("cache.clear", {});
                  }
                },

                crypto: {
                  md5: function(text) {
                    return hostCall("crypto.md5", {
                      text: String(text || "")
                    });
                  },
                  aesEcbPkcs5EncryptBase64: function(text, key) {
                    return hostCall("crypto.aesEcbPkcs5EncryptBase64", {
                      text: String(text || ""),
                      key: String(key || "")
                    });
                  },
                  aesEcbPkcs5EncryptHex: function(text, key) {
                    return hostCall("crypto.aesEcbPkcs5EncryptHex", {
                      text: String(text || ""),
                      key: String(key || "")
                    });
                  },
                  aesEcbPkcs5DecryptBase64ToText: function(base64, key) {
                    return hostCall("crypto.aesEcbPkcs5DecryptBase64ToText", {
                      base64: String(base64 || ""),
                      key: String(key || "")
                    });
                  }
                },

                base64: {
                  encodeText: function(text) {
                    return hostCall("base64.encodeText", {
                      text: String(text || "")
                    });
                  },
                  decodeText: function(base64) {
                    return hostCall("base64.decodeText", {
                      base64: String(base64 || "")
                    });
                  },
                  dropBytes: function(base64, count) {
                    return hostCall("base64.dropBytes", {
                      base64: String(base64 || ""),
                      count: count || 0
                    });
                  },
                  decodeBytes: function(base64) {
                    return hostCall("base64.decodeBytes", {
                      base64: String(base64 || "")
                    });
                  },
                  encodeBytes: function(bytes) {
                    return hostCall("base64.encodeBytes", {
                      bytes: Array.from(bytes || [])
                    });
                  },
                  encodeUrlText: function(text) {
                    return hostCall("base64.encodeUrlText", {
                      text: String(text || "")
                    });
                  },
                  decodeUrlText: function(base64Url) {
                    return hostCall("base64.decodeUrlText", {
                      base64Url: String(base64Url || "")
                    });
                  },
                  encodeUrlBytes: function(bytes) {
                    return hostCall("base64.encodeUrlBytes", {
                      bytes: Array.from(bytes || [])
                    });
                  },
                  decodeUrlBytes: function(base64Url) {
                    return hostCall("base64.decodeUrlBytes", {
                      base64Url: String(base64Url || "")
                    });
                  },
                  toUrl: function(base64) {
                    return hostCall("base64.toUrl", {
                      base64: String(base64 || "")
                    });
                  },
                  fromUrl: function(base64Url) {
                    return hostCall("base64.fromUrl", {
                      base64Url: String(base64Url || "")
                    });
                  }
                },

                bytes: {
                  xor: function(bytes, key) {
                    return hostCall("bytes.xor", {
                      bytes: Array.from(bytes || []),
                      key: Array.from(key || [])
                    });
                  },
                  xorBase64: function(base64, key) {
                    return hostCall("bytes.xorBase64", {
                      base64: String(base64 || ""),
                      key: Array.from(key || [])
                    });
                  }
                },

                compression: {
                  inflateBytesToText: function(bytes) {
                    return hostCall("compression.inflateBytesToText", {
                      bytes: Array.from(bytes || [])
                    });
                  },
                  inflateBase64ToText: function(base64) {
                    return hostCall("compression.inflateBase64ToText", {
                      base64: String(base64 || "")
                    });
                  }
                },

                http: {
                  getText: function(url, options) {
                    options = normalizeOptions(options);
                    return hostCall("http.getText", {
                      url: String(url || ""),
                      headers: options.headers || {},
                      connectTimeoutMs: options.connectTimeoutMs,
                      readTimeoutMs: options.readTimeoutMs,
                      followRedirects: options.followRedirects
                    });
                  },

                  postText: function(url, body, options) {
                    options = normalizeOptions(options);
                    return hostCall("http.postText", {
                      url: String(url || ""),
                      body: body == null ? "" : String(body),
                      contentType: options.contentType || "application/json; charset=utf-8",
                      headers: options.headers || {},
                      connectTimeoutMs: options.connectTimeoutMs,
                      readTimeoutMs: options.readTimeoutMs,
                      followRedirects: options.followRedirects
                    });
                  },

                  postBytes: function(url, body, options) {
                    options = normalizeOptions(options);
                    return hostCall("http.postBytes", {
                      url: String(url || ""),
                      body: body == null ? "" : String(body),
                      contentType: options.contentType || "application/octet-stream",
                      headers: options.headers || {},
                      connectTimeoutMs: options.connectTimeoutMs,
                      readTimeoutMs: options.readTimeoutMs,
                      followRedirects: options.followRedirects
                    });
                  },

                  get: function(url, options) {
                    options = normalizeOptions(options);
                    return hostCall("http.get", {
                      url: String(url || ""),
                      headers: options.headers || {},
                      connectTimeoutMs: options.connectTimeoutMs,
                      readTimeoutMs: options.readTimeoutMs,
                      followRedirects: options.followRedirects
                    });
                  },

                  post: function(url, body, options) {
                    return hostCall(
                      "http.post",
                      normalizeBodyPayload(url, body, options)
                    );
                  },

                  getBytes: function(url, options) {
                    options = normalizeOptions(options);
                    return hostCall("http.getBytes", {
                      url: String(url || ""),
                      headers: options.headers || {},
                      connectTimeoutMs: options.connectTimeoutMs,
                      readTimeoutMs: options.readTimeoutMs,
                      followRedirects: options.followRedirects
                    });
                  },

                  postBytesResponse: function(url, body, options) {
                    options = normalizeOptions(options);
                    var payload = normalizeBodyPayload(url, body, options);
                    payload.contentType = options.contentType || "application/octet-stream";
                    return hostCall("http.postBytesResponse", payload);
                  }
                },

                xml: {
                  getRootAttributes: function(xml) {
                    return hostCall("xml.getRootAttributes", {
                      xml: String(xml || "")
                    });
                  },

                  findElements: function(xml, query) {
                    return hostCall("xml.findElements", {
                      xml: String(xml || ""),
                      query: query || {}
                    });
                  },

                  replaceChildrenByAttr: function(xml, options) {
                    return hostCall("xml.replaceChildrenByAttr", {
                      xml: String(xml || ""),
                      options: options || {}
                    });
                  },

                  removeElements: function(xml, query) {
                    return hostCall("xml.removeElements", {
                      xml: String(xml || ""),
                      query: query || {}
                    });
                  }
                },

                log: {
                  debug: function(tag, message) {
                    if (message === undefined) {
                      message = tag;
                      tag = "PlatformPlugin";
                    }
                    return hostCall("log.debug", {
                      tag: String(tag || "PlatformPlugin"),
                      message: String(message || "")
                    });
                  },
                  warn: function(tag, message) {
                    if (message === undefined) {
                      message = tag;
                      tag = "PlatformPlugin";
                    }
                    return hostCall("log.warn", {
                      tag: String(tag || "PlatformPlugin"),
                      message: String(message || "")
                    });
                  },
                  error: function(tag, message) {
                    if (message === undefined) {
                      message = tag;
                      tag = "PlatformPlugin";
                    }
                    return hostCall("log.error", {
                      tag: String(tag || "PlatformPlugin"),
                      message: String(message || "")
                    });
                  }
                }
              };
            })();
        """.trimIndent()
    }
}
