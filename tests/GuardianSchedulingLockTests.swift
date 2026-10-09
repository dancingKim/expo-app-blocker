import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct GuardianSchedulingLockTests {
  enum Failure: Error { case os }
  static func probe(_ directory: URL) throws -> Int32 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["probe", directory.path]
    try child.run(); child.waitUntilExit()
    return child.terminationStatus
  }
  static func main() throws {
    if CommandLine.arguments.count > 1 {
      let fd = open(CommandLine.arguments[2] + "/guardian-keys.lock", O_RDWR)
      guard fd >= 0 else { exit(2) }
      defer { close(fd) }
      exit(flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : 47)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outer = try GuardianKeyFileLock(directory: directory)
    let inner = try GuardianKeyFileLock(directory: directory)
    precondition((try! probe(directory)) == 47)
    do {
      try GuardianKeyFileLock.withDeviceActivity {
        precondition((try! probe(directory)) == 0)
        throw Failure.os
      }
    } catch Failure.os {}
    precondition((try! probe(directory)) == 47, "OS failure must reacquire the file lock")
    inner.unlock()
    precondition((try! probe(directory)) == 47, "Nested unlock must preserve outer ownership")
    GuardianKeyFileLock.withDeviceActivity { precondition((try! probe(directory)) == 0) }
    outer.unlock()
    precondition((try! probe(directory)) == 0)
    print("PASS NR2: real cross-process lock released only during OS calls, reacquired on throw, recursive ownership preserved")
  }
}
