package com.kishormainali.fl_push_notifications

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import java.io.File

/** PushNotificationsPlugin */
class PushNotificationsPlugin : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var flutterApi: PushFlutterApi? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var scope: CoroutineScope? = null
    private val taps = TapPayloadHolder()
    private val activityState = ActivityActiveTracker()
    private var lifecycleCallbacks: HostActivityCallbacks? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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
            PushHostApiImpl(
                BadgeHandler.create(context), storage, channels, presenter, downloader,
                // The rest is posted: it must reach Dart after this call's reply.
                takeLaunchPayload = {
                    consumeLaunchThenDeliverRest(taps, { mainHandler.post(it) }, ::deliverLive)
                },
            ),
        )
        flutterApi = PushFlutterApi(messenger)
        // Main.immediate: work started from the main thread (onNewIntent) is
        // not posted behind later main-thread messages.
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
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
        lifecycleCallbacks?.let(binding.activity.application::unregisterActivityLifecycleCallbacks)
        // Usually attached while the activity is being created (not resumed);
        // a late attach to an already resumed activity is seeded as such.
        activityState.seed(
            (binding.activity as? LifecycleOwner)
                ?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true,
        )
        val callbacks = HostActivityCallbacks(binding.activity, activityState)
        binding.activity.application.registerActivityLifecycleCallbacks(callbacks)
        lifecycleCallbacks = callbacks
    }

    override fun onDetachedFromActivity() {
        activityBinding?.let { b ->
            b.removeOnNewIntentListener(this)
            lifecycleCallbacks?.let(b.activity.application::unregisterActivityLifecycleCallbacks)
        }
        lifecycleCallbacks = null
        activityBinding = null
        activityState.reset()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val payload = TapPayloadHolder.take(IntentPayloadSource(intent)) ?: return false
        // Captured now: Dart's lifecycle may change before the tap reaches it.
        deliverLive(NativeTap(payload, activityState.appWasActive))
        return true
    }

    /**
     * Sends [tap] to Dart now; if Dart is not listening yet (cold start,
     * before init registered PushFlutterApi) it is queued, with its captured
     * flag, behind any earlier undelivered tap for consumeLaunchPayload.
     */
    private fun deliverLive(tap: NativeTap) {
        val api = flutterApi
        deliverTapLive(
            scope,
            tap,
            api?.let { a -> { t: NativeTap -> a.onNativeTap(t.payload, t.appWasActive) } },
            taps::keep,
        )
    }

    /** Feeds the host activity's lifecycle (only that activity) to [state]. */
    private class HostActivityCallbacks(
        private val host: Activity,
        private val state: ActivityActiveTracker,
    ) : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            if (activity === host) state.onStarted()
        }

        override fun onActivityResumed(activity: Activity) {
            if (activity === host) state.onResumed()
        }

        override fun onActivityPaused(activity: Activity) {
            if (activity === host) state.onPaused()
        }

        override fun onActivityStopped(activity: Activity) {
            if (activity === host) state.onStopped()
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
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
