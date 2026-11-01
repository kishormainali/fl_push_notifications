package com.kishormainali.push_notifications

import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.util.Log

/** Returns the package name of the current default home launcher, if any. */
fun interface LauncherLookup {
    fun launcherPackage(): String?
}

/** Pushes a badge count to a recognized launcher. May throw; callers swallow. */
fun interface BadgeSender {
    fun send(vendor: BadgeVendor, count: Int)
}

/**
 * How each recognized launcher family receives a badge count (ShortcutBadger
 * style, written in-house). Launchers using notification dots derive the badge
 * from active notifications instead and need none of this.
 */
enum class BadgeVendor(vararg val packages: String) {
    /** Generic `BADGE_COUNT_UPDATE` broadcast (Samsung, LG, ASUS, KISS, ...). */
    DEFAULT(
        "com.sec.android.app.launcher", "com.sec.android.app.twlauncher",
        "com.lge.launcher2", "com.lge.launcher3", "com.asus.launcher",
        "fr.neamar.kiss", "com.quaap.launchtime", "com.quaap.launchtime_official",
    ),
    SONY("com.sonyericsson.home", "com.sonymobile.home"),
    HTC("com.htc.launcher"),
    HUAWEI("com.huawei.android.launcher"),
    HONOR("com.hihonor.android.launcher"),
    OPPO("com.oppo.launcher"),
    VIVO("com.bbk.launcher2"),
    XIAOMI("com.miui.home"),
    NOVA("com.teslacoilsw.launcher");

    companion object {
        fun of(launcher: String?): BadgeVendor? =
            launcher?.let { p -> entries.firstOrNull { p in it.packages } }
    }
}

/**
 * App icon badge on Android (best effort). The count is persisted so the main
 * and background engines agree; it is pushed to the launcher only when the
 * launcher is recognized. Reading the launcher's count back is not possible.
 */
class BadgeHandler(
    private val store: KeyValueStore,
    private val launcher: LauncherLookup,
    private val sender: BadgeSender,
) {
    private val vendor: BadgeVendor? by lazy { BadgeVendor.of(launcher.launcherPackage()) }

    fun isBadgeSupported(): Boolean = vendor != null

    /** Android launchers do not expose the badge count. */
    fun getBadgeCount(): Long? = null

    fun storedCount(): Long = store.getLong(KEY_COUNT) ?: 0L

    fun setBadgeCount(count: Long) {
        val c = count.coerceIn(0L, Int.MAX_VALUE.toLong())
        store.putAll(mapOf(KEY_COUNT to c))
        val v = vendor ?: return
        try {
            sender.send(v, c.toInt())
        } catch (e: Exception) {
            Log.w(TAG, "badge update for $v failed", e)
        }
    }

    fun clearBadge() = setBadgeCount(0)

    fun incrementBadge(): Long {
        val next = storedCount() + 1
        setBadgeCount(next)
        return next
    }

    companion object {
        const val KEY_COUNT = "push_notifications.badgeCount"
        private const val TAG = "push_notifications"

        fun create(context: Context): BadgeHandler {
            val app = context.applicationContext
            return BadgeHandler(
                SharedPreferencesStore(app),
                homeLauncherLookup(app),
                AndroidBadgeSender(app),
            )
        }

        fun homeLauncherLookup(context: Context) = LauncherLookup {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            context.packageManager
                .resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
                ?.activityInfo?.packageName
        }
    }
}

/** Sends the vendor-specific broadcast or content-provider update. */
class AndroidBadgeSender(private val context: Context) : BadgeSender {
    override fun send(vendor: BadgeVendor, count: Int) {
        val pkg = context.packageName
        val component: ComponentName =
            context.packageManager.getLaunchIntentForPackage(pkg)?.component ?: return
        val cls = component.className
        when (vendor) {
            BadgeVendor.DEFAULT -> broadcast(
                "android.intent.action.BADGE_COUNT_UPDATE",
                "badge_count" to count,
                "badge_count_package_name" to pkg,
                "badge_count_class_name" to cls,
            )
            BadgeVendor.SONY -> broadcast(
                "com.sonyericsson.home.action.UPDATE_BADGE",
                "com.sonyericsson.home.intent.extra.badge.PACKAGE_NAME" to pkg,
                "com.sonyericsson.home.intent.extra.badge.ACTIVITY_NAME" to cls,
                "com.sonyericsson.home.intent.extra.badge.MESSAGE" to count.toString(),
                "com.sonyericsson.home.intent.extra.badge.SHOW_MESSAGE" to (count > 0),
            )
            BadgeVendor.HTC -> {
                broadcast(
                    "com.htc.launcher.action.SET_NOTIFICATION",
                    "com.htc.launcher.extra.COMPONENT" to component.flattenToShortString(),
                    "com.htc.launcher.extra.COUNT" to count,
                )
                broadcast(
                    "com.htc.launcher.action.UPDATE_SHORTCUT",
                    "packagename" to pkg,
                    "count" to count,
                )
            }
            BadgeVendor.HUAWEI, BadgeVendor.HONOR -> {
                val authority = if (vendor == BadgeVendor.HUAWEI) {
                    "com.huawei.android.launcher.settings"
                } else {
                    "com.hihonor.android.launcher.settings"
                }
                context.contentResolver.call(
                    Uri.parse("content://$authority/badge/"),
                    "change_badge",
                    null,
                    bundle("package" to pkg, "class" to cls, "badgenumber" to count),
                )
            }
            BadgeVendor.OPPO -> context.contentResolver.call(
                Uri.parse("content://com.android.badge/badge"),
                "setAppBadgeCount",
                null,
                bundle("app_badge_count" to count),
            )
            BadgeVendor.VIVO -> broadcast(
                "launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM",
                "packageName" to pkg,
                "className" to cls,
                "notificationNum" to count,
            )
            // Modern MIUI derives the badge from the notification number; this
            // legacy broadcast covers older MIUI builds.
            BadgeVendor.XIAOMI -> broadcast(
                "android.intent.action.APPLICATION_MESSAGE_UPDATE",
                "android.intent.extra.update_application_component_name" to
                    "$pkg/$cls",
                "android.intent.extra.update_application_message_text" to
                    (if (count == 0) "" else count.toString()),
            )
            BadgeVendor.NOVA -> context.contentResolver.insert(
                Uri.parse("content://com.teslacoilsw.notifier/unread_count"),
                ContentValues().apply {
                    put("tag", "$pkg/$cls")
                    put("count", count)
                },
            )
        }
    }

    private fun broadcast(action: String, vararg extras: Pair<String, Any>) {
        val intent = Intent(action)
        for ((k, v) in extras) {
            when (v) {
                is Int -> intent.putExtra(k, v)
                is Boolean -> intent.putExtra(k, v)
                else -> intent.putExtra(k, v.toString())
            }
        }
        context.sendBroadcast(intent)
    }

    private fun bundle(vararg values: Pair<String, Any>) = Bundle().apply {
        for ((k, v) in values) {
            if (v is Int) putInt(k, v) else putString(k, v.toString())
        }
    }
}
