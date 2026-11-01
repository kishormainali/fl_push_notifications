package com.kishormainali.push_notifications

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Native implementation of [PushHostApi]. */
class PushHostApiImpl(
    private val badge: BadgeHandler,
    private val storage: PushStorage,
    private val channels: ChannelManager,
    private val presenter: NotificationPresenter<*>,
    private val downloader: ImageDownloader,
    /** Returns the launch tap and delivers any further queued taps live. */
    private val takeLaunchPayload: () -> String?,
) : PushHostApi {
    override fun isBadgeSupported(): Boolean = badge.isBadgeSupported()
    override fun setBadgeCount(count: Long) = badge.setBadgeCount(count)
    override fun getBadgeCount(): Long? = badge.getBadgeCount()
    override fun clearBadge() = badge.clearBadge()
    override fun incrementBadge(): Long = badge.incrementBadge()
    override fun createChannel(c: ChannelConfig) = channels.create(c)
    override fun deleteChannel(id: String) = channels.delete(id)
    override fun getLastLaunchId(): String? = storage.getLastLaunchId()
    override fun setLastLaunchId(id: String) = storage.setLastLaunchId(id)
    override fun saveBackgroundConfig(config: BackgroundConfigMsg) =
        storage.saveBackgroundConfig(config)
    override fun loadBackgroundConfig(): BackgroundConfigMsg? = storage.loadBackgroundConfig()
    override fun consumeLaunchPayload(): String? = takeLaunchPayload()
    override suspend fun showNotification(content: NotificationContent) = presenter.show(content)
    override suspend fun downloadImage(
        url: String,
        timeoutMs: Long,
        maxBytes: Long,
        httpsOnly: Boolean,
    ): String? = withContext(Dispatchers.IO) {
        downloader.download(url, timeoutMs, maxBytes, httpsOnly)?.absolutePath
    }
}
