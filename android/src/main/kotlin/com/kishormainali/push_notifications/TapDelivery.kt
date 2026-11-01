package com.kishormainali.push_notifications

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

/**
 * Sends [tap] to Dart via [send]; without a [scope] or [send] (engine
 * detached) or when the send fails, the tap is handed to [keep] with its
 * captured flag.
 *
 * The coroutine starts undispatched, so [send] (whose platform-channel send
 * is synchronous up to its first suspension) runs on the caller's thread
 * before this returns: called from `onNewIntent`, the message is posted to
 * Dart inside `onNewIntent`, with no hop behind the activity's later
 * lifecycle callbacks.
 */
internal fun deliverTapLive(
    scope: CoroutineScope?,
    tap: NativeTap,
    send: (suspend (NativeTap) -> Unit)?,
    keep: (NativeTap) -> Unit,
) {
    if (scope == null || send == null) {
        keep(tap)
        return
    }
    scope.launch(start = CoroutineStart.UNDISPATCHED) {
        try {
            send(tap)
        } catch (e: CancellationException) {
            keep(tap)
            throw e
        } catch (e: Exception) {
            Log.w("push_notifications", "onNativeTap not delivered, keeping for launch: $e")
            keep(tap)
        }
    }
}

/**
 * Whether the host activity is in the foreground for a tap arriving now via
 * `onNewIntent`: true iff it has been resumed since it was last started.
 *
 * The current lifecycle state cannot answer this: Android never delivers a
 * new intent to a resumed activity (a resumed one is paused first and
 * resumed after), so at `onNewIntent` the activity is at most STARTED both
 * for a tap made while it was in the foreground (resumed -> paused) and for
 * one that brings it back from the background (stopped -> started). The
 * difference is whether it was stopped in between.
 */
class ActivityActiveTracker {
    @Volatile
    var appWasActive: Boolean = false
        private set

    fun onStarted() {
        appWasActive = false
    }

    fun onResumed() {
        appWasActive = true
    }

    /** A pause alone (e.g. around `onNewIntent`) keeps the foreground flag. */
    fun onPaused() = Unit

    fun onStopped() {
        appWasActive = false
    }

    fun reset() {
        appWasActive = false
    }
}
