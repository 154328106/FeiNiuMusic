package com.feiniu.music.island

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Bundle
import androidx.core.app.NotificationCompat
import com.feiniu.music.R

/**
 * 通知歌词灵动岛 — 原生层。
 *
 * 采用 MIUI/HyperOS「焦点通知」路径（移植自 HyperLyric 的 buildFocusNotification，
 * GPL-3.0）：通知 extras 携带 `mFocusNotification` + `miui.focus.param`(JSON) +
 * `miui.focus.pics`(Bundle)，HyperOS 识别后在系统灵动岛渲染歌词卡片。
 *
 * 无需 root / Shizuku —— 焦点通知通过普通 [NotificationManager.notify] 发送，
 * HyperOS 原生支持第三方 App 发送（默认无需绕过白名单）。
 *
 * 同一 ID 连续 notify() 即实现歌词/进度原地刷新。
 */
class IslandLyricNotification(private val context: Context) {

    companion object {
        private const val TAG = "IslandLyricNotification"

        /** 焦点通知使用的通知 ID（与 audio_service 媒体通知 ID 不同，互不干扰）。 */
        const val NOTIFICATION_ID = 2003

        private const val CHANNEL_ID = "feiniu_island_lyric_v1"

        /** 歌词行 / 进度更新时重发通知的最小间隔，避免高频刷新压垮系统。 */
        private const val MIN_UPDATE_INTERVAL_MS = 300L
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var lastLyricKey: String? = null
    private var lastSongKey: String? = null
    private var lastUpdateMs: Long = 0
    private var lastCoverPath: String? = null
    private var lastAodLyrics: Boolean = false

    init {
        ensureNotificationChannel()
    }

    private fun ensureNotificationChannel() {
        if (notificationManager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "通知歌词灵动岛",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setSound(null, null)
            setShowBadge(false)
            enableVibration(false)
            setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
        }
        notificationManager.createNotificationChannel(channel)
    }

    /**
     * 更新灵动岛歌词。同一首歌内歌词行变化会立即刷新；仅进度变化时按
     * [MIN_UPDATE_INTERVAL_MS] 节流，避免高频刷新。
     *
     * @param leftLyric 大岛左侧歌词（长歌词前半段，短歌词传空）
     * @param lyric 大岛右侧歌词（长歌词后半段，或短歌词整行）
     * @param coverPath 封面本地文件路径（可为空，空则左侧不显示封面）
     */
    fun update(
        leftLyric: String,
        lyric: String,
        fullLyric: String,
        title: String,
        artist: String,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long,
        showProgressSetting: Boolean,
        coverPath: String?,
        aodLyrics: Boolean
    ) {
        // 完整歌词 = 左 + 右 拼接，用于歌曲变化判定（左右分割点变化不算切歌）
        val songKey = "$title|$artist"
        val lyricKey = "$leftLyric|$lyric".trim()

        // 切换歌曲或歌词行变化 → 立即刷新
        val lyricChanged = lyricKey != lastLyricKey
        val songChanged = songKey != lastSongKey
        val coverChanged = coverPath != lastCoverPath
        val aodLyricsChanged = aodLyrics != lastAodLyrics
        lastCoverPath = coverPath
        lastAodLyrics = aodLyrics

        val now = System.currentTimeMillis()
        val progressChanged = (now - lastUpdateMs) >= MIN_UPDATE_INTERVAL_MS

        if (!lyricChanged && !songChanged && !coverChanged && !aodLyricsChanged && !progressChanged) {
            return
        }

        lastLyricKey = lyricKey
        lastSongKey = songKey
        lastUpdateMs = now

        val duration = if (durationMs > 0) durationMs else 100L
        val position = positionMs.coerceIn(0, duration)
        val progress = if (duration > 1000) {
            ((position.toDouble() / duration) * 100).toInt().coerceIn(0, 100)
        } else {
            0
        }

        val songInfo = if (artist.isEmpty()) title else "$title · $artist"

        val uiState = IslandUiState(
            title = lyric,
            islandTitleLeft = leftLyric,
            fullLyric = fullLyric,
            // 通知/AOD 标题：关闭息屏歌词时显示「歌名 · 歌手」，
            // 开启时被 fullLyric 覆盖（歌词上标题、歌名·歌手移到副标题）。
            notificationTitleLeft = songInfo,
            notificationTitleRight = lyric,
            songInfo = songInfo,
            progress = progress,
            isPlaying = isPlaying,
            showProgress = showProgressSetting,
            hasCover = !coverPath.isNullOrBlank(),
            aodLyrics = aodLyrics
        )

        notify(uiState, coverPath)
    }

    fun hide() {
        notificationManager.cancel(NOTIFICATION_ID)
        lastLyricKey = null
        lastSongKey = null
        lastUpdateMs = 0
        lastCoverPath = null
        lastAodLyrics = false
    }

    private fun notify(uiState: IslandUiState, coverPath: String?) {
        // 焦点通知 extras：HyperOS 依据这些字段在灵动岛渲染
        val extras = Bundle()
        extras.putBoolean("mFocusNotification", true)
        extras.putString("miui.focus.param", FocusNotificationBuilder(uiState, uiState.showProgress).build())
        if (uiState.color != 0) {
            extras.putInt("mipush_focus_color", uiState.color)
        }

        // 图片资源：大岛左侧封面 + 小图标兜底
        val picsBundle = Bundle()
        val albumIcon = loadCoverIcon(coverPath)
        if (albumIcon != null) {
            picsBundle.putParcelable("miui.focus.pic_album", albumIcon)
        }
        extras.putBundle("miui.focus.pics", picsBundle)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOnlyAlertOnce(true)
            .setCustomContentView(null)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            // 息屏歌词开启：标题 = 完整歌词帧，歌名移到副标题；
            // 关闭：标题 = 歌名，内容 = 歌词（现状）
            .setContentTitle(
                if (uiState.aodLyrics) uiState.fullLyric else uiState.notificationTitleLeft
            )
            .setSubText(
                if (uiState.aodLyrics) uiState.songInfo else null
            )
            .setContentText(uiState.notificationTitleRight)
            .addExtras(extras)

        val notification = builder.build()
        // 常驻通知：不可手动滑动清除，仅由 stop/暂停逻辑取消
        notification.flags =
            notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR

        try {
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "发送焦点通知失败", e)
        }
    }

    /** 从本地文件加载封面为系统 Icon（失败返回 null，左侧退化为无封面）。 */
    private fun loadCoverIcon(coverPath: String?): android.graphics.drawable.Icon? {
        if (coverPath.isNullOrBlank()) return null
        return try {
            val file = java.io.File(coverPath)
            if (!file.exists()) return null
            val bitmap = android.graphics.BitmapFactory.decodeFile(coverPath)
                ?: return null
            android.graphics.drawable.Icon.createWithBitmap(bitmap)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "加载封面失败 coverPath=$coverPath", e)
            null
        }
    }
}
