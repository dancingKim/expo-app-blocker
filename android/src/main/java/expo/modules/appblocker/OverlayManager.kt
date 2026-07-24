package expo.modules.appblocker

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Build
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class OverlayManager(private val context: Context) {
  private val windowManager: WindowManager =
    context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

  private var overlayView: View? = null
  // #596: the app the overlay is currently blocking + which layer (schedule|gate), so the button
  // handlers can stamp the escape flag (#596) and the targeted-ticket package (#598) on tap.
  private var currentBlockedPackage: String? = null
  private var currentGuardType: String = GUARD_TYPE_GATE

  // #596: the overlay is an interactive block screen (iOS-shield parity), NOT the old auto-redirect
  // flash. It stays up with two buttons — "하러 가기" (land on the guarded task) and "지금 필요해"
  // (escape to the reason screen) — and only navigates when the user taps one. The normal
  // guarded-launch flag is still stamped at block time (enforceBlock), so "하러 가기" just lands;
  // the escape button swaps it for the escape flag.
  fun show(blockedPackageName: String? = null, guardType: String = GUARD_TYPE_GATE) {
    currentBlockedPackage = blockedPackageName
    currentGuardType = guardType

    if (overlayView != null) {
      Log.d(TAG, "Overlay already visible")
      return
    }

    val appName = blockedPackageName?.let { resolveAppName(it) } ?: ""
    val view = buildOverlayView(appName)
    try {
      windowManager.addView(view, buildLayoutParams())
      overlayView = view
      Log.d(TAG, "Overlay shown")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to add overlay view", e)
    }
  }

  // "하러 가기": land on the guarded task. The normal pending-guarded-launch flag was stamped at
  // block time, so the JS router drains it on resume and lands on the task.
  private fun onPrimaryTap() {
    navigateToApp()
    hide()
  }

  // "지금 필요해": swap the normal flag for the one-shot escape flag (routes to the reason screen)
  // and record the escaped package as the targeted-ticket candidate (#598), then land on the app.
  private fun onEscapeTap() {
    val now = System.currentTimeMillis()
    AppBlockerPrefs.recordPendingGuardedEscape(context, currentGuardType, now)
    currentBlockedPackage?.let { AppBlockerPrefs.recordEscapeTargetPackage(context, it, now) }
    navigateToApp()
    hide()
  }

  fun hide() {
    val view = overlayView ?: return
    try {
      windowManager.removeView(view)
      Log.d(TAG, "Overlay hidden")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to remove overlay view", e)
    }
    overlayView = null
  }

  private fun resolveAppName(packageName: String): String = try {
    val pm = context.packageManager
    val appInfo = pm.getApplicationInfo(packageName, 0)
    pm.getApplicationLabel(appInfo).toString()
  } catch (e: Exception) {
    packageName
  }

  // #535: the verified app-open on Android is the launcher intent (ACTION_MAIN + CATEGORY_LAUNCHER
  // + explicit component + NEW_TASK — exactly what an icon tap fires). A bare ACTION_VIEW deep-link
  // intent silently fails to foreground the app on some real devices, so we fire the launcher intent
  // and let routing ride the consumable guarded-launch flag (drained by the JS router #522 on
  // resume) rather than intent data.
  private fun navigateToApp() {
    val launchIntent = context.packageManager
      .getLaunchIntentForPackage(context.packageName)
      ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }

    if (launchIntent == null) {
      Log.w(TAG, "No launch intent for package ${context.packageName}")
      return
    }

    try {
      context.startActivity(launchIntent)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to launch app", e)
    }
  }

  private fun buildOverlayView(appName: String): View {
    val density = context.resources.displayMetrics.density
    fun dp(value: Float) = (value * density).toInt()

    val overlayTitle = AppBlockerPrefs.getOverlayTitle(context)
      .replace("{appName}", appName)
    val overlayText = AppBlockerPrefs.getOverlayText(context)
      .replace("{appName}", appName)
    val backgroundColor = parseColorOrDefault(
      AppBlockerPrefs.getOverlayBackgroundColor(context),
      Color.WHITE,
    )
    val titleColor = parseColorOrDefault(
      AppBlockerPrefs.getOverlayTitleColor(context),
      Color.parseColor("#111111"),
    )
    val textColor = parseColorOrDefault(
      AppBlockerPrefs.getOverlayTextColor(context),
      Color.parseColor("#737373"),
    )
    val titleFontSize = AppBlockerPrefs.getOverlayTitleFontSize(context)
    val textFontSize = AppBlockerPrefs.getOverlayTextFontSize(context)
    val titleBold = AppBlockerPrefs.getOverlayTitleBold(context)
    val padding = AppBlockerPrefs.getOverlayPadding(context)
    val iconSize = AppBlockerPrefs.getOverlayIconSize(context)
    val iconGap = AppBlockerPrefs.getOverlayIconBottomMargin(context)
    val titleGap = AppBlockerPrefs.getOverlayTitleBottomMargin(context)

    return LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      setBackgroundColor(backgroundColor)
      setPadding(dp(padding), dp(padding), dp(padding), dp(padding))

      // Optional brand icon — drawable named `expo_app_blocker_overlay_icon`
      // is copied by the config plugin from `pluginConfig.android.overlay.icon`.
      // Skip silently if missing so apps that don't ship one still get a clean overlay.
      val iconResId = context.resources.getIdentifier(
        "expo_app_blocker_overlay_icon",
        "drawable",
        context.packageName,
      )
      if (iconResId != 0) {
        addView(ImageView(context).apply {
          val bitmap = BitmapFactory.decodeResource(context.resources, iconResId)
          if (bitmap != null) setImageBitmap(bitmap)
          val size = dp(iconSize)
          layoutParams = LinearLayout.LayoutParams(size, size).apply {
            bottomMargin = dp(iconGap)
          }
        })
      }

      addView(TextView(context).apply {
        text = overlayTitle
        setTextColor(titleColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, titleFontSize)
        if (titleBold) setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        setPadding(0, 0, 0, dp(titleGap))
      })

      addView(TextView(context).apply {
        text = overlayText
        setTextColor(textColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, textFontSize)
        gravity = Gravity.CENTER
      })

      // #596 interactive buttons. Primary "하러 가기" lands on the task; secondary "지금 필요해"
      // escapes to the reason screen. Colors reuse the existing overlay knobs (title color = filled
      // primary bg, text color = plain secondary) so no new config is needed.
      addView(Button(context).apply {
        text = AppBlockerPrefs.getOverlayPrimaryButtonText(context)
        isAllCaps = false
        setTextColor(Color.WHITE)
        setBackgroundColor(titleColor)
        setPadding(dp(24f), dp(12f), dp(24f), dp(12f))
        layoutParams = LinearLayout.LayoutParams(
          LinearLayout.LayoutParams.WRAP_CONTENT,
          LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(24f) }
        setOnClickListener { onPrimaryTap() }
      })
      AppBlockerPrefs.getOverlaySecondaryButtonText(context)?.let { secondaryLabel ->
        addView(Button(context).apply {
          text = secondaryLabel
          isAllCaps = false
          setTextColor(textColor)
          setBackgroundColor(Color.TRANSPARENT)
          setPadding(dp(24f), dp(12f), dp(24f), dp(12f))
          layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
          ).apply { topMargin = dp(8f) }
          setOnClickListener { onEscapeTap() }
        })
      }

      // Optional indeterminate spinner — gives the user a visual cue that
      // the app is launching during the ~150–300ms gap between intercept
      // detection and the deep-link landing.
      if (AppBlockerPrefs.getOverlayShowSpinner(context)) {
        val spinnerSize = dp(AppBlockerPrefs.getOverlaySpinnerSize(context))
        val spinnerGap = dp(AppBlockerPrefs.getOverlaySpinnerTopMargin(context))
        addView(ProgressBar(context).apply {
          isIndeterminate = true
          val tint = AppBlockerPrefs.getOverlaySpinnerColor(context)
          if (tint != null) {
            val parsed = parseColorOrNull(tint)
            if (parsed != null) indeterminateTintList = android.content.res.ColorStateList.valueOf(parsed)
          }
          layoutParams = LinearLayout.LayoutParams(spinnerSize, spinnerSize).apply {
            topMargin = spinnerGap
          }
        })
      }
    }
  }

  private fun parseColorOrDefault(hex: String, fallback: Int): Int = try {
    Color.parseColor(hex)
  } catch (_: IllegalArgumentException) {
    fallback
  }

  private fun parseColorOrNull(hex: String): Int? = try {
    Color.parseColor(hex)
  } catch (_: IllegalArgumentException) {
    null
  }

  private fun buildLayoutParams(): WindowManager.LayoutParams {
    @Suppress("DEPRECATION")
    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
      WindowManager.LayoutParams.TYPE_PHONE
    }

    // #596: the overlay is now an INTERACTIVE block screen, so it must be focusable/touchable for the
    // buttons — drop FLAG_NOT_FOCUSABLE (which the old auto-redirect flash used). A focusable
    // full-screen overlay also captures the back button, so the user can't dismiss straight back into
    // the blocked app; the two buttons are the only way forward. FLAG_HARDWARE_ACCELERATED keeps the
    // button ripples/redraw smooth.
    return WindowManager.LayoutParams(
      WindowManager.LayoutParams.MATCH_PARENT,
      WindowManager.LayoutParams.MATCH_PARENT,
      type,
      WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
      PixelFormat.TRANSLUCENT
    ).apply {
      gravity = Gravity.TOP or Gravity.START
    }
  }

  companion object {
    private const val TAG = "ExpoAppBlocker"
    // #596: which lock layer the block came from, carried into the escape flag for the JS router.
    const val GUARD_TYPE_GATE = "gate"
    const val GUARD_TYPE_SCHEDULE = "schedule"
  }
}
