#define agentic_signal_group admission_real_signal_group
#include "../../runtime/cbits/process_group.c"
#undef agentic_signal_group
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic int armed;
static _Atomic int fired;
void admission_arm_completion_failure(void) {
    atomic_store(&fired, 0);
    atomic_store(&armed, 1);
}
int admission_completion_failure_fired(void) { return atomic_load(&fired); }

/* Test-only SQLite initialization. No connection pointer escapes its invocation. */
#define agentic_manager_sqlite_limits admission_real_sqlite_limits
#include "../cbits/coordination.c"
#undef agentic_manager_sqlite_limits

static void admission_io_failure(sqlite3_context *context, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    sqlite3_result_error_code(context, SQLITE_IOERR_WRITE);
}

static void admission_page_quota(sqlite3_context *context, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    sqlite3 *db = sqlite3_context_db_handle(context);
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(db, "PRAGMA page_count", -1, &statement, NULL);
    int pages = 0;
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(statement);
        if (rc == SQLITE_ROW) pages = sqlite3_column_int(statement, 0);
    }
    sqlite3_finalize(statement);
    if (rc != SQLITE_ROW || pages <= 0) {
        sqlite3_result_error_code(context, rc == SQLITE_ROW ? SQLITE_ERROR : rc);
        return;
    }
    char sql[80];
    sqlite3_snprintf(sizeof sql, sql, "PRAGMA max_page_count=%d", pages);
    rc = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    int applied = 0;
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(statement);
        if (rc == SQLITE_ROW) applied = sqlite3_column_int(statement, 0);
    }
    sqlite3_finalize(statement);
    if (rc != SQLITE_ROW || applied != pages)
        sqlite3_result_error_code(context, rc == SQLITE_ROW ? SQLITE_ERROR : rc);
    else
        sqlite3_result_int(context, applied);
}

void agentic_manager_sqlite_limits(sqlite3 *db) {
    admission_real_sqlite_limits(db);
    if (sqlite3_create_function_v2(db, "admission_io_failure", 0, SQLITE_UTF8,
            NULL, admission_io_failure, NULL, NULL, NULL) != SQLITE_OK ||
        sqlite3_create_function_v2(db, "admission_page_quota", 0, SQLITE_UTF8,
            NULL, admission_page_quota, NULL, NULL, NULL) != SQLITE_OK)
        abort();
}

int agentic_signal_group(int pid, int signal) {
    if (signal == SIGKILL && atomic_load(&armed)) {
        int exited;
        do {
            exited = agentic_child_exited(pid);
        } while (exited < 0 && errno == EINTR);
        int result = admission_real_signal_group(pid, signal);
        if (result == 0 && exited > 0 && atomic_exchange(&armed, 0)) {
            /* Real cleanup ran. Only its completion report is simulated as failed. */
            atomic_store(&fired, 1);
            errno = EIO;
            return -1;
        }
        return result;
    }
    return admission_real_signal_group(pid, signal);
}
