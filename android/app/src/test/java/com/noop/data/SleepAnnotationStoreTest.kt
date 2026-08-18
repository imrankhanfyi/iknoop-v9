package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class SleepAnnotationStoreTest {
    private class FakeSleepAnnotationDao : SleepAnnotationDao {
        val rows = linkedSetOf<SleepAnnotationRow>()
        val operations = mutableListOf<String>()

        override suspend fun sleepAnnotations(deviceId: String, fromTsMs: Long, toTsMs: Long): List<SleepAnnotationRow> =
            rows.filter { it.deviceId == deviceId && it.tsMs in fromTsMs..toTsMs }
                .sortedWith(compareBy(SleepAnnotationRow::tsMs, SleepAnnotationRow::type))

        override suspend fun insertSleepAnnotation(row: SleepAnnotationRow): Long {
            operations += "insert:${row.tsMs}:${row.type}"
            return if (rows.add(row)) 1L else -1L
        }

        override suspend fun deleteSleepAnnotation(row: SleepAnnotationRow) {
            operations += "delete:${row.tsMs}:${row.type}"
            rows.remove(row)
        }
    }

    @Test
    fun snapMatchesSwift() {
        assertEquals(30_000L, SleepAnnotation.snapTsMs(44_999L))
        assertEquals(60_000L, SleepAnnotation.snapTsMs(45_000L))
    }

    @Test
    fun typeCodesMatchSwift() {
        assertEquals(
            listOf(0, 1, 2, 3, 4),
            listOf(
                SleepAnnotation.Type.IN_BED,
                SleepAnnotation.Type.FELL_ASLEEP,
                SleepAnnotation.Type.AWAKE_IN_BED,
                SleepAnnotation.Type.BRIEFLY_GOT_UP,
                SleepAnnotation.Type.AROSE,
            ),
        )
    }

    @Test
    fun moveDeletesOldThenInsertIgnoresExistingTarget() = kotlinx.coroutines.runBlocking {
        val dao = FakeSleepAnnotationDao()
        val old = SleepAnnotationRow("device", 60_000L, SleepAnnotation.Type.IN_BED)
        val target = SleepAnnotationRow("device", 90_000L, SleepAnnotation.Type.IN_BED)
        dao.rows += old
        dao.rows += target

        dao.moveSleepAnnotation(old, target.tsMs)

        assertEquals(listOf("delete:60000:0", "insert:90000:0"), dao.operations)
        assertEquals(listOf(target), dao.rows.toList())
    }

    @Test
    fun replaceDeletesOldThenInsertIgnoresExistingTarget() = kotlinx.coroutines.runBlocking {
        val dao = FakeSleepAnnotationDao()
        val old = SleepAnnotationRow("device", 60_000L, SleepAnnotation.Type.IN_BED)
        val target = SleepAnnotationRow("device", 60_000L, SleepAnnotation.Type.AROSE)
        dao.rows += old
        dao.rows += target

        dao.replaceSleepAnnotation(old, target.type)

        assertEquals(listOf("delete:60000:0", "insert:60000:4"), dao.operations)
        assertEquals(listOf(target), dao.rows.toList())
    }

    @Test
    fun inclusiveReadDeduplicatesAndOrdersByTimestampThenType() = kotlinx.coroutines.runBlocking {
        val dao = FakeSleepAnnotationDao()
        val fell = SleepAnnotationRow("device", 60_000L, SleepAnnotation.Type.FELL_ASLEEP)
        val awake = SleepAnnotationRow("device", 60_000L, SleepAnnotation.Type.AWAKE_IN_BED)
        val arose = SleepAnnotationRow("device", 90_000L, SleepAnnotation.Type.AROSE)
        for (row in listOf(arose, awake, fell, awake)) dao.insertSleepAnnotation(row)

        assertEquals(listOf(fell, awake, arose), dao.sleepAnnotations("device", 60_000L, 90_000L))
    }
}
