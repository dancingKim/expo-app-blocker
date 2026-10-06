import Foundation

@main struct GuardianConcurrentKeysTests {
  static func main() throws {
    if CommandLine.arguments.count > 1 {
      let directory = URL(fileURLWithPath: CommandLine.arguments[1])
      for _ in 0..<40 {
        let lock = try GuardianKeyFileLock(directory: directory)
        let file = directory.appendingPathComponent("counter")
        let value = Int(try String(contentsOf: file, encoding: .utf8))!
        try String(value + 1).write(to: file, atomically: true, encoding: .utf8)
        lock.unlock()
      }
      return
    }
    let now = 1000.0
    func key(_ id: String, _ end: Double, apps: [String] = [], web: [String] = [], kind: String = "targets") throws -> GuardianScopedKey {
      let scope: [String: Any] = kind == "allow-layer" ? ["policy":"targets-v2", "kind":kind]
        : kind == "full" ? ["policy":"targets-v1", "kind":kind]
        : ["policy":"targets-v1", "kind":kind, "apps":apps, "webDomains":web]
      return try GuardianScopedKey(["id":id, "scope":scope, "startedAtMillis":now, "untilMillis":end])
    }
    let a = try key("a", 2000, apps: ["a"]), b = try key("b", 3000, apps: ["b"], web: ["site"])
    let empty = try GuardianKeyRegistry()
    let both = try empty.adding(a, now: now).adding(b, now: now)
    precondition(both.live(1000).count == 2 && both.live(2000).map(\.id) == ["b"] && both.live(3000).isEmpty)
    precondition((both.snapshot(now)["nextExpiryMillis"] as? Double) == 2000)
    let retry = try both.adding(a, now: 1500); precondition(retry.keys == both.keys)
    do { _ = try both.adding(key("a", 2500, apps:["a"]), now: now); fatalError("Conflict accepted") } catch GuardianKeyFailure.conflict {}
    let closed = both.closing("a")
    precondition(closed.live(1100).map(\.id) == ["b"])
    do { _ = try closed.adding(a, now: 1100); fatalError("Closed key resurrected") } catch GuardianKeyFailure.closed {}
    let restored = try GuardianKeyRegistry(closed.keys.map(\.persisted)); precondition(restored.keys == closed.keys)
    precondition(closed.closing("missing").keys == closed.keys)
    let allowed = Set((0..<49).map { "safe\($0)" })
    try empty.adding(a, now: now).validateCapacity(allowed: allowed, decode: { $0 }, now: now)
    do { try both.validateCapacity(allowed: allowed, decode: { $0 }, now: now); fatalError("51 exceptions accepted") } catch GuardianKeyFailure.invalid {}
    let allow = try key("allow", 1500, kind:"allow-layer")
    let masked = try both.adding(allow, now: now)
    do { try masked.validateCapacity(allowed: allowed, decode: { $0 }, now: now); fatalError("Future expiry overflow accepted") } catch GuardianKeyFailure.invalid {}
    let covering = try both.adding(key("allow", 4000, kind:"allow-layer"), now:now)
    do { try covering.validateCapacity(allowed:allowed, decode:{$0}, now:now); fatalError("Early-close overflow accepted") } catch GuardianKeyFailure.invalid {}
    try both.validateCapacity(allowed:Set<String>(), decode:{$0}, now:now)
    // Changing configuration from 48 allowed to 49 is rejected with existing keys intact.
    try both.validateCapacity(allowed:Set(allowed.prefix(48)), decode:{$0}, now:now)
    precondition(both.live(now).count == 2)
    let overlapping = try empty.adding(a, now:now).adding(key("same-app", 4000, apps:["a"]), now:now)
    try overlapping.validateCapacity(allowed:allowed, decode:{$0}, now:now)
    let website = try empty.adding(key("web", 2000, web:["site"]), now:now)
    try website.validateCapacity(allowed:allowed, decode:{$0}, now:now)
    let roundtrip = try GuardianKeyRegistry(masked.keys.map(\.persisted))
    precondition(roundtrip.live(now).count == 3)
    // Process A and Monitor-equivalent B use the actual production file lock.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    try "0".write(to:directory.appendingPathComponent("counter"), atomically:true, encoding:.utf8)
    let nested = try GuardianKeyFileLock(directory: directory)
    let inner = try GuardianKeyFileLock(directory: directory); inner.unlock(); nested.unlock()
    let children = (0..<2).map { _ -> Process in
      let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); process.arguments = [directory.path]; return process
    }
    for child in children { try child.run() }; for child in children { child.waitUntilExit(); precondition(child.terminationStatus == 0) }
    let counter = try String(contentsOf:directory.appendingPathComponent("counter"), encoding:.utf8); precondition(counter == "80")
    print("Swift concurrent registry: independent expiry, tombstones, replay, future capacity, persistence, cross-process lock passed")
  }
}
