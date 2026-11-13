// The tests of the file events: created, modified, deleted and none.
namespace watch_event_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_file_events(dir: const u8[:], w: i32) {

    var file_path: u8[>..] = [];
    file_path.append(dir[..]);
    file_path.append("/a.txt");
    // A new file gives created.
    {
        write_file(file_path[..], "one");
        var got: u8[>..] = [];
        assert(watch_helpers::wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(got[..], "/a.txt"));
    }

}
