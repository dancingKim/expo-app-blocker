package expo.modules.appblocker

/** Pure validation/composition shared by persisted immediate and schedule policy. */
internal data class GuardianTargetPolicy(
  val allowEnabled: Boolean, val blockEnabled: Boolean,
  val allowed: Set<String>, val blocked: Set<String>
) {
  val enforceable: Boolean get() = (allowEnabled && allowed.isNotEmpty()) || (blockEnabled && blocked.isNotEmpty())
  fun blocks(pkg: String, alwaysAllowed: Boolean, directlyBlockable: Boolean): Boolean =
    (blockEnabled && pkg in blocked && directlyBlockable) ||
      (allowEnabled && allowed.isNotEmpty() && pkg !in allowed && !alwaysAllowed)
  companion object {
    fun packages(value: Any?): Set<String> {
      require(value is List<*> && value.all { it is String && it.isNotBlank() }) { "Invalid packages" }
      return value.filterIsInstance<String>().toSet()
    }
    fun parse(raw: Map<String, Any?>): GuardianTargetPolicy {
      require(raw["targetPolicy"] == "dual-v1" && raw["allowEnabled"] is Boolean && raw["blockEnabled"] is Boolean)
      return GuardianTargetPolicy(raw["allowEnabled"] == true, raw["blockEnabled"] == true,
        packages(raw["allowedItems"]), packages(raw["blockedItems"]))
    }
  }
}

internal data class GuardianKeyScope(val full: Boolean, val apps: Set<String>) {
  fun opens(pkg: String): Boolean = full || pkg in apps
  fun asMap(): Map<String, Any> = if (full) mapOf("policy" to "targets-v1", "kind" to "full") else
    mapOf("policy" to "targets-v1", "kind" to "targets", "apps" to apps.sorted(), "webDomains" to emptyList<String>())
  companion object {
    fun parse(raw: Map<String, Any?>): GuardianKeyScope {
      require(raw["policy"] == "targets-v1")
      if (raw["kind"] == "full") {
        require(!raw.containsKey("apps") && !raw.containsKey("webDomains"))
        return GuardianKeyScope(true, emptySet())
      }
      require(raw["kind"] == "targets" && raw["webDomains"] is List<*> && (raw["webDomains"] as List<*>).isEmpty())
      val packages = GuardianTargetPolicy.packages(raw["apps"])
      require(packages.isNotEmpty())
      return GuardianKeyScope(false, packages)
    }
  }
}
