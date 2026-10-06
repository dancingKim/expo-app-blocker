#!/usr/bin/env python3
"""Compile unchanged production layer-reapply bodies with in-memory iOS boundary fixtures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'ios/ExpoAppBlockerModule.swift').read_text()

def method(name):
    start = source.index('  private func ' + name + '(')
    end = source.index('\n  }', start) + len('\n  }')
    return source[start:end].replace('private func', 'func', 1)

# The fixture executes the same methods called by scoped Start, not a copied policy algorithm.
start_body = source.split('AsyncFunction("suppressBlocksWithScope")', 1)[1].split('// Explicit user early close.', 1)[0]
assert 'try self.reapplyPersistedLayers()' in start_body
fixture = (root / 'tests/GuardianEscapeRuntimeTests.swift').read_text()
fixture = fixture.replace('// PRODUCTION_REAPPLY', method('reapplyPersistedLayers'))
fixture = fixture.replace('// PRODUCTION_SCHEDULE', method('reevaluateScheduleShieldThrowing'))
rollback = start_body.split('if persistedThisAttempt {', 1)[1].split('\n          }', 1)[0]
fixture = fixture.replace('// PRODUCTION_ROLLBACK', 'func rollback() {' + rollback + '\n  }')
with tempfile.TemporaryDirectory(prefix='guardian-escape-tests-') as directory:
    output = Path(directory)
    (output / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', str(root / 'ios/GuardianTargetPolicy.swift'), str(root / 'targets/ShieldAction/GuardianEscapeScope.swift'), str(output / 'Fixture.swift'), '-o', str(output / 'tests')], check=True)
    subprocess.run([str(output / 'tests')], check=True)
