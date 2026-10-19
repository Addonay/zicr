const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.option(std.Build.LazyPath, "shader-compiler", "Host-native sokol-shdc executable (overrides the bundled lazy dependency)");

    const debug = b.option(bool, "debug", "Enable the validation layer and debug log messages (default: Debug and ReleaseSafe)");
    const validate_non_fatal = b.option(bool, "validate_non_fatal", "Log validation errors without raising VALIDATION_FAILED") orelse false;
    const options = zicrOptions(b, debug, validate_non_fatal);

    const gpu_mod = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_mod.addOptions("zicr_options", options);

    const zicr = b.addModule("zicr", .{
        .root_source_file = b.path("src/zicr.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gpu", .module = gpu_mod }},
    });

    const autodoc = b.addObject(.{ .name = "zicr-docs", .root_module = zicr });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate the public Zig API documentation in zig-out/docs").dependOn(&install_docs.step);

    // ------------------------------------------------------------ tests

    const test_step = b.step("test", "Run the unit tests");
    const check_step = b.step("check", "Compile the library and its tests");
    const module_check = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/module_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "gpu", .module = gpu_mod }, .{ .name = "zicr", .module = zicr } },
    }) });
    test_step.dependOn(&b.addRunArtifact(module_check).step);
    check_step.dependOn(&module_check.step);

    const shader_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/shdc/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(shader_tests).step);
    check_step.dependOn(&shader_tests.step);
    const compiler_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/shdc/compiler.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(compiler_tests).step);
    check_step.dependOn(&compiler_tests.step);

    // the unit tests exercise failing validation, so validation is non-fatal for them
    const test_options = zicrOptions(b, debug, true);
    inline for (.{ "src/gpu/tests.zig", "src/gpu/api_tests.zig" }) |root| {
        const unit_tests = b.addTest(.{ .root_module = testModule(b, root, target, optimize, test_options) });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        check_step.dependOn(&unit_tests.step);
    }

    // tests ported from upstream sokol (tests/functional/sokol_gfx_test.c); like
    // upstream they run with fatal validation and a logger that doesn't abort
    const upstream_options = zicrOptions(b, debug, false);
    const upstream_step = b.step("test-upstream", "Run the tests ported from upstream sokol_gfx_test.c");
    inline for (1..5) |part| {
        const root = std.fmt.comptimePrint("src/gpu/upstream_test_{d}.zig", .{part});
        const part_tests = b.addTest(.{ .root_module = testModule(b, root, target, optimize, upstream_options) });
        const part_run = b.addRunArtifact(part_tests);
        b.step(std.fmt.comptimePrint("test-upstream-{d}", .{part}), "Run part of the upstream sokol_gfx tests").dependOn(&part_run.step);
        upstream_step.dependOn(&part_run.step);
        check_step.dependOn(&part_tests.step);
    }

    // Differential fuzzing against the original C implementation. The C header is
    // compiled only into this test tool, never into the library.
    const ref_c = b.addTranslateC(.{ .root_source_file = b.path("tools/diff/sokol_ref.h"), .target = target, .optimize = optimize });
    ref_c.addIncludePath(b.path("."));
    const fuzz_module = toolModule(b, "tools/diff/fuzz.zig", target, optimize, zicrOptions(b, true, true));
    fuzz_module.addImport("sokol_ref", ref_c.createModule());
    fuzz_module.addIncludePath(b.path("."));
    fuzz_module.addCSourceFile(.{ .file = b.path("tools/diff/sokol_ref.c"), .flags = &.{"-fno-sanitize=undefined"} });
    const fuzz = b.addExecutable(.{ .name = "zicr-diff-fuzz", .root_module = fuzz_module });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addPassthruArgs();
    b.step("test-diff", "Differential fuzzing of the core against the original C sokol_gfx.h").dependOn(&fuzz_run.step);

    // Independent C/raw/public real-GPU baseline; the C reference is test-only.
    const webgpu_include = b.option([]const u8, "webgpu-include", "Native webgpu.h include directory for the C benchmark");
    const webgpu_library = b.option([]const u8, "webgpu-library", "Native WebGPU shared library for the C benchmark");
    if (target.result.os.tag == .linux or target.result.os.tag == .windows or target.result.os.tag == .macos) {
        const bench_step = b.step("bench-tools", "Build and install independent C/raw/public GPU benchmarks");
        inline for (.{ "gl", "vulkan", "wgpu", "d3d11", "metal" }) |bench_backend| {
            const vulkan_bench = comptime std.mem.eql(u8, bench_backend, "vulkan");
            const wgpu_bench = comptime std.mem.eql(u8, bench_backend, "wgpu");
            const d3d11_bench = comptime std.mem.eql(u8, bench_backend, "d3d11");
            const metal_bench = comptime std.mem.eql(u8, bench_backend, "metal");
            const supported = if (d3d11_bench) target.result.os.tag == .windows else if (metal_bench) target.result.os.tag == .macos else target.result.os.tag == .linux;
            if (supported and (!wgpu_bench or (webgpu_include != null and webgpu_library != null))) {
                const bench = toolModule(b, "tools/bench/main.zig", target, .fast, zicrOptions(b, false, false));
                const bench_options = b.addOptions();
                bench_options.addOption([]const u8, "backend", bench_backend);
                bench.addOptions("bench_options", bench_options);
                const bench_zicr = bench.import_table.get("zicr").?;
                if (shaderModule(b, b, .{ .input = b.path("tools/bench/shaders.glsl"), .zicr = bench_zicr })) |bench_shaders| {
                    bench.addImport("bench_shaders", bench_shaders);
                    bench.addImport("harness", b.createModule(.{ .root_source_file = b.path("tools/harness/harness.zig"), .target = target, .optimize = .fast, .imports = &.{.{ .name = "zicr", .module = bench_zicr }} }));
                    const reference = b.addTranslateC(.{ .root_source_file = b.path("tools/bench/ref.h"), .target = target, .optimize = .fast });
                    reference.addIncludePath(b.path("."));
                    bench.addImport("bench_ref", reference.createModule());
                    bench.addIncludePath(b.path("."));
                    bench.addCSourceFile(.{ .file = b.path("tools/bench/ref.c"), .flags = if (metal_bench) &.{ "-x", "objective-c", "-fobjc-arc", "-O3", "-DNDEBUG", "-DZICR_BENCH_METAL", "-fno-sanitize=undefined" } else if (d3d11_bench) &.{ "-O3", "-DNDEBUG", "-DZICR_BENCH_D3D11", "-fno-sanitize=undefined" } else if (wgpu_bench) &.{ "-O3", "-DNDEBUG", "-DZICR_BENCH_WGPU", "-fno-sanitize=undefined" } else if (vulkan_bench) &.{ "-O3", "-DNDEBUG", "-DZICR_BENCH_VULKAN", "-fno-sanitize=undefined" } else &.{ "-O3", "-DNDEBUG", "-fno-sanitize=undefined" } });
                    if (wgpu_bench) {
                        bench.addSystemIncludePath(.{ .cwd_relative = webgpu_include.? });
                        bench.addObjectFile(.{ .cwd_relative = webgpu_library.? });
                        bench.addRPath(.{ .cwd_relative = std.fs.path.dirname(webgpu_library.?) orelse "." });
                    } else if (d3d11_bench) {
                        inline for (.{ "kernel32", "user32", "dxgi", "d3d11" }) |library| bench.linkSystemLibrary(library, .{});
                    } else if (metal_bench) {
                        bench.linkFramework("Metal", .{});
                        bench.linkFramework("Foundation", .{});
                        bench.linkFramework("QuartzCore", .{});
                    } else bench.linkSystemLibrary(if (vulkan_bench) "vulkan" else "GL", .{});
                    const executable = b.addExecutable(.{ .name = "zicr-bench-" ++ bench_backend, .root_module = bench });
                    const install_bench = b.addInstallArtifact(executable, .{});
                    bench_step.dependOn(&install_bench.step);
                    b.step("bench-" ++ bench_backend ++ "-tools", "Build and install one native benchmark").dependOn(&install_bench.step);
                    const run = b.addRunArtifact(executable);
                    run.addPassthruArgs();
                    b.step("bench-" ++ bench_backend, "Run a native baseline with validation disabled and checked output").dependOn(&run.step);
                }
            }
        }
    }

    // ------------------------------------------------------------ scene suite

    // the same scenes on every backend, compared with CPU-computed results
    const scene_options = zicrOptions(b, true, true);
    const scene_step = b.step("test-scenes", "Run the cross-backend scene suite on this platform's backends");
    if (sceneExecutable(b, target, optimize, scene_options)) |scenes_exe| {
        const run = b.addRunArtifact(scenes_exe);
        run.addPassthruArgs();
        scene_step.dependOn(&run.step);
    }
    const windows_scene_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    if (sceneExecutable(b, windows_scene_target, optimize, scene_options)) |scenes_exe| {
        b.step("check-scenes-windows", "Build the scene suite for Windows (D3D11, D3D12, Vulkan)").dependOn(&b.addInstallArtifact(scenes_exe, .{}).step);
    }

    // Freestanding wasm: no Emscripten runtime or native window-system dependency.
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web = toolModule(b, "tools/web/main.zig", web_target, optimize, scene_options);
    web.link_libc = null;
    const web_zicr = web.import_table.get("zicr").?;
    if (shaderModule(b, b, .{ .input = b.path("tools/scenes/scenes.glsl"), .zicr = web_zicr })) |render| {
        if (shaderModule(b, b, .{ .input = b.path("tools/scenes/compute.glsl"), .compute = true, .zicr = web_zicr })) |compute| {
            const feature = featureShaderModule(b, web_zicr) orelse return;
            web.addImport("scenes", b.createModule(.{
                .root_source_file = b.path("tools/scenes/scenes.zig"),
                .target = web_target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "zicr", .module = web_zicr }, .{ .name = "scene_shaders", .module = render }, .{ .name = "scene_compute_shaders", .module = compute }, .{ .name = "scene_feature_shaders", .module = feature } },
            }));
            const wasm = b.addExecutable(.{ .name = "zicr-scenes", .root_module = web });
            wasm.entry = .disabled;
            wasm.rdynamic = true;
            const install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
            const check_web = b.step("check-scenes-web", "Build freestanding browser scenes and WebGL2 shim");
            check_web.dependOn(&install.step);
            const test_web = b.step("test-web", "Run WebGL2 and WebGPU scenes in headless Chromium (CHROMIUM overrides binary)");
            const format_tests = b.addSystemCommand(&.{"node"});
            format_tests.addFileArg(b.path("tools/web/formats.test.mjs"));
            b.step("test-web-formats", "Check native-to-Web-IDL texture format spellings").dependOn(&format_tests.step);
            test_web.dependOn(&format_tests.step);

            inline for (.{ "webgl2", "wgpu" }) |backend_name| {
                const web_test = b.addSystemCommand(&.{"node"});
                web_test.addFileArg(b.path("tools/web/test.mjs"));
                web_test.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
                web_test.addArg(backend_name);
                web_test.step.dependOn(check_web);
                b.step("test-web-" ++ backend_name, "Run browser " ++ backend_name ++ " scenes").dependOn(&web_test.step);
                test_web.dependOn(&web_test.step);
                const hardware_test = b.addSystemCommand(&.{"node"});
                hardware_test.setEnvironmentVariable("ZICR_GPU", "hardware");
                hardware_test.addFileArg(b.path("tools/web/test.mjs"));
                hardware_test.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
                hardware_test.addArg(backend_name);
                hardware_test.step.dependOn(check_web);
                b.step("test-web-hardware-" ++ backend_name, "Run " ++ backend_name ++ " scenes requiring a hardware browser adapter").dependOn(&hardware_test.step);

                const firefox_test = b.addSystemCommand(&.{"node"});
                firefox_test.setEnvironmentVariable("ZICR_BROWSER", "firefox");
                firefox_test.addFileArg(b.path("tools/web/test.mjs"));
                firefox_test.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
                firefox_test.addArg(backend_name);
                firefox_test.step.dependOn(check_web);
                b.step("test-firefox-" ++ backend_name, "Run browser " ++ backend_name ++ " scenes in isolated Firefox").dependOn(&firefox_test.step);
            }
            inline for (.{ "index.html", "scenes.js", "gl.js", "wgpu.js", "formats.mjs" }) |file| {
                check_web.dependOn(&b.addInstallFileWithDir(b.path("tools/web/" ++ file), .{ .custom = "web" }, file).step);
            }
        }
    }

    // ------------------------------------------------------------ GPU smoke tests

    inline for (.{
        .{ "test-gl", "tools/gl_smoke.zig", "zicr-gl-smoke", "Verify OpenGL and GLES rendering with surfaceless EGL" },
        .{ "test-vk", "tools/vk_smoke.zig", "zicr-vk-smoke", "Verify Vulkan rendering with the system Vulkan loader" },
        .{ "test-wgpu", "tools/wgpu_smoke.zig", "zicr-wgpu-smoke", "Verify WebGPU rendering with a wgpu-native library" },
    }) |smoke| {
        const exe = b.addExecutable(.{ .name = smoke[2], .root_module = toolModule(b, smoke[1], target, optimize, options) });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(smoke[0], smoke[3]).dependOn(&run.step);
    }

    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const d3d_module = toolModule(b, "tools/d3d11_smoke.zig", windows_target, optimize, options);
    d3d_module.link_libc = null;
    const d3d_smoke = b.addExecutable(.{ .name = "zicr-d3d11-smoke", .root_module = d3d_module });
    b.step("check-d3d11", "Build the D3D11 rendering smoke executable").dependOn(&b.addInstallArtifact(d3d_smoke, .{}).step);

    // Metal can only run on Apple platforms; this step type-checks the backend
    // for macOS and iOS without linking.
    const metal_step = b.step("check-metal", "Type-check the Metal backend for macOS and iOS targets");
    inline for (.{
        std.Target.Query{ .cpu_arch = .aarch64, .os_tag = .macos },
        std.Target.Query{ .cpu_arch = .x86_64, .os_tag = .macos },
        std.Target.Query{ .cpu_arch = .aarch64, .os_tag = .ios },
    }) |query| {
        const apple_target = b.resolveTargetQuery(query);
        const apple_module = toolModule(b, "tools/metal_check.zig", apple_target, optimize, options);
        apple_module.link_libc = null;
        const apple_harness = b.createModule(.{ .root_source_file = b.path("tools/harness/harness.zig"), .target = apple_target, .optimize = optimize, .imports = &.{.{ .name = "zicr", .module = apple_module.import_table.get("zicr").? }} });
        apple_module.addImport("harness", apple_harness);
        const apple_zicr = apple_module.import_table.get("zicr").?;
        if (shaderModule(b, b, .{ .input = b.path("tools/scenes/scenes.glsl"), .zicr = apple_zicr })) |render| {
            if (shaderModule(b, b, .{ .input = b.path("tools/scenes/compute.glsl"), .compute = true, .zicr = apple_zicr })) |compute| {
                const feature = featureShaderModule(b, apple_zicr) orelse return;
                apple_module.addImport("scenes", b.createModule(.{
                    .root_source_file = b.path("tools/scenes/scenes.zig"),
                    .target = apple_target,
                    .optimize = optimize,
                    .imports = &.{ .{ .name = "zicr", .module = apple_zicr }, .{ .name = "scene_shaders", .module = render }, .{ .name = "scene_compute_shaders", .module = compute }, .{ .name = "scene_feature_shaders", .module = feature } },
                }));
            }
        }

        const metal_check = b.addObject(.{ .name = "zicr-metal-check-" ++ @tagName(query.os_tag.?) ++ "-" ++ @tagName(query.cpu_arch.?), .root_module = apple_module });
        metal_step.dependOn(&metal_check.step);
    }
}

fn sceneExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) ?*std.Build.Step.Compile {
    const module = toolModule(b, "tools/scenes/main.zig", target, optimize, options);
    if (target.result.os.tag == .windows) module.link_libc = null;
    if (target.result.os.tag.isDarwin()) {
        module.linkFramework("Metal", .{});
        module.linkFramework("Foundation", .{});
        if (target.result.os.tag == .macos) {
            module.linkFramework("AppKit", .{});
            module.linkFramework("QuartzCore", .{});
        }
    }
    const zicr = module.import_table.get("zicr").?;
    const render = shaderModule(b, b, .{ .input = b.path("tools/scenes/scenes.glsl"), .zicr = zicr }) orelse return null;
    const compute = shaderModule(b, b, .{ .input = b.path("tools/scenes/compute.glsl"), .compute = true, .zicr = zicr }) orelse return null;
    const harness = b.createModule(.{ .root_source_file = b.path("tools/harness/harness.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zicr", .module = zicr }} });
    module.addImport("scene_shaders", render);
    module.addImport("scene_compute_shaders", compute);
    module.addImport("scene_feature_shaders", featureShaderModule(b, zicr) orelse return null);
    module.addImport("harness", harness);
    return b.addExecutable(.{ .name = "zicr-scenes", .root_module = module });
}

fn featureShaderModule(b: *std.Build, zicr: *std.Build.Module) ?*std.Build.Module {
    return shaderModule(b, b, .{ .input = b.path("tools/scenes/features.glsl"), .zicr = zicr, .slangs = "glsl410:hlsl5:metal_macos:metal_ios:metal_sim:spirv_vk" });
}

fn zicrOptions(b: *std.Build, debug: ?bool, validate_non_fatal: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(?bool, "debug", debug);
    options.addOption(bool, "validate_non_fatal", validate_non_fatal);
    return options;
}

fn testModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
    module.addOptions("zicr_options", options);
    return module;
}

/// A tool executable importing its own instance of the library, built with `options`.
fn toolModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const gpu_module = b.createModule(.{ .root_source_file = b.path("src/gpu/root.zig"), .target = target, .optimize = optimize });
    gpu_module.addOptions("zicr_options", options);
    const zicr = b.createModule(.{ .root_source_file = b.path("src/zicr.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gpu", .module = gpu_module }} });
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zicr", .module = zicr }},
    });
}

// ---------------------------------------------------------------- shaders

pub const ShaderOptions = struct {
    /// Annotated GLSL in sokol-shdc syntax.
    input: std.Build.LazyPath,
    /// Compiles for GL 4.3 and GLES 3.1 instead of GL 4.1 and GLES 3.0/WebGL2,
    /// required for compute shaders and storage resources on GL.
    compute: bool = false,
    /// Optional colon-separated target subset for feature-specific shaders.
    /// A generated desc returns null for backends omitted from this set.
    slangs: ?[]const u8 = null,
    /// Host-native sokol-shdc executable. Use a locally built compiler on hosts
    /// without a bundled binary; the executable must support bare_yaml output.
    compiler: ?std.Build.LazyPath = null,
    /// The zicr module the generated code imports.
    zicr: *std.Build.Module,
};

/// Compiles a shader file for every backend and returns a module with one
/// namespace per program, providing bind slots and `desc(backend)`.
/// Returns null until the lazy shader compiler dependency has been fetched.
pub fn addShaderModule(b: *std.Build, zicr_dep: *std.Build.Dependency, options: ShaderOptions) ?*std.Build.Module {
    return shaderModule(b, zicr_dep.builder, options);
}

fn shaderModule(b: *std.Build, owner: *std.Build, options: ShaderOptions) ?*std.Build.Module {
    const host = owner.graph.host;
    const configured: ?std.Build.LazyPath = if (owner.user_input_options.get("shader-compiler")) |value| switch (value) {
        .scalar => |path| .{ .cwd_relative = path },
        .lazy_path => |path| path,
        else => null,
    } else null;
    const compiler = options.compiler orelse configured orelse bundled: {
        const sub_path = @import("tools/shdc/compiler.zig").bundledPath(host.result.os.tag, host.result.cpu.arch) orelse {
            // Keep library-only dependency builds usable on unsupported hosts.
            // Requesting a shader-dependent step fails with an actionable message.
            const failure = b.addFail("No bundled shader compiler for this host. Supply -Dshader-compiler=/path/to/sokol-shdc, configure the dependency's shader-compiler path, or set ShaderOptions.compiler.");
            const files = b.addWriteFiles();
            files.step.dependOn(&failure.step);
            return b.createModule(.{ .root_source_file = files.add("shaders.zig", "@compileError(\"a host-native shader compiler is required\");\n") });
        };
        const shdc_dep = owner.lazyDependency("sokol_tools_bin", .{}) orelse return null;
        break :bundled shdc_dep.path(sub_path);
    };
    const generator = owner.addExecutable(.{
        .name = "zicr-shdc",
        .root_module = owner.createModule(.{ .root_source_file = owner.path("tools/shdc/main.zig"), .target = host, .optimize = .safe }),
    });
    const run = b.addRunArtifact(generator);
    run.addFileArg(compiler);
    run.addFileArg(options.input);
    const output = run.addOutputFileArg("shaders.zig");
    _ = run.addOutputDirectoryArg("shdc");
    run.addArg(options.slangs orelse if (options.compute)
        "glsl430:glsl310es:hlsl5:metal_macos:metal_ios:metal_sim:wgsl:spirv_vk"
    else
        "glsl410:glsl300es:hlsl5:metal_macos:metal_ios:metal_sim:wgsl:spirv_vk");
    return b.createModule(.{
        .root_source_file = output,
        .imports = &.{.{ .name = "zicr", .module = options.zicr }},
    });
}
