package com.kishormainali.push_notifications

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** PushNotificationsPlugin */
class PushNotificationsPlugin : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var flutterApi: PushFlutterApi? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var scope: CoroutineScope? = null
    private val taps = TapPayloadHolder()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = flutterPluginBinding.binaryMessenger
        // Registered for every engine, including FCM's background engine.
        val context = flutterPluginBinding.applicationContext
        val storage = PushStorage(SharedPreferencesStore(context))
        val defaultChannel = { storage.loadBackgroundConfig()?.defaultChannelId }
        val channels = ChannelManager(SystemChannelStore(context), defaultChannel)
        val downloader = ImageDownloader(File(context.cacheDir, "push_notifications_images"))
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val presenter = NotificationPresenter<Bitmap>(
            config = { storage.loadBackgroundConfig() },
            loadImage = { url, httpsOnly ->
                withContext(Dispatchers.IO) {
                    downloader.download(url, IMAGE_TIMEOUT_MS, IMAGE_MAX_BYTES, httpsOnly)?.let(::decode)
                }
            },
            build = { c, bitmap ->
                NotificationBuilder.build(context, c, bitmap, channels::exists, defaultChannel())
            },
            canPost = { canPost(context) },
            notifier = { id, n -> nm.notify(id, n) },
        )
        PushHostApi.setUp(
            messenger,
            PushHostApiImpl(BadgeHandler.create(context), storage, channels, presenter, downloader, taps),
        )
        flutterApi = PushFlutterApi(messenger)
        scope = MainScope()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PushHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
        scope?.cancel()
        scope = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        listen(binding)
        binding.activity.intent?.let { taps.captureLaunch(IntentPayloadSource(it)) }
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // Same launch: a recreated activity may carry the original intent again,
    // so the payload is not re-captured.
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        listen(binding)

    private fun listen(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val payload = TapPayloadHolder.take(IntentPayloadSource(intent)) ?: return false
        val api = flutterApi
        val s = scope
        if (api == null || s == null) {
            taps.keep(payload)
            return true
        }
        s.launch {
            try {
                api.onNativeTap(payload)
            } catch (e: Exception) {
                // Dart side not listening yet: keep it for consumeLaunchPayload.
                Log.w(TAG, "onNativeTap not delivered, keeping for launch: $e")
                taps.keep(payload)
            }
        }
        return true
    }

    private companion object {
        const val TAG = "push_notifications"
        const val IMAGE_TIMEOUT_MS = 10_000L
        const val IMAGE_MAX_BYTES = 5L * 1024 * 1024
        const val MAX_IMAGE_EDGE = 2048

        fun canPost(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

        /** Decodes with downsampling so a large image cannot exhaust memory. */
        fun decode(file: File): Bitmap? = try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            var sample = 1
            while (bounds.outWidth / sample > MAX_IMAGE_EDGE || bounds.outHeight / sample > MAX_IMAGE_EDGE) {
                sample *= 2
            }
            BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (e: Throwable) {
            Log.w(TAG, "image decode failed: $e")
            null
        }
    }
}
