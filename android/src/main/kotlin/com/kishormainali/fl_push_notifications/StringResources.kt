package com.kishormainali.fl_push_notifications

import android.content.Context

/**
 * Resolves the app string resource named [key] and formats [args] into it, as
 * FCM does for `title_loc_key` / `body_loc_key`. Returns null when there is no
 * such resource or the arguments do not fit its format.
 */
internal fun resolveStringResource(context: Context, key: String, args: List<String>): String? {
    val id = context.resources.getIdentifier(key, "string", context.packageName)
    if (id == 0) return null
    return try {
        if (args.isEmpty()) context.getString(id) else context.getString(id, *args.toTypedArray())
    } catch (e: Exception) {
        null
    }
}
