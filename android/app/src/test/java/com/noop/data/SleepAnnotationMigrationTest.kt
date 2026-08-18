package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class SleepAnnotationMigrationTest {
    @Test
    fun migrationSqlMatchesSwiftColumnAndKeyOrder() {
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `sleepAnnotation` (`deviceId` TEXT NOT NULL, " +
                    "`tsMs` INTEGER NOT NULL, `type` INTEGER NOT NULL, " +
                    "PRIMARY KEY(`deviceId`, `tsMs`, `type`))",
            ),
            WhoopDatabase.SLEEP_ANNOTATION_MIGRATION_SQL,
        )
    }

    @Test
    fun migrationVersionIs21To22() {
        assertEquals(21, WhoopDatabase.MIGRATION_21_22.startVersion)
        assertEquals(22, WhoopDatabase.MIGRATION_21_22.endVersion)
    }
}
