const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const sqlite_zstd_path = b.option([]const u8, "sqlite-zstd-lib-path", "Path to sqlite-zstd library");
    const sqlite_regex_path = b.option([]const u8, "sqlite-regex-lib-path", "Path to sqlite-regex library");
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const opts = b.addOptions();
    opts.addOption([]const u8, "program_name", "clogite");
    opts.addOption(std.SemanticVersion, "program_version", std.SemanticVersion.parse("0.0.0") catch unreachable);

    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize, .fts5 = true });
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("clogite", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite.module("sqlite") },
            .{ .name = "vaxis", .module = vaxis.module("vaxis" ) },
        },
    });

    mod.addOptions("program_info", opts);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "clogite",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "clogite" is the name you will use in your source code to
                // import this module (e.g. `@import("clogite")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "clogite", .module = mod },
            },
        }),
    });
    exe.lto = .full;

    const zstd_path = b.pathJoin(&.{ b.build_root.path.?, "deps", "sqlite-zstd" });
    const patch_zstd_static = b.addSystemCommand(&.{ "sed", "-i", "s/crate-type = \\[\"cdylib\"\\]/crate-type = [\"staticlib\", \"cdylib\"]/", b.pathJoin(&.{ zstd_path, "Cargo.toml" }) });
    const patch_zstd_log = b.addSystemCommand(&.{ "sed", "-i", "/log::info/d", b.pathJoin(&.{ zstd_path, "src", "create_extension.rs" }) });
    
    const regex_path = b.pathJoin(&.{ b.build_root.path.?, "deps", "sqlite-regex" });
    const patch_regex_static = b.addSystemCommand(&.{ "sed", "-i", "s/crate-type =/crate-type = [\"staticlib\", \"cdylib\"]/", b.pathJoin(&.{ regex_path, "Cargo.toml" }) });

    if (sqlite_zstd_path) |path| {
        mod.addLibraryPath(.{ .cwd_relative = path });
        mod.linkSystemLibrary("sqlite_zstd", .{ .preferred_link_mode = .static });

        mod.linkSystemLibrary("gcc_s", .{});
        if (target.result.os.tag != .windows) {
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("m", .{});
        }
    } else {
        installRustCrate(
        b,
        mod,
        target,
        exe,
        "https://github.com/phiresky/sqlite-zstd",
        &.{ patch_zstd_static, patch_zstd_log },
        false,
        &.{ "gcc_s" },
        null,
        &.{ "build_extension" },
        null,
    ) catch |e| {
            std.log.err("Failed to install sqlite-zstd rust crate: {any}", .{e});
            return;
        };
    }

    if (sqlite_regex_path) |path| {
        mod.addLibraryPath(.{ .cwd_relative = path });
        mod.linkSystemLibrary("sqlite_regex", .{ .preferred_link_mode = .dynamic });

        exe.addRPath(.{ .cwd_relative = regex_path });

        if (target.result.os.tag != .windows) {
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("m", .{});
        }
    } else {
        installRustCrate(
        b,
        mod,
        target,
        exe,
        "https://github.com/asg017/sqlite-regex",
        &.{ patch_regex_static },
        true, // As I cannot find a way to reliably and correctly statically link 2 rust libraries due to their stdlib bundling method
        null,
        null,
        null,
        null,
    ) catch |e| {
            std.log.err("Failed to install sqlite-regex rust crate: {any}", .{e});
            return;
        };
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

inline fn repoNameFromUrl(alloc: std.mem.Allocator, url: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, url, "/");
    _ = it.next(); // Skip https
    _ = it.next(); // Skip //
    _ = it.next(); // Skip github
    _ = it.next(); // Skip owner

    const repo = it.next() orelse return null;
    const clean_repo = if (std.mem.endsWith(u8, repo, ".git")) repo[0 .. repo.len - 4] else repo;
    return alloc.dupe(u8, clean_repo) catch null;
}

fn installRustCrate(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    exe: *std.Build.Step.Compile,
    repo_url: []const u8,
    patches: ?[]const *std.Build.Step.Run,
    dynamic: bool,
    extra_system_libs: ?[]const []const u8,
    relative_cargo_path: ?[]const u8,
    features: ?[]const []const u8,
    custom_lib_dir: ?[]const []const u8,
) !void {
    const alloc = b.allocator;
    const name = repoNameFromUrl(alloc, repo_url) orelse repo_url;
    defer if (std.mem.eql(u8, name, repo_url)) alloc.free(name);
    const build_path = b.pathJoin(&.{ b.build_root.path.?, "deps", name});
    const cargo_toml = b.pathJoin(&.{ build_path, relative_cargo_path orelse "Cargo.toml" });
    const check_and_clone = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt("if [ ! -d {s} ]; then git clone --depth 1 {s} {s}; fi", .{
            build_path, repo_url, build_path,
        }),
    });
    check_and_clone.has_side_effects = true;
    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release", "--manifest-path", cargo_toml });
    if (features) |f| {
        for (f) |feature| {
            cargo_build.addArgs(&.{ "--features", feature });
        }
    }

    if (patches) |p| {
        for (p) |patch| {
            patch.step.dependOn(&check_and_clone.step);
            cargo_build.step.dependOn(&patch.step);
        }
    }
    exe.step.dependOn(&cargo_build.step);

    const lib_dir: []const u8 = if (custom_lib_dir) |cld| blk: {
        const paths = try alloc.alloc([]const u8, cld.len + 1);
        defer alloc.free(paths);

        paths[0] = build_path;
        @memcpy(paths[1..], cld);

        break :blk b.pathJoin(paths);
    } else b.pathJoin(&.{ build_path, "target", "release" });
    mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    const replace_name = try alloc.dupe(u8, name);
    std.mem.replaceScalar(u8, replace_name, '-', '_');
    defer alloc.free(replace_name);
    mod.linkSystemLibrary(replace_name, .{ .preferred_link_mode = if (dynamic) .dynamic else .static});

    if (target.result.os.tag != .windows) {
        mod.linkSystemLibrary("pthread", .{});
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("m", .{});
        if (extra_system_libs) |esl| {
            for (esl) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        }
    }
}
