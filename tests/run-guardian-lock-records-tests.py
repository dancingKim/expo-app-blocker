#!/usr/bin/env python3
"""chapchu #988: run the schedule-lock boundary recorder (iOS + Android) against real storage boundaries; no device."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)

with tempfile.TemporaryDirectory(prefix='guardian-lock-records-') as output:
    output = Path(output)
    run(['xcrun', 'swiftc', 'ios/GuardianLockRecords.swift', 'tests/GuardianLockRecordsTests.swift', '-o', output / 'swift-tests'])
    run([output / 'swift-tests'])
    kotlin_sources = ['android/src/main/java/expo/modules/appblocker/' + name + '.kt' for name in ['GuardianTargetPolicy', 'GuardianConcurrentKeys', 'AppBlockerPrefs', 'ScheduleStore', 'ScheduleLockRecords']] + ['tests/AndroidPreferencesFixture.kt', 'tests/GuardianLockRecordsTests.kt']
    cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
    json_jar = next((cache / 'org.json/json/20180813').glob('*/*.jar'))
    compiler = shutil.which('kotlinc')
    main_class = 'expo.modules.appblocker.GuardianLockRecordsTestsKt'
    if compiler:
        run([compiler, *kotlin_sources, '-classpath', json_jar, '-include-runtime', '-d', output / 'kotlin-tests.jar'])
        run(['java', '-cp', str(output / 'kotlin-tests.jar') + os.pathsep + str(json_jar), main_class])
    else:
        # Reuse the already-installed Gradle Kotlin compiler (same as run-guardian-concurrent-tests.py).
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
        run([java, '-cp', str(output / 'kotlin') + os.pathsep + classpath, main_class])
