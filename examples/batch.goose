// An example for the burst merge, the filter and the rename path.
//
// The example writes three files and renames one. It reads the burst
// as merged events with a filter that drops *.tmp files.

import std;
import glob from "rekanalar/goose-glob@v1.1.0";
import os;
import watch from "..";

fn main() {
    var dir: u8[>..] = [];
    dir.append("./goose-watch-example-batch-");
    format(dir, clock_ns());
    make_dir(dir[..]);
    let w = watch::start(dir[..], false);
    assert(w > 0);

    var a: u8[>..] = [];
    a.append(dir[..]);
    a.append("/a.txt");
    var b: u8[>..] = [];
    b.append(dir[..]);
    b.append("/b.tmp");
    var c: u8[>..] = [];
    c.append(dir[..]);
    c.append("/c.txt");
    write_file(a[..], "one");
    write_file(a[..], "one two");
    write_file(b[..], "scratch");
    write_file(c[..], "three");

    // One event for each path, whatever the number of writes.
    var store: u8[>..] = [];
    var events: watch::Event[>..] = [];
    let f = watch::Filter { ignore: "*.tmp", .. };
    assert(watch::next_batch(w, 5000, 200, f, store, events));
    for e in events {
        print(watch::kind_name(e.kind), " ", e.path);
    }

    // A rename gives the new path and the old path.
    var d: u8[>..] = [];
    d.append(dir[..]);
    d.append("/d.txt");
    rename_file(c[..], d[..]);
    var got: u8[>..] = [];
    var old: u8[>..] = [];
    let e, ok = watch::next_event(w, 5000, got, old);
    assert(ok);
    print(watch::kind_name(e.kind), " ", e.old_path, " -> ", e.path);

    assert(watch::stop(w));
    delete_file(a[..]);
    delete_file(b[..]);
    delete_file(d[..]);
    delete_dir(dir[..]);
    return 0;
}
