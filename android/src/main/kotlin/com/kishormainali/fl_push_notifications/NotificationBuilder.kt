package com.kishormainali.fl_push_notifications

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import android.util.Log

enum class NotificationStyleKind { BIG_PICTURE, BIG_TEXT, PLAIN }

/** Every decision the builder makes, separated from Android types for testing. */
data class NotificationPlan(
    val id: Int,
    val channelId: String,
    val title: String?,
    val body: String?,
    val number: Int?,
    val style: NotificationStyleKind,
    val payload: String,
    /** setLargeIcon gets a small thumbnail ([LargeIconScaler]), not the picture. */
    val thumbnailLargeIcon: Boolean = false,
    /** BigPictureStyle.bigLargeIcon(null): the expanded view shows the picture once. */
    val clearBigLargeIcon: Boolean = false,
)

object NotificationPlanner {
    fun plan(
        content: NotificationContent,
        hasBitmap: Boolean,
        channelExists: (String) -> Boolean,
        defaultChannelId: String?,
    ): NotificationPlan {
        val channelId = resolveChannel(content.channelId, channelExists, defaultChannelId)
        val style = when {
            hasBitmap -> NotificationStyleKind.BIG_PICTURE
            !content.body.isNullOrEmpty() -> NotificationStyleKind.BIG_TEXT
            else -> NotificationStyleKind.PLAIN
        }
        return NotificationPlan(
            id = content.id.toInt(),
            channelId = channelId,
            title = content.title,
            body = content.body,
            number = content.badge?.toInt(),
            style = style,
            payload = payloadJson(content, channelId),
            thumbnailLargeIcon = style == NotificationStyleKind.BIG_PICTURE,
            clearBigLargeIcon = style == NotificationStyleKind.BIG_PICTURE,
        )
    }

    /**
     * Android 8+ silently drops notifications posted to a missing channel, so
     * an unknown id falls back to the stored default.
     */
    fun resolveChannel(requested: String, exists: (String) -> Boolean, defaultChannelId: String?): String {
        if (exists(requested) || defaultChannelId == null) return requested
        Log.w(TAG, "unknown channel \"$requested\", using \"$defaultChannelId\"")
        return defaultChannelId
    }

    /**
     * Tap payload contract read by `PushMessage.fromLocalPayload`:
     * `{"id","title","body","data","imageUrl","channelId"}`; `id` is
     * `extras["messageId"]` when present, else the notification id.
     */
    fun payloadJson(content: NotificationContent, channelId: String): String {
        val id = (content.extras["messageId"] as? String)?.takeIf { it.isNotEmpty() }
            ?: content.id.toString()
        val data = content.data.entries
            .filter { it.key != null }
            .joinToString(",", "{", "}") { "${quote(it.key)}:${quote(it.value)}" }
        return "{\"id\":${quote(id)},\"title\":${quote(content.title)},\"body\":${quote(content.body)}," +
            "\"data\":$data,\"imageUrl\":${quote(content.imageUrl)},\"channelId\":${quote(channelId)}}"
    }

    private fun quote(s: String?): String {
        if (s == null) return "null"
        val sb = StringBuilder(s.length + 2).append('"')
        for (ch in s) {
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (ch < ' ') sb.append("\\u%04x".format(ch.code)) else sb.append(ch)
            }
        }
        return sb.append('"').toString()
    }

    private const val TAG = "push_notifications"
}

/**
 * Size math for the collapsed-view large icon. The picture itself is up to
 * 2048 px; the large icon is shown at ~64 dp, so a thumbnail keeps the
 * Binder transaction small.
 */
object LargeIconScaler {
    const val MAX_EDGE = 256

    fun needsScaling(width: Int, height: Int, maxEdge: Int = MAX_EDGE): Boolean =
        maxOf(width, height) > maxEdge

    /** Longer edge at most [maxEdge], aspect preserved, never upscaled. */
    fun targetSize(width: Int, height: Int, maxEdge: Int = MAX_EDGE): Pair<Int, Int> {
        if (!needsScaling(width, height, maxEdge)) return width to height
        return if (width >= height) {
            maxEdge to Math.round(height.toDouble() * maxEdge / width).toInt().coerceAtLeast(1)
        } else {
            Math.round(width.toDouble() * maxEdge / height).toInt().coerceAtLeast(1) to maxEdge
        }
    }

    /** A thumbnail of [bitmap] (the same instance when already small), or null on failure. */
    fun thumbnail(bitmap: Bitmap): Bitmap? = try {
        val (w, h) = targetSize(bitmap.width, bitmap.height)
        if (w == bitmap.width && h == bitmap.height) bitmap else Bitmap.createScaledBitmap(bitmap, w, h, true)
    } catch (e: Throwable) {
        Log.w("push_notifications", "large icon thumbnail failed: $e")
        null
    }
}

object SmallIconResolver {
    const val META_PLUGIN = "com.kishormainali.fl_push_notifications.default_icon"
    const val META_FCM = "com.google.firebase.messaging.default_notification_icon"

    /** First non-zero of plugin meta-data, FCM meta-data, launcher icon. */
    fun pick(pluginIcon: Int, fcmIcon: Int, launcherIcon: Int): Int = when {
        pluginIcon != 0 -> pluginIcon
        fcmIcon != 0 -> fcmIcon
        launcherIcon != 0 -> launcherIcon
        else -> android.R.drawable.sym_def_app_icon
    }

    fun resolve(context: Context): Int {
        val app = try {
            context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
        } catch (e: Exception) {
            return android.R.drawable.sym_def_app_icon
        }
        val meta = app.metaData
        val icon = pick(meta?.getInt(META_PLUGIN, 0) ?: 0, meta?.getInt(META_FCM, 0) ?: 0, app.icon)
        // Android 8.0 crashes System UI on an adaptive icon used as a small icon.
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.O && icon == app.icon) {
            val adaptive = try {
                context.getDrawable(icon) is AdaptiveIconDrawable
            } catch (e: Exception) {
                true
            }
            if (adaptive) return android.R.drawable.sym_def_app_icon
        }
        return icon
    }
}

object NotificationBuilder {
    /** Intent extra holding the tap payload JSON. */
    const val PAYLOAD_EXTRA = "push_notifications.payload"

    fun build(
        context: Context,
        content: NotificationContent,
        bitmap: Bitmap?,
        channelExists: (String) -> Boolean = { true },
        defaultChannelId: String? = null,
    ): Notification {
        val plan = NotificationPlanner.plan(content, bitmap != null, channelExists, defaultChannelId)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, plan.channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        b.setSmallIcon(SmallIconResolver.resolve(context))
            .setContentTitle(plan.title)
            .setContentText(plan.body)
            .setAutoCancel(true)
        plan.number?.let { b.setNumber(it) }
        when (plan.style) {
            NotificationStyleKind.BIG_PICTURE -> {
                val style = Notification.BigPictureStyle().bigPicture(bitmap).setSummaryText(plan.body)
                if (plan.clearBigLargeIcon) style.bigLargeIcon(null as Bitmap?)
                val icon = if (plan.thumbnailLargeIcon) bitmap?.let(LargeIconScaler::thumbnail) else bitmap
                icon?.let { b.setLargeIcon(it) }
                b.setStyle(style)
            }
            NotificationStyleKind.BIG_TEXT -> b.setStyle(Notification.BigTextStyle().bigText(plan.body))
            NotificationStyleKind.PLAIN -> Unit
        }
        contentIntent(context, plan)?.let { b.setContentIntent(it) }
        return b.build()
    }

    private fun contentIntent(context: Context, plan: NotificationPlan): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.putExtra(PAYLOAD_EXTRA, plan.payload)
        // CLEAR_TOP + SINGLE_TOP delivers onNewIntent to a running activity.
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        // Per-notification request code so each keeps its own payload.
        return PendingIntent.getActivity(
            context,
            plan.id,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
