package expo.modules.appblocker

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Build
import android.provider.Settings
import android.telecom.TelecomManager

/**
 * #563 allowlist mode: packages that must NEVER be shielded, so that "block everything except the
 * user's allowed apps" can't brick the phone or remove the OS-level emergency exit.
 *
 * The guardian doctrine (see domain overview) deliberately keeps force-stop / permission-revoke as
 * the genuine-emergency escape — that path runs through Settings — so Settings is treated as
 * essential too, alongside the launcher, system UI, the dialer/telephony/emergency path, the active
 * IME (keyboard), and the host app itself.
 *
 * Resolved dynamically where the platform exposes the current default (launcher / dialer / IME) and
 * augmented with the stable framework package names as a floor.
 */
object SystemEssentialApps {
  /** Includes built-in apps that have since received a Play/OEM update. */
  fun isSystemApp(flags: Int): Boolean =
    flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0

  /**
   * Package visibility hides some OEM internal surfaces. Do not shield a package unless we can
   * establish that it is a user app. This needs no QUERY_ALL_PACKAGES permission: launchable user
   * apps remain visible through the existing MAIN/LAUNCHER query. Unresolvable background/internal
   * packages are also exempt; this is a deliberate safety fallback, not a claim they are system apps.
   * Resolve on use so installation/updates do not leave a stale service-lifetime classification.
   */
  fun isSystemOrUnresolved(context: Context, packageName: String): Boolean = try {
    @Suppress("DEPRECATION")
    isSystemApp(context.packageManager.getApplicationInfo(packageName, 0).flags)
  } catch (_: PackageManager.NameNotFoundException) {
    true
  } catch (_: SecurityException) {
    true
  }

  /** Explicit block selections may include launcher-visible system apps, never essential roles. */
  fun canDirectlyBlock(context: Context, packageName: String): Boolean {
    if (packageName in resolve(context)) return false
    return try {
      val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(packageName)
      @Suppress("DEPRECATION")
      context.packageManager.queryIntentActivities(intent, 0).any {
        it.activityInfo?.applicationInfo?.enabled == true && it.activityInfo?.enabled == true
      }
    } catch (_: Exception) {
      false
    }
  }

  fun resolve(context: Context): Set<String> {
    val pkgs = HashSet<String>()
    val pm = context.packageManager

    // The host app itself — the shield landing must always be reachable.
    pkgs.add(context.packageName)

    // Stable framework packages.
    pkgs.add("android")
    pkgs.add("com.android.systemui")

    // Default launcher (home) — losing it means no home screen.
    resolveDefaultPackage(pm, Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))?.let { pkgs.add(it) }

    // Settings — reaching force-stop / permission-revoke (the emergency exit) must stay open.
    resolveDefaultPackage(pm, Intent(Settings.ACTION_SETTINGS))?.let { pkgs.add(it) }
    pkgs.add("com.android.settings")

    // Dialer / telephony / emergency-call path.
    try {
      val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
      telecom?.defaultDialerPackage?.let { pkgs.add(it) }
    } catch (_: Exception) {
    }
    resolveDefaultPackage(pm, Intent(Intent.ACTION_DIAL))?.let { pkgs.add(it) }
    pkgs.add("com.android.phone")
    pkgs.add("com.android.server.telecom")
    pkgs.add("com.android.dialer")
    pkgs.add("com.google.android.dialer")
    pkgs.add("com.android.emergency")

    // Active input method (keyboard) — the component's package.
    try {
      val ime = Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
      if (!ime.isNullOrEmpty()) {
        ComponentName.unflattenFromString(ime)?.packageName?.let { pkgs.add(it) }
      }
    } catch (_: Exception) {
    }

    return pkgs
  }

  private fun resolveDefaultPackage(pm: PackageManager, intent: Intent): String? = try {
    val flags = PackageManager.MATCH_DEFAULT_ONLY
    val resolved: ResolveInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      pm.resolveActivity(intent, PackageManager.ResolveInfoFlags.of(flags.toLong()))
    } else {
      @Suppress("DEPRECATION")
      pm.resolveActivity(intent, flags)
    }
    resolved?.activityInfo?.packageName
  } catch (_: Exception) {
    null
  }
}
