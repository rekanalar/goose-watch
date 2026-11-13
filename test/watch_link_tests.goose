// The tests of the links, the new directory, the flag of a directory and the mode of a file.
namespace watch_link_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

extern fn watch_test_symlink(target: const u8[:], link_path: const u8[:]) -> i32;
extern fn watch_test_chmod(path: const u8[:], mode: i32) -> i32;

fn test_link(dir: const u8[:], w: i32) {
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
        target.append(watch_helpers::base_of(ext[..]));
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
            assert(watch_helpers::no_event(d, watch::KIND_CREATED, 500));

            assert(watch::set_follow_symlinks(d, true));
            var f2: u8[>..] = [];
            f2.append(ext[..]);
            f2.append("/g.txt");
            write_file(f2[..], "2");
            var got: u8[>..] = [];
            assert(watch_helpers::wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
            assert(watch_helpers::ends_with(got[..], "/lnk/g.txt"));
            assert(!watch::set_follow_symlinks(0, true));
            assert(watch::stop(d));
            delete_file(f1[..]);
            delete_file(f2[..]);
            delete_file(lnk[..]);
            delete_dir(ext[..]);
            watch_helpers::drain(w, 300);
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
        assert(watch_helpers::wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(got[..], "/late"));
        var late_file: u8[>..] = [];
        late_file.append(sub[..]);
        late_file.append("/note.txt");
        write_file(late_file[..], "late");
        var got2: u8[>..] = [];
        assert(watch_helpers::wait_kind(d, watch::KIND_CREATED, 3000, got2) == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(got2[..], "/late/note.txt"));
        write_file(late_file[..], "late two");
        assert(watch_helpers::wait_path(d, watch::KIND_MODIFIED, "/late/note.txt", 3000) == watch::KIND_MODIFIED);
        assert(watch::stop(d));
        delete_file(late_file[..]);
        delete_dir(sub[..]);
        delete_dir(root[..]);
    }

    // The flag is_dir tells a directory from a file, on both watchers.
    {
        watch_helpers::drain(w, 300);
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
            if e.kind == watch::KIND_CREATED && watch_helpers::ends_with(buf[..], "/flagdir") {
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
            if e.kind == watch::KIND_DELETED && watch_helpers::ends_with(buf[..], "/flagdir") {
                assert(e.is_dir);
                seen_delete = true;
            }
        }
        assert(seen_delete);
        watch_helpers::drain(w, 300);
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
        assert(watch_helpers::wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        var bname: u8[>..] = [];
        if watch::backend(bname) == "inotify" {
            assert(watch_test_chmod(att[..], 384) == 1);
            assert(watch_helpers::wait_kind(w, watch::KIND_ATTRIB, 3000, got) == watch::KIND_ATTRIB);
            assert(watch_helpers::ends_with(got[..], "/att.txt"));
            // A write is not an attrib.
            write_file(att[..], "y");
            assert(watch_helpers::wait_kind(w, watch::KIND_MODIFIED, 3000, got) == watch::KIND_MODIFIED);
        }
        delete_file(att[..]);
        watch_helpers::drain(w, 300);
    }

    // A negative timeout does not wait. It gives the kind none at once
    // when no event waits.
    {
        watch_helpers::drain(w, 500);
        let t0 = clock_ns();
        var got: u8[>..] = [];
        let e, ok = watch::next(w, -1, got);
        assert(ok);
        assert(e.kind == watch::KIND_NONE);
        assert(clock_ns() - t0 < 100000000);
    }

}
