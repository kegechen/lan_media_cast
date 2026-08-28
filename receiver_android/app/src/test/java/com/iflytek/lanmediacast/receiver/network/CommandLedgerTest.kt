package com.iflytek.lanmediacast.receiver.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandLedgerTest {
    @Test
    fun `duplicates return cached result without executing`() {
        val ledger = CommandLedger()
        assertTrue(ledger.inspect(1, "a") is CommandLedger.Decision.Execute)
        ledger.record(1, "a", "ok")
        assertEquals(CommandLedger.Decision.Cached("ok"), ledger.inspect(1, "a"))
        assertEquals(CommandLedger.Decision.Reject("sequence_conflict"), ledger.inspect(1, "b"))
    }

    @Test
    fun `expired duplicate is never executed again`() {
        var now = 1_000L
        val ledger = CommandLedger(retentionMillis = 100, nowMillis = { now })
        ledger.record(1, "a", "ok")
        now += 101
        assertEquals(CommandLedger.Decision.Reject("duplicate_expired"), ledger.inspect(1, "a"))
    }
}
