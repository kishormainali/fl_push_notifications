package com.kishormainali.push_notifications

/**
 * Native implementation of [PushHostApi]. Every method is a stub until the
 * owning task (badge, channels, notification display, config, launch payload)
 * replaces it.
 */
class PushHostApiImpl : PushHostApi {
    private fun notImplemented(): Nothing =
        throw FlutterError("not-implemented", "Not implemented yet", null)

    override fun isBadgeSupported(): Boolean = notImplemented()
    override fun setBadgeCount(count: Long) = notImplemented()
    override fun getBadgeCount(): Long? = notImplemented()
    override fun clearBadge() = notImplemented()
    override fun incrementBadge(): Long = notImplemented()
    override fun createChannel(c: ChannelConfig) = notImplemented()
    override fun deleteChannel(id: String) = notImplemented()
    override fun getLastLaunchId(): String? = notImplemented()
    override fun setLastLaunchId(id: String) = notImplemented()
    override fun saveBackgroundConfig(config: BackgroundConfigMsg) = notImplemented()
    override fun loadBackgroundConfig(): BackgroundConfigMsg? = notImplemented()
    override fun consumeLaunchPayload(): String? = notImplemented()
    override suspend fun showNotification(content: NotificationContent) = notImplemented()
    override suspend fun downloadImage(
        url: String,
        timeoutMs: Long,
        maxBytes: Long,
        httpsOnly: Boolean,
    ): String? = notImplemented()
}
