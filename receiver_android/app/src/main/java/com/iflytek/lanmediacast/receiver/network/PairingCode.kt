package com.iflytek.lanmediacast.receiver.network

import java.security.SecureRandom

internal object PairingCode {
    private const val LIMIT = 1_000_000
    private val pattern = Regex("^[0-9]{6}$")

    fun generate(random: SecureRandom): String = format(random.nextInt(LIMIT))

    fun format(value: Int): String {
        require(value in 0 until LIMIT)
        return value.toString().padStart(6, '0')
    }

    fun isValid(value: String?): Boolean = value?.matches(pattern) == true
}
