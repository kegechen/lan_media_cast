package com.iflytek.lanmediacast.receiver.network

class PairingRateLimiter(
    private val sourceLimit: Int = 5,
    private val sourceWindowMillis: Long = 30_000L,
    private val globalLimit: Int = 20,
    private val globalWindowMillis: Long = 5L * 60L * 1_000L,
) {
    private val failuresBySource = mutableMapOf<String, ArrayDeque<Long>>()
    private val globalFailures = ArrayDeque<Long>()

    @Synchronized
    fun isAllowed(source: String, nowMillis: Long = System.currentTimeMillis()): Boolean {
        prune(nowMillis)
        return (failuresBySource[source]?.size ?: 0) < sourceLimit && globalFailures.size < globalLimit
    }

    @Synchronized
    fun recordFailure(source: String, nowMillis: Long = System.currentTimeMillis()) {
        prune(nowMillis)
        failuresBySource.getOrPut(source, ::ArrayDeque).addLast(nowMillis)
        globalFailures.addLast(nowMillis)
    }

    private fun prune(nowMillis: Long) {
        globalFailures.removeBefore(nowMillis - globalWindowMillis)
        val iterator = failuresBySource.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.removeBefore(nowMillis - sourceWindowMillis)
            if (entry.value.isEmpty()) iterator.remove()
        }
    }

    private fun ArrayDeque<Long>.removeBefore(cutoff: Long) {
        while (firstOrNull()?.let { it <= cutoff } == true) removeFirst()
    }
}
