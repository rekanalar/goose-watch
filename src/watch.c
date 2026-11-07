// The C part of the goose-watch package.
//
// It watches a directory and gives the path and the kind of each
// change. On Linux the package uses inotify. On macOS and Windows the
// package compares the times and the sizes of the files. Both give the
// same kinds, so the caller does not need to know the system.
//
// An event is one number. The low byte holds the kind. Bit 8 says that
// the path is a directory. A kind of 5 says that the attributes of the
// path changed and the content did not.
//
// The caller gives the buffers. The path of an event goes out in the
// buffer of the caller.

#include "goose.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#endif

#ifdef __linux__
#include <sys/inotify.h>
#define WATCH_HAS_INOTIFY 1
#else
#define WATCH_HAS_INOTIFY 0
#endif

// The environment variable GOOSE_WATCH_COMPARE asks for the comparison
// watcher, whatever the system. The test suite uses it, so the kinds of
// that path are proven on every system.
static int use_compare(void) {
    const char *v = getenv("GOOSE_WATCH_COMPARE");
    return v != NULL && v[0] != 0;
}

static int watch_use_inotify(void) {
#if WATCH_HAS_INOTIFY
    return !use_compare();
#else
    return 0;
#endif
}

#ifndef WATCH_SL_U8
#define WATCH_SL_U8 1
typedef struct { const uint8_t *data; int64_t len; } watch_slice;
#endif

// The kinds of an event. The numbers are the API.
#define EV_NONE 0
#define EV_CREATED 1
#define EV_MODIFIED 2
#define EV_DELETED 3
#define EV_RENAMED 4
#define EV_ATTRIB 5

// The flag of a directory. It sits in bit 8 of the kind.
#define EV_ISDIR 0x100

#define MAX_WATCHERS 64
#define MAX_DEPTH 64
#ifdef _WIN32
// The header of Windows gives this name another value.
#undef MAX_PATH
#endif
#define MAX_PATH 1024
#define DEFAULT_INTERVAL_MS 50
#define MAX_INTERVAL_MS 60000

// The queue of events that wait for the caller.
typedef struct {
    int kind;
    char path[MAX_PATH];
    char old[MAX_PATH];
} queued;

// One watched directory, for the inotify watcher.
typedef struct {
    int wd;
    char path[MAX_PATH];
} wd_entry;

// One entry of the tree, for the comparison watcher.
typedef struct {
    char path[MAX_PATH];
    long long mtime;
    long long size;
    long long ino;
    unsigned int mode;
    int is_dir;
} file_entry;

// The tables of a watcher are on the heap and grow, so the size of the
// tree is no limit of the package.
typedef struct {
    int used;
    int recursive;
    // The rule for a symbolic link: 1 follows it, 0 does not.
    int follow;
    // The pause between two looks of the comparison watcher, in ms.
    int interval;
    char root[MAX_PATH];
    int fd;
    // The events of the inotify watcher that wait in the buffer.
    uint8_t *pending;
    int64_t pending_len;
    int64_t pending_cap;
    int64_t pending_at;
    // The queue of events that wait for the caller.
    queued *queue;
    int nqueue;
    int queue_cap;
    // The old path of the last rename event, empty for the others.
    char old[MAX_PATH];
    wd_entry *wds;
    int nwds;
    int wds_cap;
    file_entry *files;
    int nfiles;
    int files_cap;
} watcher_t;

static watcher_t g_watchers[MAX_WATCHERS];

// grow doubles the table when it is full. It gives 0 when the memory
// is out.
static int grow(void **p, int *cap, int64_t item) {
    int n = *cap > 0 ? *cap * 2 : 16;
    void *q = realloc(*p, (size_t)n * (size_t)item);
    if (!q) return 0;
    *p = q;
    *cap = n;
    return 1;
}

// queue_push puts one event at the end of the queue of the watcher.
static int queue_push(watcher_t *w, int kind, const char *path,
                      const char *old) {
    if (w->nqueue >= w->queue_cap &&
        !grow((void **)&w->queue, &w->queue_cap, sizeof(queued))) return 0;
    queued *q = &w->queue[w->nqueue++];
    q->kind = kind;
    snprintf(q->path, MAX_PATH, "%s", path);
    snprintf(q->old, MAX_PATH, "%s", old ? old : "");
    return 1;
}

// path_join puts the directory and the name together in the buffer.
static void path_join(char *out, int64_t out_cap, const char *dir,
                      const char *name) {
    int64_t n = (int64_t)strlen(dir);
    if (n > 0 && dir[n - 1] == '/') {
        snprintf(out, (size_t)out_cap, "%s%s", dir, name);
    } else {
        snprintf(out, (size_t)out_cap, "%s/%s", dir, name);
    }
}

static int is_dir(const char *path);

#ifdef _WIN32

// win_wide gives the path in the form of Windows. The bytes of the path
// are UTF-8, as every path of Goose. It gives 0 when the path is not
// valid UTF-8 or does not fit.
static int win_wide(const char *path, wchar_t *out, int cap) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, out, cap);
    if (n <= 0) return 0;
    return n - 1;
}

// win_utf8 gives the name of Windows in UTF-8. It gives 0 when the name
// is not valid or does not fit.
static int win_utf8(const wchar_t *name, char *out, int cap) {
    int n = WideCharToMultiByte(CP_UTF8, 0, name, -1, out, cap, NULL, NULL);
    if (n <= 0) return 0;
    return n - 1;
}

static int is_dir(const char *path) {
    wchar_t wide[MAX_PATH];
    if (!win_wide(path, wide, MAX_PATH)) return 0;
    DWORD attrs = GetFileAttributesW(wide);
    if (attrs == INVALID_FILE_ATTRIBUTES) return 0;
    return (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// dir_identity gives the number of the file. It finds a loop of links.
static long long dir_identity(const char *path) {
    BY_HANDLE_FILE_INFORMATION info;
    wchar_t wide[MAX_PATH];
    if (!win_wide(path, wide, MAX_PATH)) return 0;
    HANDLE h = CreateFileW(wide, 0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int ok = GetFileInformationByHandle(h, &info);
    CloseHandle(h);
    if (!ok) return 0;
    return ((long long)info.nFileIndexHigh << 32) | (long long)info.nFileIndexLow;
}

#else

static int is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode);
}

// dir_identity gives the inode of the directory. It finds a loop of
// links. Two files on one device can share the number, so the device
// joins it.
static long long dir_identity(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return ((long long)st.st_dev << 32) | (long long)st.st_ino;
}

#endif

// The comparison watcher. It walks the tree and keeps the time, the
// size, the mode and the rule of a directory of every entry.

// cmp_entries puts the new list of entries next to the old list and
// queues one event for each change.
static void cmp_entries(watcher_t *w, file_entry *fresh, int nfresh) {
    // A path that is new gives created. A known entry that left its
    // path and kept its number is the same entry under a new name: a
    // rename.
    for (int i = 0; i < nfresh; i++) {
        int known = 0;
        for (int j = 0; j < w->nfiles; j++) {
            if (strcmp(w->files[j].path, fresh[i].path) == 0) { known = 1; break; }
        }
        if (known) continue;
        for (int j = 0; j < w->nfiles; j++) {
            if (w->files[j].ino != fresh[i].ino || w->files[j].ino == 0) continue;
            int still = 0;
            for (int k = 0; k < nfresh; k++) {
                if (strcmp(fresh[k].path, w->files[j].path) == 0) { still = 1; break; }
            }
            if (still) continue;
            char oldp[MAX_PATH];
            snprintf(oldp, MAX_PATH, "%s", w->files[j].path);
            memcpy(&w->files[j], &fresh[i], sizeof(file_entry));
            queue_push(w, EV_RENAMED | (fresh[i].is_dir ? EV_ISDIR : 0),
                       fresh[i].path, oldp);
            goto next_fresh;
        }
        if (w->nfiles >= w->files_cap &&
            !grow((void **)&w->files, &w->files_cap, sizeof(file_entry))) continue;
        memcpy(&w->files[w->nfiles++], &fresh[i], sizeof(file_entry));
        queue_push(w, EV_CREATED | (fresh[i].is_dir ? EV_ISDIR : 0),
                   fresh[i].path, NULL);
next_fresh: ;
    }
    // A path that is gone gives deleted.
    for (int j = 0; j < w->nfiles; ) {
        int still = 0;
        for (int i = 0; i < nfresh; i++) {
            if (strcmp(fresh[i].path, w->files[j].path) == 0) { still = 1; break; }
        }
        if (still) { j++; continue; }
        char gone[MAX_PATH];
        int gone_dir = w->files[j].is_dir;
        snprintf(gone, MAX_PATH, "%s", w->files[j].path);
        memmove(&w->files[j], &w->files[j + 1],
                (size_t)(w->nfiles - j - 1) * sizeof(file_entry));
        w->nfiles -= 1;
        queue_push(w, EV_DELETED | (gone_dir ? EV_ISDIR : 0), gone, NULL);
    }
    // An entry with another time, size or mode gives modified or
    // attrib.
    for (int i = 0; i < nfresh; i++) {
        for (int j = 0; j < w->nfiles; j++) {
            if (strcmp(fresh[i].path, w->files[j].path) != 0) continue;
            if (fresh[i].mtime == w->files[j].mtime &&
                fresh[i].size == w->files[j].size) {
                if (fresh[i].mode != w->files[j].mode) {
                    w->files[j].mode = fresh[i].mode;
                    queue_push(w, EV_ATTRIB | (fresh[i].is_dir ? EV_ISDIR : 0),
                               fresh[i].path, NULL);
                }
                break;
            }
            memcpy(&w->files[j], &fresh[i], sizeof(file_entry));
            queue_push(w, EV_MODIFIED | (fresh[i].is_dir ? EV_ISDIR : 0),
                       fresh[i].path, NULL);
            break;
        }
    }
}

#ifdef _WIN32

// win_time_ns gives the time of a file in nanoseconds since the epoch.
// The time of Windows counts from 1601.
static long long win_time_ns(FILETIME ft) {
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    long long ticks = (long long)u.QuadPart;
    // The difference between 1601 and 1970 in steps of 100 nanoseconds.
    return (ticks - 116444736000000000LL) * 100LL;
}

// win_open opens a path for the reading of its attributes. The flags
// say whether a symbolic link is followed.
static HANDLE win_open(const char *path, int follow) {
    wchar_t wide[MAX_PATH];
    if (!win_wide(path, wide, MAX_PATH)) return INVALID_HANDLE_VALUE;
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS;
    if (!follow) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
    return CreateFileW(wide, 0,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, flags, NULL);
}

// win_stat gives the attributes, the time, the size, the mode and the
// number of the file of the path. A followed link gives the file of
// the target. It gives 0 when the path cannot be opened.
static int win_stat(const char *path, int follow, BY_HANDLE_FILE_INFORMATION *info,
                    unsigned int *mode, int *isdir) {
    HANDLE h = win_open(path, follow);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int ok = GetFileInformationByHandle(h, info);
    CloseHandle(h);
    if (!ok) return 0;
    DWORD a = info->dwFileAttributes;
    *isdir = (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
    // The low bits of the word of the attributes stand for the mode.
    *mode = (unsigned int)a & 0xffff;
    return 1;
}

// win_walk puts the entries of the tree into the list. It gives the
// number of entries. A directory is an entry too.
//
// The count of the directories stops the walk only as a guard against
// a tree that grows while the walk runs. A loop of links is cut by the
// number of the directory.
static int win_walk(const char *dir, int recursive, int follow, int depth,
                    long long *seen, int nseen, int *ndirs,
                    file_entry *fresh, int cap, int n) {
    if (*ndirs >= 4096 || depth >= MAX_DEPTH) return n;
    *ndirs += 1;
    long long id = dir_identity(dir);
    for (int i = 0; i < nseen; i++) {
        if (seen[i] == id && id != 0) return n;
    }
    char pattern[MAX_PATH];
    path_join(pattern, MAX_PATH, dir, "*");
    wchar_t wide[MAX_PATH];
    if (!win_wide(pattern, wide, MAX_PATH)) return n;
    WIN32_FIND_DATAW found;
    HANDLE h = FindFirstFileW(wide, &found);
    if (h == INVALID_HANDLE_VALUE) return n;
    do {
        char name[MAX_PATH];
        if (!win_utf8(found.cFileName, name, MAX_PATH)) continue;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        char full[MAX_PATH];
        path_join(full, MAX_PATH, dir, name);
        int islink = (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 &&
                     found.dwReserved0 == IO_REPARSE_TAG_SYMLINK;
        int isdir = (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
                    !islink;
        // The entry itself goes on the list first, so a rename of a
        // directory is one event of the directory.
        if (n < cap) {
            BY_HANDLE_FILE_INFORMATION info;
            unsigned int mode = 0;
            int entry_isdir = isdir;
            if (win_stat(full, follow && islink, &info, &mode, &entry_isdir)) {
                snprintf(fresh[n].path, MAX_PATH, "%s", full);
                fresh[n].mtime = win_time_ns(info.ftLastWriteTime);
                fresh[n].size = ((long long)info.nFileSizeHigh << 32) |
                                (long long)info.nFileSizeLow;
                fresh[n].ino = ((long long)info.nFileIndexHigh << 32) |
                               (long long)info.nFileIndexLow;
                fresh[n].mode = mode;
                fresh[n].is_dir = entry_isdir;
                n += 1;
            }
        }
        if (isdir && recursive) {
            n = win_walk(full, recursive, follow, depth + 1, seen, nseen,
                         ndirs, fresh, cap, n);
        }
    } while (FindNextFileW(h, &found));
    FindClose(h);
    return n;
}

// scan_files puts the entries of the tree of the watcher into the list.
static int scan_files(watcher_t *w, file_entry *fresh, int cap) {
    int ndirs = 0;
    long long seen[MAX_DEPTH];
    return win_walk(w->root, w->recursive, w->follow, 0, seen, 0, &ndirs,
                    fresh, cap, 0);
}

#else

// The time of a file in nanoseconds. The name of the field of the
// time is not the same on every system.
#if defined(__APPLE__)
#define ST_MTIME_NS(st) \
    ((long long)(st).st_mtimespec.tv_sec * 1000000000LL + \
     (long long)(st).st_mtimespec.tv_nsec)
#else
#define ST_MTIME_NS(st) \
    ((long long)(st).st_mtim.tv_sec * 1000000000LL + \
     (long long)(st).st_mtim.tv_nsec)
#endif

// scan_files puts the entries of the tree of the watcher into the
// list. A directory is an entry too. A loop of links is cut by the
// number of the directory.
static int scan_files(watcher_t *w, file_entry *fresh, int cap) {
    int nfresh = 0;
    // The stack of the walk. Each step holds the directory, the stack
    // place of its parent and the identities of the directories on the
    // path from the root. An identity that appears twice is a loop of
    // links, and the walk does not go into it again.
    char stack[MAX_DEPTH][MAX_PATH];
    int parent[MAX_DEPTH];
    long long seen[MAX_DEPTH][MAX_DEPTH];
    int nseen[MAX_DEPTH];
    int top = 0;
    snprintf(stack[0], MAX_PATH, "%s", w->root);
    parent[0] = -1;
    nseen[0] = 0;
    while (top >= 0) {
        char dir[MAX_PATH];
        int here = top;
        snprintf(dir, MAX_PATH, "%s", stack[top]);
        long long id = dir_identity(dir);
        top -= 1;
        int loop = 0;
        for (int i = 0; i < nseen[here]; i++) {
            if (seen[here][i] == id && id != 0) { loop = 1; break; }
        }
        if (loop) continue;
        DIR *d = opendir(dir);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
            char full[MAX_PATH];
            path_join(full, MAX_PATH, dir, e->d_name);
            struct stat st;
            if ((w->follow ? stat(full, &st) : lstat(full, &st)) != 0) continue;
            int isdir = S_ISDIR(st.st_mode);
            if (nfresh < cap) {
                snprintf(fresh[nfresh].path, MAX_PATH, "%s", full);
                fresh[nfresh].mtime = ST_MTIME_NS(st);
                fresh[nfresh].size = (long long)st.st_size;
                fresh[nfresh].ino = (long long)st.st_ino;
                fresh[nfresh].mode = (unsigned int)st.st_mode;
                fresh[nfresh].is_dir = isdir;
                nfresh += 1;
            }
            if (isdir && w->recursive && top + 1 < MAX_DEPTH) {
                top += 1;
                snprintf(stack[top], MAX_PATH, "%s", full);
                parent[top] = here;
                int carry = nseen[here];
                if (carry > MAX_DEPTH - 1) carry = MAX_DEPTH - 1;
                memcpy(seen[top], seen[here], (size_t)carry * sizeof(long long));
                if (id != 0 && carry < MAX_DEPTH) {
                    seen[top][carry] = id;
                    nseen[top] = carry + 1;
                } else {
                    nseen[top] = carry;
                }
            }
        }
        closedir(d);
    }
    return nfresh;
}

#endif

// prime fills the list of the entries with the entries of the tree now.
static int prime(watcher_t *w) {
    int cap = 256;
    file_entry *fresh = (file_entry *)malloc((size_t)cap * sizeof(file_entry));
    if (!fresh) return 0;
    int n = scan_files(w, fresh, cap);
    while (n >= cap) {
        int nc = cap * 2;
        file_entry *q = (file_entry *)realloc(fresh, (size_t)nc * sizeof(file_entry));
        if (!q) break;
        fresh = q;
        cap = nc;
        n = scan_files(w, fresh, cap);
    }
    w->files = fresh;
    w->files_cap = cap;
    w->nfiles = n;
    return 1;
}

// cmp_files walks the tree and queues the changes.
static int cmp_files(watcher_t *w) {
    int cap = w->nfiles + 64;
    file_entry *fresh = (file_entry *)malloc((size_t)cap * sizeof(file_entry));
    if (!fresh) return 0;
    int nfresh = scan_files(w, fresh, cap);
    while (nfresh >= cap) {
        int nc = cap * 2;
        file_entry *q = (file_entry *)realloc(fresh, (size_t)nc * sizeof(file_entry));
        if (!q) break;
        fresh = q;
        cap = nc;
        nfresh = scan_files(w, fresh, cap);
    }
    cmp_entries(w, fresh, nfresh);
    free(fresh);
    return 1;
}

// The inotify watcher. It is only on Linux, because the calls of
// inotify do not exist on the other systems.
#if WATCH_HAS_INOTIFY

// add_watch puts a watch on the directory and remembers the path.
static int add_watch(watcher_t *w, const char *dir) {
    for (int i = 0; i < w->nwds; i++) {
        if (strcmp(w->wds[i].path, dir) == 0) return w->wds[i].wd;
    }
    int wd = inotify_add_watch(w->fd, dir,
        IN_CREATE | IN_DELETE | IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE |
        IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF | IN_DELETE_SELF);
    if (wd < 0) return -1;
    if (w->nwds >= w->wds_cap &&
        !grow((void **)&w->wds, &w->wds_cap, sizeof(wd_entry))) {
        inotify_rm_watch(w->fd, wd);
        return -1;
    }
    w->wds[w->nwds].wd = wd;
    snprintf(w->wds[w->nwds].path, MAX_PATH, "%s", dir);
    w->nwds += 1;
    return wd;
}

// drop_watch removes the entry of a watch descriptor. The kernel may
// give the number to another directory later, so a dead entry must go.
static void drop_watch(watcher_t *w, int wd) {
    for (int i = 0; i < w->nwds; i++) {
        if (w->wds[i].wd != wd) continue;
        memmove(&w->wds[i], &w->wds[i + 1],
                (size_t)(w->nwds - i - 1) * sizeof(wd_entry));
        w->nwds -= 1;
        return;
    }
}

// The path of a watch descriptor. It gives the root when the number is
// not in the table.
static const char *wd_path(watcher_t *w, int wd) {
    for (int i = 0; i < w->nwds; i++) {
        if (w->wds[i].wd == wd) return w->wds[i].path;
    }
    return w->root;
}

// watch_subtree puts a watch on the directory and, when the watcher is
// deep, on each directory below it. It queues a created event for each
// entry, because an entry may have come before the watch was set.
static void watch_subtree(watcher_t *w, const char *dir, int depth);

static void watch_subtree(watcher_t *w, const char *dir, int depth) {
    if (depth >= MAX_DEPTH) return;
    add_watch(w, dir);
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char full[MAX_PATH];
        path_join(full, MAX_PATH, dir, e->d_name);
        struct stat st;
        if ((w->follow ? stat(full, &st) : lstat(full, &st)) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            // The subtree was another tree before, so its entries are
            // new for the watcher.
            if (w->recursive) {
                queue_push(w, EV_CREATED | EV_ISDIR, full, NULL);
                watch_subtree(w, full, depth + 1);
            }
            continue;
        }
        queue_push(w, EV_CREATED, full, NULL);
    }
    closedir(d);
}

// rewrite_prefix moves the watches of a renamed directory to the new
// path. The rename of a directory keeps the watch descriptors, so only
// the stored paths must change.
static void rewrite_prefix(watcher_t *w, const char *from, const char *to) {
    size_t flen = strlen(from);
    for (int i = 0; i < w->nwds; i++) {
        if (strcmp(w->wds[i].path, from) == 0) {
            snprintf(w->wds[i].path, MAX_PATH, "%s", to);
            continue;
        }
        if (strncmp(w->wds[i].path, from, flen) == 0 &&
            w->wds[i].path[flen] == '/') {
            char rest[MAX_PATH];
            snprintf(rest, MAX_PATH, "%s", w->wds[i].path + flen + 1);
            snprintf(w->wds[i].path, MAX_PATH, "%s/%s", to, rest);
        }
    }
}

// fill_more reads more events behind the ones that wait. It gives 1
// when it read something.
static int fill_more(watcher_t *w, int wait_ms) {
    int64_t keep = w->pending_len - w->pending_at;
    if (keep > 0 && w->pending_at > 0) {
        memmove(w->pending, w->pending + w->pending_at, (size_t)keep);
    }
    w->pending_len = keep > 0 ? keep : 0;
    w->pending_at = 0;
    if (w->pending_len + 1024 > w->pending_cap) {
        int64_t nc = w->pending_cap > 0 ? w->pending_cap * 2 : 65536;
        uint8_t *q = (uint8_t *)realloc(w->pending, (size_t)nc);
        if (!q) return 0;
        w->pending = q;
        w->pending_cap = nc;
    }
    struct pollfd p = { .fd = w->fd, .events = POLLIN };
    if (poll(&p, 1, wait_ms) <= 0) return 0;
    ssize_t n = read(w->fd, w->pending + w->pending_len,
                     (size_t)(w->pending_cap - w->pending_len));
    if (n <= 0) return 0;
    w->pending_len += (int64_t)n;
    return 1;
}

// event_path puts the directory of the watch and the name of the event
// together.
static void event_path(watcher_t *w, struct inotify_event *ev, char *out,
                       int64_t cap) {
    const char *dir = wd_path(w, ev->wd);
    if (ev->len > 0 && ev->name[0] != 0) {
        path_join(out, cap, dir, ev->name);
    } else {
        snprintf(out, (size_t)cap, "%s", dir);
    }
}

// find_pair looks behind the event at `from` for the MOVED_TO event of
// the same cookie. It marks that event as used and gives its path.
static int find_pair(watcher_t *w, int64_t from, uint32_t cookie, char *out,
                     int64_t cap) {
    int64_t scan = from;
    while (scan + (int64_t)sizeof(struct inotify_event) <= w->pending_len) {
        struct inotify_event *e = (struct inotify_event *)(w->pending + scan);
        int64_t rec = (int64_t)sizeof(struct inotify_event) + e->len;
        if (scan + rec > w->pending_len) break;
        if ((e->mask & IN_MOVED_TO) && e->cookie == cookie) {
            event_path(w, e, out, cap);
            e->mask = 0;
            return 1;
        }
        scan += rec;
    }
    return 0;
}

// handle_inotify reads the events that wait and fills the queue.
static void handle_inotify(watcher_t *w, int first_wait_ms) {
    if (w->pending_at >= w->pending_len) {
        if (!fill_more(w, first_wait_ms)) return;
    }
    while (w->pending_at + (int64_t)sizeof(struct inotify_event) <= w->pending_len) {
        struct inotify_event *ev = (struct inotify_event *)(w->pending + w->pending_at);
        int64_t rec = (int64_t)sizeof(struct inotify_event) + ev->len;
        if (w->pending_at + rec > w->pending_len) break;
        w->pending_at += rec;
        uint32_t mask = ev->mask;
        int isdir = (mask & IN_ISDIR) ? EV_ISDIR : 0;
        if (mask & IN_Q_OVERFLOW) {
            // The queue of the kernel dropped events. The tree is the
            // truth now: a new look gives the difference.
            if (cmp_files(w)) return;
            continue;
        }
        if (mask & (IN_IGNORED | IN_DELETE_SELF)) {
            drop_watch(w, ev->wd);
            continue;
        }
        char path[MAX_PATH];
        event_path(w, ev, path, MAX_PATH);
        if (mask & IN_MOVED_FROM) {
            uint32_t cookie = ev->cookie;
            char from[MAX_PATH];
            snprintf(from, MAX_PATH, "%s", path);
            int found = find_pair(w, w->pending_at, cookie, path, MAX_PATH);
            if (!found) {
                // The second event may be in the next read. Wait a
                // moment for it.
                if (fill_more(w, 10)) {
                    found = find_pair(w, w->pending_at, cookie, path, MAX_PATH);
                }
            }
            if (found) {
                queue_push(w, EV_RENAMED | isdir, path, from);
            } else {
                queue_push(w, EV_DELETED | isdir, from, NULL);
            }
            continue;
        }
        int kind = EV_NONE;
        if (mask & (IN_CREATE | IN_MOVED_TO)) kind = EV_CREATED;
        else if (mask & (IN_DELETE | IN_DELETE_SELF)) kind = EV_DELETED;
        else if (mask & IN_ATTRIB) kind = EV_ATTRIB;
        else if (mask & (IN_MODIFY | IN_CLOSE_WRITE)) kind = EV_MODIFIED;
        else if (mask & IN_MOVE_SELF) kind = EV_NONE;
        if (kind == EV_NONE) continue;
        if (kind == EV_CREATED && isdir && w->recursive) {
            // The directory is a change of its own. Its subtree is
            // new too, so the scan queues the entries of it.
            queue_push(w, EV_CREATED | EV_ISDIR, path, NULL);
            watch_subtree(w, path, 0);
            continue;
        }
        queue_push(w, kind | isdir, path, NULL);
    }
    // The rest of the buffer is not a whole event, so it goes.
    if (w->pending_at >= w->pending_len) {
        w->pending_at = 0;
        w->pending_len = 0;
    }
}

#endif

// watch_backend gives the name of the watcher of the system: "inotify"
// or "compare".
int watch_backend(gs_rref out_name) {
    const char *name = watch_use_inotify() ? "inotify" : "compare";
    gs_bld_append(out_name, name, (int64_t)strlen(name));
    return 1;
}

// watch_open opens a watcher on the path. It gives 1 on success and 0
// when the path is missing or is not a directory.
int watch_open(watch_slice path, int recursive, int32_t *handle_out) {
    char dir[MAX_PATH];
    int64_t len = path.len;
    if (len <= 0 || len >= (int64_t)sizeof(dir)) return 0;
    memcpy(dir, path.data, (size_t)len);
    dir[len] = 0;
    if (!is_dir(dir)) return 0;
    int slot = -1;
    for (int i = 0; i < MAX_WATCHERS; i++) {
        if (!g_watchers[i].used) { slot = i; break; }
    }
    if (slot < 0) return 0;
    watcher_t *w = &g_watchers[slot];
    memset(w, 0, sizeof(*w));
    w->fd = -1;
    w->used = 1;
    w->recursive = recursive ? 1 : 0;
    w->follow = 0;
    w->interval = DEFAULT_INTERVAL_MS;
    snprintf(w->root, MAX_PATH, "%s", dir);
    if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
        w->fd = inotify_init1(IN_NONBLOCK);
        if (w->fd < 0) { w->used = 0; return 0; }
        w->pending_cap = 65536;
        w->pending = (uint8_t *)malloc((size_t)w->pending_cap);
        if (!w->pending) { close(w->fd); w->used = 0; return 0; }
        // The watch of the root and, when the watcher is deep, of
        // each directory of the tree. The subtree scan queues the
        // entries that came before their watch; a shallow watcher
        // keeps only the watch of the root.
        watch_subtree(w, w->root, 0);
        w->nqueue = 0;
#endif
    } else {
        if (!prime(w)) { w->used = 0; return 0; }
    }
    *handle_out = (int32_t)slot + 1;
    return 1;
}

// watch_close ends a watcher. It gives 1 when the watcher was open.
int watch_close(int32_t handle) {
    if (handle <= 0 || handle > MAX_WATCHERS) return 0;
    watcher_t *w = &g_watchers[handle - 1];
    if (!w->used) return 0;
#if WATCH_HAS_INOTIFY
    if (w->fd >= 0) close(w->fd);
#endif
    free(w->pending);
    free(w->queue);
    free(w->wds);
    free(w->files);
    memset(w, 0, sizeof(*w));
    return 1;
}

// watch_next waits for the next change. It gives the kind of the
// change, with bit 8 set when the path is a directory, and puts the
// path of the change in the buffer of the caller.
int watch_next(int32_t handle, int32_t timeout_ms, gs_rref out_path) {
    if (handle <= 0 || handle > MAX_WATCHERS) return EV_NONE;
    watcher_t *w = &g_watchers[handle - 1];
    if (!w->used) return EV_NONE;
    // A timeout of 0 waits with no limit. A negative timeout does not
    // wait at all.
    int wait = timeout_ms > 0 ? (int)timeout_ms : (timeout_ms == 0 ? -1 : 0);
    w->old[0] = 0;
    for (;;) {
        if (w->nqueue > 0) {
            queued *q = &w->queue[0];
            int kind = q->kind;
            snprintf(w->old, MAX_PATH, "%s", q->old);
            gs_bld_append(out_path, q->path, (int64_t)strlen(q->path));
            memmove(&w->queue[0], &w->queue[1],
                    (size_t)(w->nqueue - 1) * sizeof(queued));
            w->nqueue -= 1;
            return kind;
        }
#if WATCH_HAS_INOTIFY
        if (watch_use_inotify()) {
            handle_inotify(w, wait);
            if (w->nqueue > 0) continue;
            return EV_NONE;
        }
#endif
        // The comparison watcher waits in short steps and checks the
        // tree. A timeout of 0 waits with no limit, so the steps go
        // on.
        int64_t step = w->interval;
        int64_t left = wait > 0 ? wait : 0;
        if (!cmp_files(w)) return EV_NONE;
        while (w->nqueue == 0 && wait != 0 && (wait < 0 || left > 0)) {
            // The last pause is as short as the time that is left, so
            // a long interval does not make the call late.
            int64_t pause = (wait > 0 && left < step) ? left : step;
#ifdef _WIN32
            Sleep((DWORD)pause);
#else
            struct pollfd p = { .fd = 0, .events = 0 };
            poll(&p, 1, (int)pause);
#endif
            left -= pause;
            if (!cmp_files(w)) return EV_NONE;
        }
        if (w->nqueue == 0) return EV_NONE;
    }
}

// watch_old puts the old path of the last event in the buffer of the
// caller. It gives 1 when the last event was a rename with an old path.
int watch_old(int32_t handle, gs_rref out_path) {
    if (handle <= 0 || handle > MAX_WATCHERS) return 0;
    watcher_t *w = &g_watchers[handle - 1];
    if (!w->used || w->old[0] == 0) return 0;
    gs_bld_append(out_path, w->old, (int64_t)strlen(w->old));
    return 1;
}

// The keys of watch_set.
#define SET_INTERVAL 1
#define SET_FOLLOW 2

// watch_set changes one setting of an open watcher. The call has three
// slots, so the C API stays narrow for every new setting. It gives 1 on
// success.
int watch_set(int32_t handle, int32_t key, int32_t value) {
    if (handle <= 0 || handle > MAX_WATCHERS) return 0;
    watcher_t *w = &g_watchers[handle - 1];
    if (!w->used) return 0;
    if (key == SET_INTERVAL) {
        if (value < 1 || value > MAX_INTERVAL_MS) return 0;
        w->interval = (int)value;
        return 1;
    }
    if (key == SET_FOLLOW) {
        int follow = value ? 1 : 0;
        if (follow == w->follow) return 1;
        w->follow = follow;
        // The tree is another one now, so the watcher looks at it
        // again. The watch of each directory that is visible now is
        // set, and the list of the entries is made again. The events
        // of the first look are not given to the caller.
        if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
            watch_subtree(w, w->root, 0);
            prime(w);
            w->nqueue = 0;
#endif
        } else {
            prime(w);
        }
        return 1;
    }
    return 0;
}

// watch_test_chmod changes the mode of a path. The tests use it,
// because the standard library has no call for it. The mode holds the
// bits of POSIX. On Windows the call does nothing and gives 0.
//
// It gives 1 when the mode is set. It gives 0 on Windows or on a
// fault.
int watch_test_chmod(watch_slice path, int mode) {
#ifdef _WIN32
    (void)path;
    (void)mode;
    return 0;
#else
    char buf[MAX_PATH];
    if (path.len <= 0 || path.len >= (int64_t)sizeof(buf)) return 0;
    memcpy(buf, path.data, (size_t)path.len);
    buf[path.len] = 0;
    if (chmod(buf, (mode_t)mode) != 0) return 0;
    return 1;
#endif
}

// watch_test_symlink makes a symbolic link. The tests use it, because
// the standard library has no call for it.
//
// It gives 1 when the link is there. It gives 0 when the system does
// not allow symbolic links. It gives -1 when the call fails.
int watch_test_symlink(watch_slice target, watch_slice link_path) {
    char a[MAX_PATH], b[MAX_PATH];
    if (target.len <= 0 || target.len >= MAX_PATH) return -1;
    if (link_path.len <= 0 || link_path.len >= MAX_PATH) return -1;
    memcpy(a, target.data, (size_t)target.len);
    a[target.len] = 0;
    memcpy(b, link_path.data, (size_t)link_path.len);
    b[link_path.len] = 0;
#ifdef _WIN32
    // Windows gives the right to make a symbolic link to the
    // administrators and to the systems with developer mode.
    //
    // The target of a link on Windows holds backslashes. A target with
    // a slash gives the error ERROR_INVALID_NAME when the link is
    // opened.
    wchar_t wtarget[MAX_PATH];
    wchar_t wlink[MAX_PATH];
    if (!win_wide(a, wtarget, MAX_PATH)) return -1;
    if (!win_wide(b, wlink, MAX_PATH)) return -1;
    for (int i = 0; wtarget[i]; i++) {
        if (wtarget[i] == L'/') wtarget[i] = L'\\';
    }
    DWORD flags = SYMBOLIC_LINK_FLAG_DIRECTORY;
    if (CreateSymbolicLinkW(wlink, wtarget, flags)) return 1;
    if (GetLastError() == ERROR_INVALID_PARAMETER) {
        flags |= SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
        if (CreateSymbolicLinkW(wlink, wtarget, flags)) return 1;
    }
    return 0;
#else
    if (symlink(a, b) == 0) return 1;
    return -1;
#endif
}
