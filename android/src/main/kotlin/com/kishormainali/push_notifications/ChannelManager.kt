package com.kishormainali.push_notifications

import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/** Platform-free description of a notification channel. */
data class ChannelSpec(
    val id: String,
    val name: String,
    val description: String?,
    val importance: Int,
    val playSound: Boolean,
    val enableVibration: Boolean,
    val showBadge: Boolean,
    val groupId: String?,
)

/** Seam over [NotificationManager] channel calls so logic is JVM-testable. */
interface ChannelStore {
    fun exists(id: String): Boolean

    /** Creates the channel, or updates the mutable fields of an existing one. */
    fun upsert(spec: ChannelSpec)

    fun delete(id: String)
}

/** Channel rules: idempotent create, the default channel is undeletable. */
class ChannelManager(
    private val store: ChannelStore,
    private val defaultChannelId: () -> String?,
) {
    fun create(c: ChannelConfig) = store.upsert(
        ChannelSpec(
            id = c.id,
            name = c.name,
            description = c.channelDescription,
            // Same scale as Android IMPORTANCE_NONE..IMPORTANCE_MAX.
            importance = if (c.importance in 0..5) c.importance.toInt() else IMPORTANCE_DEFAULT,
            playSound = c.playSound,
            enableVibration = c.enableVibration,
            showBadge = c.showBadge,
            groupId = c.groupId,
        ),
    )

    fun delete(id: String) {
        if (id == defaultChannelId()) {
            throw FlutterError("default-channel", "The default channel \"$id\" cannot be deleted", null)
        }
        store.delete(id)
    }

    fun exists(id: String) = store.exists(id)

    companion object {
        private const val IMPORTANCE_DEFAULT = 3
    }
}

/** [ChannelStore] backed by the system. Channels only exist on Android 8+. */
class SystemChannelStore(context: Context) : ChannelStore {
    private val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /** Below Android 8 there are no channels, so every id is usable. */
    override fun exists(id: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || nm.getNotificationChannel(id) != null

    override fun upsert(spec: ChannelSpec) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val group = spec.groupId
        // A channel naming a missing group is rejected by the system.
        if (group != null && nm.notificationChannelGroups.none { it.id == group }) {
            nm.createNotificationChannelGroup(NotificationChannelGroup(group, group))
        }
        val ch = NotificationChannel(spec.id, spec.name, spec.importance).apply {
            description = spec.description
            setGroup(group)
            if (!spec.playSound) setSound(null, null)
            enableVibration(spec.enableVibration)
            setShowBadge(spec.showBadge)
        }
        // Idempotent: re-creating an existing id only updates name/description/group.
        nm.createNotificationChannel(ch)
    }

    override fun delete(id: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        nm.deleteNotificationChannel(id)
    }
}
