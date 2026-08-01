/** @type {import('@bacons/apple-targets/app.plugin').ConfigFunction} */
module.exports = (config) => {
  const appGroup = config.ios?.entitlements?.["com.apple.security.application-groups"]?.[0]
    || "group.expo.app-blocker";

  return {
    type: "shield-action",
    name: "ShieldAction",
    deploymentTarget: "16.0",
    bundleIdentifier: ".ShieldAction",
    frameworks: ["ManagedSettings", "ManagedSettingsUI"],
    entitlements: {
      "com.apple.developer.family-controls": true,
      "com.apple.security.application-groups": [appGroup],
      // #583: the primary-button landing notification is posted from this
      // extension with interruptionLevel = .timeSensitive so it breaks through
      // while a shield is on-screen. The level only elevates when this
      // entitlement is present AND the App ID has the Time Sensitive
      // Notifications capability enabled; otherwise the system downgrades the
      // notification to .active (no build/runtime error).
      "com.apple.developer.usernotifications.time-sensitive": true,
    },
  };
};
