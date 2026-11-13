// The test of the burst: many changes merge into one event for each path.
namespace watch_burst_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

fn test_burst(dir: const u8[:]) {
    // A burst merges into one event for each path.
    {
        let b = watch::start(dir[..], false);
        assert(b > 0);
        var n1: u8[>..] = [];
        n1.append(dir[..]);
        n1.append("/n1.txt");
        var n2: u8[>..] = [];
        n2.append(dir[..]);
        n2.append("/n2.txt");
        var n3: u8[>..] = [];
        n3.append(dir[..]);
        n3.append("/n3.txt");
        write_file(n1[..], "1");
        write_file(n2[..], "2");
        write_file(n2[..], "22");
        write_file(n3[..], "3");
        delete_file(n3[..]);
        var store: u8[>..] = [];
        var events: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { .. }, store, events));
        // n1 and n2 each come once as created, and n3 comes not at all.
        assert(events.len == 2);
        var saw1 = false;
        var saw2 = false;
        for e in events {
            assert(e.kind == watch::KIND_CREATED);
            if watch_helpers::ends_with(e.path, "/n1.txt") { saw1 = true; }
            if watch_helpers::ends_with(e.path, "/n2.txt") { saw2 = true; }
        }
        assert(saw1 && saw2);

        // A delete and a create of one path merge to one modify.
        delete_file(n1[..]);
        write_file(n1[..], "now longer");
        var store2: u8[>..] = [];
        var events2: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { .. }, store2, events2));
        assert(events2.len == 1);
        assert(events2[0].kind == watch::KIND_MODIFIED);
        assert(watch_helpers::ends_with(events2[0].path, "/n1.txt"));

        // A wait with no change gives an empty list.
        var store3: u8[>..] = [];
        var events3: watch::Event[>..] = [];
        assert(watch::next_batch(b, 200, 100, watch::Filter { .. }, store3, events3));
        assert(events3.len == 0);

        // The filter works in a batch.
        write_file(n3[..], "again");
        delete_file(n2[..]);
        var store4: u8[>..] = [];
        var events4: watch::Event[>..] = [];
        assert(watch::next_batch(b, 3000, 300, watch::Filter { ignore: "n3*", .. }, store4, events4));
        assert(events4.len == 1);
        assert(events4[0].kind == watch::KIND_DELETED);
        assert(watch_helpers::ends_with(events4[0].path, "/n2.txt"));

        assert(watch::stop(b));
        // A batch on a closed watcher gives no event, as next does.
        var s5: u8[>..] = [];
        var e5: watch::Event[>..] = [];
        assert(watch::next_batch(b, 100, 100, watch::Filter { .. }, s5, e5));
        assert(e5.len == 0);
        // A batch on a handle that never was open fails.
        assert(!watch::next_batch(0, 100, 100, watch::Filter { .. }, s5, e5));
        delete_file(n1[..]);
        delete_file(n3[..]);
    }

}
