import Foundation

/// chapchu #988: the schedule-lock recorder keeps actual boundaries, ignores repeats, survives
/// acknowledgement of open records, and stays bounded.
@main struct GuardianLockRecordsTests {
  static func main() {
    let suite = "guardian-lock-records-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    GuardianLockRecords.observe(locked: false, at: t0, defaults: defaults)
    precondition(GuardianLockRecords.read(defaults).isEmpty, "unlocked→unlocked must not record")

    GuardianLockRecords.observe(locked: true, at: t0, defaults: defaults)
    GuardianLockRecords.observe(locked: true, at: t0.addingTimeInterval(60), defaults: defaults)
    var records = GuardianLockRecords.read(defaults)
    precondition(records.count == 1 && records[0]["endedAt"] == nil, "repeat lock observation must not open a second record")
    precondition(records[0]["startedAt"] as? Double == 1_700_000_000_000, "start = boundary instant")

    let id = records[0]["id"] as! String
    GuardianLockRecords.acknowledge(ids: [id], defaults: defaults)
    precondition(GuardianLockRecords.read(defaults).count == 1, "an open record must survive acknowledgement")

    GuardianLockRecords.observe(locked: false, at: t0.addingTimeInterval(3600), defaults: defaults)
    records = GuardianLockRecords.read(defaults)
    precondition(records[0]["endedAt"] as? Double == 1_700_003_600_000, "end = release instant")

    GuardianLockRecords.acknowledge(ids: [id], defaults: defaults)
    precondition(GuardianLockRecords.read(defaults).isEmpty, "a closed acknowledged record is dropped")

    for i in 0..<(GuardianLockRecords.maxRecords + 10) {
      GuardianLockRecords.observe(locked: i % 2 == 0, at: t0.addingTimeInterval(Double(i)), defaults: defaults)
    }
    precondition(GuardianLockRecords.read(defaults).count <= GuardianLockRecords.maxRecords, "records stay bounded")
    print("PASS #988: schedule-lock boundaries recorded once, open records kept, closed acknowledged dropped, bounded")
  }
}
