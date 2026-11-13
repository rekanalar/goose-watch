// The tests of the trees: the subdirectories, the two watchers and the deep tree.
namespace watch_tree_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_tree(dir: const u8[:]) {
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
        assert(watch_helpers::wait_kind(d, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(got[..], "/sub/b.txt"));
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
        assert(watch_helpers::no_event(s, watch::KIND_CREATED, 500));
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
        assert(watch_helpers::wait_kind(one, watch::KIND_CREATED, 3000, got1) == watch::KIND_CREATED);
        assert(watch_helpers::wait_kind(two, watch::KIND_CREATED, 3000, got2) == watch::KIND_CREATED);
        assert(watch::stop(one));
        assert(watch::stop(two));
    }

    // A deep tree is watched to its last directory. The walk has no
    // limit of depth of its own, only a guard against a loop of links.
    // The depth of 25 stays under the limit of 260 bytes that Windows
    // puts on a path without its long form.
    {
        // The tree comes first, so the making of it gives no event.
        var deep: u8[>..] = [];
        deep.append(dir[..]);
        var i = 0;
        while i < 25 {
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
        assert(watch_helpers::wait_kind(d, watch::KIND_CREATED, 3000, deep_file) == watch::KIND_CREATED);
        assert(watch::stop(d));
        // The chain of the directories goes away from the deepest up.
        watch_helpers::remove_level_dirs(dir[..], 25);
    }

}
