// The C part of the goose-watch package.
//
// It watches a directory and gives the path and the kind of each
// change. On Linux the package uses inotify. On macOS and Windows the
// package compares the times and the sizes of the files. Both give the
// same kinds, so the caller does not need to know the system.
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

#define MAX_WATCHERS 16
#define MAX_DEPTH 32
#ifdef _WIN32
// The header of Windows gives this name another value.
#undef MAX_PATH
#endif
#define MAX_PATH 1024
#define MAX_EVENTS 4096
#define MAX_DIRS 512
#define MAX_FILES 1024
#define DEFAULT_INTERVAL_MS 50
#define MAX_INTERVAL_MS 60000

// One watched directory, for the inotify watcher.
typedef struct {
    int wd;
    char path[MAX_PATH];
} wd_entry;

// One file, for the comparison watcher.
typedef struct {
    char path[MAX_PATH];
    long long mtime;
    long long size;
    long long ino;
} file_entry;

// The tables of a watcher are on the heap, so a program that opens one
// watcher does not pay for the tables of the other ones.
typedef struct {
    int used;
    int recursive;
    // The rule for a symbolic link: 1 follows it, 0 does not.
    int follow;
    // The pause between two looks of the comparison watcher, in ms.
    int interval;
    // The old path of the last rename event, empty for the others.
    char old[MAX_PATH];
    char root[MAX_PATH];
    int fd;
    // The events that wait in the buffer of the watcher.
    uint8_t pending[MAX_EVENTS];
    int64_t pending_len;
    int64_t pending_at;
    wd_entry *wds;
    int nwds;
    file_entry *files;
    int nfiles;
} watcher_t;

static watcher_t g_watchers[MAX_WATCHERS];

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

// is_dir tells whether the path names a directory.
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
#else
static int is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode);
}
#endif

#ifndef _WIN32
// collect_dirs puts the root and, when the flag is set, each
// subdirectory into the list. It gives the number of directories.
//
// The walk uses a stack. Each step pops one directory and then pushes
// its subdirectories, so the stack holds the directories that wait.
static int collect_dirs(const char *root, int recursive, int follow,
                        char out[][MAX_PATH], int cap) {
    int n = 0;
    char stack[MAX_DEPTH][MAX_PATH];
    // The depth of each entry of the stack. The depth is the depth in
    // the tree, not the place in the stack.
    int depths[MAX_DEPTH];
    int top = 0;
    snprintf(stack[0], MAX_PATH, "%s", root);
    depths[0] = 0;
    while (top >= 0) {
        char dir[MAX_PATH];
        int level = depths[top];
        snprintf(dir, MAX_PATH, "%s", stack[top]);
        top -= 1;
        if (n < cap) {
            snprintf(out[n], MAX_PATH, "%s", dir);
            n += 1;
        }
        if (!recursive) continue;
        DIR *dp = opendir(dir);
        if (!dp) continue;
        struct dirent *e;
        while ((e = readdir(dp)) != NULL) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
            char full[MAX_PATH];
            path_join(full, MAX_PATH, dir, e->d_name);
            struct stat st;
            // A symbolic link is followed only when the caller asks.
            if ((follow ? stat(full, &st) : lstat(full, &st)) != 0 || !S_ISDIR(st.st_mode)) continue;
            // The tree is deeper than the limit.
            if (level + 1 >= MAX_DEPTH) continue;
            if (top + 1 >= MAX_DEPTH) continue;
            top += 1;
            depths[top] = level + 1;
            snprintf(stack[top], MAX_PATH, "%s", full);
        }
        closedir(dp);
    }
    return n;
}
#endif

#if 1
// The comparison watcher. It walks the tree and keeps the time and the
// size of every file.

// The new list of the files of a walk.
static file_entry g_fresh[MAX_FILES];

// cmp_entries puts the new list of files next to the old list and
// gives the first change. It gives EV_NONE when nothing changed.
static int cmp_entries(watcher_t *w, file_entry *fresh, int nfresh,
                        char *out_path, int64_t out_cap) {
    // A path that is new gives created. The path joins the list of the
    // watcher, so the next walk knows it.
    for (int i = 0; i < nfresh; i++) {
        int known = 0;
        for (int j = 0; j < w->nfiles; j++) {
            if (strcmp(w->files[j].path, fresh[i].path) == 0) { known = 1; break; }
        }
        if (known) continue;
        // A known file that left its path and kept its inode is the
        // same file under a new name: a rename.
        for (int j = 0; j < w->nfiles; j++) {
            if (w->files[j].ino != fresh[i].ino) continue;
            int still = 0;
            for (int k = 0; k < nfresh; k++) {
                if (strcmp(fresh[k].path, w->files[j].path) == 0) { still = 1; break; }
            }
            if (still) continue;
            snprintf(w->old, MAX_PATH, "%s", w->files[j].path);
            memcpy(&w->files[j], &fresh[i], sizeof(file_entry));
            snprintf(out_path, (size_t)out_cap, "%s", fresh[i].path);
            return EV_RENAMED;
        }
        if (w->nfiles < MAX_FILES) {
            memcpy(&w->files[w->nfiles], &fresh[i], sizeof(file_entry));
            w->nfiles += 1;
        }
        snprintf(out_path, (size_t)out_cap, "%s", fresh[i].path);
        return EV_CREATED;
    }
    // A path that is gone gives deleted. The path leaves the list, so
    // the next walk does not give it again.
    for (int j = 0; j < w->nfiles; j++) {
        int still = 0;
        for (int i = 0; i < nfresh; i++) {
            if (strcmp(fresh[i].path, w->files[j].path) == 0) { still = 1; break; }
        }
        if (still) continue;
        char gone[MAX_PATH];
        snprintf(gone, MAX_PATH, "%s", w->files[j].path);
        for (int k = j; k + 1 < w->nfiles; k++) {
            memcpy(&w->files[k], &w->files[k + 1], sizeof(file_entry));
        }
        w->nfiles -= 1;
        snprintf(out_path, (size_t)out_cap, "%s", gone);
        return EV_DELETED;
    }
    // A path with another time or size gives modified.
    for (int i = 0; i < nfresh; i++) {
        for (int j = 0; j < w->nfiles; j++) {
            if (strcmp(fresh[i].path, w->files[j].path) != 0) continue;
            if (fresh[i].mtime == w->files[j].mtime && fresh[i].size == w->files[j].size) continue;
            memcpy(&w->files[j], &fresh[i], sizeof(file_entry));
            snprintf(out_path, (size_t)out_cap, "%s", fresh[i].path);
            return EV_MODIFIED;
        }
    }
    return EV_NONE;
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

// win_stat gives the attributes, the time, the size and the number of
// the file of the path. The number stays the same when the file gets
// another name. A followed link gives the file of the target. It gives
// 0 when the path cannot be opened.
static int win_stat(const char *path, int follow, BY_HANDLE_FILE_INFORMATION *info) {
    HANDLE h = win_open(path, follow);
    if (h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "watch debug: cannot open %s follow %d error %lu\n", path, follow, (unsigned long)GetLastError());
        return 0;
    }
    int ok = GetFileInformationByHandle(h, info);
    if (!ok) fprintf(stderr, "watch debug: cannot read %s follow %d error %lu\n", path, follow, (unsigned long)GetLastError());
    CloseHandle(h);
    return ok;
}

// win_walk puts the files of the tree into the list. It gives the
// number of files.
//
// A symbolic link is a file of its own when the caller does not follow
// the links. A followed link gives the file of the target.
//
// The count of the directories stops the walk. A loop of links gives
// many paths of the same directory, and the walk ends then.
static int win_walk(const char *dir, int recursive, int follow, int depth,
                    int *ndirs, file_entry *fresh, int cap, int n) {
    if (*ndirs >= MAX_DIRS) return n;
    *ndirs += 1;
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
        int isdir = (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        fprintf(stderr, "watch debug: entry %s attrs %lu tag %lu\n", full, (unsigned long)found.dwFileAttributes, (unsigned long)found.dwReserved0);
        // Only a symbolic link is a link. A mount point and a cloud
        // file are reparse points of another kind.
        int islink = (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 &&
                     found.dwReserved0 == IO_REPARSE_TAG_SYMLINK;
        // A plain directory needs no open. The list of the directory
        // tells that it is one.
        if (isdir && !islink) {
            if (recursive && depth + 1 < MAX_DEPTH) {
                n = win_walk(full, recursive, follow, depth + 1, ndirs, fresh, cap, n);
            }
            continue;
        }
        BY_HANDLE_FILE_INFORMATION info;
        if (!win_stat(full, follow, &info)) {
            fprintf(stderr, "watch debug: skip %s attrs %lu tag %lu\n", full, (unsigned long)found.dwFileAttributes, (unsigned long)found.dwReserved0);
            continue;
        }
        if (follow) {
            // A followed link gives the file of the target.
            isdir = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        } else {
            // A link is a file of its own when the caller does not follow it.
            isdir = 0;
        }
        if (isdir) {
            if (recursive && depth + 1 < MAX_DEPTH) {
                n = win_walk(full, recursive, follow, depth + 1, ndirs, fresh, cap, n);
            }
        } else {
            if (n >= cap) break;
            snprintf(fresh[n].path, MAX_PATH, "%s", full);
            fresh[n].mtime = win_time_ns(info.ftLastWriteTime);
            fresh[n].size = ((long long)info.nFileSizeHigh << 32) | (long long)info.nFileSizeLow;
            fresh[n].ino = ((long long)info.nFileIndexHigh << 32) | (long long)info.nFileIndexLow;
            n += 1;
        }
    } while (FindNextFileW(h, &found));
    FindClose(h);
    return n;
}

// scan_files puts the files of the tree of the watcher into the list.
static int scan_files(watcher_t *w, file_entry *fresh, int cap) {
    int ndirs = 0;
    return win_walk(w->root, w->recursive, w->follow, 0, &ndirs, fresh, cap, 0);
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

// scan_files puts the files of the tree of the watcher into the list.
static int scan_files(watcher_t *w, file_entry *fresh, int cap) {
    int nfresh = 0;
    char dirs[MAX_DIRS][MAX_PATH];
    int ndirs = collect_dirs(w->root, w->recursive, w->follow, dirs, MAX_DIRS);
    for (int i = 0; i < ndirs; i++) {
        DIR *d = opendir(dirs[i]);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
            char full[MAX_PATH];
            path_join(full, MAX_PATH, dirs[i], e->d_name);
            struct stat st;
            if ((w->follow ? stat(full, &st) : lstat(full, &st)) != 0) continue;
            if (S_ISDIR(st.st_mode)) continue;
            if (nfresh >= cap) continue;
            snprintf(fresh[nfresh].path, MAX_PATH, "%s", full);
            fresh[nfresh].mtime = ST_MTIME_NS(st);
            fresh[nfresh].size = (long long)st.st_size;
            fresh[nfresh].ino = (long long)st.st_ino;
            nfresh += 1;
        }
        closedir(d);
    }
    return nfresh;
}

#endif

// cmp_files puts the new list of files next to the old list and gives
// the first change. It gives EV_NONE when nothing changed.
static int cmp_files(watcher_t *w, char *out_path, int64_t out_cap) {
    file_entry *fresh = g_fresh;
    int nfresh = scan_files(w, fresh, MAX_FILES);
    return cmp_entries(w, fresh, nfresh, out_path, out_cap);
}

// prime fills the list of the files with the files of the tree now.
static void prime(watcher_t *w) {
    int n = scan_files(w, g_fresh, MAX_FILES);
    if (n > 0) memcpy(w->files, g_fresh, (size_t)n * sizeof(file_entry));
    w->nfiles = n;
}
#endif

// The inotify watcher. It is only on Linux, because the calls of
// inotify do not exist on the other systems.
#if WATCH_HAS_INOTIFY

// add_watch puts a watch on the directory and remembers the path.
static int add_watch(watcher_t *w, const char *dir) {
    if (w->nwds >= MAX_DIRS) return -1;
    for (int i = 0; i < w->nwds; i++) {
        if (strcmp(w->wds[i].path, dir) == 0) return w->wds[i].wd;
    }
    int wd = inotify_add_watch(w->fd, dir,
        IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF);
    if (wd < 0) return -1;
    w->wds[w->nwds].wd = wd;
    snprintf(w->wds[w->nwds].path, MAX_PATH, "%s", dir);
    w->nwds += 1;
    return wd;
}

// The path of a watch descriptor.
static const char *wd_path(watcher_t *w, int wd) {
    for (int i = 0; i < w->nwds; i++) {
        if (w->wds[i].wd == wd) return w->wds[i].path;
    }
    return w->root;
}

// The event kind of an inotify mask.
static int mask_kind(uint32_t mask) {
    if (mask & (IN_CREATE | IN_MOVED_TO)) return EV_CREATED;
    if (mask & (IN_DELETE | IN_DELETE_SELF)) return EV_DELETED;
    if (mask & (IN_MOVED_FROM | IN_MOVE_SELF)) return EV_RENAMED;
    if (mask & (IN_MODIFY | IN_CLOSE_WRITE)) return EV_MODIFIED;
    return EV_NONE;
}

// fill_more reads more events behind the ones that wait. The events
// that wait move to the start of the buffer first. It gives 1 when it
// read something.
static int fill_more(watcher_t *w, int wait_ms) {
    int64_t keep = w->pending_len - w->pending_at;
    if (keep > 0 && w->pending_at > 0) {
        memmove(w->pending, w->pending + w->pending_at, (size_t)keep);
    }
    w->pending_len = keep > 0 ? keep : 0;
    w->pending_at = 0;
    if (w->pending_len >= (int64_t)sizeof(w->pending)) return 0;
    struct pollfd p = { .fd = w->fd, .events = POLLIN };
    if (poll(&p, 1, wait_ms) <= 0) return 0;
    ssize_t n = read(w->fd, w->pending + w->pending_len,
                     sizeof(w->pending) - (size_t)w->pending_len);
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

// read_inotify waits for one event and gives its kind and its path.
//
// The read gives many events at once. The events that wait stay in the
// buffer of the watcher, so no event goes missing. A move inside the
// tree comes as two events with one cookie. They join into one rename
// event: the path is the new path and w->old holds the old path. A move
// out of the tree has no second event and gives a removal.
static int read_inotify(watcher_t *w, int timeout_ms, char *out_path,
                        int64_t out_cap) {
    if (w->pending_at >= w->pending_len) {
        struct pollfd p = { .fd = w->fd, .events = POLLIN };
        int pr = poll(&p, 1, timeout_ms);
        if (pr <= 0) return EV_NONE;
        ssize_t n = read(w->fd, w->pending, sizeof(w->pending));
        if (n <= 0) return EV_NONE;
        w->pending_len = (int64_t)n;
        w->pending_at = 0;
    }
    for (;;) {
        int64_t at = w->pending_at;
        if (at + (int64_t)sizeof(struct inotify_event) > w->pending_len) break;
        struct inotify_event *ev = (struct inotify_event *)(w->pending + at);
        int64_t rec = (int64_t)sizeof(struct inotify_event) + ev->len;
        if (at + rec > w->pending_len) break;
        uint32_t mask = ev->mask;
        if (mask & IN_MOVED_FROM) {
            uint32_t cookie = ev->cookie;
            char from[MAX_PATH];
            event_path(w, ev, from, MAX_PATH);
            int found = find_pair(w, at + rec, cookie, out_path, out_cap);
            if (!found) {
                // The second event may be in the next read. Wait a
                // moment for it.
                w->pending_at = at;
                if (fill_more(w, 10)) {
                    found = find_pair(w, rec, cookie, out_path, out_cap);
                }
                at = w->pending_at;
            }
            w->pending_at = at + rec;
            if (found) {
                snprintf(w->old, MAX_PATH, "%s", from);
                return EV_RENAMED;
            }
            snprintf(out_path, (size_t)out_cap, "%s", from);
            return EV_DELETED;
        }
        w->pending_at = at + rec;
        int kind = mask_kind(mask);
        if (kind == EV_NONE) continue;
        event_path(w, ev, out_path, out_cap);
        return kind;
    }
    // The rest of the buffer is not a whole event, so it goes.
    w->pending_at = w->pending_len;
    return EV_NONE;
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
    w->wds = (wd_entry *)malloc((size_t)MAX_DIRS * sizeof(wd_entry));
    w->files = (file_entry *)malloc((size_t)MAX_FILES * sizeof(file_entry));
    if (!w->wds || !w->files) {
        free(w->wds);
        free(w->files);
        memset(w, 0, sizeof(*w));
        return 0;
    }
    w->used = 1;
    w->recursive = recursive ? 1 : 0;
    w->follow = 0;
    w->interval = DEFAULT_INTERVAL_MS;
    snprintf(w->root, MAX_PATH, "%s", dir);
    if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
        w->fd = inotify_init1(IN_NONBLOCK);
        if (w->fd < 0) { w->used = 0; return 0; }
        char dirs[MAX_DIRS][MAX_PATH];
        int ndirs = collect_dirs(dir, w->recursive, w->follow, dirs, MAX_DIRS);
        for (int i = 0; i < ndirs; i++) add_watch(w, dirs[i]);
#endif
    } else {
        prime(w);
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
    free(w->wds);
    free(w->files);
    memset(w, 0, sizeof(*w));
    return 1;
}

// watch_next waits for the next change. It gives the kind of the
// change, and puts the path of the change in the buffer of the caller.
int watch_next(int32_t handle, int32_t timeout_ms, gs_rref out_path) {
    if (handle <= 0 || handle > MAX_WATCHERS) return EV_NONE;
    watcher_t *w = &g_watchers[handle - 1];
    if (!w->used) return EV_NONE;
    // A timeout of 0 waits with no limit. The poll takes -1 for that.
    // A negative timeout does not wait at all.
    int wait = timeout_ms > 0 ? (int)timeout_ms : (timeout_ms == 0 ? -1 : 0);
    char path[MAX_PATH];
    path[0] = 0;
    w->old[0] = 0;
    int kind = EV_NONE;
    if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
        kind = read_inotify(w, wait, path, MAX_PATH);
#endif
    } else {
        // The comparison watcher waits in short steps and checks the
        // tree. A timeout of 0 waits with no limit, so the steps go on.
        int64_t step = w->interval;
        int64_t left = wait > 0 ? wait : 0;
        kind = cmp_files(w, path, MAX_PATH);
        while (kind == EV_NONE && wait != 0 && (wait < 0 || left > 0)) {
            // The last pause is as short as the time that is left, so a
            // long interval does not make the call late.
            int64_t pause = (wait > 0 && left < step) ? left : step;
#ifdef _WIN32
            Sleep((DWORD)pause);
#else
            struct pollfd p = { .fd = 0, .events = 0 };
            poll(&p, 1, (int)pause);
#endif
            left -= pause;
            kind = cmp_files(w, path, MAX_PATH);
        }
    }
    if (kind == EV_NONE) return EV_NONE;
    if (path[0] != 0) gs_bld_append(out_path, path, (int64_t)strlen(path));
    return kind;
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
        // The tree is another one now, so the watcher looks at it again.
        if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
            char dirs[MAX_DIRS][MAX_PATH];
            int ndirs = collect_dirs(w->root, w->recursive, w->follow, dirs, MAX_DIRS);
            for (int i = 0; i < ndirs; i++) add_watch(w, dirs[i]);
#endif
        } else {
            prime(w);
        }
        return 1;
    }
    return 0;
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
    wchar_t wtarget[MAX_PATH];
    wchar_t wlink[MAX_PATH];
    if (!win_wide(a, wtarget, MAX_PATH)) return -1;
    if (!win_wide(b, wlink, MAX_PATH)) return -1;
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
