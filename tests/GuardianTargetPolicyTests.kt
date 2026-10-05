package expo.modules.appblocker

fun main() {
  fun policy(allow: List<String>, block: List<String>) = GuardianTargetPolicy.parse(mapOf(
    "targetPolicy" to "dual-v1", "allowEnabled" to true, "blockEnabled" to true,
    "allowedItems" to allow, "blockedItems" to block))
  val dual = policy(listOf("overlap"), listOf("overlap", "built-in"))
  check(dual.blocks("overlap", false, true))
  check(dual.blocks("built-in", true, true))
  check(!dual.blocks("built-in", true, false))
  check(!dual.blocks("essential", true, false))
  val empty = policy(emptyList(), listOf("b"))
  check(empty.blocks("b", false, true) && !empty.blocks("other", false, true))
  val many = policy((0..100).map { "app.$it" }, (0..100).map { "blocked.$it" })
  check(many.allowed.size == 101 && many.blocked.size == 101)
  val scope = GuardianKeyScope.parse(mapOf("policy" to "targets-v1", "kind" to "targets", "apps" to listOf("a", "b"), "webDomains" to emptyList<String>()))
  check(scope.opens("a") && scope.opens("b") && !scope.opens("c"))
  check(GuardianKeyScope.parse(scope.asMap()) == scope)
  check(GuardianKeyScope.parse(mapOf("policy" to "targets-v1", "kind" to "full")).opens("any"))
  for (raw in listOf(emptyMap(), mapOf("policy" to "targets-v1", "kind" to "targets", "apps" to listOf("a"), "webDomains" to listOf("site")), mapOf("policy" to "targets-v1", "kind" to "targets", "apps" to emptyList<String>(), "webDomains" to emptyList<String>()))) {
    check(runCatching { GuardianKeyScope.parse(raw) }.isFailure)
  }
  val context = android.content.Context()
  val config = mapOf("targetPolicy" to "dual-v1", "allowEnabled" to true, "blockEnabled" to true,
    "allowedItems" to listOf("safe"), "blockedItems" to listOf("b"), "isActive" to true,
    "policy" to "continuous-v1", "windows" to emptyList<Map<String, Any>>())
  AppBlockerPrefs.setTargetConfiguration(context, config)
  check(AppBlockerPrefs.getTargetPolicy(context)?.blocked == setOf("b"))
  AppBlockerPrefs.setTargetConfiguration(context, config + ("allowedItems" to emptyList<String>()))
  check(AppBlockerPrefs.getTargetPolicy(context)?.blocked == setOf("b"))
  context.preferences.failNextCommit = true
  check(runCatching { AppBlockerPrefs.setTargetConfiguration(context, config + ("blockedItems" to listOf("wrong"))) }.isFailure)
  check(AppBlockerPrefs.getTargetPolicy(context)?.blocked == setOf("b"))
  ScheduleStore.setConfiguration(context, config)
  check(ScheduleStore.isContinuous(context) && ScheduleStore.getTargetPolicy(context)?.enforceable == true)
  val stored = ScheduleStore.getConfigurationMap(context)!!
  ScheduleStore.setConfiguration(context, stored)
  check(ScheduleStore.getTargetPolicy(context)?.blocked == setOf("b") && ScheduleStore.isContinuous(context))
  val windowed = config + ("windows" to listOf(mapOf("startMinute" to 300, "endMinute" to 400, "weekdays" to listOf(1,2,3))))
  ScheduleStore.setConfiguration(context, windowed)
  ScheduleStore.setConfiguration(context, ScheduleStore.getConfigurationMap(context)!!)
  check(ScheduleStore.getWindows(context).single() == ScheduleStore.Window(300, 400, setOf(1,2,3)))
  ScheduleStore.setConfiguration(context, config - "policy")
  check(!ScheduleStore.isContinuous(context))
  ScheduleStore.setConfiguration(context, config + ("windows" to listOf("malformed")))
  check(!ScheduleStore.isContinuous(context))
  AppBlockerPrefs.setScopedSuppression(context, System.currentTimeMillis() + 60000L, scope)
  check(AppBlockerPrefs.isSuppressed(context) && AppBlockerPrefs.getKeyScope(context) == scope)
  AppBlockerPrefs.clearImmediateBlock(context)
  check(AppBlockerPrefs.getTargetPolicy(context) == null && AppBlockerPrefs.getKeyScope(context) == scope)
  AppBlockerPrefs.clearSuppression(context)
  context.preferences.failNextCommit = true
  check(runCatching { AppBlockerPrefs.setScopedSuppression(context, System.currentTimeMillis() + 60000L, scope) }.isFailure)
  check(!AppBlockerPrefs.isSuppressed(context))
  ScheduleStore.clear(context)
  check(ScheduleStore.getTargetPolicy(context) == null && !ScheduleStore.isContinuous(context))
  println("Kotlin target policy: 21 scenarios passed")
}
