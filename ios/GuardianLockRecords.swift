import Foundation

/// chapchu #988: records the ACTUAL schedule-lock boundaries (the moment the gap shield went up and
/// the moment it came down) in the App Group, so the host app can upload them after the fact — the
/// schedule layer is locked/unlocked by the DeviceActivity monitor while the app is not running.
///
/// "Locked" here means the schedule commitment is in force (armed and outside every free window).
/// A live escape ticket does NOT end the record: tickets are recorded separately as door passes, so
/// the host subtracts them instead of the schedule session being split.
///
/// One source file, compiled into both the module and the DeviceActivityMonitor extension (the
/// config plugin copies it into the monitor target, like GuardianTokenRecovery.swift). Callers hold
/// the Guardian key lock, so monitor and app process never interleave a read-modify-write.
public enum GuardianLockRecords {
  public static let stateKey = "appBlocker.scheduleLockState.v1"
  public static let recordsKey = "appBlocker.scheduleLockRecords.v1"
  /// Bounded so a device that never syncs cannot grow the App Group without limit; oldest go first.
  public static let maxRecords = 200

  /// Feed the current schedule-lock state. Only a transition writes: unlocked→locked opens a record,
  /// locked→unlocked closes the newest open one. Repeated observations of the same state are no-ops.
  public static func observe(locked: Bool, at date: Date, defaults: UserDefaults) {
    let wasLocked = defaults.bool(forKey: stateKey)
    guard wasLocked != locked else { return }
    var records = read(defaults)
    let ms = (date.timeIntervalSince1970 * 1000).rounded()
    if locked {
      records.append(["id": UUID().uuidString.lowercased(), "startedAt": ms])
    } else if let index = records.lastIndex(where: { $0["endedAt"] == nil }) {
      let startedAt = (records[index]["startedAt"] as? Double) ?? ms
      records[index]["endedAt"] = max(ms, startedAt)
    }
    if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
    defaults.set(records, forKey: recordsKey)
    defaults.set(locked, forKey: stateKey)
    defaults.synchronize()
  }

  /// Every record not yet acknowledged, oldest first. An open record has no `endedAt`.
  public static func read(_ defaults: UserDefaults) -> [[String: Any]] {
    guard let raw = defaults.array(forKey: recordsKey) else { return [] }
    return raw.compactMap { item in
      guard let dict = item as? [String: Any], dict["id"] is String, dict["startedAt"] is Double else { return nil }
      return dict
    }
  }

  /// Drop CLOSED records the host has durably handed off. Open records are kept even when named:
  /// their end is still to come and must not be lost.
  public static func acknowledge(ids: [String], defaults: UserDefaults) {
    let drop = Set(ids)
    let records = read(defaults).filter { record in
      !(drop.contains(record["id"] as? String ?? "") && record["endedAt"] != nil)
    }
    defaults.set(records, forKey: recordsKey)
    defaults.synchronize()
  }
}
