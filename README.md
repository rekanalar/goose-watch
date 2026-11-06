# goose-watch

[![ci](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml)

File watching for the Goose programming language. The package watches a
directory and gives the path and the kind of each change.

The C part of the package uses only libc. On Linux the package uses
inotify. On the other systems the package compares the times and the
sizes of the files. The kinds are the same on every system.

The environment variable GOOSE_WATCH_COMPARE asks for the comparison
watcher on every system. The test suite uses it, so the kinds of that
path are proven on every system.

## Install

Add this to the root file of the program that uses it:

```goose
import watch from "rekanalar/goose-watch@v0.1.0";
```

## API

| Function | What it does |
|---|---|
| `start(path, deep)` | start a watcher on a directory, and give the handle |
| `next(handle, timeout_ms, out_path)` | wait for the next change |
| `stop(handle)` | end the watcher |
| `kind_name(kind)` | give the name of a kind |
| `backend(out_name)` | give the name of the watcher of the system |

The kinds are `KIND_NONE`, `KIND_CREATED`, `KIND_MODIFIED`,
`KIND_DELETED` and `KIND_RENAMED`.

The `next` call gives the event and a flag. The path of the event goes
out in the buffer of the caller. The buffer must outlive the event.

The timeout is in milliseconds. A timeout of 0 waits with no limit. A
negative timeout does not wait. It gives the next event at once, if one
waits.

## Example

```goose
import std;
import watch from "rekanalar/goose-watch@v0.1.0";

fn main() {
    var got: u8[>..] = [];
    let w = watch::start("/tmp/build", false);
    if w == 0 { return 1; }
    let e, ok = watch::next(w, 5000, got);
    if ok && e.kind != watch::KIND_NONE {
        print(watch::kind_name(e.kind));
        print(" ");
        print(e.path[..]);
        print("\n");
    }
    watch::stop(w);
    return 0;
}
```

## Limits

The program holds 16 open watchers at a time. The tree is at most 32
levels deep. The package follows no symbolic link into another
directory.

On Linux the package sees every change at once, and it tells a rename
from a removal. On the other systems the package looks at the files
every 50 ms. A change that starts and ends between two looks may be
missed on those systems. A file that changes and keeps its time and its
size may look unchanged on those systems. A rename on those systems
gives a removal and a new file, not a rename.

## License

MIT
