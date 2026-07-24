// ──────────────────────────────────────────────────────────────────────────────
// Permission types
// ──────────────────────────────────────────────────────────────────────────────

export interface PermissionStatus {
  allGranted: boolean;
  details: AndroidPermissions | IOSPermissions;
}

export interface AndroidPermissions {
  platform: "android";
  overlay: boolean;
  usageStats: boolean;
  notifications: boolean;
}

export interface IOSPermissions {
  platform: "ios";
  authorized: boolean;
  status: "notDetermined" | "denied" | "approved";
}

// ──────────────────────────────────────────────────────────────────────────────
// App selection types
// ──────────────────────────────────────────────────────────────────────────────

export interface AndroidBlockableApp {
  packageName: string;
  name: string;
  iconBase64?: string | null;
}

export interface IOSBlockedItem {
  type: "app" | "category" | "webDomain";
  token: string;
  bundleIdentifier?: string;
  displayName?: string;
  categoryName?: string;
  domain?: string;
  iconBase64?: string;
}

// ──────────────────────────────────────────────────────────────────────────────
// iOS-specific types
// ──────────────────────────────────────────────────────────────────────────────

/**
 * #563: block semantics. `"block"` (default) shields the listed apps (denylist). `"allow"` keeps the
 * listed apps open and shields everything else (allowlist, via `ShieldSettings.ActivityCategoryPolicy
 * .all(except:)` on iOS / an inverted foreground check on Android). iOS never shields system-
 * essential apps; Android exempts launcher/system UI/dialer/IME/settings/host explicitly.
 */
export type BlockMode = "block" | "allow";

export interface IOSBlockConfiguration {
  /** #563: `"allow"` reinterprets the item set (in `allowedItems`) as the apps to KEEP open. */
  mode?: BlockMode;
  /** Denylist items (mode "block"). Optional in allow mode. */
  blockedItems?: IOSBlockedItem[];
  /** #563: allowlist — the apps to keep open (mode "allow"). Everything else is shielded. */
  allowedItems?: IOSBlockedItem[];
  isActive: boolean;
  schedule?: {
    intervalStart: number;
    intervalEnd: number;
    repeats: boolean;
    warningTime: number;
  };
  /**
   * Wall-clock auto-release time (epoch ms), symmetric with Android's `setBlockedApps`
   * `expiresAtMillis`. When set, a `DeviceActivity` fires at that instant and the monitor
   * extension lifts the shield **even if the app process is force-quit**. Omit (or `<= 0`) for a
   * block with no auto-release — then only an explicit `clearAllBlocks()` clears it. Do not rely on
   * a JS-side timer for release: it is lost when the OS kills the app.
   */
  expiresAtMillis?: number;
}

// ──────────────────────────────────────────────────────────────────────────────
// Schedule-window blocking (time-based, independent of immediate blocking)
// ──────────────────────────────────────────────────────────────────────────────

/**
 * A recurring local-time window during which the schedule's `blockedItems` are shielded.
 * Times are minutes since local midnight (0..1439). `endMinute < startMinute` means the
 * window crosses midnight (e.g. 23:00–07:00 → `startMinute: 1380, endMinute: 420`); for
 * the after-midnight portion the weekday gate follows the window's START day.
 */
export interface ScheduleWindow {
  /** Minutes since local midnight when the window opens (0..1439). */
  startMinute: number;
  /** Minutes since local midnight when the window closes (0..1439). */
  endMinute: number;
  /**
   * ISO weekdays the window applies to: 1 = Monday … 7 = Sunday. An empty array means the
   * window is never active on any day (weekdays must be filled explicitly) — identical on
   * iOS and Android.
   */
  weekdays: number[];
}

/**
 * iOS schedule configuration. Items use the same FamilyActivity tokens as
 * {@link IOSBlockConfiguration} (from the picker). #563: in `mode: "allow"` the kept apps ride in
 * `allowedItems` and an active window shields everything else; legacy `mode: "block"` shields
 * `blockedItems`.
 */
export interface IOSScheduleConfiguration {
  mode?: BlockMode;
  windows: ScheduleWindow[];
  blockedItems?: IOSBlockedItem[];
  allowedItems?: IOSBlockedItem[];
}

/**
 * Android schedule configuration. Items are package names, matching `setBlockedApps` /
 * `setAllowedApps`. #563: `allowedItems` (mode "allow") = kept packages; `blockedItems` (legacy) =
 * shielded packages.
 */
export interface AndroidScheduleConfiguration {
  mode?: BlockMode;
  windows: ScheduleWindow[];
  blockedItems?: string[];
  allowedItems?: string[];
}

/** Platform-tagged union passed to {@link setScheduleConfiguration}. */
export type ScheduleConfiguration =
  | IOSScheduleConfiguration
  | AndroidScheduleConfiguration;

export interface TemporaryUnlockResult {
  unlocked: boolean;
  expiresAt: number;
}

export interface RelockResult {
  locked: boolean;
}

/**
 * #572 escape ticket state. `untilMillis` is the wall-clock end (epoch ms); `remainingMs` is
 * milliseconds left (0 once expired). `active` is `remainingMs > 0`.
 */
export interface SuppressionState {
  active: boolean;
  untilMillis: number;
  remainingMs: number;
}

export interface FamilyActivityPickerSelectionEvent {
  /** Selected apps, categories, and web domains (pass to setBlockConfiguration) */
  items: IOSBlockedItem[];
  /** Number of individual apps selected */
  totalApps: number;
  /** Number of categories selected */
  totalCategories: number;
  /** Number of web domains selected */
  totalWebDomains: number;
  /** Base64 string - save and pass back as initialSelection to restore state */
  selectionData: string;
}

export interface FamilyActivityPickerViewProps {
  /** Base64-encoded FamilyActivitySelection to restore a previous selection */
  initialSelection?: string;
  /** Called each time the user toggles an app or category */
  onSelectionChange?: (event: FamilyActivityPickerSelectionEvent) => void;
  /** Forces the picker's color scheme: "light", "dark", or "system" (default) */
  theme?: "light" | "dark" | "system";
  /** Increment to programmatically clear the picker selection without remounting */
  clearTrigger?: number;
  /** Standard React Native style */
  style?: any;
}

/**
 * #602: emitted when the user taps a row's remove button. Identifies the removed row by both its
 * position (`index`) and its exact base64 token string (`token` — the same value passed in via
 * `items[].token`), so the JS owner can drop it from its registration SSOT. The native view does NOT
 * mutate anything itself — registration state lives in JS.
 */
export interface BlockedAppsRemoveEvent {
  /** Position of the removed row in the `items` array. */
  index: number;
  /** Base64 token string of the removed item (matches `items[].token`). */
  token: string;
  /** "app" | "category" */
  type: string;
}

export interface BlockedAppsNativeListProps {
  /** Array of blocked items from picker */
  items: IOSBlockedItem[];
  /** Base64-encoded FamilyActivitySelection for accurate rendering */
  selectionData?: string;
  /**
   * #602: render a per-row remove (minus) button. Default false keeps the plain labelled list.
   * Requires `onRemoveItem` to be useful.
   */
  removable?: boolean;
  /** #602: called when a row's remove button is tapped. See {@link BlockedAppsRemoveEvent}. */
  onRemoveItem?: (event: BlockedAppsRemoveEvent) => void;
  /** Standard React Native style */
  style?: any;
}

// ──────────────────────────────────────────────────────────────────────────────
// Plugin configuration types
// ──────────────────────────────────────────────────────────────────────────────

export interface ShieldConfig {
  /** Title shown on the shield. Default: "Hold on!" */
  title?: string;
  /** Subtitle shown on the shield. Use {appName} as placeholder. Default: "{appName} is blocked." */
  subtitle?: string;
  /** Primary button label. Default: "Earn Free Time" */
  primaryButtonLabel?: string;
  /** Secondary button label. Set to null to hide. Default: "Not now" */
  secondaryButtonLabel?: string | null;
  /** Primary button background color (hex). Default: "#fb6107" */
  primaryButtonColor?: string;
  /** Title text color (hex). Default: "#111111" */
  titleColor?: string;
  /** Subtitle text color (hex). Default: "#737373" */
  subtitleColor?: string;
  /**
   * Solid background color (hex). Optional.
   * When set, the shield uses this color instead of (or in addition to) a blur.
   * Example: "#f6f6f6" for light gray, "#1a1a2e" for dark.
   */
  backgroundColor?: string | null;
  /**
   * Background blur style. Default: "systemThickMaterial" (when no backgroundColor is set).
   * Set to null to disable blur (when using backgroundColor only).
   * Both can be combined - blur renders behind the color.
   *
   * Adaptive (light/dark auto):
   * - "systemUltraThinMaterial", "systemThinMaterial", "systemMaterial",
   *   "systemThickMaterial", "systemChromeMaterial"
   *
   * Light only:
   * - "systemUltraThinMaterialLight", "systemThinMaterialLight", "systemMaterialLight",
   *   "systemThickMaterialLight", "systemChromeMaterialLight"
   *
   * Dark only:
   * - "systemUltraThinMaterialDark", "systemThinMaterialDark", "systemMaterialDark",
   *   "systemThickMaterialDark", "systemChromeMaterialDark"
   *
   * Legacy: "regular", "prominent", "light", "dark", "extraLight"
   */
  backgroundBlurStyle?: string | null;
  /** Path to shield icon image (PNG). Optional. */
  icon?: string;
}

export interface AndroidConfig {
  /** Bold title rendered on the blocking overlay. Use {appName} as placeholder. Default: "App Blocked" */
  overlayTitle?: string;
  /** Body text shown under the overlay title. Use {appName} as placeholder. Default: "{appName} is blocked." */
  overlayText?: string;
  /** Hex color (e.g. "#f6f6f6") for the overlay background. Default: "#FFFFFF". */
  overlayBackgroundColor?: string;
  /** Hex color (e.g. "#111111") for the overlay title text. Default: "#111111". */
  overlayTitleColor?: string;
  /** Hex color (e.g. "#737373") for the overlay body text. Default: "#737373". */
  overlayTextColor?: string;
  /** Title font size in sp. Default: 24. */
  overlayTitleFontSize?: number;
  /** Body font size in sp. Default: 16. */
  overlayTextFontSize?: number;
  /** Render the title in bold. Default: true. */
  overlayTitleBold?: boolean;
  /** Inner padding (all sides) in dp. Default: 32. */
  overlayPadding?: number;
  /** Icon edge length in dp (square). Default: 96. Only used when an overlay icon is configured via the plugin. */
  overlayIconSize?: number;
  /** Vertical gap (dp) between the icon and the title. Default: 20. */
  overlayIconBottomMargin?: number;
  /** Vertical gap (dp) between the title and the body text. Default: 12. */
  overlayTitleBottomMargin?: number;
  /** Show an indeterminate circular spinner under the body text. Useful as a "launching…" cue during the brief gap between intercept and the deep-link landing. Default: false. */
  overlayShowSpinner?: boolean;
  /** Spinner edge length in dp (square). Default: 32. */
  overlaySpinnerSize?: number;
  /** Vertical gap (dp) between the body text and the spinner. Default: 24. */
  overlaySpinnerTopMargin?: number;
  /** Hex color (e.g. "#7cb518") tinting the spinner. Default: system primary. */
  overlaySpinnerColor?: string;
  /**
   * #596: label for the overlay's primary "go do it" button, which lands the user on the guarded
   * task. Default: "Go do it".
   */
  overlayPrimaryButtonText?: string;
  /**
   * #596: label for the overlay's secondary "escape" button, which routes to the reason screen
   * (guardian_escape) and issues a ticket. Pass "none" or an empty string to hide it (no escape
   * offered). Default: "I need it now".
   */
  overlaySecondaryButtonText?: string;
  /** Hex fill color of the overlay's primary button. Default: the overlay title color. */
  overlayPrimaryButtonColor?: string;
  /** Hex text color of the overlay's primary button. Default: white. */
  overlayPrimaryButtonTextColor?: string;
  /** Hex text color of the overlay's (transparent) secondary button. Default: the overlay body text color. */
  overlaySecondaryButtonTextColor?: string;
  /**
   * Title of the always-on foreground-service notification (the ongoing "guardian is running" one,
   * distinct from the per-block alert). Default: the baked-in Korean copy.
   */
  foregroundNotificationTitle?: string;
  /** Text of the always-on foreground-service notification. Default: the baked-in Korean copy. */
  foregroundNotificationText?: string;
  /** Notification title when app is blocked. Use {appName} as placeholder. Default: "App Blocked" */
  notificationTitle?: string;
  /** Notification text when app is blocked. Use {appName} as placeholder. */
  notificationText?: string;
}

export interface PluginConfig {
  ios?: {
    /** App Group identifier for shared data between app and extensions. Required. */
    appGroup: string;
    /** Shield overlay customization */
    shield?: ShieldConfig;
  };
  android?: AndroidConfig & {
    /**
     * URL scheme used for deep-linking back into your app when a blocked app is detected.
     * Defaults to your app's `scheme` from app.json, or the package name with dots replaced by hyphens.
     * Must match the scheme registered in your AndroidManifest intent-filter.
     */
    scheme?: string;
  };
}
