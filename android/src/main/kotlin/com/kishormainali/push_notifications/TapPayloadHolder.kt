package com.kishormainali.push_notifications

import android.content.Intent

/** Seam over the payload extra of an [Intent]. */
interface PayloadSource {
    fun get(): String?
    fun remove()
}

class IntentPayloadSource(private val intent: Intent) : PayloadSource {
    override fun get(): String? = intent.getStringExtra(NotificationBuilder.PAYLOAD_EXTRA)
    override fun remove() = intent.removeExtra(NotificationBuilder.PAYLOAD_EXTRA)
}

/** Holds a native tap payload until Dart asks for it, exactly once. */
class TapPayloadHolder {
    private var pending: String? = null

    /** Reads and strips the launch intent's payload so it is not re-delivered. */
    fun captureLaunch(source: PayloadSource) {
        take(source)?.let { pending = it }
    }

    /** Keeps a payload that could not be delivered live (e.g. Dart not ready). */
    fun keep(payload: String) {
        pending = payload
    }

    fun consumeLaunchPayload(): String? = pending.also { pending = null }

    companion object {
        fun take(source: PayloadSource): String? =
            source.get()?.also { source.remove() }
    }
}
