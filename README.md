# goose-watch

[![ci](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/rekanalar/goose-watch/actions/workflows/ci.yml)

File watching for the [Goose](https://github.com/aardappel/goose) programming language. The package watches a
directory and gives the path and the kind of each change.

The C part of the package uses the C library of the system. On Windows
it uses the wide calls of Windows, so a path may hold any character. On
Linux the package uses inotify. On macOS and Windows the package
compares the times and the sizes of the files. The kinds are the same
on every system.

The environment variable GOOSE_WATCH_COMPARE asks for the comparison
watcher on every system. The CI runs the test suite twice. One run uses
the variable and one does not. So the kinds of that path are proven on
every system.

## Install

Add these two lines to the root file of the program that uses it:

```goose
import watch from "rekanalar/goose-watch@v1.1.0";
import glob from "rekanalar/goose-glob@v1.2.0";
```

The filter of the watcher uses the package `goose-glob`. A package that
needs another package must have that package declared in the root file
of the program. If the second line is missing, the compiler names the
line to add.

The CI runs the gate on Linux, macOS and Windows. It uses Goose v2026.4
and v2026.3 on each.

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
| `set_compare_contents(handle, on)` | compare the content of a file, or not |
| `set_depth(handle, depth)` | set the number of the levels of subdirectories to watch |
| `set_base_dir(handle, dir)` | set the base of the paths of the events |
| `add_path(handle, dir)` | add a root to a live watcher |
| `remove_path(handle, dir)` | take a root out of a live watcher |
| `stop(handle)` | end the watcher |
| `group_add(group, path, deep)` | start a watcher and put it in the group |
| `group_next(group, timeout_ms, which, out_path, out_old)` | the next event of any watcher of the group |
| `group_remove(group, which)` | end one watcher of the group and take it out |
| `group_close(group)` | end every watcher of the group |
| `kind_name(kind)` | give the name of a kind |
| `backend(out_name)` | give the name of the watcher of the system |
| `glob_match(pattern, text)` | the match that the filter uses. The text is a whole path. |
| `any_match(list, path)` | tell whether one pattern of a list fits the path |
| `allowed(filter, path)` | tell whether the filter lets a path through |

The kinds are `KIND_NONE`, `KIND_CREATED`, `KIND_MODIFIED`,
`KIND_DELETED`, `KIND_RENAMED` and `KIND_ATTRIB`.

The event holds the flag `is_dir`. It is true when the path is a
directory. `KIND_ATTRIB` says that the mode of the path changed and the
content did not. `chmod` of a file gives it on Linux. The comparison
watcher gives it when only the mode differs.

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

A filter has three lists, `include`, `ignore` and `ignore_regexp`. A list
is a text of patterns with a semicolon between them.

The pattern is a glob pattern of the package `goose-glob`. The syntax is
that syntax:

| Pattern | Matches |
|---|---|
| `*` | any bytes in one segment |
| `**` | any number of segments, when it is a whole segment |
| `?` | one byte |
| `[abc]` | one byte from the set |
| `[a-c]` | one byte from the range |
| `[!abc]` | one byte that is not in the set |
| `{a,b}` | either alternative |
| `\x` | the byte x, as a literal |

A pattern with no slash fits the name of the file. A pattern with a
slash fits the whole path.

An empty `include` takes every path. An `ignore` pattern wins over
`include`.

The `ignore_regexp` list holds regular expressions. The syntax is the
syntax of the `regex` module of the standard library. A regular
expression fits a path when it matches anywhere in the path, because
that module has no anchors. A pattern that the module refuses matches
nothing, so a bad pattern never stops the watcher. The module builds
its tables before the first search, so a search costs one step per
byte of the path. No pattern can make the search slow.

Before v0.3.0, the filter had its own matcher. That matcher had no
`**` and no class of characters. A star crossed a separator, so the
pattern `src/*.c` fitted the path `src/x/y.c`. It does not fit now.
Write `src/**/*.c` for that path.

### The compare of the content

`set_compare_contents(handle, true)` makes the comparison watcher read
the content of every file at every look. Then a write that keeps the
size and the time of the file gives a `KIND_MODIFIED` event. The flag
is off by default, as the option of `notify` is off by default.

The flag has no effect on the inotify watcher. That watcher sees every
write at once.

A look with the flag on reads every file of the tree, so a big tree
costs time. The hash of the content has 64 bits, so a rare change can
hide behind a collision. Only a regular file gets a hash. A pipe or a
device is never read, so it cannot stop the watcher.

### The depth

`set_depth(handle, depth)` sets the number of the levels of
subdirectories that the watcher watches. The root directory is level 0.
A depth of -1 watches every level, and is the default. A depth of 0
watches the root only. A depth of n watches the root and n levels below
it, as the `depth` option of `chokidar` does.

A change takes effect at once. The comparison watcher takes a new look
at the trees. A value below -1 is refused.

### The roots of a live watcher

`add_path(handle, dir)` adds a directory as a root of a live watcher.
The events of the new tree come like the events of the tree of
`start`. The comparison watcher takes the entries of the new tree in
with no events. The inotify watcher gives a created event for each
entry.

`remove_path(handle, dir)` takes a root out. The entries of the tree
give no event after the call. The `Remove` call of `fsnotify` gives no
event either. The `unwatch` call of `chokidar` gives no event. Give
the path as the exact text of the root.

Both calls fail for a path that is not a directory. They fail too for a
path that is already a root, and for a closed watcher. The removal of
the last root fails too, because a watcher without a root watches
nothing.

Keep the roots apart. A root under another root shares its entries.
The removal of the outer root keeps the inner one working.

### The base of the paths

`set_base_dir(handle, dir)` makes the paths of the events relative to
the base. A path that is the base or under it goes out without the
base. An empty base, the default, gives the full paths, as `chokidar`
gives the paths relative to its `cwd`.

A change takes effect at once. The old path of a rename is short too.

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
import watch from "rekanalar/goose-watch@v1.1.0";
import glob from "rekanalar/goose-glob@v1.2.0";

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

## Security

The package watches the directories that a caller names. These protections
go beyond the reference libraries.

- The package follows no symbolic link into another directory, unless the
  caller calls `set_follow_symlinks`. The option `followSymlinks` of
  `chokidar` is on by default. A link can take the watcher out of the
  tree that the caller named. A loop of links is cut at 64 levels.
- The burst merge keeps one event for each path. A file that changes many
  times gives one event, so it cannot flood the caller.

These risks stay.

- The package reads the names of the files of a directory that the caller
  names. A caller that watches a directory with secrets must trust that
  directory.
- The comparison watcher reads the content of the files that it watches
  when the caller turns the compare on. It reads every byte that it may
  read.
- The package writes nothing and runs no command.

## Limits

The package follows no symbolic link into another directory, unless the
caller calls `set_follow_symlinks`. A loop of links is cut at 64 levels.
A tree that grows while the walk of the comparison watcher runs may
confuse one look. The next look fixes it.

On Linux the package sees every change at once, and it tells a rename
from a removal. A directory that appears under a deep watcher is
watched, and its entries give created events. A directory that goes
leaves the table of the watches. The kernel cannot give its watch
number to the wrong path.

On the other systems the package looks at the tree every 50 ms.
`set_poll_interval` changes that pause. It has no effect on the inotify
watcher.

On Windows the comparison watcher finds a rename by the number of the
file. A system that does not give the right to make symbolic links has
no link to follow.

A change that starts and ends between two looks may be missed on those
systems. A file that changes and keeps its time and its size may look
unchanged on those systems. The caller turns the compare of the
content on to see it. The comparison watcher finds a rename by the
inode. A file that is copied while the original is removed looks like
a removal and a new file.

The burst merge keeps one event for each path, so it cannot show how
many times a file changed.

Two options of `chokidar` stay out. The option `ignoreInitial` tells
the watcher to give no event for the entries of a tree that it sees
first. `notify`, `fsnotify` and `watchdog` have no such option. The
package gives the entries of a new subtree as created events. The
option `alwaysStat` tells the watcher to give the stat of a path with
every event. `fsnotify` and `watchdog` give no stat with an event, and
the package gives none.

## The disagreements with the other languages

The rule of the project is hard. A gap stays in one case. The mature
libraries of Python, Node, Rust and Go disagree on the behavior, and no
standard decides it. Three such gaps stay:

- **Open and close of a file.** `watchdog` gives `FileOpenedEvent` and
  `FileClosedEvent` on Linux. `notify` gives access events on Linux
  only. `chokidar` and `fsnotify` give none. The package gives none.
- **The event of the parent of a change.** `watchdog` gives
  `DirModified` for the directory that holds the changed file. `fsnotify`
  gives none. `chokidar` does not give it by default. The package gives
  none.
- **The count of the events of one burst.** A push backend gives one
  event per write. A poll backend gives one per look. `fsnotify` does
  not merge. `chokidar` merges with `awaitWriteFinish`. The package
  merges in `next_batch`, and the caller picks the merge.

## Changes that break old code

The struct `Event` holds the new field `is_dir`. Code that builds an
`Event` value must set the field. Code that reads only the old fields
works.

The constant `KIND_ATTRIB` is new, and the value 5 was unknown before.

## Test

```bash
goose run test/run.goose
goose run examples/watch.goose
goose run examples/batch.goose
goose run examples/filter.goose
goose run examples/group.goose
```

## License

MIT
