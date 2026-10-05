package com.alexgwyn.tabdisplay

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.method.LinkMovementMethod
import android.text.util.Linkify
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** What the tablet can tell about the connection, most specific first. */
sealed class ConnectionPhase {
    /** Not connected to a computer over USB (unplugged, or only a charger). */
    data object NoCable : ConnectionPhase()
    /** Attached to a computer, but no accessory handshake: the Mac app isn't running or installed. */
    data object CableNoMacApp : ConnectionPhase()
    /** The Mac switched us to accessory mode but Android's USB permission was declined. */
    data object NeedsPermission : ConnectionPhase()
    /** Accessory open, waiting for the Mac app to say hello. */
    data object WaitingForMac : ConnectionPhase()
    /** The Mac app disconnected (user clicked Disconnect, quit, or slept). */
    data class Disconnected(val macName: String, val versionNote: String? = null) : ConnectionPhase()
}

/**
 * Full-screen guidance shown whenever no Mac is streaming: what's wrong and what to do about it.
 * Built in code to match the rest of the UI; centered, scrollable for small split-screen windows.
 */
class StatusView(context: Context, private val onAllowUsb: () -> Unit) : FrameLayout(context) {
    private val icon = ImageView(context)
    private val title = text(26f, Color.WHITE, bold = true)
    private val body = text(16f, 0xFFB8BCC6.toInt())
    private val steps = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val button = Button(context).apply {
        text = "Allow"
        setOnClickListener { onAllowUsb() }
    }
    private val footer = text(13f, 0xFF80848E.toInt())

    init {
        setBackgroundColor(Color.BLACK)
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(32), dp(32), dp(32))
            icon.setImageResource(R.mipmap.ic_launcher)
            addView(icon, LinearLayout.LayoutParams(dp(88), dp(88)).apply { bottomMargin = dp(20) })
            addView(title, wrap().apply { bottomMargin = dp(10) })
            addView(body, wrap().apply { bottomMargin = dp(22) })
            addView(steps, LinearLayout.LayoutParams(-1, -2))
            addView(button, wrap().apply { topMargin = dp(18) })
            addView(footer, wrap().apply { topMargin = dp(26) })
        }
        title.gravity = Gravity.CENTER
        body.gravity = Gravity.CENTER
        footer.gravity = Gravity.CENTER
        val scroll = ScrollView(context).apply {
            isFillViewport = true
            addView(FrameLayout(context).apply {
                addView(column, LayoutParams(dp(560).coerceAtMost(resources.displayMetrics.widthPixels), -2, Gravity.CENTER))
            }, LayoutParams(-1, -2))
        }
        addView(scroll, LayoutParams(-1, -1))
    }

    fun show(phase: ConnectionPhase) {
        val macUrl = context.getString(R.string.mac_app_url)
        val install = if (macUrl.isNotBlank()) "Install Tab Display on your Mac from $macUrl" else "Install Tab Display on your Mac"
        val clickConnect = "On the Mac, click the Tab Display icon in the menu bar, then Connect next to this tablet. After the first time it connects automatically."
        button.visibility = GONE
        footer.text = "Needs a Mac with Apple silicon and macOS 14 or later. Three-finger tap shows connection stats once connected."
        when (phase) {
            ConnectionPhase.NoCable -> {
                title.text = "Connect to your Mac"
                body.text = "Use this tablet as a second display for your Mac, with pen and touch."
                setSteps(
                    install + ".",
                    "Open it and allow Screen Recording and Accessibility when asked.",
                    "Connect this tablet to the Mac with a USB‑C cable that carries data (not a charge-only cable).",
                    clickConnect,
                )
            }
            ConnectionPhase.CableNoMacApp -> {
                title.text = "Open Tab Display on your Mac"
                body.text = "This tablet is connected over USB, but Tab Display isn't running on the computer, or isn't installed."
                setSteps(
                    "$install, or open it if it's already installed.",
                    "Allow Screen Recording and Accessibility when asked.",
                    clickConnect,
                )
                footer.text = "Using a hub or dock? If nothing happens, connect the tablet directly to the Mac."
            }
            ConnectionPhase.NeedsPermission -> {
                title.text = "Allow USB access"
                body.text = "Your Mac is ready. Tab Display needs permission to talk to it over this cable."
                setSteps("Tap Allow, then tick “Always open Tab Display” so you won't be asked again.")
                button.visibility = VISIBLE
            }
            ConnectionPhase.WaitingForMac -> {
                title.text = "Waiting for your Mac…"
                body.text = "Connected to Tab Display over USB."
                setSteps(
                    "If this takes more than a few seconds, make sure Tab Display is open on the Mac and has Screen Recording and Accessibility permission.",
                    "Still stuck? Unplug the cable and plug it back in.",
                )
            }
            is ConnectionPhase.Disconnected -> {
                title.text = "Disconnected from ${phase.macName}"
                body.text = phase.versionNote ?: "The Mac stopped sharing its display."
                if (phase.versionNote != null) setSteps(
                    "Update the older app: Tab Display on the Mac, or this app from the store (or from the Tab Display menu on the Mac, with USB debugging on).",
                ) else setSteps(
                    "To reconnect, click the Tab Display icon in the Mac's menu bar, then Connect.",
                    "Or unplug the cable and plug it back in.",
                )
            }
        }
    }

    private fun setSteps(vararg items: String) {
        steps.removeAllViews()
        items.forEachIndexed { i, s ->
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, dp(6), 0, dp(6))
            }
            val badge = text(14f, Color.WHITE, bold = true).apply {
                text = (i + 1).toString()
                gravity = Gravity.CENTER
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0xFF3B5BFF.toInt()) }
            }
            val label = text(16f, 0xFFE6E8EE.toInt()).apply {
                text = s
                autoLinkMask = Linkify.WEB_URLS
                movementMethod = LinkMovementMethod.getInstance()
                setLinkTextColor(0xFF8AB4FF.toInt())
            }
            row.addView(badge, LinearLayout.LayoutParams(dp(26), dp(26)).apply { marginEnd = dp(14) })
            row.addView(label, LinearLayout.LayoutParams(0, -2, 1f))
            steps.addView(row)
        }
        steps.visibility = if (items.isEmpty()) GONE else VISIBLE
    }

    private fun text(sp: Float, color: Int, bold: Boolean = false) = TextView(context).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(color)
        setLineSpacing(0f, 1.15f)
        if (bold) typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }

    private fun wrap() = LinearLayout.LayoutParams(-2, -2)
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
