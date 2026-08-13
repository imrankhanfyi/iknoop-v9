package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RrOrdMigrationTest {
    @Test fun migrationIsAdditiveAndNullable() {
        val sql = WhoopDatabase.RR_ORD_MIGRATION_SQL.single()
        assertEquals("ALTER TABLE `rrInterval` ADD COLUMN `ord` INTEGER", sql)
        assertFalse(sql.uppercase().contains("NOT NULL"))
        assertFalse(sql.uppercase().contains("DEFAULT"))
        assertEquals(20, WhoopDatabase.MIGRATION_20_21.startVersion)
        assertEquals(21, WhoopDatabase.MIGRATION_20_21.endVersion)
    }

    @Test fun stampsEverySameSecondBeatInArrivalOrder() {
        val out = assignRrSeq("d", listOf(
            RrRow(100, 812), RrRow(100, 795), RrRow(100, 840),
        ))
        assertEquals(listOf(0, 1, 2), out.map { it.ord })
        assertEquals(listOf(0, 0, 0), out.map { it.seq })
    }

    @Test fun legacyConstructedRowKeepsUnknownOrder() {
        assertNull(RrInterval(deviceId = "d", ts = 1, rrMs = 800).ord)
    }
}
