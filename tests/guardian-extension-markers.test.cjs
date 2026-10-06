const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const plist = require('@expo/plist').default;
const plugin = require('../plugin/src');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'guardian-extension-markers-'));
try {
  const action = path.join(root, 'targets/ShieldAction');
  fs.mkdirSync(action, { recursive: true });
  fs.writeFileSync(path.join(action, 'Info.plist'), plist.build({
    AppOwnedSetting: 'preserved',
    NSExtension: { NSExtensionPrincipalClass: '$(PRODUCT_MODULE_NAME).ShieldActionExtension' },
  }));
  function configure() {
    plugin({ name: 'Guardian Fixture', slug: 'guardian-fixture',
      _internal: { projectRoot: root }, ios: { bundleIdentifier: 'fixture.guardian' },
    }, { ios: { registerAppleTargets: false } });
  }
  configure(); configure();
  for (const name of ['ShieldAction', 'DeviceActivityMonitor']) {
    const info = plist.parse(fs.readFileSync(path.join(root, 'targets', name, 'Info.plist'), 'utf8'));
    assert.equal(info.ExpoGuardianAllowLayerScopePolicy, 'allow-layer-v1');
    assert.ok(info.NSExtension.NSExtensionPrincipalClass.endsWith(`${name}Extension`));
  }
  const info = plist.parse(fs.readFileSync(path.join(action, 'Info.plist'), 'utf8'));
  assert.equal(info.AppOwnedSetting, 'preserved');
  assert.ok(fs.existsSync(path.join(action, 'GuardianEscapeScope.swift')));
  assert.equal(fs.readFileSync(path.join(root, 'targets/DeviceActivityMonitor/GuardianTargetPolicy.swift'), 'utf8'),
    fs.readFileSync(path.join(__dirname, '../ios/GuardianTargetPolicy.swift'), 'utf8'));
  console.log('Extension markers: existing plist preserved, both capabilities and policy sources packaged');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
