package com.kishormainali.fl_push_notifications

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
 * A native tap: its payload and whether the app was in the foreground when
 * the tap was received natively (labels `PushMessage.appState` in Dart).
 */
data class NativeTap(val payload: String, val appWasActive: Boolean)

/**
 * FIFO of native tap payloads not yet delivered to Dart, so no tap is lost
 * (e.g. a second tap via onNewIntent during cold start, before Dart's init
 * registered `PushFlutterApi`). Each payload is handed out exactly once.
 */
class TapPayloadHolder {
    private val pending = ArrayDeque<NativeTap>()

    /** Reads and strips the launch intent's payload so it is not re-delivered. */
    @Synchronized
    fun captureLaunch(source: PayloadSource) {
        // A cold-start tap: the app was not in the foreground. Dart labels the
        // launch head `terminated`; the flag matters only if it is delivered
        // live as part of the rest.
        take(source)?.let { pending.addLast(NativeTap(it, appWasActive = false)) }
    }

    /**
     * Keeps a tap that could not be delivered live (e.g. Dart not ready),
     * with the app state captured when it was received.
     */
    @Synchronized
    fun keep(tap: NativeTap) {
        pending.addLast(tap)
    }

    /**
     * Returns the oldest pending payload (the launch tap) and hands every
     * remaining one, in order and with its captured flag, to [deliverRest]
     * (live delivery to Dart).
     */
    fun consumeLaunchPayload(deliverRest: (NativeTap) -> Unit): String? {
        val head: String?
        val rest: List<NativeTap>
        synchronized(this) {
            head = pending.removeFirstOrNull()?.payload
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
