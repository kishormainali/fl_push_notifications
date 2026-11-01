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

/**
 * FIFO of native tap payloads not yet delivered to Dart, so no tap is lost
 * (e.g. a second tap via onNewIntent during cold start, before Dart's init
 * registered `PushFlutterApi`). Each payload is handed out exactly once.
 */
class TapPayloadHolder {
    private val pending = ArrayDeque<String>()

    /** Reads and strips the launch intent's payload so it is not re-delivered. */
    @Synchronized
    fun captureLaunch(source: PayloadSource) {
        take(source)?.let { pending.addLast(it) }
    }

    /** Keeps a payload that could not be delivered live (e.g. Dart not ready). */
    @Synchronized
    fun keep(payload: String) {
        pending.addLast(payload)
    }

    /**
     * Returns the oldest pending payload (the launch tap) and hands every
     * remaining one, in order, to [deliverRest] (live delivery to Dart).
     */
    fun consumeLaunchPayload(deliverRest: (String) -> Unit): String? {
        val head: String?
        val rest: List<String>
        synchronized(this) {
            head = pending.removeFirstOrNull()
            rest = pending.toList()
            pending.clear()
        }
        rest.forEach(deliverRest)
        return head
    }

    companion object {
        fun take(source: PayloadSource): String? =
            source.get()?.also { source.remove() }
    }
}
