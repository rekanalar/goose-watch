// The tests of the open: a missing path and a path that names a file both fault.
namespace watch_open_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_open(dir: const u8[:]) {

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

}
