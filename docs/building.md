# Building

This document contains instructions for how to build Godot Jolt from source.

*See [`hacking.md`][hck] for details aimed at developers.*

## Table of Contents

- [Building for Windows](#building-for-windows)
- [Building for Linux](#building-for-linux)
- [Building for macOS](#building-for-macos)
- [Building for iOS](#building-for-ios)
- [Building for Android](#building-for-android)
- [Building for double-precision](#building-for-double-precision)
- [New source files and IntelliSense](#new-source-files-and-intellisense)

## New source files and IntelliSense

The root `CMakeLists.txt` recursively discovers `src/*.cpp` and `src/*.hpp` with
`CONFIGURE_DEPENDS`. This includes `src/rollback/jolt_rollback.cpp` and
`src/rollback/jolt_rollback.hpp`; no separate source-list entry is needed.

After adding source files, re-run configuration to refresh the build graph and
IntelliSense compilation database. From the x64 Native Tools Command Prompt,
in the repository root:

```sh
cmake --preset windows-msvc-x64
```

This configures the project without building the extension. The presets enable
`CMAKE_EXPORT_COMPILE_COMMANDS`, which generates
`build/windows-msvc-x64/compile_commands.json` for this preset. Do not edit that
generated file manually.

The local VS Code settings use that database through
`C_Cpp.default.compileCommands`. Open this repository as the workspace folder.
If using another preset, point that setting to its corresponding
`build/<preset>/compile_commands.json`. With CMake Tools installed, selecting the
matching configure preset and running **CMake: Configure** is the editor equivalent.
If Microsoft C/C++ IntelliSense remains stale after configuration, run
**C/C++: Reset IntelliSense Database**.

Configuration refreshes the source-file list; dependency headers and generated
headers must also exist for complete IntelliSense. On a fresh checkout, follow
the platform build instructions below to prepare those dependencies.

When ready to compile, use the existing build preset, for example:

```sh
cmake --build --preset windows-msvc-x64-editor-debug
```

The rollback files are compiled into the existing extension target. They do not
yet enable rollback automatically: see [rollback integration notes](rollback.md)
for the remaining adapter and Godot binding work.

## Building for Windows

Prerequisites:

- Git 2.25 or newer
- CMake 3.22 or newer
- Python 3.8 or newer
- Visual Studio 2022 (with the "Desktop development with C++" workload)
  - You can also use the more lightweight "Build Tools for Visual Studio 2022" instead
- (Optional) Visual Studio's [clang-cl][ccl] component
  - If you wish to compile with LLVM clang-cl instead of Visual C++

⚠️ These commands will build binaries for 64-bit systems. If you instead wish to build binaries for
32-bit systems then replace `x64` with `x86`.

⚠️ These commands must be run from one of Visual Studio's "[Native Tools Command Prompt][cmd]" in
order for CMake to find the correct toolchain. Make sure you pick the one appropriate for your
target architecture (x64 or x86).

⚠️ Visual Studio's "Developer Command Prompt" and "Developer PowerShell" will not work when
targeting x64 due to them exposing an x86 toolchain. Use the "x64 Native Tools Command Prompt"
instead.

Using Microsoft Visual C++:

```sh
# Generate the build directory
cmake --preset windows-msvc-x64

# Build non-editor binaries and install them into the examples project
cmake --build --preset windows-msvc-x64-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset windows-msvc-x64-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-msvc-x64 --config Distribution --prefix C:/Path/To/Project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-msvc-x64 --config EditorDistribution --prefix C:/Path/To/Project
```

Using LLVM clang-cl:

```sh
# Generate the build directory
cmake --preset windows-clangcl-x64

# Build non-editor binaries and install them into the examples project
cmake --build --preset windows-clangcl-x64-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset windows-clangcl-x64-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-clangcl-x64 --config Distribution --prefix C:/Path/To/Project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-clangcl-x64 --config EditorDistribution --prefix C:/Path/To/Project
```

## Building for Linux

Prerequisites:

- Git 2.25 or newer
- CMake 3.22 or newer
- Python 3.8 or newer
- GCC 13 or newer
- (Optional) Clang 19.1.0 or newer
  - If you wish to compile with LLVM/Clang instead of GCC

⚠️ These commands will build binaries for 64-bit systems. If you instead wish to build binaries for
32-bit systems then replace `x64` with `x86`.

Using GCC:

```sh
# Generate the build directory
cmake --preset linux-gcc-x64

# Build non-editor binaries and install them into the examples project
cmake --build --preset linux-gcc-x64-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset linux-gcc-x64-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/linux-gcc-x64 --config Distribution --prefix /path/to/project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/linux-gcc-x64 --config EditorDistribution --prefix /path/to/project
```

Using Clang:

```sh
# Generate the build directory
cmake --preset linux-clang-x64

# Build non-editor binaries and install them into the examples project
cmake --build --preset linux-clang-x64-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset linux-clang-x64-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/linux-clang-x64 --config Distribution --prefix /path/to/project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/linux-clang-x64 --config EditorDistribution --prefix /path/to/project
```

## Building for macOS

Prerequisites:

- Git 2.25 or newer
- CMake 3.22 or newer
- Python 3.8 or newer
- Xcode 16.4 or equivalent Xcode Command Line Tools

```sh
# Generate the build directory
cmake --preset macos-clang

# Build non-editor binaries and install them into the examples project
cmake --build --preset macos-clang-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset macos-clang-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/macos-clang --config Distribution --prefix /path/to/project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/macos-clang --config EditorDistribution --prefix /path/to/project
```

## Building for iOS

Prerequisites:

- Git 2.25 or newer
- CMake 3.22 or newer
- Python 3.8 or newer
- Xcode 16.4 or equivalent Xcode Command Line Tools

```sh
# Generate the build directory
cmake --preset macos-ios

# Build non-editor binaries and install them into the examples project
cmake --build --preset macos-ios-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset macos-ios-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/macos-ios --config Distribution --prefix /path/to/project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/macos-ios --config EditorDistribution --prefix /path/to/project
```

## Building for Android

Prerequisites:

- Git 2.25 or newer
- CMake 3.22 or newer
- Python 3.8 or newer
- Android NDK 25.2.9519653 or newer

⚠️ These commands assume that there's an environment variable called `ANDROID_NDK_ROOT` that points
to the Android NDK root directory.

⚠️ These commands assume that the host platform is Windows. To build on other host platforms simply
replace `windows-` with either `linux-` or `macos-`.

```sh
# Generate the build directories
cmake --preset windows-android-arm64
cmake --preset windows-android-arm32
cmake --preset windows-android-x64
cmake --preset windows-android-x86

# Build non-editor binaries and install them into the examples project
cmake --build --preset windows-android-arm64-distribution
cmake --build --preset windows-android-arm32-distribution
cmake --build --preset windows-android-x64-distribution
cmake --build --preset windows-android-x86-distribution

# Build editor binaries and install them into the examples project
cmake --build --preset windows-android-arm64-editor-distribution
cmake --build --preset windows-android-arm32-editor-distribution
cmake --build --preset windows-android-x64-editor-distribution
cmake --build --preset windows-android-x86-editor-distribution

# Install non-editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-android-arm64 --config Distribution --prefix /path/to/project
cmake --install build/windows-android-arm32 --config Distribution --prefix /path/to/project
cmake --install build/windows-android-x64 --config Distribution --prefix /path/to/project
cmake --install build/windows-android-x86 --config Distribution --prefix /path/to/project

# Install editor binaries into your project, under `addons/godot-jolt`
cmake --install build/windows-android-arm64 --config EditorDistribution --prefix /path/to/project
cmake --install build/windows-android-arm32 --config EditorDistribution --prefix /path/to/project
cmake --install build/windows-android-x64 --config EditorDistribution --prefix /path/to/project
cmake --install build/windows-android-x86 --config EditorDistribution --prefix /path/to/project
```

[hck]: hacking.md
[ccl]: https://learn.microsoft.com/en-us/cpp/build/clang-support-msbuild
[cmd]: https://learn.microsoft.com/en-us/cpp/build/building-on-the-command-line

## Building for double-precision

Building for double-precision builds of Godot involves the same steps as what's shown above, but
with the only difference that you add the `-DGDJ_DOUBLE_PRECISION=TRUE` argument when generating the
build directory.

So instead of doing this:

```sh
# Generate the build directory
cmake --preset windows-msvc-x64
```

You would instead do this:

```sh
# Generate the build directory with double-precision enabled
cmake --preset windows-msvc-x64 -DGDJ_DOUBLE_PRECISION=TRUE
```
