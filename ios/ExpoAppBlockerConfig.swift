import Foundation

// This file provides the App Group identifier for the MODULE (app process). Unlike the extension
// templates under `targets/`, this file is part of the pod and is NOT placeholder-substituted by the
// config plugin, so it must resolve the group at runtime.

public struct ExpoAppBlockerConfig {
  public static var appGroupIdentifier: String {
    // #609 PRIMARY: the config plugin writes the app group into the app's Info.plist at prebuild
    // (`ExpoAppBlockerAppGroup`), derived from the SAME `ios.appGroup` option the extension templates'
    // `APP_GROUP_PLACEHOLDER` is substituted with. Reading it here keeps the module and the extensions
    // on ONE container.
    //
    // Before this, the getter only read a UserDefaults key that nothing in the package ever writes, so
    // it always fell through to `group.<bundleId>` — a non-entitled GHOST group distinct from the
    // extensions' real group. That silently broke every App-Group handoff (block/schedule config,
    // suppression window + expiry probe, escape-target candidate), and left the module's container-file
    // writes no-ops (containerURL is nil for a non-entitled group).
    if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "ExpoAppBlockerAppGroup") as? String,
       !fromPlist.isEmpty {
      return fromPlist
    }
    // Back-compat: an explicit UserDefaults override, if a host app sets one.
    if let appGroup = UserDefaults.standard.string(forKey: "expo.appblocker.appGroup"),
       !appGroup.isEmpty {
      return appGroup
    }
    // Last-resort fallback (the historical path). Only reached on a misconfigured build where the
    // plugin did not inject the Info.plist key — kept so the app still runs rather than crashing.
    return "group.\(Bundle.main.bundleIdentifier ?? "expo.app-blocker")"
  }
}
