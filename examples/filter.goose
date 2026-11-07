// An example for the watch package.
//
// It shows the filter of the watcher. The filter takes the full glob
// syntax of the package goose-glob.
//
// Run with: goose run examples/filter.goose

import std;
import glob from "rekanalar/goose-glob@v1.0.1";
import watch from "..";

fn main() {
    // A filter that takes the Go files under the source folder, and that
    // drops the temporary files.
    let f = watch::Filter { include: "src/**/*.go", ignore: "**/*~" };

    print("src/main.go    : ");
    print(watch::allowed(f, "src/main.go"));
    print("src/a/b/x.go   : ");
    print(watch::allowed(f, "src/a/b/x.go"));
    print("src/a/b/x.txt  : ");
    print(watch::allowed(f, "src/a/b/x.txt"));
    print("src/a/x.go~    : ");
    print(watch::allowed(f, "src/a/x.go~"));
    print("other/x.go     : ");
    print(watch::allowed(f, "other/x.go"));

    // A pattern with a class of characters.
    print("log[0-9].txt   : ");
    print(watch::glob_match("log[0-9].txt", "log7.txt"));
    print("logx.txt       : ");
    print(watch::glob_match("log[0-9].txt", "logx.txt"));

    // The glob package gives the same answer.
    print("glob says      : ");
    print(glob::matches("src/a/b/x.go", "src/**/*.go"));
    return 0;
}
