package com.kishormainali.fl_push_notifications

import android.app.Notification
import android.util.Log
import kotlinx.coroutines.CancellationException

/**
 * `showNotification` flow: optionally download the image, build, post.
 * [I] is the decoded image type (Bitmap in production). An image failure
 * never blocks the notification; it is shown text-only instead.
 */
class NotificationPresenter<I : Any>(
    private val config: () -> BackgroundConfigMsg?,
    private val loadImage: suspend (url: String, httpsOnly: Boolean) -> I?,
    private val build: (NotificationContent, I?) -> Notification,
    private val canPost: () -> Boolean,
    private val notifier: (id: Int, notification: Notification) -> Unit,
    /** Builds the group summary for a notification with a group key. */
    private val summary: (NotificationContent) -> Pair<Int, Notification>? = { null },
) {
    suspend fun show(content: NotificationContent) {
        if (!canPost()) {
            Log.w(TAG, "notification ${content.id} not shown: POST_NOTIFICATIONS not granted")
            return
        }
        val url = content.imageUrl
        val image = if (content.imageStyle == ImageStyle.BIG_PICTURE && !url.isNullOrEmpty()) {
            try {
                loadImage(url, config()?.imageHttpsOnly ?: true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "image load failed, showing text-only: $e")
                null
            }
        } else {
            null
        }
        if (image != null) {
            try {
                post(content, image)
                return
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // e.g. a bitmap the builder or binder rejects: never lose the
                // notification, retry once without the image.
                Log.w(TAG, "notification with image failed, retrying text-only: $e")
            }
        }
        post(content, null)
    }

    private fun post(content: NotificationContent, image: I?) {
        val notification = build(content, image)
        try {
            // Same id replaces the existing notification instead of stacking.
            notifier(content.id.toInt(), notification)
            if (!content.groupKey.isNullOrEmpty()) {
                summary(content)?.let { (id, n) -> notifier(id, n) }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "notify denied: $e")
        }
    }

    private companion object {
        const val TAG = "fl_push_notifications"
    }
}
