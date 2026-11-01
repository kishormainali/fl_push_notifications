package com.kishormainali.push_notifications

import android.content.Context

/** Minimal key/value seam over SharedPreferences so storage logic is JVM-testable. */
interface KeyValueStore {
    fun getString(key: String): String?
    fun getLong(key: String): Long?
    fun getBoolean(key: String): Boolean?

    /** Writes all entries in one commit; a `null` value removes the key. */
    fun putAll(values: Map<String, Any?>)
}

/**
 * [KeyValueStore] backed by the `push_notifications` SharedPreferences file.
 * Uses the application context so it works from background engines too.
 */
class SharedPreferencesStore(context: Context) : KeyValueStore {
    private val prefs =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun getLong(key: String): Long? =
        if (prefs.contains(key)) prefs.getLong(key, 0L) else null

    override fun getBoolean(key: String): Boolean? =
        if (prefs.contains(key)) prefs.getBoolean(key, false) else null

    override fun putAll(values: Map<String, Any?>) {
        val e = prefs.edit()
        for ((k, v) in values) {
            when (v) {
                null -> e.remove(k)
                is String -> e.putString(k, v)
                is Long -> e.putLong(k, v)
                is Boolean -> e.putBoolean(k, v)
                else -> throw IllegalArgumentException("Unsupported type for $k")
            }
        }
        // commit (not apply): a background engine may be torn down right after.
        e.commit()
    }

    companion object {
        const val PREFS_NAME = "push_notifications"
    }
}

/** Persists the background config and the last launch-tap ids. */
class PushStorage(private val store: KeyValueStore) {
    fun getLastLaunchId(): String? = store.getString(KEY_LAST_LAUNCH_ID)

    fun setLastLaunchId(id: String) = store.putAll(mapOf(KEY_LAST_LAUNCH_ID to id))

    fun saveBackgroundConfig(c: BackgroundConfigMsg) = store.putAll(
        mapOf(
            CFG + "defaultChannelId" to c.defaultChannelId,
            CFG + "channelKey" to c.channelKey,
            CFG + "imageKey" to c.imageKey,
            CFG + "titleKey" to c.titleKey,
            CFG + "bodyKey" to c.bodyKey,
            CFG + "imageHttpsOnly" to c.imageHttpsOnly,
            CFG + "autoIncrementOnPush" to c.autoIncrementOnPush,
            CFG + "autoClearOnForeground" to c.autoClearOnForeground,
            CFG + "hookHandle" to c.hookHandle,
        ),
    )

    fun loadBackgroundConfig(): BackgroundConfigMsg? {
        fun s(k: String) = store.getString(CFG + k)
        fun b(k: String) = store.getBoolean(CFG + k)
        return BackgroundConfigMsg(
            defaultChannelId = s("defaultChannelId") ?: return null,
            channelKey = s("channelKey") ?: return null,
            imageKey = s("imageKey") ?: return null,
            titleKey = s("titleKey") ?: return null,
            bodyKey = s("bodyKey") ?: return null,
            imageHttpsOnly = b("imageHttpsOnly") ?: return null,
            autoIncrementOnPush = b("autoIncrementOnPush") ?: return null,
            autoClearOnForeground = b("autoClearOnForeground") ?: return null,
            hookHandle = store.getLong(CFG + "hookHandle"),
        )
    }

    companion object {
        const val KEY_LAST_LAUNCH_ID = "push_notifications.lastLaunchId"
        private const val CFG = "push_notifications.bgConfig."
    }
}
