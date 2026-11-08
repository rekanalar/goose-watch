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
import os;
import glob from "rekanalar/goose-glob@v1.2.0";

// The kinds of an event.
const KIND_NONE: i32 = 0;
const KIND_CREATED: i32 = 1;
const KIND_MODIFIED: i32 = 2;
const KIND_DELETED: i32 = 3;
const KIND_RENAMED: i32 = 4;
const KIND_ATTRIB: i32 = 5;

// The flag of a directory. It sits in bit 8 of the number that the C
// layer gives. The caller never sees it in a kind.
const FLAG_DIR: i32 = 0x100;

extern fn watch_open(dir: const u8[:], deep: i32, handle_out: i32&) -> bool;
extern fn watch_backend(out_name: u8[>..]&) -> bool;
extern fn watch_close(handle: i32) -> bool;
extern fn watch_next(handle: i32, timeout_ms: i32, out_path: u8[>..]&) -> i32;
extern fn watch_old(handle: i32, out_path: u8[>..]&) -> bool;
extern fn watch_set(handle: i32, key: i32, value: i32) -> bool;

// The keys of watch_set.
const SET_INTERVAL: i32 = 1;
const SET_FOLLOW: i32 = 2;

// Event holds one change. The paths are slices over the buffers of the
// caller. For a rename, the path is the new path and old_path is the
// old path. For every other kind, old_path is empty. The flag is_dir is
// true when the path is a directory.
struct Event {
    kind: i32,
    is_dir: bool,
    path: const u8[:],
    old_path: const u8[:],
}

// The event that says that no change came.
const NONE_EVENT = Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" };

// Group holds many watchers. next gives the next event of any one of
// them. The paths are slices over the buffers of the caller, as in
// Event.
struct Group {
    handles: i32[>..],
}

// Filter holds two lists of patterns. Each list is a text of patterns
// with a semicolon between them. An empty include list takes every
// path. A path that an ignore pattern takes is out, whatever the
// include list says.
struct Filter {
    include: const u8[:],
    ignore: const u8[:],
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
// the buffer of the caller. For a rename, the path is the new path and
// the old path is lost: use next_event to get it.
//
// It gives the event and true. The kind of the event is KIND_NONE when
// the wait ended with no change.
fn next(handle: i32, timeout_ms: i32, out_path: u8[>..]&) -> Event, bool {
    if handle <= 0 { return Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" }, false; }
    let raw = watch_next(handle, timeout_ms, out_path);
    if raw & 0xff == KIND_NONE { return Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" }, true; }
    let kind = raw & 0xff;
    return Event { kind: kind, is_dir: (raw & FLAG_DIR) != 0, path: out_path[..], old_path: "" }, true;
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
    if kind == KIND_ATTRIB { return "attrib"; }
    return "none";
}

// next_event is next with the old path of a rename. The old path goes
// out in the second buffer. Both buffers must outlive the event.
fn next_event(handle: i32, timeout_ms: i32, out_path: u8[>..]&, out_old: u8[>..]&) -> Event, bool {
    let e, ok = next(handle, timeout_ms, out_path);
    if !ok || e.kind != KIND_RENAMED { return e, ok; }
    if !watch_old(handle, out_old) { return e, true; }
    return Event { kind: e.kind, is_dir: e.is_dir, path: e.path, old_path: out_old[..] }, true;
}

// glob_match tells whether the text fits the pattern. The text is a whole
// path. The syntax is the syntax of the glob package: a * stops at a
// separator, a ** takes any number of segments, and a class of characters
// takes one byte.
fn glob_match(pattern: const u8[:], text: const u8[:]) -> bool {
    return glob::matches(text, pattern);
}

// base_name gives the part of the path after the last slash.
fn base_name(path: const u8[:]) -> const u8[:] {
    var i = path.len;
    while i > 0 && path[i - 1] != '/' { i -= 1; }
    return path[i..];
}

// any_match tells whether one pattern of the list fits the path. A
// pattern with no slash is tried on the name of the file. A pattern with
// a slash is tried on the whole path.
fn any_match(list: const u8[:], path: const u8[:]) -> bool {
    var start: i64 = 0;
    var i: i64 = 0;
    while i <= list.len {
        if i == list.len || list[i] == ';' {
            let pat = list[start..i];
            if pat.len > 0 {
                var slash = false;
                for c in pat { if c == '/' { slash = true; } }
                if slash {
                    if glob::matches(path, pat) { return true; }
                } else {
                    if glob::match_name(base_name(path), pat) { return true; }
                }
            }
            start = i + 1;
        }
        i += 1;
    }
    return false;
}

// allowed tells whether the filter lets the path through.
fn allowed(f: Filter, path: const u8[:]) -> bool {
    if f.ignore.len > 0 && any_match(f.ignore, path) { return false; }
    if f.include.len > 0 { return any_match(f.include, path); }
    return true;
}

// next_filtered is next_event with a filter. An event that the filter
// refuses is dropped and the wait goes on. The timeout covers the whole
// wait, not each event. A rename passes when the new path or the old
// path passes.
fn next_filtered(handle: i32, timeout_ms: i32, f: Filter, out_path: u8[>..]&, out_old: u8[>..]&) -> Event, bool {
    let start = clock_ns();
    while true {
        var left: i32 = timeout_ms;
        if timeout_ms > 0 {
            let spent = ((clock_ns() - start) / 1000000) as i32;
            if spent >= timeout_ms { return Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" }, true; }
            left = timeout_ms - spent;
        }
        out_path.clear();
        out_old.clear();
        let e, ok = next_event(handle, left, out_path, out_old);
        if !ok { return e, false; }
        if e.kind == KIND_NONE { return e, true; }
        if allowed(f, e.path) || (e.old_path.len > 0 && allowed(f, e.old_path)) { return e, true; }
        // A negative timeout does not wait, so the loop must end.
        if timeout_ms < 0 { return Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" }, true; }
    }
    return Event { kind: KIND_NONE, is_dir: false, path: "", old_path: "" }, true;
}

// set_poll_interval sets the pause between two looks of the comparison
// watcher, in milliseconds, from 1 to 60000. The default is 50. The
// inotify watcher does not poll, so the value has no effect on it. It
// gives false for a closed watcher or a value out of range.
fn set_poll_interval(handle: i32, ms: i32) -> bool {
    if handle <= 0 { return false; }
    return watch_set(handle, SET_INTERVAL, ms);
}

// set_follow_symlinks sets the rule for a symbolic link. With true, the
// watcher goes into a linked directory and sees the linked files. The
// default is false. A change takes effect at once, and the comparison
// watcher takes a new look at the tree. It gives false for a closed
// watcher.
fn set_follow_symlinks(handle: i32, follow: bool) -> bool {
    if handle <= 0 { return false; }
    return watch_set(handle, SET_FOLLOW, if follow { 1 } else { 0 });
}

// next_batch waits for a first change, then keeps reading until no
// change comes for quiet_ms. It merges the changes of one path into one
// event: a create and a modify give a create, a create and a delete give
// nothing, a delete and a create give a modify, a modify and a delete
// give a delete. The paths go on the store, and the merged events go on
// the events list, in the order of their first change. The list is
// empty when the first wait ended with no change.
//
// The timeout is the wait for the first change, as in next. The store
// must outlive the events.
fn next_batch(handle: i32, timeout_ms: i32, quiet_ms: i32, f: Filter, store: u8[>..]&, events: Event[>..]&) -> bool {
    var raw: Event[>..] = [];
    var keep: u8[>..] = [];
    var buf: u8[>..] = [];
    var old: u8[>..] = [];
    var wait = timeout_ms;
    while true {
        buf.clear();
        old.clear();
        let e, ok = next_filtered(handle, wait, f, buf, old);
        if !ok { return false; }
        if e.kind == KIND_NONE { break; }
        // The path goes on the store at once, so it outlives the buffer.
        let a = store.len;
        store.append(e.path);
        let b = store.len;
        store.append(e.old_path);
        let c = store.len;
        merge_event(raw, e.kind, e.is_dir, store[a..b], store[b..c]);
        wait = if quiet_ms > 0 { quiet_ms } else { -1 };
    }
    for r in raw {
        if r.kind != KIND_NONE { events.push(r); }
    }
    return true;
}

// merge_event puts one change into the list, and joins it with an
// earlier change of the same path.
fn merge_event(raw: Event[>..]&, kind: i32, is_dir: bool, path: const u8[:], old_path: const u8[:]) {
    if kind != KIND_RENAMED {
        var i: i64 = 0;
        while i < raw.len {
            if raw[i].kind != KIND_NONE && raw[i].kind != KIND_RENAMED && raw[i].path == path {
                let before = raw[i].kind;
                var now = kind;
                if before == KIND_CREATED && kind == KIND_MODIFIED { now = KIND_CREATED; }
                else if before == KIND_CREATED && kind == KIND_DELETED { now = KIND_NONE; }
                else if before == KIND_DELETED && kind == KIND_CREATED { now = KIND_MODIFIED; }
                else if before == KIND_MODIFIED && kind == KIND_MODIFIED { now = KIND_MODIFIED; }
                // An attribute change changes nothing in the content.
                // It stays when it comes alone. It joins the kind that
                // is there, except after a delete: a change of the
                // mode of a gone file is no event.
                else if before == KIND_ATTRIB { now = kind; }
                else if kind == KIND_ATTRIB && before != KIND_DELETED { now = before; }
                raw[i] = Event { kind: now, is_dir: raw[i].is_dir || is_dir, path: raw[i].path, old_path: "" };
                return;
            }
            i += 1;
        }
    }
    raw.push(Event { kind: kind, is_dir: is_dir, path: path, old_path: old_path });
}

// group_add opens a watcher on the path and puts it in the group. It
// gives the place of the watcher in the group, or -1 when the path is
// missing or the group is full. A group holds up to 64 watchers.
fn group_add(g: Group&, dir: const u8[:], deep: bool) -> i32 {
    let h = start(dir, deep);
    if h <= 0 { return -1; }
    g.handles.push(h);
    return g.handles.len as i32 - 1;
}

// group_next waits for the next event of any watcher of the group. The
// wait goes to each watcher in turn, until the whole timeout is spent.
// The place of the watcher that gave the event goes out in `which`. The
// paths go out in the buffers of the caller. It gives the event and
// true. The kind is KIND_NONE when the wait ended with no event.
fn group_next(g: Group&, timeout_ms: i32, which: i32&, out_path: u8[>..]&, out_old: u8[>..]&) -> Event, bool {
    which = -1;
    let start_ns = clock_ns();
    // A timeout of 0 waits with no limit. The loop then runs until an
    // event comes, and each round is one pass over the group.
    var rounds: i64 = 1;
    if timeout_ms == 0 { rounds = -1; }
    var round: i64 = 0;
    while rounds < 0 || round < rounds {
        var i: i64 = 0;
        while i < g.handles.len {
            var left: i32 = timeout_ms;
            if timeout_ms > 0 {
                let spent = ((clock_ns() - start_ns) / 1000000) as i32;
                if spent >= timeout_ms { return NONE_EVENT, true; }
                left = timeout_ms - spent;
            }
            var slice: i32 = 20;
            if left >= 0 && left < slice { slice = left; }
            let e, ok = next_event(g.handles[i], slice, out_path, out_old);
            if !ok { return e, false; }
            if e.kind != KIND_NONE {
                which = i as i32;
                return e, true;
            }
            i += 1;
        }
        if timeout_ms < 0 { return NONE_EVENT, true; }
        round += 1;
    }
    return NONE_EVENT, true;
}

// group_remove stops the watcher at the place and takes it out of the
// group. The places after it move down by one. It gives false when the
// place is out of the group.
fn group_remove(g: Group&, which: i32) -> bool {
    if which < 0 || which >= g.handles.len { return false; }
    stop(g.handles[which]);
    var i: i64 = which;
    while i + 1 < g.handles.len {
        g.handles[i] = g.handles[i + 1];
        i += 1;
    }
    g.handles.pop();
    return true;
}

// group_close stops every watcher of the group and empties it.
fn group_close(g: Group&) {
    var i: i64 = 0;
    while i < g.handles.len {
        stop(g.handles[i]);
        i += 1;
    }
    while g.handles.len > 0 { g.handles.pop(); }
}
