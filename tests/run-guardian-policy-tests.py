#!/usr/bin/env python3
"""Run pure production policy rules; no device, network, dependency install or app state."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)

with tempfile.TemporaryDirectory(prefix='guardian-policy-tests-') as output:
    output = Path(output)
    assert (ROOT / 'ios/GuardianTargetPolicy.swift').read_bytes() == (ROOT / 'targets/DeviceActivityMonitor/GuardianTargetPolicy.swift').read_bytes(), 'Host/monitor policy drift'
    run(['xcrun', 'swiftc', 'ios/GuardianTargetPolicy.swift', 'tests/GuardianTargetPolicyTests.swift', '-o', output / 'swift-tests'])
    run([output / 'swift-tests'])
    kotlin_sources = ['android/src/main/java/expo/modules/appblocker/' + name + '.kt' for name in ['GuardianTargetPolicy', 'AppBlockerPrefs', 'ScheduleStore']] + ['tests/AndroidPreferencesFixture.kt', 'tests/GuardianTargetPolicyTests.kt']
    json_cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1/org.json/json/20180813'
    json_jar = next(json_cache.glob('*/*.jar'))
    compiler = shutil.which('kotlinc')
    if compiler:
        run([compiler, *kotlin_sources, '-classpath', json_jar, '-include-runtime', '-d', output / 'kotlin-tests.jar'])
        run(['java', '-cp', str(output / 'kotlin-tests.jar') + os.pathsep + str(json_jar), 'expo.modules.appblocker.GuardianTargetPolicyTestsKt'])
    else:
        # Reuse exactly the already-installed Gradle compiler; this does not fetch anything.
        cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
        specs = [('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.1.20'),
                 ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.1.20'),
                 ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.1.20'),
                 ('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
                 ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
                 ('org.jetbrains.intellij.deps', 'trove4j', '1.0.20200330'),
                 ('org.jetbrains', 'annotations', '13.0')]
        jars = [next((cache / group / artifact / version).glob('*/*.jar')) for group, artifact, version in specs]
        classpath = os.pathsep.join(map(str, jars + [json_jar]))
        java = Path(os.environ['JAVA_HOME']) / 'bin/java' if 'JAVA_HOME' in os.environ else Path(shutil.which('java') or 'java')
        run([java, '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', classpath, '-d', output / 'kotlin', *kotlin_sources])
        run([java, '-cp', str(output / 'kotlin') + os.pathsep + classpath, 'expo.modules.appblocker.GuardianTargetPolicyTestsKt'])
