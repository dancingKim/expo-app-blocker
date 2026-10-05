package android.content

/** In-memory boundary fixture; failed commit models Android's already-updated memory. */
class Context {
  val preferences = SharedPreferences()
  fun getSharedPreferences(name: String, mode: Int) = preferences
  companion object { const val MODE_PRIVATE = 0 }
}
class SharedPreferences {
  private val values = mutableMapOf<String, Any?>()
  var failNextCommit = false
  fun contains(key: String) = values.containsKey(key)
  fun getString(key: String, fallback: String?): String? = values[key] as? String ?: fallback
  @Suppress("UNCHECKED_CAST")
  fun getStringSet(key: String, fallback: Set<String>?): Set<String>? = values[key] as? Set<String> ?: fallback
  fun getLong(key: String, fallback: Long): Long = values[key] as? Long ?: fallback
  fun getBoolean(key: String, fallback: Boolean): Boolean = values[key] as? Boolean ?: fallback
  fun getFloat(key: String, fallback: Float): Float = values[key] as? Float ?: fallback
  fun edit() = Editor()
  inner class Editor {
    private val changes = mutableMapOf<String, Any?>()
    fun putString(key: String, value: String?) = apply { changes[key] = value }
    fun putStringSet(key: String, value: Set<String>?) = apply { changes[key] = value }
    fun putLong(key: String, value: Long) = apply { changes[key] = value }
    fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }
    fun putFloat(key: String, value: Float) = apply { changes[key] = value }
    fun remove(key: String) = apply { changes[key] = null }
    fun commit(): Boolean {
      for ((key, value) in changes) if (value == null) values.remove(key) else values[key] = value
      val result = !failNextCommit
      failNextCommit = false
      return result
    }
    fun apply() { commit() }
  }
}
