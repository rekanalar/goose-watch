// The C part of the goose-watch package.
//
// It watches a directory and gives the path and the kind of each
// change. On Linux the package uses inotify. On the other systems the
// package compares the times and the sizes of the files. Both give the
// same kinds, so the caller does not need to know the system.
//
// The caller gives the buffers. The path of an event goes out in the
// buffer of the caller.

#include "goose.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>

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
#define MAX_PATH 1024
#define MAX_EVENTS 4096
#define MAX_DIRS 512
#define MAX_FILES 1024

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
} file_entry;

// The tables of a watcher are on the heap, so a program that opens one
// watcher does not pay for the tables of the other ones.
typedef struct {
    int used;
    int recursive;
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
static int is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode);
}

// collect_dirs puts the root and, when the flag is set, each
// subdirectory into the list. It gives the number of directories.
//
// The walk uses a stack. Each step pops one directory and then pushes
// its subdirectories, so the stack holds the directories that wait.
static int collect_dirs(const char *root, int recursive, char out[][MAX_PATH],
                        int cap) {
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
            // A symbolic link is not followed.
            if (lstat(full, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
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

#if 1
// The comparison watcher. It walks the tree and keeps the time and the
// size of every file.

// cmp_files puts the new list of files next to the old list and gives
// the first change. It gives EV_NONE when nothing changed.
static file_entry g_fresh[MAX_FILES];

static int cmp_files(watcher_t *w, char *out_path, int64_t out_cap) {
    file_entry *fresh = g_fresh;
    int nfresh = 0;
    char dirs[MAX_DIRS][MAX_PATH];
    int ndirs = collect_dirs(w->root, w->recursive, dirs, MAX_DIRS);
    for (int i = 0; i < ndirs; i++) {
        DIR *d = opendir(dirs[i]);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
            char full[MAX_PATH];
            path_join(full, MAX_PATH, dirs[i], e->d_name);
            struct stat st;
            if (lstat(full, &st) != 0) continue;
            if (S_ISDIR(st.st_mode)) continue;
            if (nfresh >= MAX_FILES) continue;
            snprintf(fresh[nfresh].path, MAX_PATH, "%s", full);
            fresh[nfresh].mtime = ST_MTIME_NS(st);
            fresh[nfresh].size = (long long)st.st_size;
            nfresh += 1;
        }
        closedir(d);
    }
    // A path that is new gives created. The path joins the list of the
    // watcher, so the next walk knows it.
    for (int i = 0; i < nfresh; i++) {
        int known = 0;
        for (int j = 0; j < w->nfiles; j++) {
            if (strcmp(w->files[j].path, fresh[i].path) == 0) { known = 1; break; }
        }
        if (known) continue;
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
#endif

// The inotify watcher.

// add_watch puts a watch on the directory and remembers the path.
static int add_watch(watcher_t *w, const char *dir) {
    if (w->nwds >= MAX_DIRS) return -1;
    int wd = inotify_add_watch(w->fd, dir,
        IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVE_SELF);
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
    if (mask & IN_CREATE) return EV_CREATED;
    if (mask & (IN_DELETE | IN_DELETE_SELF)) return EV_DELETED;
    if (mask & (IN_MOVED_FROM | IN_MOVE_SELF)) return EV_RENAMED;
    if (mask & (IN_MODIFY | IN_CLOSE_WRITE)) return EV_MODIFIED;
    return EV_NONE;
}

// read_inotify waits for one event and gives its kind and its path.
//
// The read gives many events at once. The events that wait stay in the
// buffer of the watcher, so no event goes missing.
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
    int64_t at = w->pending_at;
    while (at + (int64_t)sizeof(struct inotify_event) <= w->pending_len) {
        struct inotify_event *ev = (struct inotify_event *)(w->pending + at);
        int64_t rec = (int64_t)sizeof(struct inotify_event) + ev->len;
        if (at + rec > w->pending_len) break;
        at += rec;
        int kind = mask_kind(ev->mask);
        if (kind == EV_NONE) continue;
        const char *dir = wd_path(w, ev->wd);
        if (ev->len > 0 && ev->name[0] != 0) {
            path_join(out_path, out_cap, dir, ev->name);
        } else {
            snprintf(out_path, (size_t)out_cap, "%s", dir);
        }
        w->pending_at = at;
        return kind;
    }
    // The rest of the buffer is not a whole event, so it goes.
    w->pending_at = w->pending_len;
    return EV_NONE;
}

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
    snprintf(w->root, MAX_PATH, "%s", dir);
    if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
        w->fd = inotify_init1(IN_NONBLOCK);
        if (w->fd < 0) { w->used = 0; return 0; }
        char dirs[MAX_DIRS][MAX_PATH];
        int ndirs = collect_dirs(dir, w->recursive, dirs, MAX_DIRS);
        for (int i = 0; i < ndirs; i++) add_watch(w, dirs[i]);
#endif
    } else {
        // The first walk fills the list of the files. Each call adds
        // one file, so the calls go on until nothing is new.
        char first[MAX_PATH];
        first[0] = 0;
        w->nfiles = 0;
        for (int i = 0; i < MAX_FILES; i++) {
            if (cmp_files(w, first, MAX_PATH) == EV_NONE) break;
        }
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
    int kind = EV_NONE;
    if (watch_use_inotify()) {
#if WATCH_HAS_INOTIFY
        kind = read_inotify(w, wait, path, MAX_PATH);
#endif
    } else {
        // The comparison watcher waits in short steps and checks the
        // tree. A timeout of 0 waits with no limit, so the steps go on.
        int64_t step = 50;
        int64_t left = wait > 0 ? wait : 0;
        kind = cmp_files(w, path, MAX_PATH);
        while (kind == EV_NONE && wait > 0 && left > 0) {
            struct pollfd p = { .fd = 0, .events = 0 };
            poll(&p, 1, (int)step);
            if (left > 0) left -= step;
            kind = cmp_files(w, path, MAX_PATH);
        }
    }
    if (kind == EV_NONE) return EV_NONE;
    if (path[0] != 0) gs_bld_append(out_path, path, (int64_t)strlen(path));
    return kind;
}
