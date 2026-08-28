package com.iflytek.lanmediacast.receiver.security

import java.io.File
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class SasCalculatorTest {
    @Test
    fun `reserved Phase 2 SAS matches shared fixed vector`() {
        val fixture = Json.parseToJsonElement(
            File("../../protocol/fixtures/v1/valid/sas_vector.json").readText(Charsets.UTF_8),
        ).jsonObject
        fun string(name: String) = fixture.getValue(name).jsonPrimitive.content
        fun bytes(name: String) = Base64.getUrlDecoder().decode(string(name))

        assertEquals(
            string("expectedSas"),
            SasCalculator.calculate(
                bytes("certificateSha256"),
                string("senderId"),
                bytes("senderNonce"),
                bytes("receiverNonce"),
                string("challengeId"),
            ),
        )
    }
}
