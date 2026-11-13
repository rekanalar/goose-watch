// The helpers of the watch tests. They wait for the events and clean the directories.
namespace watch_helpers;

import std;
import os;
import watch from "..";


// remove_level_dirs removes the chain of the directories named
// "level". The chain goes from the deepest directory up, because a
// directory can only go when it is empty.
fn remove_level_dirs(base: const u8[:], count: i32) {
    var i = count;
    while i > 0 {
        var dir: u8[>..] = [];
        dir.append(base[..]);
        var j = 0;
        while j < i {
            dir.append("/level");
            j += 1;
        }
        delete_dir(dir[..]);
        i -= 1;
    }
}

// wait_kind waits for an event of the kind. Other kinds do not stop the
// wait, because the system may give more than one event for one
// change. It gives the kind of the event that was found, or -1.
fn wait_kind(w: i32, want: i32, timeout_ms: i32, out_path: u8[>..]&) -> i32 {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 100, buf);
        if !ok { return -1; }
        if e.kind == want {
            out_path.append(buf[..]);
            return e.kind;
        }
    }
    return -1;
}

// wait_path waits for an event of the kind whose path ends with the
// text. Other kinds and other paths do not stop the wait. It gives the
// kind of the event that was found, or -1.
fn wait_path(w: i32, want: i32, suffix: const u8[:], timeout_ms: i32) -> i32 {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 100, buf);
        if !ok { return -1; }
        if e.kind == want && ends_with(buf[..], suffix) { return e.kind; }
    }
    return -1;
}

// no_event waits for a while and gives true when no event of the kind
// came.
fn no_event(w: i32, want: i32, timeout_ms: i32) -> bool {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 100, buf);
        if !ok { return false; }
        if e.kind == want { return false; }
    }
    return true;
}

// no_path waits for a while and gives true when no event whose path
// ends with the text came.
fn no_path(w: i32, suffix: const u8[:], timeout_ms: i32) -> bool {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 100, buf);
        if !ok { return false; }
        if e.kind != watch::KIND_NONE && ends_with(buf[..], suffix) { return false; }
    }
    return true;
}

// wait_two waits for one event of each of the two kinds. The order of
// the events does not matter.
fn wait_two(w: i32, kind_a: i32, kind_b: i32, timeout_ms: i32) -> bool {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    var seen_a = false;
    var seen_b = false;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 100, buf);
        if !ok { return false; }
        if e.kind == kind_a { seen_a = true; }
        if e.kind == kind_b { seen_b = true; }
        if seen_a && seen_b { return true; }
    }
    return seen_a && seen_b;
}

// wait_rename waits for a renamed event and gives its two paths.
fn wait_rename(w: i32, timeout_ms: i32, out_path: u8[>..]&, out_old: u8[>..]&) -> bool {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        var old: u8[>..] = [];
        let e, ok = watch::next_event(w, 100, buf, old);
        if !ok { return false; }
        if e.kind == watch::KIND_RENAMED {
            out_path.append(e.path);
            out_old.append(e.old_path);
            return true;
        }
    }
    return false;
}

// base_of gives the part of the path after the last slash.
fn base_of(path: const u8[:]) -> const u8[:] {
    return watch::base_name(path);
}

// drain waits until no event waits.
fn drain(w: i32, timeout_ms: i32) {
    let deadline = clock_ns() + (timeout_ms as i64) * 1000000;
    while clock_ns() < deadline {
        var buf: u8[>..] = [];
        let e, ok = watch::next(w, 20, buf);
        if !ok { return; }
        if e.kind == watch::KIND_NONE { return; }
    }
}

// ends_with tells whether the text ends with the tail.
fn ends_with(text: const u8[:], tail: const u8[:]) -> bool {
    if tail.len > text.len { return false; }
    let cut = text.len - tail.len;
    return text[cut..] == tail;
}

