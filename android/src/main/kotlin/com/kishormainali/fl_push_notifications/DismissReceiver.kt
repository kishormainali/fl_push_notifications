package com.kishormainali.fl_push_notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Receives the delete intent of a notification posted by this plugin. */
class DismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(NotificationBuilder.PAYLOAD_EXTRA) ?: return
        DismissBus.emit(payload)
    }
}

/**
 * Hands dismissals to the running Flutter engine. Without a listener (the app
 * process is not running Dart) a dismissal is dropped.
 */
object DismissBus {
    @Volatile
    var listener: ((String) -> Unit)? = null

    fun emit(payload: String) {
        listener?.invoke(payload)
    }
}
