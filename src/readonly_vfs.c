#include "sqlite3.h"

static sqlite3_vfs readonly_vfs;
static sqlite3_vfs *underlying_vfs;
static int registered;

static int readonly_open(sqlite3_vfs *vfs, sqlite3_filename name,
                         sqlite3_file *file, int flags, int *out_flags) {
    (void)vfs;
    if (!name) return SQLITE_READONLY;
    flags &= ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
               SQLITE_OPEN_DELETEONCLOSE);
    flags |= SQLITE_OPEN_READONLY;
    return underlying_vfs->xOpen(underlying_vfs, name, file, flags, out_flags);
}

static int readonly_delete(sqlite3_vfs *vfs, const char *name, int sync_dir) {
    (void)vfs;
    (void)name;
    (void)sync_dir;
    return SQLITE_READONLY;
}

int t3code_readonly_vfs_init(void) {
    int result = sqlite3_initialize();
    if (result != SQLITE_OK) return result;
    sqlite3_mutex *mutex = sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_APP1);
    sqlite3_mutex_enter(mutex);
    if (!registered) {
        underlying_vfs = sqlite3_vfs_find(0);
        if (!underlying_vfs) {
            result = SQLITE_ERROR;
        } else {
            readonly_vfs = *underlying_vfs;
            readonly_vfs.pNext = 0;
            readonly_vfs.zName = "t3code-readonly";
            readonly_vfs.xOpen = readonly_open;
            readonly_vfs.xDelete = readonly_delete;
            result = sqlite3_vfs_register(&readonly_vfs, 0);
            if (result == SQLITE_OK) registered = 1;
        }
    }
    sqlite3_mutex_leave(mutex);
    return result;
}
