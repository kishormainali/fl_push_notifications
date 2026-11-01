package com.kishormainali.push_notifications

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** PushNotificationsPlugin */
class PushNotificationsPlugin : FlutterPlugin {
    private var flutterApi: PushFlutterApi? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = flutterPluginBinding.binaryMessenger
        PushHostApi.setUp(messenger, PushHostApiImpl())
        flutterApi = PushFlutterApi(messenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PushHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
    }
}
