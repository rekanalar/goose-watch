// The tests of the rename: a new name and a move out of the tree.
namespace watch_rename_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_rename(dir: const u8[:], w: i32) {
    // A renamed file gives one renamed event with the new path and the
    // old path, on both watchers.
    {
        var from: u8[>..] = [];
        from.append(dir[..]);
        from.append("/before.txt");
        write_file(from[..], "same");
        // The watcher sees the file first, so it knows the old name.
        var first_got: u8[>..] = [];
        assert(watch_helpers::wait_kind(w, watch::KIND_CREATED, 3000, first_got) == watch::KIND_CREATED);
        watch_helpers::drain(w, 300);
        var to: u8[>..] = [];
        to.append(dir[..]);
        to.append("/after.txt");
        rename_file(from[..], to[..]);
        var got: u8[>..] = [];
        var old: u8[>..] = [];
        assert(watch_helpers::wait_rename(w, 3000, got, old));
        assert(watch_helpers::ends_with(got[..], "/after.txt"));
        assert(watch_helpers::ends_with(old[..], "/before.txt"));
        delete_file(to[..]);
        watch_helpers::drain(w, 300);
    }

    // A file that moves out of the watched directory gives a removal.
    {
        var from: u8[>..] = [];
        from.append(dir[..]);
        from.append("/leaving.txt");
        write_file(from[..], "x");
        var got: u8[>..] = [];
        assert(watch_helpers::wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        watch_helpers::drain(w, 300);
        var to: u8[>..] = [];
        to.append(dir[..]);
        to.append("/sub2/leaving.txt");
        rename_file(from[..], to[..]);
        var gone: u8[>..] = [];
        assert(watch_helpers::wait_kind(w, watch::KIND_DELETED, 3000, gone) == watch::KIND_DELETED);
        assert(watch_helpers::ends_with(gone[..], "/leaving.txt"));
        delete_file(to[..]);
        watch_helpers::drain(w, 300);
    }

}
