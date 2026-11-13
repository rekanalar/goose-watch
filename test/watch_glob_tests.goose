// The tests of the glob patterns and of the filter.
namespace watch_glob_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_glob(dir: const u8[:], w: i32) {
    // The import line of the entry file pins the tag of the glob package.
    {
        var text: u8[>..] = [];
        assert(read_file("watch.goose", text));
        let pin: const u8[:] = "rekanalar/goose-glob@v1.2.0";
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
        watch_helpers::drain(w, 300);
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
        assert(watch_helpers::ends_with(e.path, "/f2.txt"));
        watch_helpers::drain(w, 300);
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
                assert(!watch_helpers::ends_with(ev.path, ".txt"));
                if watch_helpers::ends_with(ev.path, "/f4.log") { seen_log = true; }
            }
        }
        assert(seen_log);
        delete_file(log[..]);
        delete_file(txt[..]);
        delete_file(more[..]);
        delete_file(more_log[..]);
        watch_helpers::drain(w, 300);
    }
}
