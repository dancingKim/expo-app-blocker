const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
// Run the real exported component at its native-view boundary, without a device
// or resolving private Apple token names in JS.
const source = ts.transpileModule(fs.readFileSync(path.join(__dirname, '../src/index.ts'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
}).outputText;
const exported = {};
vm.runInNewContext(source, { exports: exported, require(name) {
  if (name === 'expo-modules-core') return { requireNativeModule: () => ({}), requireNativeViewManager: name => name };
  if (name === 'react-native') return { Platform: { OS: 'ios' } };
  if (name === 'react') return { createElement: (type, props) => ({ type, props }) };
  throw new Error(`Unexpected dependency: ${name}`);
} });
let removed;
const items = [{ type: 'app', token: 'opaque-app' }, { type: 'webDomain', token: 'opaque-web' }];
const result = exported.BlockedAppsNativeList({ items, removable: true, onRemoveItem: value => { removed = value; } });
assert.equal(result.type, 'ExpoAppBlocker');
assert.deepEqual(JSON.parse(JSON.stringify(result.props.tokens)), items);
assert.equal(result.props.style[0].height, exported.BLOCKED_APPS_ROW_HEIGHT * 2);
const webEvent = { index: 1, type: 'webDomain', token: 'opaque-web' };
result.props.onRemoveItem({ nativeEvent: webEvent });
assert.strictEqual(removed, webEvent);
const webOnly = exported.BlockedAppsNativeList({ items: items.slice(1), removable: true });
assert.equal(webOnly.props.tokens.length, 1);
assert.equal(webOnly.props.tokens[0].type, 'webDomain');
assert.equal(webOnly.props.style[0].height, exported.BLOCKED_APPS_ROW_HEIGHT);
console.log('Web native-list bridge: mixed and web-only rows preserve order, height and exact removal identity');
