# goose-watch

[![ci](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml)

File watching for the [Goose](https://github.com/aardappel/goose) programming language. The package watches a
directory and gives the path and the kind of each change.

The C part of the package uses only libc. On Linux the package uses
inotify. On the other systems the package compares the times and the
sizes of the files. The kinds are the same on every system.

The environment variable GOOSE_WATCH_COMPARE asks for the comparison
watcher on every system. The CI runs the test suite twice. One run uses
the variable and one does not. So the kinds of that path are proven on
every system.

## Install

Add this to the root file of the program that uses it:

```goose
import watch from "rekanalar/goose-watch@v0.2.0";
```

## API

| Function | What it does |
|---|---|
| `start(path, deep)` | start a watcher on a directory, and give the handle |
| `next(handle, timeout_ms, out_path)` | wait for the next change |
| `next_event(handle, timeout_ms, out_path, out_old)` | the same, and give the old path of a rename |
| `next_filtered(handle, timeout_ms, filter, out_path, out_old)` | the same, and drop the paths that the filter refuses |
| `next_batch(handle, timeout_ms, quiet_ms, filter, store, events)` | wait for a burst, and merge it into one event for each path |
| `set_poll_interval(handle, ms)` | set the pause of the comparison watcher, 1 to 60000 ms |
| `set_follow_symlinks(handle, follow)` | go into linked directories, or not |
| `stop(handle)` | end the watcher |
| `kind_name(kind)` | give the name of a kind |
| `backend(out_name)` | give the name of the watcher of the system |
| `glob_match(pattern, text)` | the match that the filter uses |
| `allowed(filter, path)` | tell whether the filter lets a path through |

The kinds are `KIND_NONE`, `KIND_CREATED`, `KIND_MODIFIED`,
`KIND_DELETED` and `KIND_RENAMED`.

The `next` call gives the event and a flag. The path of the event goes
out in the buffer of the caller. The buffer must outlive the event.

The timeout is in milliseconds. A timeout of 0 waits with no limit. A
negative timeout does not wait. It gives the next event at once, if one
waits.

### Rename

A rename inside the watched tree gives one `KIND_RENAMED` event. The
`path` is the new path. The `old_path` is the old path. Use `next_event`
to get the old path.

On Linux the two events of the kernel join by their cookie. The other
systems match the inode of the file.

A move out of the watched tree gives `KIND_DELETED`. A move into it
gives `KIND_CREATED`.

Before v0.2.0, the path of a rename was the old path.

### Filter

A filter has two lists, `include` and `ignore`. A list is a text of
patterns with a semicolon between them.

A `*` takes any run of bytes, and a `?` takes one byte. A pattern with
no slash fits the name of the file. A pattern with a slash fits the
whole path.

An empty `include` takes every path. An `ignore` pattern wins over
`include`.

### Burst merge

`next_batch` waits for a first change. Then it reads until no change
comes for `quiet_ms`. The result is one event for each path, in the
order of the first change.

The merge rules are these:

- A create and a modify give a create.
- A create and a delete give nothing.
- A delete and a create give a modify.
- A modify and a delete give a delete.
- A rename stays as it is.

The paths go on the `store` buffer, which must outlive the events.

## Example

```goose
import std;
import watch from "rekanalar/goose-watch@v0.2.0";

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
directory, unless the caller calls `set_follow_symlinks`. The package
does not detect a loop of links. The depth limit and the limit of 512
directories stop it.

On Linux the package sees every change at once, and it tells a rename
from a removal.

On the other systems the package looks at the files every 50 ms.
`set_poll_interval` changes that pause. It has no effect on the inotify
watcher.

A change that starts and ends between two looks may
be missed on those systems. A file that changes and keeps its time and
its size may look unchanged on those systems. The comparison watcher
finds a rename by the inode. A file that is copied and the original
removed looks like a removal and a new file.

A directory that is made after the start of a deep watcher on Linux is
not watched. Turning `set_follow_symlinks` off does not remove the
watches that it added on Linux.

The filter has no `**` and no character classes. The burst merge keeps
one event for each path, so it cannot show how many times a file changed.

## Test

```bash
goose run test/run.goose
goose run examples/watch.goose
goose run examples/batch.goose
```

## License

MIT
