// Tests for the watch package. Run with: goose run test/run.goose
//
// The tests make a directory, watch it, and change the files in it.
// The tests check every kind of the event.

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

fn main() {
    // The base of the test directory. The name of the test directory is
    // unique, so parallel runs do not collide.
    var dir: u8[>..] = [];
    dir.append("./goose-watch-test-");
    format(dir, clock_ns() as i64);
    make_dir(dir[..]);

    var file_path: u8[>..] = [];
    file_path.append(dir[..]);
    file_path.append("/a.txt");

    // A missing path faults at the open.
    {
        var missing: u8[>..] = [];
        missing.append(dir[..]);
        missing.append("/not-there");
        assert(watch::start(missing[..], false) == 0);
    }

    // A path that names a file faults at the open.
    {
        write_file(file_path[..], "one");
        assert(watch::start(file_path[..], false) == 0);
        // The file goes away, so the next write makes a new file.
        delete_file(file_path[..]);
    }

    // A watcher on the directory.
    let w = watch::start(dir[..], false);
    assert(w > 0);

    // A new file gives created.
    {
        write_file(file_path[..], "one");
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(ends_with(got[..], "/a.txt"));
    }

    // A change of the file gives modified.
    {
        write_file(file_path[..], "one two three");
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_MODIFIED, 3000, got) == watch::KIND_MODIFIED);
        assert(ends_with(got[..], "/a.txt"));
    }

    // A removed file gives deleted.
    {
        delete_file(file_path[..]);
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_DELETED, 3000, got) == watch::KIND_DELETED);
        assert(ends_with(got[..], "/a.txt"));
    }

    // A wait with no change gives none.
    {
        var got: u8[>..] = [];
        let e, ok = watch::next(w, 300, got);
        assert(ok);
        assert(e.kind == watch::KIND_NONE);
        assert(e.path.len == 0);
    }

    // A watcher with the subdirectories sees a file in a subdirectory.
    {
        var sub: u8[>..] = [];
        sub.append(dir[..]);
        sub.append("/sub");
        make_dir(sub[..]);
        var deep_file: u8[>..] = [];
        deep_file.append(sub[..]);
        deep_file.append("/b.txt");

        let d = watch::start(dir[..], true);
        assert(d > 0);
        write_file(deep_file[..], "deep");
        var got: u8[>..] = [];
        assert(wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(ends_with(got[..], "/sub/b.txt"));
        assert(watch::stop(d));
    }

    // A watcher without the subdirectories does not see a file in a
    // subdirectory.
    {
        var sub2: u8[>..] = [];
        sub2.append(dir[..]);
        sub2.append("/sub2");
        make_dir(sub2[..]);
        var deep_file2: u8[>..] = [];
        deep_file2.append(sub2[..]);
        deep_file2.append("/c.txt");

        let s = watch::start(dir[..], false);
        assert(s > 0);
        write_file(deep_file2[..], "deep");
        assert(no_event(s, watch::KIND_CREATED, 500));
        assert(watch::stop(s));
    }

    // Two watchers on the same path each give their own event.
    {
        let one = watch::start(dir[..], false);
        let two = watch::start(dir[..], false);
        assert(one > 0);
        assert(two > 0);
        var shared: u8[>..] = [];
        shared.append(dir[..]);
        shared.append("/d.txt");
        write_file(shared[..], "shared");
        var got1: u8[>..] = [];
        var got2: u8[>..] = [];
        assert(wait_kind(one, watch::KIND_CREATED, 3000, got1) == watch::KIND_CREATED);
        assert(wait_kind(two, watch::KIND_CREATED, 3000, got2) == watch::KIND_CREATED);
        assert(watch::stop(one));
        assert(watch::stop(two));
    }

    // A tree deeper than the limit of 32 is not watched.
    {
        // The tree comes first, so the making of it gives no event.
        var deep: u8[>..] = [];
        deep.append(dir[..]);
        var i = 0;
        while i < 32 {
            deep.append("/level");
            make_dir(deep[..]);
            i += 1;
        }
        let d = watch::start(dir[..], true);
        assert(d > 0);
        var deep_file: u8[>..] = [];
        deep_file.append(deep[..]);
        deep_file.append("/deep.txt");
        write_file(deep_file[..], "deep");
        assert(no_event(d, watch::KIND_CREATED, 500));
        assert(watch::stop(d));
    }

    // A renamed file gives renamed on the inotify watcher. The
    // comparison watcher cannot tell a rename from a removal and a new
    // file, so it gives removed and then created.
    {
        var name_buf: u8[>..] = [];
        let backend = watch::backend(name_buf);
        var from: u8[>..] = [];
        from.append(dir[..]);
        from.append("/before.txt");
        write_file(from[..], "same");
        // The watcher sees the file first, so it knows the old name.
        var first_got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, first_got) == watch::KIND_CREATED);
        var to: u8[>..] = [];
        to.append(dir[..]);
        to.append("/after.txt");
        rename_file(from[..], to[..]);
        if backend == "inotify" {
            var got: u8[>..] = [];
            assert(wait_kind(w, watch::KIND_RENAMED, 3000, got) == watch::KIND_RENAMED);
            assert(ends_with(got[..], "/before.txt"));
        } else {
            // The comparison watcher gives a removal and a new file.
            assert(wait_two(w, watch::KIND_DELETED, watch::KIND_CREATED, 3000));
        }
        delete_file(to[..]);
    }

    // A negative timeout does not wait. It gives the kind none at once
    // when no event waits.
    {
        drain(w, 500);
        let t0 = clock_ns();
        var got: u8[>..] = [];
        let e, ok = watch::next(w, -1, got);
        assert(ok);
        assert(e.kind == watch::KIND_NONE);
        assert(clock_ns() - t0 < 100000000);
    }

    // The close of the watcher.
    assert(watch::stop(w));
    // A second close gives false.
    assert(!watch::stop(w));
    // A call after the close gives no event.
    {
        var got: u8[>..] = [];
        let e, ok = watch::next(w, 100, got);
        assert(e.kind == watch::KIND_NONE);
    }

    // The clean up. The files go first, then the directories.
    {
        var f: u8[>..] = [];
        f.append(dir[..]);
        f.append("/d.txt");
        delete_file(f[..]);
        var s1: u8[>..] = [];
        s1.append(dir[..]);
        s1.append("/sub/b.txt");
        delete_file(s1[..]);
        var s2: u8[>..] = [];
        s2.append(dir[..]);
        s2.append("/sub2/c.txt");
        delete_file(s2[..]);
        var deep_dir: u8[>..] = [];
        deep_dir.append(dir[..]);
        var i = 0;
        while i < 32 {
            deep_dir.append("/level");
            i += 1;
        }
        var deep_file2: u8[>..] = [];
        deep_file2.append(deep_dir[..]);
        deep_file2.append("/deep.txt");
        delete_file(deep_file2[..]);
        remove_level_dirs(dir[..], 32);
        var sub_dir: u8[>..] = [];
        sub_dir.append(dir[..]);
        sub_dir.append("/sub");
        delete_dir(sub_dir[..]);
        var sub2_dir: u8[>..] = [];
        sub2_dir.append(dir[..]);
        sub2_dir.append("/sub2");
        delete_dir(sub2_dir[..]);
        delete_dir(dir[..]);
    }

    print("all tests passed");
    return 0;
}
