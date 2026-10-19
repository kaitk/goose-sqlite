/* The C under sqlite.goose: SQLite's C interface adapted to opaque handles,
   bytes in and bytes out, and result codes. goose build compiles it with
   vendor/sqlite/sqlite3.c and the options in sqlite.build, so it sees none of
   the generated C but goose.h.

   A handle is the address of a sqlite3 or a sqlite3_stmt, as an int64_t; 0 is
   none. No function keeps a pointer into Goose memory after it returns: text
   and blobs are bound as SQLITE_TRANSIENT, so SQLite copies them, and column
   values are appended to the caller's builder. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "goose.h"
#include "sqlite3.h"

#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } sq_bytes;
#pragma pack(pop)
_Static_assert(sizeof(sq_bytes) == sizeof(void *) + 8, "a Goose slice is { data, len }, packed");

#define DB(h) ((sqlite3 *)(intptr_t)(h))
#define STMT(h) ((sqlite3_stmt *)(intptr_t)(h))

/* A parameter or column index from Goose's i64 as SQLite's int, or -1, which
   SQLite takes as out of range, when it doesn't fit: a plain conversion would
   make 4294967297 parameter 1. */
static int idx(int64_t i) { return i < 0 || i > INT32_MAX ? -1 : (int)i; }

/* A C string would end at a NUL inside s, and mean something else. */
static int has_nul(sq_bytes s) {
    return s.len > 0 && memchr(s.data, 0, (size_t)s.len) != NULL;
}

/* A NUL-terminated copy of s, for the calls that take a C string; NULL when
   s holds a NUL or memory runs out. */
static char *c_string(sq_bytes s) {
    if (s.len < 0 || has_nul(s)) return NULL;
    char *c = malloc((size_t)s.len + 1);
    if (!c) return NULL;
    if (s.len) memcpy(c, s.data, (size_t)s.len);
    c[s.len] = 0;
    return c;
}

static void append_str(gs_rref out, const char *s) {
    if (s) gs_bld_append(out, s, (int64_t)strlen(s));
}

/* Opens path with SQLite's SQLITE_OPEN_* flags and extended result codes.
   *db is the connection even when the open fails, for sq_errmsg, and must
   then be closed; it is 0 only when SQLite couldn't allocate one. */
int32_t sq_open(sq_bytes path, int32_t flags, int64_t *db) {
    *db = 0;
    /* SQLITE_OMIT_AUTOINIT leaves this to the program. It is thread-safe and
       does nothing after the first call. */
    int rc = sqlite3_initialize();
    if (rc != SQLITE_OK) return rc;
    char *p = c_string(path);
    if (!p) return has_nul(path) ? SQLITE_CANTOPEN : SQLITE_NOMEM;
    sqlite3 *h = NULL;
    rc = sqlite3_open_v2(p, &h, flags | SQLITE_OPEN_EXRESCODE, NULL);
    free(p);
    *db = (int64_t)(intptr_t)h;
    return rc;
}

/* SQLITE_BUSY, with the connection still open, while a statement of it isn't
   finalized. */
int32_t sq_close(int64_t db) { return sqlite3_close(DB(db)); }

int32_t sq_errcode(int64_t db) { return sqlite3_extended_errcode(DB(db)); }

void sq_errmsg(int64_t db, gs_rref out) { append_str(out, sqlite3_errmsg(DB(db))); }

void sq_errstr(int32_t rc, gs_rref out) { append_str(out, sqlite3_errstr(rc)); }

/* Runs every statement in sql, discarding rows. */
int32_t sq_exec(int64_t db, sq_bytes sql) {
    char *s = c_string(sql);
    if (!s) return has_nul(sql) ? SQLITE_MISUSE : SQLITE_NOMEM;
    int rc = sqlite3_exec(DB(db), s, NULL, NULL, NULL);
    free(s);
    return rc;
}

/* Prepares the first statement in sql. *used is how many bytes of sql it
   took; *stmt is 0 when sql held only spaces and comments. */
int32_t sq_prepare(int64_t db, sq_bytes sql, int64_t *stmt, int64_t *used) {
    *stmt = 0;
    *used = 0;
    if (sql.len < 0 || sql.len > INT32_MAX) return SQLITE_TOOBIG;
    /* An empty slice may have no address, which SQLite would read. */
    const char *p = sql.len ? (const char *)sql.data : "";
    sqlite3_stmt *s = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v3(DB(db), p, (int)sql.len, 0, &s, &tail);
    *stmt = (int64_t)(intptr_t)s;
    if (tail) *used = (int64_t)(tail - p);
    return rc;
}

int32_t sq_finalize(int64_t stmt) { return sqlite3_finalize(STMT(stmt)); }

int32_t sq_reset(int64_t stmt) { return sqlite3_reset(STMT(stmt)); }

int32_t sq_clear_bindings(int64_t stmt) { return sqlite3_clear_bindings(STMT(stmt)); }

int64_t sq_db_of(int64_t stmt) { return (int64_t)(intptr_t)sqlite3_db_handle(STMT(stmt)); }

int32_t sq_bind_int64(int64_t stmt, int64_t i, int64_t v) {
    return sqlite3_bind_int64(STMT(stmt), idx(i), v);
}

int32_t sq_bind_double(int64_t stmt, int64_t i, double v) {
    return sqlite3_bind_double(STMT(stmt), idx(i), v);
}

int32_t sq_bind_text(int64_t stmt, int64_t i, sq_bytes v) {
    if (v.len < 0) return SQLITE_RANGE;
    /* An empty slice may have no address; SQLite reads NULL as SQL NULL. */
    const char *p = v.len ? (const char *)v.data : "";
    return sqlite3_bind_text64(STMT(stmt), idx(i), p, (sqlite3_uint64)v.len, SQLITE_TRANSIENT, SQLITE_UTF8);
}

int32_t sq_bind_blob(int64_t stmt, int64_t i, sq_bytes v) {
    if (v.len < 0) return SQLITE_RANGE;
    if (v.len == 0) return sqlite3_bind_zeroblob(STMT(stmt), idx(i), 0);
    return sqlite3_bind_blob64(STMT(stmt), idx(i), v.data, (sqlite3_uint64)v.len, SQLITE_TRANSIENT);
}

int32_t sq_bind_null(int64_t stmt, int64_t i) { return sqlite3_bind_null(STMT(stmt), idx(i)); }

/* The index of the parameter named name, such as ":id", or 0. */
int32_t sq_bind_index(int64_t stmt, sq_bytes name) {
    char *n = c_string(name);
    if (!n) return 0;
    int i = sqlite3_bind_parameter_index(STMT(stmt), n);
    free(n);
    return i;
}

int32_t sq_bind_count(int64_t stmt) { return sqlite3_bind_parameter_count(STMT(stmt)); }

int32_t sq_step(int64_t stmt) { return sqlite3_step(STMT(stmt)); }

int32_t sq_column_count(int64_t stmt) { return sqlite3_column_count(STMT(stmt)); }

int32_t sq_column_type(int64_t stmt, int64_t i) { return sqlite3_column_type(STMT(stmt), idx(i)); }

int64_t sq_column_int64(int64_t stmt, int64_t i) { return sqlite3_column_int64(STMT(stmt), idx(i)); }

double sq_column_double(int64_t stmt, int64_t i) { return sqlite3_column_double(STMT(stmt), idx(i)); }

/* Appends column i as text, converting a number or blob as SQLite does.
   SQLITE_NOMEM when the conversion ran out of memory, else SQLITE_OK. */
int32_t sq_column_text(int64_t stmt, int64_t i, gs_rref out) {
    const unsigned char *p = sqlite3_column_text(STMT(stmt), idx(i));
    int n = sqlite3_column_bytes(STMT(stmt), idx(i));
    if (!p) return sqlite3_errcode(sqlite3_db_handle(STMT(stmt))) == SQLITE_NOMEM ? SQLITE_NOMEM : SQLITE_OK;
    gs_bld_append(out, p, n);
    return SQLITE_OK;
}

/* Appends column i's bytes, as sq_column_text. */
int32_t sq_column_blob(int64_t stmt, int64_t i, gs_rref out) {
    const void *p = sqlite3_column_blob(STMT(stmt), idx(i));
    int n = sqlite3_column_bytes(STMT(stmt), idx(i));
    if (!p) return sqlite3_errcode(sqlite3_db_handle(STMT(stmt))) == SQLITE_NOMEM ? SQLITE_NOMEM : SQLITE_OK;
    gs_bld_append(out, p, n);
    return SQLITE_OK;
}

void sq_column_name(int64_t stmt, int64_t i, gs_rref out) {
    append_str(out, sqlite3_column_name(STMT(stmt), idx(i)));
}

int64_t sq_changes(int64_t db) { return sqlite3_changes64(DB(db)); }

int64_t sq_last_insert_rowid(int64_t db) { return sqlite3_last_insert_rowid(DB(db)); }

/* ms clamped to what SQLite's int takes; below 0 means 0 to SQLite too. */
int32_t sq_busy_timeout(int64_t db, int64_t ms) {
    return sqlite3_busy_timeout(DB(db), ms < 0 ? 0 : ms > INT32_MAX ? INT32_MAX : (int)ms);
}

/* Whether the connection is outside a transaction. */
uint8_t sq_autocommit(int64_t db) { return sqlite3_get_autocommit(DB(db)) != 0; }

void sq_version(gs_rref out) { append_str(out, sqlite3_libversion()); }
