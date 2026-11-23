package com.vyse.vyse_tv

import android.app.ActivityManager
import android.app.AppOpsManager
import android.content.ActivityNotFoundException
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.speech.RecognizerIntent
import android.util.Rational
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import androidx.annotation.RequiresApi
import com.vyse.player.DeferredSurfaceTextureListener
import com.vyse.player.ExternalPlayerChannel
import com.vyse.player.FlutterRendererPolicy
import com.vyse.player.TvDetection
import com.vyse.player.exoplayer.DoviBridge
import com.vyse.player.exoplayer.ExoPlayerPlugin
import com.vyse.player.mpv.MpvAudioPlayerPlugin
import com.vyse.player.mpv.MpvPlayerPlugin
import com.vyse.player.shared.DeviceQuirks
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

/**
 * Hosts the player (android/app/src/main/kotlin/com/vyse/player, copied
 * from upstream's activity): the video lives in a SurfaceView
 * *below* Flutter, so Flutter must render through a transparent TextureView.
 */
class MainActivity : FlutterActivity() {
  private val pipChannelName = "vyse/pip"

  private var flutterTextureView: FlutterTextureView? = null
  private var flutterSurfaceReconnectPending = false
  private var activityStarted = false

  // Upstream's "open in another player" (vyse/external_player)
  private val externalPlayerChannel = ExternalPlayerChannel(this)

  private var autoPipReady = false
  private var autoPipWidth = 16
  private var autoPipHeight = 9

  // Voice search (lib/widgets/voice_search.dart): the answer waiting for Android's "Speak now"
  private var pendingVoice: MethodChannel.Result? = null

  private fun speechIntent(prompt: String?): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
      .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
      .apply { if (!prompt.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt) }

  // Whether a text box in the app has focus (lib/dpad/tv_text_input.dart says so, on TVs)
  private var nativeTextInputFocused = false
  private var imeLeakRestartBudget = 0
  private var lastImeLeakRestartUptime = 0L

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (TvDetection.isTv(this)) installTextEditorProxy()
  }

  // ── How Flutter draws, chosen before it starts (upstream's activity) ──
  //
  // Flutter draws with Impeller on Android. On TV boxes its raster cost is far higher than
  // Skia's: upstream runs Skia below Android 12, on Fire TVs, on 32-bit TV chips (the low-memory,
  // low-throughput class, which many TCL and Hisense TVs are), on NVIDIA and Huawei, and on
  // anything without Vulkan 1.1 (FlutterRendererPolicy.kt, copied with the player and never used
  // until now). Testers found VyseTV slow on TVs where their other apps ran smoothly. And Dart's
  // heap otherwise grows to half of all memory, which gets apps killed on 2 GB boxes: there it
  // is capped (the manifest's OldGenHeapSize keeps Flutter from putting its default back).
  @Suppress("DEPRECATION") // (as in upstream: the per-device choice has no other way in yet)
  override fun getFlutterShellArgs(): FlutterShellArgs {
    val args = super.getFlutterShellArgs()
    val renderer = FlutterRendererPolicy.select(
      isEWaste = DeviceQuirks.isEWaste,
      manufacturer = Build.MANUFACTURER,
      isAndroidTv = TvDetection.isTv(this),
      sdkInt = Build.VERSION.SDK_INT,
      // FEATURE_VULKAN_HARDWARE_VERSION gives 1.1.0 as 0x401000
      supportsVulkan11 = packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION, 0x401000),
      is64Bit = Process.is64Bit()
    )
    renderer.shellArgument?.let { args.add(it) }
    val lowRam = isLowRamClass()
    args.add("--old-gen-heap-size=${if (lowRam) 256 else defaultOldGenHeapSizeMegabytes()}")
    Log.i(TAG, "Renderer ${renderer.diagnosticName}, little memory: $lowRam")
    return args
  }

  private fun memoryInfo(): Pair<ActivityManager, ActivityManager.MemoryInfo> {
    val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val info = ActivityManager.MemoryInfo()
    activityManager.getMemoryInfo(info)
    return activityManager to info
  }

  /** A 32-bit process, the system's low-memory flag, or about 2.2 GB of memory or less. */
  private fun isLowRamClass(): Boolean {
    val (activityManager, info) = memoryInfo()
    return !Process.is64Bit() || activityManager.isLowRamDevice || info.totalMem <= LOW_MEM_THRESHOLD_BYTES
  }

  /** Flutter's own default, half of all memory (the manifest's meta-data turns it off). */
  private fun defaultOldGenHeapSizeMegabytes(): Int = (memoryInfo().second.totalMem / 1e6 / 2).toInt()

  // ── The TV's on-screen keyboard (from upstream's activity) ──
  //
  // Android TV's low-memory setting (config_preventImeStartupUnlessTextEditor: Chromecast with
  // Google TV, TCL and Philips Google TVs) answers every keyboard start whose focused view does
  // not say it is a text editor by unbinding the keyboard. FlutterView never says so, so the
  // keyboard is drawn but the app holds no typing session: the letters go nowhere, and the
  // remote's arrows, meant for the keyboard's keys, fall through to the app, where they moved
  // focus about behind the keyboard (a tester could not type into the sign-in box).
  //
  // This 1-by-1 view inside FlutterView holds Android's focus in its place, says it is a text
  // editor while a text box in the app has focus, and hands the keyboard Flutter's own
  // connection. Keys are unaffected: FlutterView.dispatchKeyEvent runs before its focused child.
  private inner class TextEditorProxyView(context: Context, private val flutterView: View) : View(context) {
    init {
      isFocusable = true
      isFocusableInTouchMode = true
      importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onCheckIsTextEditor(): Boolean = nativeTextInputFocused

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? = flutterView.onCreateInputConnection(outAttrs)

    override fun checkInputConnectionProxy(view: View): Boolean = view === flutterView
  }

  private fun installTextEditorProxy() {
    val flutterView = findViewById<View>(FLUTTER_VIEW_ID) as? ViewGroup ?: return
    flutterView.descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
    val proxy = TextEditorProxyView(this, flutterView)
    flutterView.addView(proxy, FrameLayout.LayoutParams(1, 1))
    if (flutterView.isFocused) proxy.requestFocus()
  }

  private fun isImeVisible(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
    return window.decorView.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
  }

  // A keyboard that is up owns the arrows: a healthy one takes them before the app does. One
  // arriving here means its typing session is not bound to this app, so bind it again and eat
  // the press, so focus cannot wander behind the keyboard. A few tries at most, a second apart,
  // so keys always flow again on a device that cannot be mended.
  private fun consumeLeakedImeNavigationKey(event: KeyEvent): Boolean {
    if (!nativeTextInputFocused || imeLeakRestartBudget <= 0) return false
    when (event.keyCode) {
      KeyEvent.KEYCODE_DPAD_UP,
      KeyEvent.KEYCODE_DPAD_DOWN,
      KeyEvent.KEYCODE_DPAD_LEFT,
      KeyEvent.KEYCODE_DPAD_RIGHT,
      KeyEvent.KEYCODE_DPAD_CENTER -> Unit
      else -> return false
    }
    if (!isImeVisible()) return false
    if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
      val now = SystemClock.uptimeMillis()
      if (now - lastImeLeakRestartUptime >= IME_LEAK_RESTART_MIN_INTERVAL_MS) {
        lastImeLeakRestartUptime = now
        imeLeakRestartBudget--
        findViewById<View>(FLUTTER_VIEW_ID)?.let { view ->
          (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).restartInput(view)
        }
      }
    }
    return true
  }

  // (reaching the activity means the keyboard already passed on this key)
  override fun dispatchKeyEvent(event: KeyEvent): Boolean {
    if (consumeLeakedImeNavigationKey(event)) return true
    return super.dispatchKeyEvent(event)
  }

  // ── Player: video under a transparent Flutter ──

  // Keep Flutter in the normal View hierarchy so the player's video/subtitle
  // SurfaceViews stay the only native composition layers.
  override fun getRenderMode(): RenderMode = RenderMode.texture

  // Transparent so the video below shows through wherever Flutter paints nothing.
  override fun getTransparencyMode(): TransparencyMode = TransparencyMode.transparent

  override fun onFlutterTextureViewCreated(flutterTextureView: FlutterTextureView) {
    this.flutterTextureView = flutterTextureView
    val original = flutterTextureView.surfaceTextureListener ?: return
    flutterTextureView.surfaceTextureListener =
      DeferredSurfaceTextureListener(
        delegate = original,
        onSurfaceAvailable = ::tryReconnectFlutterSurface,
        // A resize must rebuild the surface at the new size, or an idle screen
        // stays squeezed into the old buffer after a rotation.
        onResize = { swapFlutterSurface(flutterTextureView) }
      ) { surface ->
        flutterTextureView.isAvailable && flutterTextureView.surfaceTexture === surface
      }
  }

  override fun onStop() {
    activityStarted = false
    if (TvDetection.isTv(this)) flutterSurfaceReconnectPending = true
    super.onStop()
  }

  override fun onStart() {
    super.onStart()
    activityStarted = true
    tryReconnectFlutterSurface()
  }

  // Some TV firmware keeps an "available" TextureView while invalidating its
  // compositor surface in standby; swap the surface so rendering resumes.
  private fun tryReconnectFlutterSurface() {
    if (!activityStarted || !flutterSurfaceReconnectPending) return
    val textureView = flutterTextureView ?: return
    textureView.post {
      if (!activityStarted ||
        !flutterSurfaceReconnectPending ||
        textureView !== flutterTextureView ||
        !textureView.isAttachedToWindow ||
        !textureView.isAvailable
      ) {
        return@post
      }
      Log.i(TAG, "Reconnecting Flutter texture surface after Android TV standby")
      swapFlutterSurface(textureView)
      flutterSurfaceReconnectPending = false
    }
  }

  private fun swapFlutterSurface(textureView: FlutterTextureView) {
    textureView.pause()
    textureView.resume()
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(MpvPlayerPlugin())
    flutterEngine.plugins.add(ExoPlayerPlugin())
    flutterEngine.plugins.add(MpvAudioPlayerPlugin())
    // VyseTV: second audio-only core so audiobooks keep their own track next to music
    flutterEngine.plugins.add(MpvAudio2PlayerPlugin())
    // VyseTV: a third that plays nothing out loud: it decodes a video's sound for subtitle sync
    flutterEngine.plugins.add(MpvAudioListenerPlugin())
    externalPlayerChannel.attach(flutterEngine.dartExecutor.binaryMessenger)

    // Upstream's device signals: lib/core/platform/device_performance.dart picks the lighter
    // visual tier from them on a weak box (no focus glow, instant focus animations, smaller caches)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vyse/device").setMethodCallHandler { call, result ->
      // VyseTV: what this TV can do with HDR and Dolby Vision, for the report card
      // (lib/data/playback/playback_report.dart)
      if (call.method == "getPlaybackCapabilities") {
        result.success(runCatching { DoviBridge.capabilities(this) }.getOrDefault(emptyMap<String, Any?>()))
        return@setMethodCallHandler
      }
      if (call.method != "getPerformanceSignals") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val (activityManager, info) = memoryInfo()
      result.success(
        mapOf(
          // the process's own bitness: cheap TV boxes often run a 32-bit system
          "is64Bit" to Process.is64Bit(),
          "isLowRamDevice" to activityManager.isLowRamDevice,
          "totalMemBytes" to info.totalMem
        )
      )
    }

    // VyseTV: voice search. One press of a search box's microphone listens at once, with
    // whatever this device has for it (on Android TV and Google TV, Google's own voice screen).
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vyse/voice").setMethodCallHandler { call, result ->
      if (call.method != "listen") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val intent = speechIntent(call.argument<String>("prompt"))
      if (intent.resolveActivity(packageManager) == null) {
        result.error("UNAVAILABLE", "Nothing on this device listens for speech.", null)
        return@setMethodCallHandler
      }
      // a second press while one is listening answers the first with nothing
      pendingVoice?.success(null)
      pendingVoice = result
      try {
        @Suppress("DEPRECATION")
        startActivityForResult(intent, VOICE_REQUEST)
      } catch (e: ActivityNotFoundException) {
        pendingVoice = null
        result.error("UNAVAILABLE", "Nothing on this device listens for speech.", null)
      }
    }

    // VyseTV: whether a text box has focus, for the TV keyboard's stand-in view above
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vyse/text_input").setMethodCallHandler { call, result ->
      if (call.method != "setNativeTextInputFocused") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val was = nativeTextInputFocused
      nativeTextInputFocused = call.arguments as? Boolean ?: false
      if (nativeTextInputFocused && !was) imeLeakRestartBudget = IME_LEAK_RESTART_BUDGET
      result.success(null)
    }

    // VyseTV: the updater hands a downloaded, checked APK to Android's own installer
    // (lib/data/updates/updater.dart). Android asks the person before anything is installed.
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vyse/update").setMethodCallHandler { call, result ->
      if (call.method != "install") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      try {
        val file = File(call.argument<String>("path") ?: "")
        if (!file.isFile) {
          result.error("NO_FILE", "The update file is missing.", null)
          return@setMethodCallHandler
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(
          Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        result.success(true)
      } catch (e: Exception) {
        result.error("INSTALL_FAILED", "Android couldn't open the installer.", e.message)
      }
    }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName).setMethodCallHandler { call, result ->
      when (call.method) {
        "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isPipSupportedDevice())
        "enter" -> {
          if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("success" to false, "errorCode" to "android_version"))
            return@setMethodCallHandler
          }
          if (!isPipSupportedDevice()) {
            result.success(mapOf("success" to false, "errorCode" to "not_supported"))
            return@setMethodCallHandler
          }
          if (!isPipPermissionGranted()) {
            result.success(mapOf("success" to false, "errorCode" to "permission_disabled"))
            return@setMethodCallHandler
          }
          try {
            val width = call.argument<Int>("width") ?: 16
            val height = call.argument<Int>("height") ?: 9
            val success = enterPictureInPictureMode(buildPipParams(width, height))
            result.success(if (success) mapOf("success" to true) else mapOf("success" to false, "errorCode" to "failed"))
          } catch (e: IllegalStateException) {
            result.success(mapOf("success" to false, "errorCode" to "not_supported"))
          } catch (e: Exception) {
            Log.w(TAG, "Failed to enter PiP", e)
            result.success(mapOf("success" to false, "errorCode" to "unknown", "errorMessage" to e.message))
          }
        }
        "setAutoPipReady" -> {
          if (!isPipSupportedDevice()) {
            autoPipReady = false
            result.success(true)
            return@setMethodCallHandler
          }
          autoPipReady = call.argument<Boolean>("ready") ?: false
          autoPipWidth = call.argument<Int>("width") ?: 16
          autoPipHeight = call.argument<Int>("height") ?: 9
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
              setPictureInPictureParams(buildPipParams(autoPipWidth, autoPipHeight, autoEnterEnabled = autoPipReady))
            } catch (e: Exception) {
              Log.w(TAG, "Failed to set auto-PiP params", e)
            }
          }
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }
  }

  @Deprecated("FlutterActivity still routes results through here")
  @Suppress("DEPRECATION")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode == VOICE_REQUEST) {
      val heard = if (resultCode == RESULT_OK) data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() else null
      pendingVoice?.success(heard)
      pendingVoice = null
      return
    }
    if (!externalPlayerChannel.onActivityResult(requestCode, resultCode, data)) {
      super.onActivityResult(requestCode, resultCode, data)
    }
  }

  override fun onDestroy() {
    externalPlayerChannel.dispose()
    super.onDestroy()
  }

  // ── Picture-in-picture ──

  override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    flutterEngine?.let { engine ->
      MethodChannel(engine.dartExecutor.binaryMessenger, pipChannelName).invokeMethod("onPipChanged", isInPictureInPictureMode)
      (engine.plugins.get(ExoPlayerPlugin::class.java) as? ExoPlayerPlugin)?.onPipModeChanged(isInPictureInPictureMode)
    }
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    // Auto PiP for API 26-30 (API 31+ uses setAutoEnterEnabled)
    if (isPipSupportedDevice() &&
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
      autoPipReady &&
      isPipPermissionGranted()
    ) {
      try {
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
          MethodChannel(messenger, pipChannelName).invokeMethod("onAutoPipEntering", null)
        }
        enterPictureInPictureMode(buildPipParams(autoPipWidth, autoPipHeight))
      } catch (e: Exception) {
        Log.w(TAG, "Failed to enter auto-PiP", e)
      }
    }
  }

  private fun isPipSupportedDevice(): Boolean =
    !TvDetection.isTv(this) && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

  @RequiresApi(Build.VERSION_CODES.O)
  private fun isPipPermissionGranted(): Boolean {
    val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
    @Suppress("DEPRECATION")
    return appOps.checkOpNoThrow(AppOpsManager.OPSTR_PICTURE_IN_PICTURE, applicationInfo.uid, packageName) ==
      AppOpsManager.MODE_ALLOWED
  }

  @RequiresApi(Build.VERSION_CODES.O)
  private fun buildPipParams(width: Int, height: Int, autoEnterEnabled: Boolean? = null): PictureInPictureParams {
    val (w, h) = if (width <= 0 || height <= 0) {
      Pair(16, 9)
    } else {
      val ratio = width.toFloat() / height.toFloat()
      when {
        ratio < 1f / 2.39f -> Pair(100, 239)
        ratio > 2.39f -> Pair(239, 100)
        else -> Pair(width, height)
      }
    }
    val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(w, h))
    if (autoEnterEnabled != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setAutoEnterEnabled(autoEnterEnabled)
    }
    return builder.build()
  }

  /** Audiobooks' own mpv audio core (upstream ships one; VyseTV needs two). */
  class MpvAudio2PlayerPlugin : MpvPlayerPlugin(channelBase = "vyse/mpv_audio_player_2", audioOnly = true)

  /** Decodes stretches of a video's sound to a file (ao=pcm) for subtitle sync by ear. */
  class MpvAudioListenerPlugin : MpvPlayerPlugin(channelBase = "vyse/mpv_audio_listener", audioOnly = true)

  private companion object {
    const val TAG = "VyseMainActivity"

    const val VOICE_REQUEST = 7301

    // about 2.2 GB: above what 2 GB boxes report, below 3 GB ones (upstream's line)
    const val LOW_MEM_THRESHOLD_BYTES = 2252L shl 20

    // repairs of a keyboard left without a typing session (see consumeLeakedImeNavigationKey)
    const val IME_LEAK_RESTART_BUDGET = 2
    const val IME_LEAK_RESTART_MIN_INTERVAL_MS = 1000L
  }
}
