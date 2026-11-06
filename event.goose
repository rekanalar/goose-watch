// The file watching API for the watch package.
//
// The package watches a directory and gives the path and the kind of
// each change. The kinds are the same on every system.
//
// A watcher takes a buffer for the path of the event. The path of the
// event is a slice over that buffer, so the buffer must outlive the
// event.
namespace watch;

import std;

// The kinds of an event.
const KIND_NONE: i32 = 0;
const KIND_CREATED: i32 = 1;
const KIND_MODIFIED: i32 = 2;
const KIND_DELETED: i32 = 3;
const KIND_RENAMED: i32 = 4;

extern fn watch_open(dir: const u8[:], deep: i32, handle_out: i32&) -> bool;
extern fn watch_backend(out_name: u8[>..]&) -> bool;
extern fn watch_close(handle: i32) -> bool;
extern fn watch_next(handle: i32, timeout_ms: i32, out_path: u8[>..]&) -> i32;

// Event holds one change. The path is a slice over the buffer of the
// caller.
struct Event {
    kind: i32,
    path: const u8[:],
}

// start starts a watcher on the path. The flag asks for the
// subdirectories. It gives the handle, or 0 when the path is missing
// or is not a directory.
fn start(dir: const u8[:], deep: bool) -> i32 {
    var handle: i32 = 0;
    var flag: i32 = 0;
    if deep { flag = 1; }
    let ok = watch_open(dir, flag, handle);
    if !ok { return 0; }
    return handle;
}

// stop ends a watcher. It gives false when the watcher was not open.
fn stop(handle: i32) -> bool {
    if handle <= 0 { return false; }
    return watch_close(handle);
}

// next waits for the next change. The timeout is in milliseconds. A
// timeout of 0 waits with no limit. The path of the change goes out in
// the buffer of the caller.
//
// It gives the event and true. The kind of the event is KIND_NONE when
// the wait ended with no change.
fn next(handle: i32, timeout_ms: i32, out_path: u8[>..]&) -> Event, bool {
    if handle <= 0 { return Event { kind: KIND_NONE, path: "" }, false; }
    let kind = watch_next(handle, timeout_ms, out_path);
    if kind == KIND_NONE { return Event { kind: KIND_NONE, path: "" }, true; }
    return Event { kind: kind, path: out_path[..] }, true;
}

// backend gives the name of the watcher of the system. It gives
// "inotify" on Linux and "compare" on the other systems. The
// environment variable GOOSE_WATCH_COMPARE asks for the comparison
// watcher on every system.
fn backend(out_name: u8[>..]&) -> const u8[:] {
    if !watch_backend(out_name) { return "compare"; }
    return out_name[..];
}

// kind_name gives the name of a kind. It gives "none" for an unknown
// kind.
fn kind_name(kind: i32) -> const u8[:] {
    if kind == KIND_CREATED { return "created"; }
    if kind == KIND_MODIFIED { return "modified"; }
    if kind == KIND_DELETED { return "deleted"; }
    if kind == KIND_RENAMED { return "renamed"; }
    return "none";
}
