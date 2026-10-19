/* The C under sqlite.goose: SQLite's C interface adapted to opaque handles,
   bytes in and bytes out, and result codes. goose build compiles it with
   vendor/sqlite/sqlite3.c and the options in sqlite.build, so it sees none of
   the generated C but goose.h.

   A handle names a sqlite3 or a sqlite3_stmt in the table below, as an
   int64_t; 0 is none. No function keeps a pointer into Goose memory after it
   returns: text and blobs are bound as SQLITE_TRANSIENT, so SQLite copies
   them, and column values are appended to the caller's builder. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "goose.h"
#include "sqlite3.h"

#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } sq_bytes;
#pragma pack(pop)
_Static_assert(sizeof(sq_bytes) == sizeof(void *) + 8, "a Goose slice is { data, len }, packed");

/* The handle table. A handle is a slot's index + 1 in its low 32 bits and the
   slot's generation in its high ones. close and finalize free the slot and
   bump its generation, so every copy of the handle goes stale at once: a call
   through one finds the generation moved on and fails with SQLITE_MISUSE, or
   reads as nothing, instead of reaching freed memory. Goose copies a Db or
   Stmt freely, and a handle can cross threads, so there is one table, under
   SQLite's static application mutex. That guards the table, not a call in
   progress: closing a connection while another thread is inside a call on it
   is still a race. */
enum { FREE, KIND_DB, KIND_STMT };

typedef struct {
    void *p;
    int64_t db;       /* a statement's connection, for sq_db_of */
    uint32_t gen;     /* 1 to INT32_MAX, so a handle is never negative */
    uint32_t next;    /* while free, the next free slot's index + 1, or 0 */
    uint8_t kind;
} sq_slot;

static sq_slot *slots;
static uint32_t nslots, cap, free_head;

static sqlite3_mutex *table_mutex(void) {
    /* Opening a connection has initialized SQLite before any handle exists;
       SQLITE_OMIT_AUTOINIT leaves this call to the shim. */
    if (sqlite3_initialize() != SQLITE_OK) return NULL;
    return sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_APP1);
}

/* The slot h names, if it holds an object of kind; the caller holds the
   mutex. */
static sq_slot *slot_of(int64_t h, int kind) {
    uint32_t i = (uint32_t)(h & 0xffffffff), gen = (uint32_t)(h >> 32);
    if (i == 0 || i > nslots) return NULL;
    sq_slot *s = &slots[i - 1];
    return s->kind == kind && s->gen == gen ? s : NULL;
}

/* A handle for p, or 0 when memory runs out. */
static int64_t put(int kind, void *p, int64_t db) {
    sqlite3_mutex *m = table_mutex();
    sqlite3_mutex_enter(m);
    uint32_t i = free_head;
    if (i) {
        free_head = slots[i - 1].next;
    } else {
        if (nslots == cap && cap < INT32_MAX / 2) {
            uint32_t more = cap ? cap * 2 : 16;
            sq_slot *grown = realloc(slots, (size_t)more * sizeof *slots);
            if (grown) {
                slots = grown;
                cap = more;
            }
        }
        if (nslots < cap) {
            i = ++nslots;
            slots[i - 1].gen = 1;
        }
    }
    int64_t h = 0;
    if (i) {
        sq_slot *s = &slots[i - 1];
        s->p = p;
        s->db = db;
        s->kind = (uint8_t)kind;
        h = (int64_t)s->gen << 32 | i;
    }
    sqlite3_mutex_leave(m);
    return h;
}

/* The object h names, or NULL when h is stale or of another kind. */
static void *get(int64_t h, int kind, int64_t *db) {
    sqlite3_mutex *m = table_mutex();
    sqlite3_mutex_enter(m);
    sq_slot *s = slot_of(h, kind);
    void *p = s ? s->p : NULL;
    if (db) *db = s ? s->db : 0;
    sqlite3_mutex_leave(m);
    return p;
}

/* Frees h's slot and returns its object, or NULL when h is stale. */
static void *take(int64_t h, int kind) {
    sqlite3_mutex *m = table_mutex();
    sqlite3_mutex_enter(m);
    sq_slot *s = slot_of(h, kind);
    void *p = NULL;
    if (s) {
        p = s->p;
        s->p = NULL;
        s->kind = FREE;
        s->gen = s->gen == INT32_MAX ? 1 : s->gen + 1;
        s->next = free_head;
        free_head = (uint32_t)(s - slots) + 1;
    }
    sqlite3_mutex_leave(m);
    return p;
}

static sqlite3 *db_of(int64_t h) { return get(h, KIND_DB, NULL); }
static sqlite3_stmt *stmt_of(int64_t h) { return get(h, KIND_STMT, NULL); }

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
    /* FULLMUTEX makes this connection serialized under SQLITE_THREADSAFE=2: it
       takes its mutex on each call, so two threads that use it at once wait
       for each other rather than corrupt it. */
    rc = sqlite3_open_v2(p, &h, flags | SQLITE_OPEN_EXRESCODE | SQLITE_OPEN_FULLMUTEX, NULL);
    free(p);
    if (!h) return rc;
    *db = put(KIND_DB, h, 0);
    if (!*db) {
        sqlite3_close(h);
        return SQLITE_NOMEM;
    }
    /* SQLite's hardening for a database file that may come from elsewhere
       (sqlite.org/security.html): no SQL that corrupts the file on purpose,
       such as writes to sqlite_schema, and no functions with side effects run
       from the schema's views and triggers. */
    if (rc == SQLITE_OK) rc = sqlite3_db_config(h, SQLITE_DBCONFIG_DEFENSIVE, 1, (int *)0);
    if (rc == SQLITE_OK) rc = sqlite3_db_config(h, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, (int *)0);
    return rc;
}

/* SQLITE_BUSY, with the connection still open, while a statement of it isn't
   finalized; SQLITE_MISUSE when db is closed already. */
int32_t sq_close(int64_t db) {
    sqlite3 *h = db_of(db);
    if (!h) return SQLITE_MISUSE;
    int rc = sqlite3_close(h);
    if (rc == SQLITE_OK) take(db, KIND_DB);
    return rc;
}

/* For a stale handle, SQLITE_MISUSE and the message that says so. */
int32_t sq_errcode(int64_t db) {
    sqlite3 *h = db_of(db);
    return h ? sqlite3_extended_errcode(h) : SQLITE_MISUSE;
}

void sq_errmsg(int64_t db, gs_rref out) {
    sqlite3 *h = db_of(db);
    append_str(out, h ? sqlite3_errmsg(h) : "no open connection: closed, or never opened");
}

void sq_errstr(int32_t rc, gs_rref out) { append_str(out, sqlite3_errstr(rc)); }

/* Runs every statement in sql, discarding rows. */
int32_t sq_exec(int64_t db, sq_bytes sql) {
    sqlite3 *h = db_of(db);
    if (!h) return SQLITE_MISUSE;
    char *s = c_string(sql);
    if (!s) return has_nul(sql) ? SQLITE_MISUSE : SQLITE_NOMEM;
    int rc = sqlite3_exec(h, s, NULL, NULL, NULL);
    free(s);
    return rc;
}

/* Prepares the first statement in sql. *used is how many bytes of sql it
   took; *stmt is 0 when sql held only spaces and comments. */
int32_t sq_prepare(int64_t db, sq_bytes sql, int64_t *stmt, int64_t *used) {
    *stmt = 0;
    *used = 0;
    sqlite3 *h = db_of(db);
    if (!h) return SQLITE_MISUSE;
    if (sql.len < 0 || sql.len > INT32_MAX) return SQLITE_TOOBIG;
    /* An empty slice may have no address, which SQLite would read. */
    const char *p = sql.len ? (const char *)sql.data : "";
    sqlite3_stmt *s = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v3(h, p, (int)sql.len, 0, &s, &tail);
    if (tail) *used = (int64_t)(tail - p);
    if (s) {
        *stmt = put(KIND_STMT, s, db);
        if (!*stmt) {
            sqlite3_finalize(s);
            return SQLITE_NOMEM;
        }
    }
    return rc;
}

/* SQLITE_MISUSE, and nothing done, for a stale handle, here and below. */
int32_t sq_finalize(int64_t stmt) {
    sqlite3_stmt *s = take(stmt, KIND_STMT);
    return s ? sqlite3_finalize(s) : SQLITE_MISUSE;
}

int32_t sq_reset(int64_t stmt) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_reset(s) : SQLITE_MISUSE;
}

int32_t sq_clear_bindings(int64_t stmt) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_clear_bindings(s) : SQLITE_MISUSE;
}

/* The connection's handle, or 0 for a stale statement. */
int64_t sq_db_of(int64_t stmt) {
    int64_t db = 0;
    get(stmt, KIND_STMT, &db);
    return db;
}

int32_t sq_bind_int64(int64_t stmt, int64_t i, int64_t v) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_bind_int64(s, idx(i), v) : SQLITE_MISUSE;
}

int32_t sq_bind_double(int64_t stmt, int64_t i, double v) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_bind_double(s, idx(i), v) : SQLITE_MISUSE;
}

int32_t sq_bind_text(int64_t stmt, int64_t i, sq_bytes v) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (!s) return SQLITE_MISUSE;
    if (v.len < 0) return SQLITE_RANGE;
    /* An empty slice may have no address; SQLite reads NULL as SQL NULL. */
    const char *p = v.len ? (const char *)v.data : "";
    return sqlite3_bind_text64(s, idx(i), p, (sqlite3_uint64)v.len, SQLITE_TRANSIENT, SQLITE_UTF8);
}

int32_t sq_bind_blob(int64_t stmt, int64_t i, sq_bytes v) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (!s) return SQLITE_MISUSE;
    if (v.len < 0) return SQLITE_RANGE;
    if (v.len == 0) return sqlite3_bind_zeroblob(s, idx(i), 0);
    return sqlite3_bind_blob64(s, idx(i), v.data, (sqlite3_uint64)v.len, SQLITE_TRANSIENT);
}

int32_t sq_bind_null(int64_t stmt, int64_t i) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_bind_null(s, idx(i)) : SQLITE_MISUSE;
}

/* The index of the parameter named name, such as ":id", 0 when there is
   none, or -1 for a stale statement. */
int32_t sq_bind_index(int64_t stmt, sq_bytes name) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (!s) return -1;
    char *n = c_string(name);
    if (!n) return 0;
    int i = sqlite3_bind_parameter_index(s, n);
    free(n);
    return i;
}

/* The reads that can't fail give 0, or NULL, for a stale statement. */
int32_t sq_bind_count(int64_t stmt) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_bind_parameter_count(s) : 0;
}

int32_t sq_step(int64_t stmt) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_step(s) : SQLITE_MISUSE;
}

int32_t sq_column_count(int64_t stmt) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_column_count(s) : 0;
}

int32_t sq_column_type(int64_t stmt, int64_t i) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_column_type(s, idx(i)) : SQLITE_NULL;
}

int64_t sq_column_int64(int64_t stmt, int64_t i) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_column_int64(s, idx(i)) : 0;
}

double sq_column_double(int64_t stmt, int64_t i) {
    sqlite3_stmt *s = stmt_of(stmt);
    return s ? sqlite3_column_double(s, idx(i)) : 0.0;
}

/* Appends column i as text, converting a number or blob as SQLite does.
   SQLITE_NOMEM when the conversion ran out of memory, else SQLITE_OK. */
int32_t sq_column_text(int64_t stmt, int64_t i, gs_rref out) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (!s) return SQLITE_MISUSE;
    const unsigned char *p = sqlite3_column_text(s, idx(i));
    int n = sqlite3_column_bytes(s, idx(i));
    if (!p) return sqlite3_errcode(sqlite3_db_handle(s)) == SQLITE_NOMEM ? SQLITE_NOMEM : SQLITE_OK;
    gs_bld_append(out, p, n);
    return SQLITE_OK;
}

/* Appends column i's bytes, as sq_column_text. */
int32_t sq_column_blob(int64_t stmt, int64_t i, gs_rref out) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (!s) return SQLITE_MISUSE;
    const void *p = sqlite3_column_blob(s, idx(i));
    int n = sqlite3_column_bytes(s, idx(i));
    if (!p) return sqlite3_errcode(sqlite3_db_handle(s)) == SQLITE_NOMEM ? SQLITE_NOMEM : SQLITE_OK;
    gs_bld_append(out, p, n);
    return SQLITE_OK;
}

void sq_column_name(int64_t stmt, int64_t i, gs_rref out) {
    sqlite3_stmt *s = stmt_of(stmt);
    if (s) append_str(out, sqlite3_column_name(s, idx(i)));
}

int64_t sq_changes(int64_t db) {
    sqlite3 *h = db_of(db);
    return h ? sqlite3_changes64(h) : 0;
}

int64_t sq_last_insert_rowid(int64_t db) {
    sqlite3 *h = db_of(db);
    return h ? sqlite3_last_insert_rowid(h) : 0;
}

/* ms clamped to what SQLite's int takes; below 0 means 0 to SQLite too. */
int32_t sq_busy_timeout(int64_t db, int64_t ms) {
    sqlite3 *h = db_of(db);
    if (!h) return SQLITE_MISUSE;
    return sqlite3_busy_timeout(h, ms < 0 ? 0 : ms > INT32_MAX ? INT32_MAX : (int)ms);
}

/* Whether the connection is outside a transaction, as a closed one is. */
uint8_t sq_autocommit(int64_t db) {
    sqlite3 *h = db_of(db);
    return h ? sqlite3_get_autocommit(h) != 0 : 1;
}

void sq_version(gs_rref out) { append_str(out, sqlite3_libversion()); }
