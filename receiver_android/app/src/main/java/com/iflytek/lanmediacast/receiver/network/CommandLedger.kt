package com.iflytek.lanmediacast.receiver.network

import java.util.LinkedHashMap

class CommandLedger(
    private val maxEntries: Int = 256,
    private val retentionMillis: Long = 60_000,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    sealed interface Decision {
        data object Execute : Decision
        data class Cached(val response: String) : Decision
        data class Reject(val code: String) : Decision
    }

    private data class Entry(val id: String, val response: String, val storedAt: Long)

    private val entries = LinkedHashMap<Long, Entry>()
    private var highestSequence = 0L

    @Synchronized
    fun inspect(sequence: Long, id: String): Decision {
        evictExpired()
        val existing = entries[sequence]
        if (existing != null) {
            return if (existing.id == id) Decision.Cached(existing.response) else Decision.Reject("sequence_conflict")
        }
        if (sequence <= highestSequence) return Decision.Reject("duplicate_expired")
        return Decision.Execute
    }

    @Synchronized
    fun record(sequence: Long, id: String, response: String) {
        highestSequence = maxOf(highestSequence, sequence)
        entries[sequence] = Entry(id, response, nowMillis())
        while (entries.size > maxEntries) entries.remove(entries.keys.first())
        evictExpired()
    }

    private fun evictExpired() {
        val cutoff = nowMillis() - retentionMillis
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().value.storedAt < cutoff) iterator.remove()
        }
    }
}
