package expo.modules.appblocker
import android.content.Context

/** chapchu #988: Android twin of GuardianLockRecordsTests.swift. */
fun main() {
  val context = Context()
  val t0 = 1_700_000_000_000L
  ScheduleLockRecords.observe(context, false, t0)
  check(ScheduleLockRecords.read(context).isEmpty()) // unlocked→unlocked records nothing
  ScheduleLockRecords.observe(context, true, t0)
  ScheduleLockRecords.observe(context, true, t0 + 60_000)
  var records = ScheduleLockRecords.read(context)
  check(records.size == 1 && records[0]["endedAt"] == null && records[0]["startedAt"] == t0.toDouble())
  val id = records[0]["id"] as String
  ScheduleLockRecords.acknowledge(context, listOf(id))
  check(ScheduleLockRecords.read(context).size == 1) // open record survives acknowledgement
  ScheduleLockRecords.observe(context, false, t0 + 3_600_000)
  records = ScheduleLockRecords.read(context)
  check(records[0]["endedAt"] == (t0 + 3_600_000).toDouble())
  ScheduleLockRecords.acknowledge(context, listOf(id))
  check(ScheduleLockRecords.read(context).isEmpty())
  for (i in 0 until ScheduleLockRecords.MAX_RECORDS * 2 + 20) ScheduleLockRecords.observe(context, i % 2 == 0, t0 + i)
  check(ScheduleLockRecords.read(context).size <= ScheduleLockRecords.MAX_RECORDS)
  // No schedule configured → commitment not in force (an empty schedule never becomes a lock).
  check(!ScheduleLockRecords.commitmentInForce(context, t0))
  println("Kotlin #988 schedule-lock records: boundaries once, open kept, closed acknowledged dropped, bounded passed")
}
