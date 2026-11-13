// The tests of the timing: the polling interval and the timeout of the comparison watcher.
namespace watch_timing_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_timing(dir: const u8[:], w: i32) {
    // The polling interval has a range, and events still come.
    {
        assert(watch::set_poll_interval(w, 20));
        assert(!watch::set_poll_interval(w, 0));
        assert(!watch::set_poll_interval(w, -5));
        assert(!watch::set_poll_interval(w, 60001));
        assert(watch::set_poll_interval(w, 60000));
        assert(watch::set_poll_interval(w, 30));
        assert(!watch::set_poll_interval(0, 30));
        watch_helpers::drain(w, 300);
        var p: u8[>..] = [];
        p.append(dir[..]);
        p.append("/interval.txt");
        write_file(p[..], "i");
        var got: u8[>..] = [];
        assert(watch_helpers::wait_kind(w, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        delete_file(p[..]);
        watch_helpers::drain(w, 300);
    }

    // The comparison watcher does not wait longer than the timeout,
    // whatever the interval is.
    {
        var nb: u8[>..] = [];
        if watch::backend(nb) == "compare" {
            let s = watch::start(dir[..], false);
            assert(s > 0);
            assert(watch::set_poll_interval(s, 5000));
            let t0 = clock_ns();
            var got: u8[>..] = [];
            let e, ok = watch::next(s, 150, got);
            assert(ok);
            assert(e.kind == watch::KIND_NONE);
            assert(clock_ns() - t0 < 400000000);
            assert(watch::stop(s));
        }
    }

}
