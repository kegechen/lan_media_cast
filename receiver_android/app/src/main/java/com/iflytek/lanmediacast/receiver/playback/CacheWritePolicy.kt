package com.iflytek.lanmediacast.receiver.playback

class CacheWritePolicy(
    initialEnabled: Boolean,
    private val disableThresholdBytes: Long = 256L * 1_024L * 1_024L,
    private val enableThresholdBytes: Long = 320L * 1_024L * 1_024L,
    private val disableDelayMillis: Long = 30_000L,
    private val enableDelayMillis: Long = 60_000L,
    private val minimumSwitchIntervalMillis: Long = 60_000L,
) {
    var enabled: Boolean = initialEnabled
        private set

    private var belowThresholdSince: Long? = null
    private var aboveThresholdSince: Long? = null
    private var lastSwitchAt: Long? = null

    @Synchronized
    fun update(availableBytes: Long, nowMillis: Long): Boolean {
        if (enabled) {
            aboveThresholdSince = null
            if (availableBytes <= 0L) {
                switchTo(false, nowMillis)
            } else if (availableBytes < disableThresholdBytes) {
                val since = belowThresholdSince ?: nowMillis.also { belowThresholdSince = it }
                if (nowMillis - since >= disableDelayMillis && canSwitch(nowMillis)) switchTo(false, nowMillis)
            } else {
                belowThresholdSince = null
            }
        } else {
            belowThresholdSince = null
            if (availableBytes >= enableThresholdBytes) {
                val since = aboveThresholdSince ?: nowMillis.also { aboveThresholdSince = it }
                if (nowMillis - since >= enableDelayMillis && canSwitch(nowMillis)) switchTo(true, nowMillis)
            } else {
                aboveThresholdSince = null
            }
        }
        return enabled
    }

    private fun canSwitch(nowMillis: Long): Boolean =
        lastSwitchAt?.let { nowMillis - it >= minimumSwitchIntervalMillis } ?: true

    private fun switchTo(value: Boolean, nowMillis: Long) {
        enabled = value
        lastSwitchAt = nowMillis
        belowThresholdSince = null
        aboveThresholdSince = null
    }
}
