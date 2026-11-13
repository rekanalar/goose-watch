// The tests of the watch package. Run with: goose run test/run.goose
//
// The tests make a directory, watch it, and change the files in it.
// The tests check every kind of the event.

import std;
import os;
import watch from "..";
import glob from "rekanalar/goose-glob@v1.2.0";
import watch_helpers;
import watch_open_tests;
import watch_event_tests;
import watch_tree_tests;
import watch_rename_tests;
import watch_glob_tests;
import watch_burst_tests;
import watch_timing_tests;
import watch_link_tests;
import watch_group_tests;

// test_glob_package compares the filter of the watch package with the
// glob package. The cases cover a star of a segment, a star of the
// segments, a class, a group of alternatives and an escape byte.
fn test_glob_package() {
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
}

fn main() {
    // The base of the test directory. The name of the test directory is
    // unique, so parallel runs do not collide.
    var dir: u8[>..] = [];
    dir.append("./goose-watch-test-");
    format(dir, clock_ns() as i64);
    make_dir(dir[..]);

    watch_open_tests::test_open(dir[..]);

    // A watcher on the directory.
    let w = watch::start(dir[..], false);
    assert(w > 0);

    watch_event_tests::test_file_events(dir[..], w);
    watch_tree_tests::test_tree(dir[..]);
    watch_rename_tests::test_rename(dir[..], w);
    test_glob_package();
    watch_glob_tests::test_glob(dir[..], w);
    watch_burst_tests::test_burst(dir[..]);
    watch_timing_tests::test_timing(dir[..], w);
    watch_link_tests::test_link(dir[..], w);
    watch_group_tests::test_group(dir[..], w);

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
        watch_helpers::remove_level_dirs(dir[..], 32);
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
