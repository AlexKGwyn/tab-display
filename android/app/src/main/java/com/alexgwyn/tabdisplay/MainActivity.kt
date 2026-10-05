package com.alexgwyn.tabdisplay

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

private const val TAG = "TabDisplay"
private const val TCP_PORT = 7878
private const val ACTION_USB_PERMISSION = "com.alexgwyn.tabdisplay.USB_PERMISSION"
private const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"

class MainActivity : Activity() {
    private lateinit var usb: UsbManager
    private lateinit var surfaceView: DisplayView
    private lateinit var status: StatusView
    // What we know about the connection, for the guidance screen.
    private var usbHostConnected = false      // attached to a computer (not just a charger)
    private var accessoryActive = false       // USB accessory function actually up (USB_STATE)
    private var permissionDenied = false
    private var lastMac: String? = null        // Mac we were streaming from, until unplugged
    private var lastMacVersion = ""
    private lateinit var banner: TextView
    private lateinit var hud: TextView
    private val main = Handler(Looper.getMainLooper())
    private var hudVisible = false
    private var lastHudLog = 0L

    private val hudTick = object : Runnable {
        override fun run() {
            val text = NativeBridge.hudText()
            if (hudVisible) hud.text = text
            val now = System.currentTimeMillis()
            if (now - lastHudLog > 2000 && status.visibility != View.VISIBLE) {
                lastHudLog = now
                Log.i("TabDisplayHUD", text.replace('\n', '|'))
            }
            main.postDelayed(this, 250)
        }
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    Log.i(TAG, "accessory detached")
                    NativeBridge.stopUsb()
                    lastMac = null
                    permissionDenied = false
                }
                ACTION_USB_PERMISSION -> {
                    val acc = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && acc != null) {
                        permissionDenied = false
                        openAccessory(acc)
                    } else {
                        Log.w(TAG, "accessory permission denied")
                        permissionDenied = true
                    }
                }
                ACTION_USB_STATE -> {
                    // Sticky; "connected" means attached to a USB host, not merely charging.
                    applyUsbState(intent)
                }
            }
            refreshStatus()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        usb = getSystemService(UsbManager::class.java)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            preferredDisplayModeId = pickDisplayMode()
        }
        window.setSustainedPerformanceMode(true)

        surfaceView = DisplayView(this, { toggleHud() }) { w, h -> onVideoAreaChanged(w, h) }
        status = StatusView(this) {
            permissionDenied = false
            currentAccessory()?.let { openAccessory(it, userAsked = true) }
        }
        banner = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 15f; gravity = Gravity.CENTER
            setPadding(40, 22, 40, 22)
            background = android.graphics.drawable.GradientDrawable().apply { cornerRadius = 28f; setColor(0xE6B4560B.toInt()) }
            visibility = View.GONE
        }
        hud = TextView(this).apply {
            setTextColor(Color.GREEN); setBackgroundColor(0xB0000000.toInt()); textSize = 13f
            typeface = android.graphics.Typeface.MONOSPACE; setPadding(16, 12, 16, 12)
            visibility = TextView.GONE
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -1))
            addView(hud, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
            addView(banner, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = 48 })
        })
        window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        initNative()
        NativeBridge.stateListener = { connected, peer ->
            if (connected) {
                lastMac = peer.ifBlank { "your Mac" }
                lastMacVersion = NativeBridge.macVersion()
                versionMismatch()?.let { showBanner(it) }
            }
            refreshStatus()
            // The session's fd is gone but the accessory may still be attached: reopen it.
            if (!connected) main.postDelayed({
                if (!NativeBridge.hasUsbSession()) currentAccessory()?.let { openAccessory(it) }
            }, 300)
            Log.i(TAG, "session state connected=$connected peer=$peer")
        }
        registerReceiver(null, IntentFilter(ACTION_USB_STATE), RECEIVER_NOT_EXPORTED)?.let { applyUsbState(it) }
        registerReceiver(usbReceiver, IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            addAction(ACTION_USB_PERMISSION)
            addAction(ACTION_USB_STATE)
        }, RECEIVER_NOT_EXPORTED)

        refreshStatus()
        hudVisible = getPreferences(MODE_PRIVATE).getBoolean("hud", false)
        handleIntent(intent)
        applyHud()
        main.post(hudTick)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        if (!NativeBridge.hasUsbSession()) currentAccessory()?.let { openAccessory(it) }
    }

    override fun onDestroy() {
        unregisterReceiver(usbReceiver)
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.hasExtra("hud")) {
            hudVisible = intent.getBooleanExtra("hud", false)
            applyHud()
        }
        val acc = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        if (acc != null) openAccessory(acc)
    }

    private fun openAccessory(acc: UsbAccessory, userAsked: Boolean = false) {
        if (NativeBridge.hasUsbSession()) return
        if (!usb.hasPermission(acc)) {
            // After a decline, wait for the Allow button rather than re-prompting on every resume.
            if (permissionDenied && !userAsked) { refreshStatus(); return }
            val pi = PendingIntent.getBroadcast(this, 0, Intent(ACTION_USB_PERMISSION).setPackage(packageName), PendingIntent.FLAG_MUTABLE)
            usb.requestPermission(acc, pi)
            return
        }
        val pfd = usb.openAccessory(acc)
        if (pfd == null) {
            Log.w(TAG, "openAccessory failed")
            return
        }
        Log.i(TAG, "opened accessory ${acc.manufacturer} ${acc.model} ${acc.version}")
        main.post { refreshStatus() }
        NativeBridge.startUsb(pfd.detachFd())
    }

    private fun pickDisplayMode(): Int {
        val modes = display!!.supportedModes
        val best = modes.maxWithOrNull(compareBy({ it.physicalWidth * it.physicalHeight }, { it.refreshRate })) ?: return 0
        Log.i(TAG, "display mode ${best.modeId}: ${best.physicalWidth}x${best.physicalHeight}@${best.refreshRate}")
        return best.modeId
    }

    private fun initNative() {
        // The video area is the whole window in its current orientation (rotation, split screen
        // and free-form windows all just change this size; see onVideoAreaChanged).
        val bounds = windowManager.currentWindowMetrics.bounds
        val w = bounds.width()
        val h = bounds.height()
        // Hardware decoders this device has; the Mac picks HEVC if available, else H.264.
        val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder && it.isHardwareAccelerated }
        fun decoderFor(mime: String) = codecs.firstOrNull { it.supportedTypes.any { t -> t.equals(mime, true) } }
        val hevc = decoderFor("video/hevc")
        val avc = decoderFor("video/avc")
        val codecMask = (if (hevc != null) CodecMask.HEVC else 0) or (if (avc != null) CodecMask.H264 else 0)
        val lowLatency = hevc?.getCapabilitiesForType("video/hevc")?.isFeatureSupported(CodecCapabilities.FEATURE_LowLatency) ?: false
        Log.i(TAG, "decoders: hevc=${hevc?.name} avc=${avc?.name} lowLatency=$lowLatency")
        val (widthMm, heightMm) = millimeters(w, h)
        NativeBridge.init(hevc?.name ?: "", lowLatency, w, h, display!!.supportedModes.maxOf { it.refreshRate },
            deviceName(), if (BuildConfig.DEBUG) TCP_PORT else 0, codecMask, widthMm, heightMm, BuildConfig.VERSION_NAME)
    }

    /** Physical size of a w×h pixel area, so macOS gets the DPI right. */
    private fun millimeters(w: Int, h: Int): Pair<Int, Int> {
        val dm = resources.displayMetrics
        val dpi = (dm.xdpi + dm.ydpi) / 2
        return Pair((w / dpi * 25.4f).toInt(), (h / dpi * 25.4f).toInt())
    }

    private var pendingSize: Pair<Int, Int>? = null
    private val sendSize = Runnable {
        pendingSize?.let { (w, h) ->
            val (mmW, mmH) = millimeters(w, h)
            NativeBridge.setDisplaySize(w, h, mmW, mmH)
        }
    }

    /** The SurfaceView's size changed; tell the Mac once it settles (resizes come in bursts). */
    fun onVideoAreaChanged(width: Int, height: Int) {
        if (minOf(width, height) < 200) return
        pendingSize = Pair(width, height)
        main.removeCallbacks(sendSize)
        main.postDelayed(sendSize, 300)
    }

    /** The user's name for this device (Settings › About › Device name), falling back to manufacturer + model. */
    private fun deviceName(): String {
        android.provider.Settings.Global.getString(contentResolver, android.provider.Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }?.let { return it }
        val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else "$maker ${Build.MODEL}"
    }

    private fun toggleHud() {
        hudVisible = !hudVisible
        getPreferences(MODE_PRIVATE).edit().putBoolean("hud", hudVisible).apply()
        applyHud()
    }

    private fun applyHud() {
        hud.visibility = if (hudVisible) TextView.VISIBLE else TextView.GONE
    }

    /** A note when this app and the Mac app have different versions, else null. */
    private fun versionMismatch(): String? {
        val mine = BuildConfig.VERSION_NAME
        val mac = lastMacVersion
        if (mac.isBlank()) return null
        fun code(v: String) = v.split(".").map { it.toIntOrNull() ?: 0 }.plus(listOf(0, 0, 0)).let { it[0] * 10000 + it[1] * 100 + it[2] }
        return when {
            code(mine) < code(mac) -> "This app ($mine) is older than Tab Display on the Mac ($mac). Update it from the store, or from the Mac's Tab Display menu."
            code(mine) > code(mac) -> "Tab Display on the Mac ($mac) is older than this app ($mine). Update it on the Mac."
            else -> null
        }
    }

    private val hideBanner = Runnable { banner.visibility = View.GONE }

    private fun showBanner(text: String) {
        banner.text = text
        banner.visibility = View.VISIBLE
        main.removeCallbacks(hideBanner)
        main.postDelayed(hideBanner, 10_000)
    }

    private fun applyUsbState(intent: Intent) {
        usbHostConnected = intent.getBooleanExtra("connected", false)
        accessoryActive = usbHostConnected && intent.getBooleanExtra("accessory", false)
        if (!usbHostConnected) lastMac = null
    }

    /**
     * The attached accessory, if accessory mode is really up. UsbManager keeps listing an accessory
     * after the host switches the device back to another USB function (no ACCESSORY_DETACHED).
     */
    private fun currentAccessory(): UsbAccessory? = if (accessoryActive) usb.accessoryList?.firstOrNull() else null

    /**
     * Shows the guidance screen unless a Mac is streaming. The native session outlives this
     * Activity (recreation, backgrounding), so always ask it rather than trusting past events.
     */
    private fun refreshStatus() {
        if (NativeBridge.isConnected()) {
            status.visibility = View.GONE
            return
        }
        val accessory = currentAccessory()
        val phase = when {
            accessory != null && !usb.hasPermission(accessory) -> ConnectionPhase.NeedsPermission
            NativeBridge.hasUsbSession() -> lastMac?.let { ConnectionPhase.Disconnected(it, versionMismatch()) } ?: ConnectionPhase.WaitingForMac
            accessory != null -> ConnectionPhase.WaitingForMac
            usbHostConnected -> ConnectionPhase.CableNoMacApp
            else -> ConnectionPhase.NoCable
        }
        status.show(phase)
        status.visibility = View.VISIBLE
    }
}

/** Full-screen SurfaceView the decoder renders into; also the input capture surface. */
class DisplayView(
    context: Context,
    private val onThreeFingerTap: () -> Unit,
    private val onSizeChanged: (Int, Int) -> Unit,
) : SurfaceView(context), SurfaceHolder.Callback {
    private val input = InputEncoder(this)

    init {
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
        // The default focus highlight is a translucent white tint over the whole (focused)
        // view: it lifted black on the video to 41/255.
        defaultFocusHighlightEnabled = false
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
        requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        holder.surface.setFrameRate(120f, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, Surface.CHANGE_FRAME_RATE_ALWAYS)
        NativeBridge.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.i(TAG, "surface ${width}x$height")
        onSizeChanged(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        NativeBridge.setSurface(null)
    }

    private fun isPen(e: MotionEvent): Boolean {
        val t = e.getToolType(0)
        return t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN) requestUnbufferedDispatch(e)
        if (e.actionMasked == MotionEvent.ACTION_POINTER_DOWN && e.pointerCount == 3 && !isPen(e)) onThreeFingerTap()
        if (isPen(e)) input.onPen(e) else input.onTouch(e)
        return true
    }

    override fun onHoverEvent(e: MotionEvent): Boolean {
        if (!isPen(e)) return false
        if (e.actionMasked == MotionEvent.ACTION_HOVER_ENTER) requestUnbufferedDispatch(e)
        input.onPen(e)
        return true
    }
}
