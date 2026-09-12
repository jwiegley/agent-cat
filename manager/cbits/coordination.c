#include <sys/file.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <stdint.h>

int agentic_manager_lock(int fd) {
    return flock(fd, LOCK_EX | LOCK_NB);
}

int agentic_manager_duplicate_lease(int fd) {
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
}

void agentic_manager_sqlite_limits(sqlite3 *db) {
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 2097152);
    sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65536);
    sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 64);
    sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 256);
    sqlite3_limit(db, SQLITE_LIMIT_EXPR_DEPTH, 64);
    sqlite3_limit(db, SQLITE_LIMIT_COMPOUND_SELECT, 32);
    sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0);
}

int64_t agentic_manager_row_bytes(sqlite3_stmt *stmt) {
    int64_t bytes = 0;
    for (int i = 0; i < sqlite3_column_count(stmt); ++i) {
        int type = sqlite3_column_type(stmt, i);
        bytes += (type == SQLITE_TEXT || type == SQLITE_BLOB)
            ? sqlite3_column_bytes(stmt, i) : 8;
    }
    return bytes;
}

int agentic_manager_readonly(sqlite3_stmt *stmt) {
    return sqlite3_stmt_readonly(stmt);
}
