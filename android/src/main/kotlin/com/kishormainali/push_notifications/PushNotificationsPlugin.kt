package com.kishormainali.push_notifications

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** PushNotificationsPlugin */
class PushNotificationsPlugin : FlutterPlugin {
    private var flutterApi: PushFlutterApi? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = flutterPluginBinding.binaryMessenger
        // Registered for every engine, including FCM's background engine.
        val context = flutterPluginBinding.applicationContext
        PushHostApi.setUp(
            messenger,
            PushHostApiImpl(
                BadgeHandler.create(context),
                PushStorage(SharedPreferencesStore(context)),
            ),
        )
        flutterApi = PushFlutterApi(messenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PushHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
    }
}
