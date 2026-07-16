import {
  requireNativeModule,
  requireNativeViewManager,
  EventEmitter,
} from "expo-modules-core";
import { Platform } from "react-native";
import React from "react";

import type {
  PermissionStatus,
  AndroidPermissions,
  IOSPermissions,
  AndroidBlockableApp,
  AndroidConfig,
  IOSBlockedItem,
  IOSBlockConfiguration,
  ScheduleConfiguration,
  TemporaryUnlockResult,
  RelockResult,
  FamilyActivityPickerSelectionEvent,
  FamilyActivityPickerViewProps,
  BlockedAppsNativeListProps,
} from "./ExpoAppBlocker.types";

export type {
  PermissionStatus,
  AndroidPermissions,
  IOSPermissions,
  AndroidBlockableApp,
  IOSBlockedItem,
  IOSBlockConfiguration,
  ScheduleWindow,
  IOSScheduleConfiguration,
  AndroidScheduleConfiguration,
  ScheduleConfiguration,
  TemporaryUnlockResult,
  RelockResult,
  ShieldConfig,
  AndroidConfig,
  PluginConfig,
  FamilyActivityPickerSelectionEvent,
  FamilyActivityPickerViewProps,
  BlockedAppsNativeListProps,
} from "./ExpoAppBlocker.types";

// ──────────────────────────────────────────────────────────────────────────────
// Native module bridge
// ──────────────────────────────────────────────────────────────────────────────

const NativeModule = requireNativeModule("ExpoAppBlocker");

// ──────────────────────────────────────────────────────────────────────────────
// Permissions
// ──────────────────────────────────────────────────────────────────────────────

export async function getPermissionStatus(): Promise<PermissionStatus> {
  if (Platform.OS === "android") {
    const overlay = await NativeModule.checkOverlayPermission();
    const usageStats = await NativeModule.checkUsageStatsPermission();
    const notifications = await NativeModule.checkNotificationPermission();
    const details: AndroidPermissions = { platform: "android", overlay, usageStats, notifications };
    return { allGranted: overlay && usageStats && notifications, details };
  }

  if (Platform.OS === "ios") {
    const result = NativeModule.getAuthorizationStatus();
    const details: IOSPermissions = {
      platform: "ios",
      authorized: result.authorized,
      status: result.status,
    };
    return { allGranted: result.authorized, details };
  }

  throw new Error("Unsupported platform");
}

export async function requestPermissions(): Promise<PermissionStatus> {
  if (Platform.OS === "ios") {
    const result = await NativeModule.requestAuthorization();
    const details: IOSPermissions = {
      platform: "ios",
      authorized: result.authorized,
      status: result.status,
    };
    return { allGranted: result.authorized, details };
  }
  return getPermissionStatus();
}

// ──────────────────────────────────────────────────────────────────────────────
// Android-specific: permission settings
// ──────────────────────────────────────────────────────────────────────────────

export function openOverlaySettings(): void {
  if (Platform.OS !== "android") return;
  NativeModule.openOverlaySettings();
}

export function openUsageStatsSettings(): void {
  if (Platform.OS !== "android") return;
  NativeModule.openUsageStatsSettings();
}

// ──────────────────────────────────────────────────────────────────────────────
// Android-specific: app list and blocking
// ──────────────────────────────────────────────────────────────────────────────

export async function getInstalledApps(): Promise<AndroidBlockableApp[]> {
  if (Platform.OS !== "android") return [];
  return NativeModule.getInstalledApps();
}

/**
 * Replace the set of immediately-blocked apps (Android only; no-op elsewhere).
 *
 * Pass `options.expiresAtMillis` (epoch ms) to plant a native auto-release time: the
 * block lifts on its own at that instant **even if the app process is later killed**,
 * because the expiry lives in native prefs and a boundary alarm wakes the blocker service
 * to release it. Omit it (or pass `0`) for a block with no auto-release — then only an
 * explicit `setBlockedApps([])` / `relockApps()` clears it. Do **not** rely on a JS-side
 * `setTimeout` for release: RN timers are paused in the background and lost when the OS
 * kills the app, so a JS-only "unblock later" can silently never fire.
 *
 * iOS auto-expiry is not implemented here — the Focus lock uses a `DeviceActivity`
 * interval for its own timed release; `options` is ignored off Android.
 */
export function setBlockedApps(
  packageNames: string[],
  options?: { expiresAtMillis?: number }
): void {
  if (Platform.OS !== "android") return;
  NativeModule.setBlockedApps(packageNames);
  NativeModule.setBlockExpiryAndroid(options?.expiresAtMillis ?? 0);
}

export function getBlockedApps(): string[] {
  if (Platform.OS !== "android") return [];
  return NativeModule.getBlockedApps();
}

export function configureAndroid(config: AndroidConfig): void {
  if (Platform.OS !== "android") return;
  NativeModule.setAndroidConfig(config);
}

export function startMonitoring(): void {
  if (Platform.OS !== "android") return;
  NativeModule.startMonitoring();
}

export function stopMonitoring(): void {
  if (Platform.OS !== "android") return;
  NativeModule.stopMonitoring();
}

// ──────────────────────────────────────────────────────────────────────────────
// iOS-specific: Family Controls
// ──────────────────────────────────────────────────────────────────────────────

export async function presentFamilyActivityPicker(): Promise<IOSBlockedItem[]> {
  if (Platform.OS !== "ios") {
    throw new Error("Family Activity Picker is only available on iOS");
  }
  return NativeModule.presentFamilyActivityPicker();
}

export async function setBlockConfiguration(config: IOSBlockConfiguration): Promise<void> {
  if (Platform.OS !== "ios") {
    throw new Error("Block configuration is only available on iOS");
  }
  return NativeModule.setBlockConfiguration(config);
}

export function getBlockConfiguration(): IOSBlockConfiguration | null {
  if (Platform.OS !== "ios") return null;
  return NativeModule.getBlockConfiguration();
}

export function clearAllBlocks(): void {
  if (Platform.OS !== "ios") return;
  NativeModule.clearAllBlocks();
}

export function isAppBlocked(bundleIdentifier: string): boolean {
  if (Platform.OS !== "ios") return false;
  return NativeModule.isAppBlocked(bundleIdentifier);
}

// ──────────────────────────────────────────────────────────────────────────────
// Schedule-window blocking (both platforms — same JS API)
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Block `config.blockedItems` whenever any of `config.windows` is currently active.
 *
 * Fully independent of, and unioned with, the immediate blocking set via
 * `setBlockConfiguration` / `setBlockedApps`: with no schedule configured the immediate
 * behavior is unchanged, and clearing one never clears the other. Outside every window
 * the schedule blocks nothing.
 *
 * iOS: `blockedItems` are FamilyActivity items from the picker; enforced by a dedicated
 * `ManagedSettingsStore` driven by `DeviceActivity` window boundaries.
 * Android: `blockedItems` are package names; enforced by the foreground-service poll,
 * with exact alarms waking the service at window boundaries.
 */
export async function setScheduleConfiguration(config: ScheduleConfiguration): Promise<void> {
  if (Platform.OS !== "ios" && Platform.OS !== "android") return;
  return NativeModule.setScheduleConfiguration(config);
}

/** Remove the schedule configuration and stop schedule-based blocking. Immediate blocks are untouched. */
export function clearScheduleConfiguration(): void {
  if (Platform.OS !== "ios" && Platform.OS !== "android") return;
  NativeModule.clearScheduleConfiguration();
}

/** The current schedule configuration, or `null` if none is set. */
export function getScheduleConfiguration(): ScheduleConfiguration | null {
  if (Platform.OS !== "ios" && Platform.OS !== "android") return null;
  return NativeModule.getScheduleConfiguration() ?? null;
}

// ──────────────────────────────────────────────────────────────────────────────
// iOS-specific: Temporary unlock
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Suppress blocking for `durationMinutes`, then auto-resume.
 *
 * iOS removes the Family Controls shields; Android pauses the foreground-service
 * poll (the timer lives in the service, so it survives app backgrounding).
 * Calling again replaces any active unlock. Android rounds to a whole minute (min 1).
 */
export async function temporaryUnlock(durationMinutes: number = 15): Promise<TemporaryUnlockResult> {
  if (Platform.OS === "android") {
    NativeModule.temporaryUnlockAndroid(Math.max(1, Math.round(durationMinutes)));
    return { unlocked: true, expiresAt: Date.now() + durationMinutes * 60_000 };
  }
  return NativeModule.temporaryUnlock(durationMinutes);
}

/** iOS only — returns `false` on Android. On Android use `getRemainingUnlockTime() > 0`. */
export function isTemporarilyUnlocked(): boolean {
  if (Platform.OS !== "ios") return false;
  return NativeModule.isTemporarilyUnlocked();
}

/**
 * Seconds remaining on the active temporary unlock, or 0 if none.
 *
 * Platform divergence: on **Android** this ticks down live as the budget is spent
 * inside blocked apps (and freezes when you leave). On **iOS** Apple does not expose
 * live cumulative usage, so this returns the *granted* budget and stays flat until
 * the usage threshold re-applies the shield (then drops to 0). Don't rely on a
 * smooth iOS countdown.
 */
export function getRemainingUnlockTime(): number {
  if (Platform.OS === "android") return NativeModule.getRemainingUnlockTimeAndroid();
  return NativeModule.getRemainingUnlockTime();
}

/**
 * End an active temporary unlock immediately and re-block.
 *
 * iOS restores the shields; Android cancels the unlock and re-blocks the
 * foreground app on the next poll. Safe to call when nothing is unlocked.
 */
export async function relockApps(): Promise<RelockResult> {
  if (Platform.OS === "android") {
    NativeModule.relockAndroid();
    return { locked: true };
  }
  return NativeModule.relockApps();
}

export function checkAndClearPendingUnlock(): boolean {
  if (Platform.OS !== "ios") return false;
  return NativeModule.checkAndClearPendingUnlock();
}

/**
 * Android-only, last-resort recovery: forces a genuine process kill and
 * relaunch. Some native-layer failures (observed: an expo-sqlite connection
 * that NPEs on every operation, even a fresh `openDatabaseAsync` against a
 * freshly-rebuilt database file) can only be cleared by a real process
 * restart — closing/reopening the JS-side handle doesn't reach far enough.
 * Apps that run this module's `AppBlockerService` as a foreground service
 * can end up with an unusually long-lived Android process (the OS won't
 * kill it just because the Activity was "closed"), which surfaces this kind
 * of native-module degradation far more than it would in a normal app.
 *
 * Queues a relaunch (optionally straight back into `deepLink`, e.g. the
 * blocker intercept URL the caller was trying to reach), then calls
 * `Process.killProcess`. If that succeeds the process is gone before the
 * call would otherwise return. The native call itself can still reject
 * (e.g. a missing Android permission) — this is already the last-resort
 * path, so that failure is swallowed rather than left as an unhandled
 * rejection.
 *
 * No-op on iOS: that platform's process model doesn't exhibit this failure
 * mode, and there is no equivalent restart primitive.
 */
export function restartAppForRecovery(deepLink?: string): void {
  if (Platform.OS !== "android") return;
  NativeModule.restartApp(deepLink ?? null).catch((err: unknown) => {
    console.warn("[expo-app-blocker] restartAppForRecovery failed", err);
  });
}

/**
 * One OS-level block event: the blocker intercepted a blocked app (iOS
 * shield render / Android foreground block). `interceptedAt` is epoch
 * milliseconds; `appName` is the localized app name when the platform
 * can resolve it (null otherwise).
 */
export interface PendingIntercept {
  appName: string | null;
  interceptedAt: number;
}

/**
 * Drain and clear the queue of block events recorded natively since the
 * last call. Implemented on both platforms (iOS App Group queue / Android
 * SharedPreferences queue). The app calls this on foreground and persists
 * the results to power the "blocks" counter.
 */
export function drainPendingIntercepts(): PendingIntercept[] {
  if (Platform.OS !== "ios" && Platform.OS !== "android") return [];
  return NativeModule.drainPendingIntercepts() ?? [];
}

export function addPendingUnlockListener(
  handler: () => void
): { remove: () => void } | null {
  if (Platform.OS !== "ios") return null;
  const emitter = new EventEmitter(NativeModule);
  return (emitter as any).addListener("onPendingUnlockRequest", handler);
}

// ──────────────────────────────────────────────────────────────────────────────
// iOS Native View: renders blocked app tokens with real names and icons
// ──────────────────────────────────────────────────────────────────────────────

let NativeBlockedAppsView: any = null;
if (Platform.OS === "ios") {
  try {
    NativeBlockedAppsView = requireNativeViewManager("ExpoAppBlocker");
  } catch {}
}

export function BlockedAppsNativeList({
  items,
  selectionData,
  style,
}: BlockedAppsNativeListProps) {
  if (!NativeBlockedAppsView || Platform.OS !== "ios") return null;

  const tokens = items
    .filter((item) => (item.type as string) !== "summary")
    .map((item) => ({ token: item.token, type: item.type }));

  return React.createElement(NativeBlockedAppsView, {
    selectionData: selectionData || "",
    tokens,
    style: [{ minHeight: 50 }, style],
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// iOS Native View: inline FamilyActivityPicker (embedded in your UI)
// ──────────────────────────────────────────────────────────────────────────────

let NativePickerView: any = null;
if (Platform.OS === "ios") {
  try {
    NativePickerView = requireNativeViewManager("ExpoAppBlockerPicker");
  } catch {}
}

export function FamilyActivityPickerView({
  initialSelection,
  onSelectionChange,
  theme,
  style,
  clearTrigger,
}: FamilyActivityPickerViewProps) {
  if (!NativePickerView || Platform.OS !== "ios") return null;

  return React.createElement(NativePickerView, {
    initialSelection: initialSelection || "",
    theme: theme || "system",
    onSelectionChange: onSelectionChange
      ? (e: any) => {
          const ne = e.nativeEvent;
          const items = (ne.items ?? []).filter(
            (item: { type?: string }) =>
              item?.type === "app" ||
              item?.type === "category" ||
              item?.type === "webDomain",
          );
          onSelectionChange({ ...ne, items });
        }
      : undefined,
    ...(clearTrigger !== undefined ? { clearTrigger } : {}),
    style: [{ minHeight: 400 }, style],
  });
}
