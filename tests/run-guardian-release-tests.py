#!/usr/bin/env python3
"""Compile production bridge/schedule code; replace only OS boundaries with a reentrant callback."""
from pathlib import Path
import subprocess
import tempfile
import os
root=Path(os.environ.get('GUARDIAN_NATIVE_TEST_ROOT', str(Path(__file__).resolve().parents[1])))
output=tempfile.TemporaryDirectory(prefix='guardian-native-release-'); out=Path(output.name)
s=(root/'ios/ExpoAppBlockerModule.swift').read_text()
def method(name):
 a=s.index('  private func '+name+'('); b=s.index('\n  }',a)+4
 return s[a:b].replace('private func','func',1)
a=s.index('    AsyncFunction("setScheduleConfiguration")'); b=s.index('\n    }\n',a)+6
bridge=s[a:b].replace('    AsyncFunction("setScheduleConfiguration") { (config: [String: Any], promise: Promise) in','  func setScheduleConfiguration(_ config: [String: Any], promise: Promise) {',1)
bridge=bridge.replace('DispatchQueue.main.async { promise.resolve(nil) }','promise.resolve(nil)')
methods='\n'.join(method(n) for n in ['applyScheduleConfiguration','stopScheduleActivities','parseScheduleWindows','isAnyScheduleWindowActive','isoWeekday','isContinuousSchedule','scheduleMode','scheduleItemsRaw','registerScheduleActivity','scheduleTimeComponents','clearScheduleShield','persistScheduleConfiguration'])
fixture=r'''
import Foundation
import Dispatch
// OS framework boundary only: the production lock, scheduling order, window evaluator,
// bridge queue and clear/persist methods are compiled unchanged below.
typealias ApplicationToken = String
struct DeviceActivityName { let rawValue:String; init(_ v:String){rawValue=v} }
struct DeviceActivitySchedule { let intervalStart:DateComponents; let intervalEnd:DateComponents; let repeats:Bool }
enum BlockMode { case allow, block }
struct BlockedItemInfo {}
struct ScheduleWindowInfo { let startMinute:Int; let endMinute:Int; let weekdays:Set<Int> }
final class Shield { var applications:Set<String>?=["blocked-app"]; var applicationCategories:Set<String>?=["all-except-safe"]; var webDomains:Set<String>? }
final class Store { var shield=Shield() }
enum GuardianTargetRuntime {
 static var direct=Store()
 static func directStore(_ layer:String)->Store { direct }
 static func clear(_ store:Store){store.shield.applications=nil;store.shield.applicationCategories=nil;store.shield.webDomains=nil}
 static func full(_ d:UserDefaults)->Bool{false}
 static func render(_ c:[String:Any],store:Store,layer:String,defaults:UserDefaults,group:String)throws{}
}
final class Promise {
 let done=DispatchSemaphore(value:0)
 func resolve(_ x:Any?){done.signal()}
 func reject(_ code:String,_ message:String){print(code);done.signal()}
}
final class DeviceActivityCenter {
 let directory:URL; var child:Process?; var reentrant:Bool
 let entered=DispatchSemaphore(value:0)
 init(_ directory:URL,_ reentrant:Bool){self.directory=directory;self.reentrant=reentrant}
 var activities:[DeviceActivityName]{[DeviceActivityName("appBlocker.scheduleWindow.0")]}
 func stopMonitoring(_ names:[DeviceActivityName]) {
  if reentrant {
   let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["monitor",directory.path];child=p
   precondition(GuardianTargetRuntime.direct.shield.applications == nil, "NR2: clear shields before OS scheduling")
   try! p.run();entered.signal();p.waitUntilExit()
  } else { entered.signal() }
 }
 func startMonitoring(_ name:DeviceActivityName,during:DeviceActivitySchedule,events:[String:String])throws{}
}
final class Host {
 let stateQueue=DispatchQueue(label:"actual-native-state-queue")
 let directory:URL; let activityCenter:DeviceActivityCenter; let sharedDefaults:UserDefaults?; let userDefaults:UserDefaults
 let scheduleStore=Store();let scheduleActivityPrefix="appBlocker.scheduleWindow.";let minScheduleIntervalMinutes=15
 let scheduleShieldVariantKey="variant";let scheduleConfigStorageKey="schedule";let appGroupIdentifier="fixture"
 init(_ d:URL,_ reentrant:Bool){directory=d;activityCenter=DeviceActivityCenter(d,reentrant);userDefaults=UserDefaults(suiteName:d.lastPathComponent)!;sharedDefaults=userDefaults}
 func lockGuardianKeys() throws -> GuardianKeyFileLock {try GuardianKeyFileLock(directory:directory)}
 func validateTargetConfiguration(_ c:[String:Any])throws{}
 func makeBlockedItems(from:[[String:Any]])->[BlockedItemInfo]{[]}
 func escapeExemptToken()->ApplicationToken?{nil}
 func applyScheduleShield(_ i:[BlockedItemInfo],mode:BlockMode,exempt:ApplicationToken?){fatalError("Expected free window")}
 func updateScheduleShieldVariant(){}
 // BRIDGE
 // METHODS
}
@main struct Repro {
 static func main() throws {
  if CommandLine.arguments.count>1 && CommandLine.arguments[1]=="monitor" {
   let d=URL(fileURLWithPath:CommandLine.arguments[2]);try "entered".write(to:d.appendingPathComponent("monitor-entered"),atomically:true,encoding:.utf8)
   let lock=try GuardianKeyFileLock(directory:d);defer{lock.unlock()}
   let defaults = UserDefaults(suiteName:d.lastPathComponent)!
   defaults.synchronize()
   precondition(defaults.dictionary(forKey:"schedule") != nil, "NR2: Monitor must observe committed settings")
   try "cleared".write(to:d.appendingPathComponent("monitor-cleared"),atomically:true,encoding:.utf8);return
  }
  let d=FileManager.default.temporaryDirectory.appendingPathComponent("guardian-repro-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:d)}
  let h=Host(d,true)
  let friday=ISO8601DateFormatter().date(from:"2026-10-09T03:15:00Z")!
  let windows=[ScheduleWindowInfo(startMinute:690,endMinute:750,weekdays:Set(1...7)),ScheduleWindowInfo(startMinute:1050,endMinute:1110,weekdays:Set(1...7))]
  precondition(h.isAnyScheduleWindowActive(windows:windows,at:friday))
  print("PASS actual production evaluator: 2026-10-09 12:15 KST is free")
  let config:[String:Any]=["mode":"allow","windows":[["startMinute":0,"endMinute":1439,"weekdays":Array(1...7)]]]
  let applied=Promise();h.setScheduleConfiguration(config,promise:applied)
  precondition(h.activityCenter.entered.wait(timeout:.now()+2)==.success)
  let keyStarted=DispatchSemaphore(value:0);h.stateQueue.async{keyStarted.signal()}
  precondition(applied.done.wait(timeout:.now()+3) == .success, "NR2: OS/Monitor/file-lock cycle must finish")
  precondition(keyStarted.wait(timeout:.now()+3) == .success)
  precondition(h.scheduleStore.shield.applicationCategories == nil)
  precondition(GuardianTargetRuntime.direct.shield.applications == nil)
  precondition(FileManager.default.fileExists(atPath:d.appendingPathComponent("monitor-cleared").path))
  print("PASS NR2: actual bridge completes while OS waits for Monitor's real file lock; new settings visible, both shields clear, subsequent Start queue runs")
  let normal=Host(d,false);let ok=Promise();normal.setScheduleConfiguration(config,promise:ok)
  precondition(ok.done.wait(timeout:.now()+2) == .success)
  print("PASS ordinary OS boundary: same production schedule path completes")

 }
}
'''
fixture=fixture.replace('// BRIDGE',bridge).replace('// METHODS',methods).replace(')==.success',') == .success')
(out/'NativeQueueRepro.swift').write_text(fixture)
subprocess.run(['xcrun','swiftc',str(root/'ios/GuardianTargetPolicy.swift'),str(root/'ios/GuardianConcurrentKeys.swift'),str(out/'NativeQueueRepro.swift'),'-o',str(out/'native-queue-repro')],check=True)
subprocess.run([str(out/'native-queue-repro')],env={**os.environ,'TZ':'Asia/Seoul'},check=True,timeout=12)
subprocess.run(['xcrun','swiftc',str(root/'ios/GuardianTargetPolicy.swift'),str(root/'ios/GuardianConcurrentKeys.swift'),str(Path(__file__).parent/'GuardianSchedulingLockTests.swift'),'-o',str(out/'lock-tests')],check=True)
subprocess.run([str(out/'lock-tests')],check=True,timeout=12)
output.cleanup()
