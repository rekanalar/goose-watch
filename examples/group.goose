// An example that watches two directories with one group.
//
// The example makes two directories, puts a watcher on each in one
// group, and writes a file in the second. It prints which watcher gave
// the event, and the kind and the path of the event.

import std;
import glob from "rekanalar/goose-glob@v1.1.0";
import os;
import watch from "..";

fn main() {
    var base: u8[>..] = [];
    base.append("./goose-watch-example-group-");
    format(base, clock_ns());
    make_dir(base[..]);
    var one: u8[>..] = [];
    one.append(base[..]);
    one.append("/one");
    make_dir(one[..]);
    var two: u8[>..] = [];
    two.append(base[..]);
    two.append("/two");
    make_dir(two[..]);

    var g = watch::Group { handles: [] };
    assert(watch::group_add(g, one[..], true) == 0);
    assert(watch::group_add(g, two[..], true) == 1);

    var file: u8[>..] = [];
    file.append(two[..]);
    file.append("/note.txt");
    write_file(file[..], "hello");

    var which: i32 = -1;
    var path: u8[>..] = [];
    var old: u8[>..] = [];
    let e, ok = watch::group_next(g, 5000, which, path, old);
    assert(ok);
    assert(e.kind == watch::KIND_CREATED);
    print("watcher: ");
    print(which);
    print("\nkind: ");
    print(watch::kind_name(e.kind));
    print("\npath: ");
    print(e.path);
    print("\n");

    watch::group_close(g);
    delete_file(file[..]);
    delete_dir(one[..]);
    delete_dir(two[..]);
    delete_dir(base[..]);
}
