// The tests of the group of watchers, of the content, of the depth and of the roots.
namespace watch_group_tests;

import std;
import os;
import watch from "..";
import watch_helpers;

extern fn watch_test_touch(path: const u8[:], sec: i64, nsec: i64) -> i32;
extern fn watch_test_fifo(path: const u8[:]) -> i32;

fn test_group(dir: const u8[:], w: i32) {
    // A group of watchers gives the events of all of them, and a
    // watcher leaves the group without a fault on the others.
    {
        var d3: u8[>..] = [];
        d3.append(dir[..]);
        d3.append("/gr1");
        make_dir(d3[..]);
        var d4: u8[>..] = [];
        d4.append(dir[..]);
        d4.append("/gr2");
        make_dir(d4[..]);
        var g = watch::Group { handles: [] };
        let p1 = watch::group_add(g, d3[..], false);
        let p2 = watch::group_add(g, d4[..], false);
        assert(p1 >= 0);
        assert(p2 >= 0);
        watch_helpers::drain(w, 300);
        var f3: u8[>..] = [];
        f3.append(d3[..]);
        f3.append("/one.txt");
        write_file(f3[..], "1");
        var which: i32 = -1;
        var gp: u8[>..] = [];
        var gold: u8[>..] = [];
        let e, ok = watch::group_next(g, 3000, which, gp, gold);
        assert(ok);
        assert(e.kind == watch::KIND_CREATED);
        assert(which == p1);
        assert(watch_helpers::ends_with(gp[..], "/one.txt"));
        assert(watch::group_remove(g, which));
        assert(watch::group_next(g, 200, which, gp, gold).kind == watch::KIND_NONE);
        watch::group_close(g);
        delete_file(f3[..]);
        delete_dir(d3[..]);
        delete_dir(d4[..]);
        watch_helpers::drain(w, 300);
    }

    // The comparison of the content: a write that keeps the size and
    // the time of the file still gives a modified event when the flag
    // asks for it. The time of the file goes to a fixed value in the
    // past, and the write puts it back, so only the content can tell
    // the two forms apart.
    {
        var hd: u8[>..] = [];
        hd.append(dir[..]);
        hd.append("/hash");
        make_dir(hd[..]);
        var hf: u8[>..] = [];
        hf.append(hd[..]);
        hf.append("/data.txt");
        write_file(hf[..], "aaaa");
        assert(watch_test_touch(hf[..], 1000000000, 0) == 1);
        let h = watch::start(hd[..], true);
        assert(h > 0);
        watch_helpers::drain(h, 500);
        assert(watch::set_compare_contents(h, true));
        write_file(hf[..], "bbbb");
        assert(watch_test_touch(hf[..], 1000000000, 0) == 1);
        assert(watch_helpers::wait_path(h, watch::KIND_MODIFIED, "/data.txt", 3000) == watch::KIND_MODIFIED);
        assert(watch::set_compare_contents(h, false));
        assert(watch::stop(h));
        delete_file(hf[..]);
        delete_dir(hd[..]);
        watch_helpers::drain(w, 300);
    }

    // The depth: with 0, a write below the root gives no event for
    // the file, and a write in the root gives one. With -1, the file
    // comes through again. A value below -1 is refused.
    {
        var dd: u8[>..] = [];
        dd.append(dir[..]);
        dd.append("/depthd");
        make_dir(dd[..]);
        var ds: u8[>..] = [];
        ds.append(dd[..]);
        ds.append("/sub");
        make_dir(ds[..]);
        var df: u8[>..] = [];
        df.append(ds[..]);
        df.append("/deep.txt");
        write_file(df[..], "one");
        let d = watch::start(dd[..], true);
        assert(d > 0);
        watch_helpers::drain(d, 500);
        assert(watch::set_depth(d, 0));
        assert(!watch::set_depth(d, -2));
        watch_helpers::drain(d, 500);
        write_file(df[..], "two");
        assert(watch_helpers::no_path(d, "/sub/deep.txt", 1200));
        var dtop: u8[>..] = [];
        dtop.append(dd[..]);
        dtop.append("/top.txt");
        write_file(dtop[..], "t");
        assert(watch_helpers::wait_path(d, watch::KIND_CREATED, "/top.txt", 3000) == watch::KIND_CREATED);
        assert(watch::set_depth(d, -1));
        watch_helpers::drain(d, 500);
        write_file(df[..], "three");
        assert(watch_helpers::wait_path(d, watch::KIND_MODIFIED, "/sub/deep.txt", 3000) == watch::KIND_MODIFIED);
        assert(watch::stop(d));
        delete_file(df[..]);
        delete_file(dtop[..]);
        delete_dir(ds[..]);
        delete_dir(dd[..]);
        watch_helpers::drain(w, 300);
    }

    // The regexp list of the filter: an event of a path that a
    // pattern takes is dropped, and the events of the other paths
    // come through. A malformed pattern and a pattern that is too
    // large are refused, so they never match and never fault.
    {
        watch_helpers::drain(w, 300);
        var ft: u8[>..] = [];
        ft.append(dir[..]);
        ft.append("/tmp.txt");
        var okf: u8[>..] = [];
        okf.append(dir[..]);
        okf.append("/ok.txt");
        write_file(ft[..], "t");
        write_file(okf[..], "o");
        let f = watch::Filter { include: "", ignore: "", ignore_regexp: "tmp" };
        var buf: u8[>..] = [];
        var old: u8[>..] = [];
        let e, ok = watch::next_filtered(w, 3000, f, buf, old);
        assert(ok);
        assert(e.kind == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(buf[..], "/ok.txt"));
        delete_file(ft[..]);
        delete_file(okf[..]);
        watch_helpers::drain(w, 300);
        var ft2: u8[>..] = [];
        ft2.append(dir[..]);
        ft2.append("/tmp2.txt");
        var okf2: u8[>..] = [];
        okf2.append(dir[..]);
        okf2.append("/ok2.txt");
        write_file(ft2[..], "t");
        write_file(okf2[..], "o");
        let bad = watch::Filter { include: "", ignore: "", ignore_regexp: "([;x{9000}" };
        let e2, ok2 = watch::next_filtered(w, 3000, bad, buf, old);
        assert(ok2);
        assert(e2.kind == watch::KIND_CREATED);
        // The bad list takes nothing out, so the first event may be
        // the file of either name.
        assert(watch_helpers::ends_with(buf[..], "/ok2.txt") || watch_helpers::ends_with(buf[..], "/tmp2.txt"));
        delete_file(ft2[..]);
        delete_file(okf2[..]);
        watch_helpers::drain(w, 300);
    }

    // The roots of a live watcher: add_path brings the events of a
    // second tree, remove_path ends them, and the first tree goes on.
    // A missing path and a second add are refused, as is a remove of
    // a path that is not a root.
    {
        var r1: u8[>..] = [];
        r1.append(dir[..]);
        r1.append("/rt1");
        var r2: u8[>..] = [];
        r2.append(dir[..]);
        r2.append("/rt2");
        make_dir(r1[..]);
        make_dir(r2[..]);
        let m = watch::start(r1[..], true);
        assert(m > 0);
        watch_helpers::drain(m, 500);
        assert(!watch::remove_path(m, r2[..]));
        assert(watch::add_path(m, r2[..]));
        assert(!watch::add_path(m, r2[..]));
        var nope: u8[>..] = [];
        nope.append(dir[..]);
        nope.append("/rt-nope");
        assert(!watch::add_path(m, nope[..]));
        watch_helpers::drain(m, 500);
        var f2: u8[>..] = [];
        f2.append(r2[..]);
        f2.append("/b.txt");
        write_file(f2[..], "x");
        assert(watch_helpers::wait_path(m, watch::KIND_CREATED, "/rt2/b.txt", 3000) == watch::KIND_CREATED);
        var f1: u8[>..] = [];
        f1.append(r1[..]);
        f1.append("/a.txt");
        write_file(f1[..], "x");
        assert(watch_helpers::wait_path(m, watch::KIND_CREATED, "/rt1/a.txt", 3000) == watch::KIND_CREATED);
        assert(watch::remove_path(m, r2[..]));
        watch_helpers::drain(m, 500);
        write_file(f2[..], "y");
        assert(watch_helpers::no_path(m, "/rt2/b.txt", 1200));
        write_file(f1[..], "y");
        assert(watch_helpers::wait_path(m, watch::KIND_MODIFIED, "/rt1/a.txt", 3000) == watch::KIND_MODIFIED);
        // The last root stays, because a watcher without a root
        // watches nothing.
        assert(!watch::remove_path(m, r1[..]));
        assert(watch::stop(m));
        delete_file(f1[..]);
        delete_file(f2[..]);
        delete_dir(r1[..]);
        delete_dir(r2[..]);
        watch_helpers::drain(w, 300);
    }

    // The base directory: the paths of the events go out without the
    // base, the old path of a rename too. An empty base gives the
    // full paths again.
    {
        var bd: u8[>..] = [];
        bd.append(dir[..]);
        bd.append("/based");
        make_dir(bd[..]);
        let b = watch::start(bd[..], true);
        assert(b > 0);
        watch_helpers::drain(b, 500);
        assert(watch::set_base_dir(b, bd[..]));
        var bf: u8[>..] = [];
        bf.append(bd[..]);
        bf.append("/n.txt");
        write_file(bf[..], "x");
        var got: u8[>..] = [];
        assert(watch_helpers::wait_kind(b, watch::KIND_CREATED, 3000, got) == watch::KIND_CREATED);
        assert(got[..] == "n.txt");
        var bg: u8[>..] = [];
        bg.append(bd[..]);
        bg.append("/m.txt");
        assert(rename_file(bf[..], bg[..]));
        // The change of the directory itself can come first, so the
        // wait goes on until the renamed event is there.
        var buf2: u8[>..] = [];
        var old2: u8[>..] = [];
        var saw_ren = false;
        let ren_deadline = clock_ns() + 3000000000;
        while clock_ns() < ren_deadline && !saw_ren {
            buf2.clear();
            old2.clear();
            let e, ok = watch::next_event(b, 200, buf2, old2);
            if !ok { break; }
            if e.kind == watch::KIND_RENAMED {
                assert(buf2[..] == "m.txt");
                assert(old2[..] == "n.txt");
                saw_ren = true;
            }
        }
        assert(saw_ren);
        assert(watch::set_base_dir(b, ""));
        var bh: u8[>..] = [];
        bh.append(bd[..]);
        bh.append("/k.txt");
        write_file(bh[..], "x");
        var got3: u8[>..] = [];
        assert(watch_helpers::wait_kind(b, watch::KIND_CREATED, 3000, got3) == watch::KIND_CREATED);
        assert(watch_helpers::ends_with(got3[..], "/based/k.txt"));
        assert(watch::stop(b));
        delete_file(bg[..]);
        delete_file(bh[..]);
        delete_dir(bd[..]);
        watch_helpers::drain(w, 300);
    }

    // A named pipe in the tree does not stop the comparison watcher
    // when the compare of the content is on. A pipe is not a regular
    // file, so it gets no hash and no read.
    {
        var pd: u8[>..] = [];
        pd.append(dir[..]);
        pd.append("/fifo");
        make_dir(pd[..]);
        var pf: u8[>..] = [];
        pf.append(pd[..]);
        pf.append("/pipe");
        if watch_test_fifo(pf[..]) == 1 {
            let fp = watch::start(pd[..], true);
            assert(fp > 0);
            assert(watch::set_compare_contents(fp, true));
            watch_helpers::drain(fp, 500);
            var pt: u8[>..] = [];
            pt.append(pd[..]);
            pt.append("/after.txt");
            write_file(pt[..], "x");
            assert(watch_helpers::wait_path(fp, watch::KIND_CREATED, "/after.txt", 5000) == watch::KIND_CREATED);
            assert(watch::stop(fp));
            delete_file(pt[..]);
            delete_file(pf[..]);
            delete_dir(pd[..]);
        }
        watch_helpers::drain(w, 300);
    }

}
