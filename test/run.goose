// Tests for the watch package. Run with: goose run test/run.goose
//
// The tests make a directory, watch it, and change the files in it.
// The tests check every kind of the event.

import std;
import glob from "rekanalar/goose-glob@v1.1.0";
import os;
import watch from "..";

extern fn watch_test_symlink(target: const u8[:], link_path: const u8[:]) -> i32;
extern fn watch_test_chmod(path: const u8[:], mode: i32) -> i32;

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

// test_hostile checks a pattern with many ** segments. It must end at once.
fn test_hostile() {
    var p: u8[>..] = [];
    var t: u8[>..] = [];
    for i in 0..40 { p.append("**/"); }
    p.append("x");
    for i in 0..60 { t.append("d/"); }
    assert(!watch::glob_match(p[..], t[..]));
    assert(!watch::any_match(p[..], t[..]));
}

fn main() {
    test_hostile();
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

    // A deep tree is watched to its last directory. The walk has no
    // limit of depth, only a guard against a loop of links.
    print("sec The tree comes first, so the making o\n");
    {
        // The tree comes first, so the making of it gives no event.
        var deep: u8[>..] = [];
        deep.append(dir[..]);
        var i = 0;
        while i < 40 {
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
        var saw_deep = false;
        let deadline3 = clock_ns() + 3000000000;
        while clock_ns() < deadline3 && !saw_deep {
            var buf: u8[>..] = [];
            let e, ok = watch::next(d, 200, buf);
            if !ok { break; }
            print("evt kind=");
            print(e.kind);
            print(" dir=");
            print(e.is_dir);
            print(" path=");
            print(buf);
            print("\n");
            if e.kind == watch::KIND_CREATED && ends_with(buf[..], "/deep.txt") { saw_deep = true; }
        }
        assert(saw_deep);
        assert(watch::stop(d));
        // The chain of the directories goes away from the deepest up.
        remove_level_dirs(dir[..], 40);
    }

    // A renamed file gives one renamed event with the new path and the
    // old path, on both watchers.
    {
        var from: u8[>..] = [];
        from.append(dir[..]);
        from.append("/before.txt");
        write_file(from[..], "same");
        // The watcher sees the file first, so it knows the old name.
        var first_got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, first_got) == watch::KIND_CREATED);
        drain(w, 300);
        var to: u8[>..] = [];
        to.append(dir[..]);
        to.append("/after.txt");
        rename_file(from[..], to[..]);
        var got: u8[>..] = [];
        var old: u8[>..] = [];
        assert(wait_rename(w, 3000, got, old));
        assert(ends_with(got[..], "/after.txt"));
        assert(ends_with(old[..], "/before.txt"));
        delete_file(to[..]);
        drain(w, 300);
    }

    // A file that moves out of the watched directory gives a removal.
    {
        var from: u8[>..] = [];
        from.append(dir[..]);
        from.append("/leaving.txt");
        write_file(from[..], "x");
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        drain(w, 300);
        var to: u8[>..] = [];
        to.append(dir[..]);
        to.append("/sub2/leaving.txt");
        rename_file(from[..], to[..]);
        var gone: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_DELETED, 3000, gone) == watch::KIND_DELETED);
        assert(ends_with(gone[..], "/leaving.txt"));
        delete_file(to[..]);
        drain(w, 300);
    }

    // The import line of the entry file pins the tag of the glob package.
    {
        var text: u8[>..] = [];
        assert(read_file("watch.goose", text));
        let pin: const u8[:] = "rekanalar/goose-glob@v1.1.0";
        var found = false;
        var i = 0;
        while i + pin.len <= text.len {
            var same = true;
            var j = 0;
            while j < pin.len {
                if text[i + j] != pin[j] { same = false; break; }
                j += 1;
            }
            if same { found = true; }
            i += 1;
        }
        assert(found);
    }

    // The filter and the glob package give the same answer. The cases
    // cover a star of a segment, a star of the segments, a class, a group
    // of alternatives and an escape byte.
    {
        let pats: const u8[:] = "*.txt;a?c;a*b*c;src/*.c;src/**/*.c;log[0-9].txt;log[!0-9].txt;{a,b}.txt;**/*.go;src/**";
        let texts: const u8[:] = "a.txt;a.txt.bak;abc;ac;aXXbYYc;aXXbYY;src/x.c;src/x/y.c;log7.txt;logx.txt;a.txt;b.txt;c.txt;x/y/a.go;x/y/a.txt";
        // The list is split at the semicolons. Each pattern is compared
        // with each text.
        var pi = 0;
        var ps = 0;
        while pi <= pats.len {
            if pi == pats.len || pats[pi] == ';' {
                let pat = pats[ps..pi];
                if pat.len > 0 {
                    var ti = 0;
                    var ts = 0;
                    while ti <= texts.len {
                        if ti == texts.len || texts[ti] == ';' {
                            let txt = texts[ts..ti];
                            if txt.len > 0 {
                                assert(watch::glob_match(pat, txt) == glob::matches(txt, pat));
                            }
                            ts = ti + 1;
                        }
                        ti += 1;
                    }
                }
                ps = pi + 1;
            }
            pi += 1;
        }
    }

    // The glob match. The text is a whole path.
    {
        assert(watch::glob_match("*.txt", "a.txt"));
        assert(!watch::glob_match("*.txt", "a.txt.bak"));
        assert(watch::glob_match("a?c", "abc"));
        assert(!watch::glob_match("a?c", "ac"));
        assert(watch::glob_match("*", ""));
        assert(watch::glob_match("a*b*c", "aXXbYYc"));
        assert(!watch::glob_match("a*b*c", "aXXbYY"));
        // A star of a pattern with a separator stops at a separator. The
        // old code let the star cross it. A caller who wants the whole
        // tree writes **.
        assert(watch::glob_match("src/*.c", "src/x.c"));
        assert(!watch::glob_match("src/*.c", "src/x/y.c"));
        assert(watch::glob_match("src/**/*.c", "src/x/y.c"));
        assert(watch::glob_match("src/**/*.c", "src/x.c"));
        assert(!watch::glob_match("src/**/*.c", "other/x.c"));
        // A class of characters.
        assert(watch::glob_match("log[0-9].txt", "log7.txt"));
        assert(!watch::glob_match("log[0-9].txt", "logx.txt"));
        assert(watch::glob_match("log[!0-9].txt", "logx.txt"));
        assert(!watch::glob_match("log[!0-9].txt", "log7.txt"));
        assert(watch::glob_match("log[abc].txt", "logb.txt"));
        assert(!watch::glob_match("log[abc].txt", "logd.txt"));
        // A class that is not closed is a literal.
        assert(watch::glob_match("log[0-9.txt", "log[0-9.txt"));
        // A group of alternatives and an escape byte.
        assert(watch::glob_match("{a,b}.txt", "a.txt"));
        assert(watch::glob_match("{a,b}.txt", "b.txt"));
        assert(!watch::glob_match("{a,b}.txt", "c.txt"));
        assert(watch::glob_match("a\\*b", "a*b"));
        assert(watch::base_name("/a/b/c.txt") == "c.txt");
        assert(watch::base_name("c.txt") == "c.txt");
        // A pattern with no slash fits the name, one with a slash fits the path.
        assert(watch::any_match("*.go;*.txt", "/x/y/a.txt"));
        assert(!watch::any_match("*.go;*.c", "/x/y/a.txt"));
        // The star of a pattern with a separator stops at it. The old code
        // let the star cross it.
        assert(!watch::any_match("/x/*", "/x/y/a.txt"));
        assert(watch::any_match("/x/*", "/x/a.txt"));
        assert(watch::any_match("/x/**", "/x/y/a.txt"));
        // The filter takes the full syntax.
        assert(watch::any_match("**/*.go", "/x/y/a.go"));
        assert(!watch::any_match("**/*.go", "/x/y/a.txt"));
        assert(watch::any_match("log[0-9].txt", "/x/log3.txt"));
        assert(!watch::any_match("log[0-9].txt", "/x/logx.txt"));
        let f = watch::Filter { include: "*.txt", ignore: "tmp*" };
        assert(watch::allowed(f, "/d/a.txt"));
        assert(!watch::allowed(f, "/d/a.log"));
        assert(!watch::allowed(f, "/d/tmp1.txt"));
        assert(watch::allowed(watch::Filter { .. }, "/d/anything"));
    }

    // A filter with include patterns drops the other paths.
    {
        drain(w, 300);
        var log: u8[>..] = [];
        log.append(dir[..]);
        log.append("/f1.log");
        var txt: u8[>..] = [];
        txt.append(dir[..]);
        txt.append("/f2.txt");
        write_file(log[..], "1");
        write_file(txt[..], "2");
        var got: u8[>..] = [];
        var old: u8[>..] = [];
        let e, ok = watch::next_filtered(w, 3000, watch::Filter { include: "*.txt", .. }, got, old);
        assert(ok);
        assert(e.kind == watch::KIND_CREATED);
        assert(ends_with(e.path, "/f2.txt"));
        drain(w, 300);
        // An ignore pattern drops its paths. No txt event may come.
        var more: u8[>..] = [];
        more.append(dir[..]);
        more.append("/f3.txt");
        var more_log: u8[>..] = [];
        more_log.append(dir[..]);
        more_log.append("/f4.log");
        write_file(more[..], "3");
        write_file(more_log[..], "4");
        var seen_log = false;
        let deadline = clock_ns() + 800 * 1000000;
        while clock_ns() < deadline {
            var g: u8[>..] = [];
            var o: u8[>..] = [];
            let ev, k = watch::next_filtered(w, 100, watch::Filter { ignore: "*.txt", .. }, g, o);
            assert(k);
            if ev.kind != watch::KIND_NONE {
                assert(!ends_with(ev.path, ".txt"));
                if ends_with(ev.path, "/f4.log") { seen_log = true; }
            }
        }
        assert(seen_log);
        delete_file(log[..]);
        delete_file(txt[..]);
        delete_file(more[..]);
        delete_file(more_log[..]);
        drain(w, 300);
    }

    // A burst merges into one event for each path.
    {
        let b = watch::start(dir[..], false);
        assert(b > 0);
        var n1: u8[>..] = [];
        n1.append(dir[..]);
        n1.append("/n1.txt");
        var n2: u8[>..] = [];
        n2.append(dir[..]);
        n2.append("/n2.txt");
        var n3: u8[>..] = [];
        n3.append(dir[..]);
        n3.append("/n3.txt");
        write_file(n1[..], "1");
        write_file(n2[..], "2");
        write_file(n2[..], "22");
        write_file(n3[..], "3");
        delete_file(n3[..]);
        var store: u8[>..] = [];
        var events: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { .. }, store, events));
        // n1 and n2 each come once as created, and n3 comes not at all.
        assert(events.len == 2);
        var saw1 = false;
        var saw2 = false;
        for e in events {
            assert(e.kind == watch::KIND_CREATED);
            if ends_with(e.path, "/n1.txt") { saw1 = true; }
            if ends_with(e.path, "/n2.txt") { saw2 = true; }
        }
        assert(saw1 && saw2);

        // A delete and a create of one path merge to one modify.
        delete_file(n1[..]);
        write_file(n1[..], "now longer");
        var store2: u8[>..] = [];
        var events2: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { .. }, store2, events2));
        assert(events2.len == 1);
        assert(events2[0].kind == watch::KIND_MODIFIED);
        assert(ends_with(events2[0].path, "/n1.txt"));

        // A wait with no change gives an empty list.
        var store3: u8[>..] = [];
        var events3: watch::Event[>..] = [];
        assert(watch::next_batch(b, 200, 100, watch::Filter { .. }, store3, events3));
        assert(events3.len == 0);

        // The filter works in a batch.
        write_file(n3[..], "again");
        delete_file(n2[..]);
        var store4: u8[>..] = [];
        var events4: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { ignore: "n3*", .. }, store4, events4));
        assert(events4.len == 1);
        assert(events4[0].kind == watch::KIND_DELETED);
        assert(ends_with(events4[0].path, "/n2.txt"));

        assert(watch::stop(b));
        // A batch on a closed watcher gives no event, as next does.
        var s5: u8[>..] = [];
        var e5: watch::Event[>..] = [];
        assert(watch::next_batch(b, 100, 100, watch::Filter { .. }, s5, e5));
        assert(e5.len == 0);
        // A batch on a handle that never was open fails.
        assert(!watch::next_batch(0, 100, 100, watch::Filter { .. }, s5, e5));
        delete_file(n1[..]);
        delete_file(n3[..]);
    }

    // The polling interval has a range, and events still come.
    {
        assert(watch::set_poll_interval(w, 20));
        assert(!watch::set_poll_interval(w, 0));
        assert(!watch::set_poll_interval(w, -5));
        assert(!watch::set_poll_interval(w, 60001));
        assert(watch::set_poll_interval(w, 60000));
        assert(watch::set_poll_interval(w, 30));
        assert(!watch::set_poll_interval(0, 30));
        drain(w, 300);
        var p: u8[>..] = [];
        p.append(dir[..]);
        p.append("/interval.txt");
        write_file(p[..], "i");
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        delete_file(p[..]);
        drain(w, 300);
    }

    // The comparison watcher does not wait longer than the timeout,
    // whatever the interval is.
    {
        var nb: u8[>..] = [];
        if watch::backend(nb) == "compare" {
            let s = watch::start(dir[..], false);
            assert(s > 0);
            assert(watch::set_poll_interval(s, 5000));
            let t0 = clock_ns();
            var got: u8[>..] = [];
            let e, ok = watch::next(s, 150, got);
            assert(ok);
            assert(e.kind == watch::KIND_NONE);
            assert(clock_ns() - t0 < 400000000);
            assert(watch::stop(s));
        }
    }

    // The rule for a symbolic link. A deep watcher does not go into a
    // linked directory until the caller says so.
    {
        var ext: u8[>..] = [];
        ext.append(dir[..]);
        ext.append("-ext");
        make_dir(ext[..]);
        var lnk: u8[>..] = [];
        lnk.append(dir[..]);
        lnk.append("/lnk");
        var target: u8[>..] = [];
        target.append("../");
        target.append(base_of(ext[..]));
        // The code is 0 when the system does not allow symbolic links.
        // The test skips then.
        let made = watch_test_symlink(target[..], lnk[..]);
        if (made == 0) {
            print("skip: this system does not make symbolic links\n");
            delete_dir(ext[..]);
        } else {
            assert(made == 1);
            let d = watch::start(dir[..], true);
            assert(d > 0);
            var f1: u8[>..] = [];
            f1.append(ext[..]);
            f1.append("/f.txt");
            write_file(f1[..], "1");
            assert(no_event(d, watch::KIND_CREATED, 500));

            assert(watch::set_follow_symlinks(d, true));
            var f2: u8[>..] = [];
            f2.append(ext[..]);
            f2.append("/g.txt");
            write_file(f2[..], "2");
            var got: u8[>..] = [];
            assert(wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
            assert(ends_with(got[..], "/lnk/g.txt"));
            assert(!watch::set_follow_symlinks(0, true));
            assert(watch::stop(d));
            delete_file(f1[..]);
            delete_file(f2[..]);
            delete_file(lnk[..]);
            delete_dir(ext[..]);
            drain(w, 300);
        }
    }


    // A directory that appears later is watched by a deep watcher. The
    // directory gives its own created event, flagged as a directory.
    // A file in it gives a created event and a modified event.
    {
        var root: u8[>..] = [];
        root.append(dir[..]);
        root.append("/deeproot");
        make_dir(root[..]);
        let d = watch::start(root[..], true);
        assert(d > 0);
        var sub: u8[>..] = [];
        sub.append(root[..]);
        sub.append("/late");
        make_dir(sub[..]);
        var got: u8[>..] = [];
        assert(wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(ends_with(got[..], "/late"));
        var late_file: u8[>..] = [];
        late_file.append(sub[..]);
        late_file.append("/note.txt");
        write_file(late_file[..], "late");
        var got2: u8[>..] = [];
        assert(wait_kind(d, watch::KIND_CREATED, 3000, got2) == watch::KIND_CREATED);
        assert(ends_with(got2[..], "/late/note.txt"));
        write_file(late_file[..], "late two");
        assert(wait_path(d, watch::KIND_MODIFIED, "/late/note.txt", 3000) == watch::KIND_MODIFIED);
        assert(watch::stop(d));
        delete_file(late_file[..]);
        delete_dir(sub[..]);
        delete_dir(root[..]);
    }

    // The flag is_dir tells a directory from a file, on both watchers.
    {
        drain(w, 300);
        var d2: u8[>..] = [];
        d2.append(dir[..]);
        d2.append("/flagdir");
        make_dir(d2[..]);
        var got: u8[>..] = [];
        let deadline = clock_ns() + 3000000000;
        var saw_dir = false;
        while clock_ns() < deadline && !saw_dir {
            var buf: u8[>..] = [];
            let e, ok = watch::next(w, 200, buf);
            if !ok { break; }
            if e.kind == watch::KIND_CREATED && ends_with(buf[..], "/flagdir") {
                assert(e.is_dir);
                saw_dir = true;
            }
        }
        assert(saw_dir);
        delete_dir(d2[..]);
        var seen_delete = false;
        let deadline2 = clock_ns() + 3000000000;
        while clock_ns() < deadline2 && !seen_delete {
            var buf: u8[>..] = [];
            let e, ok = watch::next(w, 200, buf);
            if !ok { break; }
            if e.kind == watch::KIND_DELETED && ends_with(buf[..], "/flagdir") {
                assert(e.is_dir);
                seen_delete = true;
            }
        }
        assert(seen_delete);
        drain(w, 300);
    }

    // A change of the mode gives attrib. A write gives modified, not
    // attrib. The comparison watcher sees the mode of the file on the
    // systems of POSIX. On Windows the mode is the word of the
    // attributes, and a change of the mode alone is rare, so this
    // part runs on the systems of POSIX only.
    {
        var att: u8[>..] = [];
        att.append(dir[..]);
        att.append("/att.txt");
        write_file(att[..], "x");
        var got: u8[>..] = [];
        assert(wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        var bname: u8[>..] = [];
        if watch::backend(bname) == "inotify" {
            assert(watch_test_chmod(att[..], 384) == 1);
            assert(wait_kind(w, watch::KIND_ATTRIB, 3000, got) == watch::KIND_ATTRIB);
            assert(ends_with(got[..], "/att.txt"));
            // A write is not an attrib.
            write_file(att[..], "y");
            assert(wait_kind(w, watch::KIND_MODIFIED, 3000, got) == watch::KIND_MODIFIED);
        }
        delete_file(att[..]);
        drain(w, 300);
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


    // A group of watchers gives the events of all of them, and a
    // watcher leaves the group without a fault on the others.
    {
        var d3: u8[>..] = [];
        d3.append(dir[..]);
        d3.append("/gr1");
        make_dir(d3[..]);
        var d4: u8[>..] = [];
        d4.append(dir[..]);
        d4.append("/gr2");
        make_dir(d4[..]);
        var g = watch::Group { handles: [] };
        let p1 = watch::group_add(g, d3[..], false);
        let p2 = watch::group_add(g, d4[..], false);
        assert(p1 >= 0);
        assert(p2 >= 0);
        drain(w, 300);
        var f3: u8[>..] = [];
        f3.append(d3[..]);
        f3.append("/one.txt");
        write_file(f3[..], "1");
        var which: i32 = -1;
        var gp: u8[>..] = [];
        var gold: u8[>..] = [];
        let e, ok = watch::group_next(g, 3000, which, gp, gold);
        assert(ok);
        assert(e.kind == watch::KIND_CREATED);
        assert(which == p1);
        assert(ends_with(gp[..], "/one.txt"));
        assert(watch::group_remove(g, which));
        assert(watch::group_next(g, 200, which, gp, gold).kind == watch::KIND_NONE);
        watch::group_close(g);
        delete_file(f3[..]);
        delete_dir(d3[..]);
        delete_dir(d4[..]);
        drain(w, 300);
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
