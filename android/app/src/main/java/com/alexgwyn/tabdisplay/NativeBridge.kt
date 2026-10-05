package com.alexgwyn.tabdisplay

import android.os.Handler
import android.os.Looper
import android.view.Surface

object NativeBridge {
    init { System.loadLibrary("tabdisplay") }

    /** Called on the main thread when the Mac connects (peer = Mac name) or disconnects. */
    var stateListener: ((connected: Boolean, peer: String) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())

    @JvmStatic external fun init(decoder: String, lowLatency: Boolean, panelW: Int, panelH: Int, refresh: Float, name: String, tcpPort: Int, frontBuffer: Boolean,
                              codecMask: Int, widthMm: Int, heightMm: Int, appVersion: String)
    @JvmStatic external fun setSurface(surface: Surface?)
    @JvmStatic external fun startUsb(fd: Int)
    @JvmStatic external fun stopUsb()
    @JvmStatic external fun hasUsbSession(): Boolean
    @JvmStatic external fun sendInput(type: Int, data: ByteArray, len: Int, timestampNs: Long)
    @JvmStatic external fun setDisplaySize(width: Int, height: Int, widthMm: Int, heightMm: Int)
    /** Whether a Mac is connected right now (the session outlives Activity recreation). */
    @JvmStatic external fun isConnected(): Boolean
    /** App version of the connected Mac app ("" if unknown or not connected). */
    @JvmStatic external fun macVersion(): String
    @JvmStatic external fun hudText(): String

    @JvmStatic
    fun onSessionState(connected: Boolean, peer: String) {
        main.post { stateListener?.invoke(connected, peer) }
    }
}
