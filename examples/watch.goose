// An example that watches a directory.
//
// The example makes a directory, watches it, writes a file in it, and
// prints the event. The directory goes away at the end.

import std;
import glob from "rekanalar/goose-glob@v1.0.1";
import os;
import watch from "..";

fn main() {
    // The name of the directory is unique, so parallel runs do not
    // collide.
    var dir: u8[>..] = [];
    dir.append("./goose-watch-example-");
    format(dir, clock_ns() as i64);
    make_dir(dir[..]);

    // The watcher on the directory.
    let w = watch::start(dir[..], false);
    assert(w > 0);

    // The file comes later. The watcher waits for it.
    var file: u8[>..] = [];
    file.append(dir[..]);
    file.append("/note.txt");
    write_file(file[..], "hello");

    // The wait for the change.
    var got: u8[>..] = [];
    let e, ok = watch::next(w, 5000, got);
    assert(ok);
    print("kind: ");
    print(watch::kind_name(e.kind));
    print("\npath: ");
    print(e.path[..]);
    print("\n");

    // The end of the watcher and the clean up.
    assert(watch::stop(w));
    delete_file(file[..]);
    delete_dir(dir[..]);
    return 0;
}
