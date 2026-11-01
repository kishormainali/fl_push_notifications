package com.kishormainali.push_notifications

/**
 * Native implementation of [PushHostApi]. Badge, background config and launch
 * id are implemented; channels, display, image download and launch payload are
 * stubs until their owning tasks replace them.
 */
class PushHostApiImpl(
    private val badge: BadgeHandler,
    private val storage: PushStorage,
) : PushHostApi {
    private fun notImplemented(): Nothing =
        throw FlutterError("not-implemented", "Not implemented yet", null)

    override fun isBadgeSupported(): Boolean = badge.isBadgeSupported()
    override fun setBadgeCount(count: Long) = badge.setBadgeCount(count)
    override fun getBadgeCount(): Long? = badge.getBadgeCount()
    override fun clearBadge() = badge.clearBadge()
    override fun incrementBadge(): Long = badge.incrementBadge()
    override fun createChannel(c: ChannelConfig) = notImplemented()
    override fun deleteChannel(id: String) = notImplemented()
    override fun getLastLaunchId(): String? = storage.getLastLaunchId()
    override fun setLastLaunchId(id: String) = storage.setLastLaunchId(id)
    override fun saveBackgroundConfig(config: BackgroundConfigMsg) =
        storage.saveBackgroundConfig(config)
    override fun loadBackgroundConfig(): BackgroundConfigMsg? = storage.loadBackgroundConfig()
    override fun consumeLaunchPayload(): String? = notImplemented()
    override suspend fun showNotification(content: NotificationContent) = notImplemented()
    override suspend fun downloadImage(
        url: String,
        timeoutMs: Long,
        maxBytes: Long,
        httpsOnly: Boolean,
    ): String? = notImplemented()
}
