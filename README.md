# NeoCMake

NeoCMake brings the VS Code CMake Tools workflow into Neovim. Pick a preset, choose a target, and build, run, or install it from the editor. You can keep a shared library selected for builds while running the executable that uses it. NeoCMake remembers both selections per project.

![NeoCMake’s build target picker over the example CMakeLists.txt, with the extended shared library highlighted](docs/screenshots/target-picker.png)

CMake supplies the target list and executable paths through its File API. NeoCMake sends the active build's compiler flags to clangd and turns compiler errors into Neovim diagnostics and jumpable quickfix entries.

## Install

The repository is private. Use a Git account with read access, or point lazy.nvim at a checkout you already have.

You'll need **Neovim 0.12 or newer**, **CMake 3.23 or newer**, a C++ toolchain, and the build tool your project uses. The example uses Ninja. For completion, hover, and live diagnostics, install clangd and enable it in your Neovim LSP configuration.

### lazy.nvim or LazyVim

Add this plugin spec. In LazyVim, save it as `lua/plugins/neocmake.lua` under your Neovim config directory. Run `:echo stdpath('config')` to find that directory on any platform.

```lua
return {
  "gpioloco/NeovimCmake",
  main = "neocmake",
  lazy = false,
  opts = { prefix = "<leader>m" },
}
```

Restart Neovim and run `:Lazy install`. To load a local checkout, replace `"gpioloco/NeovimCmake"` with `dir = vim.fn.expand("~/NeovimCmake")`.

### Built-in Neovim package manager

Add this to your `init.lua`, restart Neovim, and confirm the initial install.

```lua
vim.pack.add({ "https://github.com/gpioloco/NeovimCmake" })
```

The plugin registers its commands and default mappings automatically. To verify either installation, open a project's `CMakeLists.txt` and run `:CMakeStatus`.

### Windows toolchain

For **MSVC + Ninja**, install **Desktop development with C++** and a Windows SDK through Visual Studio Installer. Both Visual Studio and standalone Build Tools installations are supported. Make sure Neovim can run `cmake`. [Microsoft’s command-line setup guide](https://learn.microsoft.com/en-us/cpp/build/building-on-the-command-line)

1. Start Neovim from a regular terminal and open your CMake project.
2. Press **`<leader>mv`** or run **`:CMakeConfigureEnvironment`**. Choose the installation and target architecture, for example **Visual Studio Professional · x64**. The picker shows the version and installation path so you can distinguish side-by-side installs.
3. Press **`<leader>mp`** to choose your Ninja preset, or **`<leader>mc`** to configure with the current settings. If the tree already caches a different compiler or predates the picker, choose **Re-detect compiler** to replace its CMake cache and `CMakeFiles` (requires CMake 3.24+). This is the option to use after a failed configure with a missing `kernel32.lib`.

NeoCMake remembers the selection per project and loads the developer environment again on first use after restarting Neovim. Configure, build, run, install, and the project's clangd process receive the toolchain paths. Presets can still override environment variables. Use `:CMakeStatus` to check your selection. Choose **Inherit Neovim environment** to use the launching shell again, for example with a MinGW-w64 shell.

Use a **Ninja**, **Ninja Multi-Config**, or **Makefiles** generator when you want CMake to produce `compile_commands.json` for clangd. The Visual Studio generator supports configuration-specific builds, but CMake only implements compilation database export for Ninja and Makefiles. [CMake compilation database support](https://cmake.org/cmake/help/latest/variable/CMAKE_EXPORT_COMPILE_COMMANDS.html)

## Try it on the example

Once the plugin is installed, open the bundled project from a checkout.

```sh
git clone https://github.com/gpioloco/NeovimCmake.git
cd NeovimCmake/examples/workflow
nvim CMakeLists.txt
```

In Normal mode, press each key in sequence. With Space as your leader, `<leader>mp` means **Space → m → p**.

1. **Configure** with `<leader>mp`. Choose **Debug** and press Enter. When configuration finishes, press any key to dismiss the output.
2. **Build a library** with `<leader>mt`. Choose **base**, then press `<leader>mb` to compile it.
3. **Run an application** with `<leader>ml`. Choose **hello_extended**, then press `<leader>mr`. NeoCMake builds its dependencies and opens a terminal where you'll see `extended: 42`.
4. **Install** with `<leader>mi`. Look in `stage/debug/` for both applications, both libraries, and their headers. On Windows the DLLs sit beside the executables in `bin/`.

![A Debug build running in a Neovim split, showing all eight Ninja steps and the prompt to dismiss the output](docs/screenshots/build-output.png)

Press any key in the build or configure terminal to hide it, even while the job is running. Reopen the full log with `<leader>mo` or `:CMakeLog`. A launched program has its own interactive terminal and accepts keyboard input.

## Command reference

All mappings share the configurable prefix `<leader>m`. The **Key** column gives the next key. In a picker, move with `j` / `k` or the arrows, search with `/`, confirm with Enter, and cancel with Escape.

| Key | Command | Action |
| --- | --- | --- |
| `v` | `:CMakeConfigureEnvironment` | Choose a Visual Studio installation and target architecture on Windows |
| `p` | `:CMakeConfigurePreset` | Choose and apply a configure preset |
| `d` | `:CMakeConfigureDatabase [path]` | Choose the compilation database clangd uses for this project |
| `c` | `:CMakeConfigure` | Reconfigure the project and refresh its targets |
| `P` | `:CMakeBuildPreset` | Choose a build preset compatible with the configure preset |
| `k` | `:CMakeBuildConfiguration` | Choose a build configuration such as Debug or Release |
| `t` | `:CMakeBuildTarget` | Choose a target or restore the preset's default targets |
| `b` | `:CMakeBuild` | Build the selection |
| `i` | `:CMakeBuildInstall [prefix]` | Build the default targets and install them |
| `l` | `:CMakeRunTarget` | Choose the executable to run |
| `r` | `:CMakeRun [args...]` | Build and launch that executable |
| `o` | `:CMakeBuildLog` | Reopen the project output |
| `x` | `:CMakeBuildStop` | Stop the current CMake job |
| `s` | `:CMakeStatus` | Show the active presets, targets, build directory, and configuration |

**Preset or configuration?** Use `p` to switch the whole configure preset, including its build tree, install prefix, and environment. Use `k` to change the configuration within that tree. For a single-config generator this sets `CMAKE_BUILD_TYPE` and reconfigures. For a multi-config generator the choice applies to build, run, install, and clangd. Selecting a build preset again restores its default multi-config selection.

**Arguments and paths.** Programs start in the project root with the configure preset's environment. For an argument containing a space, use `:CMakeRun --name Ada\ Lovelace`. To override the install prefix for one install, use `:CMakeBuildInstall ./stage/local`.

## clangd and build diagnostics

By default clangd follows the active CMake build. Select a Debug or Release preset with `<leader>mp` and NeoCMake points clangd at that preset's build directory. For Ninja Multi-Config, NeoCMake writes a filtered database for the active configuration under the build tree's `.cmake/neocmake/` directory. [clangd compilation database options](https://clangd.llvm.org/extensions#compilation-commands)

Press **`<leader>md`** to choose a specific database. Pick a previously used directory or **Enter file or directory…** and enter the folder or its `compile_commands.json`. You can also pass a project-relative path directly, for example `:CMakeConfigureDatabase build/debug`. Custom absolute paths work for builds outside the project. The selection applies to open clangd buffers, survives restarting Neovim, and stays selected when you change build presets. Choose **Follow active CMake build** in the same picker to resume automatic switching.

To check go-to-definition, run `:CMakeStatus` and confirm **Clangd database** points to the expected build. Open a C++ source file, place the cursor on a project function call, and use `gd` in LazyVim or `:lua vim.lsp.buf.definition()` in standard Neovim. If the jump fails, `:checkhealth vim.lsp` shows whether clangd is attached to that buffer.

After a failed build, use `:copen` to see the compiler messages and `:cnext` to jump to a source location. A successful rebuild clears stale build diagnostics. Linker errors and other messages without a source location remain available in the build log.

## Configuration

Pass these options through `opts` in lazy.nvim or call `setup` after `vim.pack.add`.

```lua
require("neocmake").setup({
  prefix = "<leader>m",     -- Set to false to use commands only
  cmake = "cmake",          -- Executable on PATH or a full path (cmake.exe on Windows)
  build_dir = "build",      -- Build directory for projects without presets
  save_before_build = true, -- Save modified project buffers before configure/build
  -- select = vim.ui.select, -- Use your configured UI picker
})
```

## Verification

From the repository root, the integration test drives the pickers, builds and runs both executables, installs them, and checks a compiler error and its recovery.

```sh
nvim --headless -u NONE -i NONE -c "luafile tests/integration.lua"
```

With clangd installed, the test opens the project in a fresh Neovim process and jumps from a call to its definition in a different source file using the saved build directory. To also test with your configured clangd immediately after a build, omit `-u NONE` and set `NEOCMAKE_LOCAL_LSP=1` in the environment.

On Windows, set `$env:NEOCMAKE_TEST_VISUAL_STUDIO = "1"` in a regular PowerShell terminal before running the integration test to exercise the first discovered x64 installation. To test switching between two fixture installations and restoring the choice across two Neovim processes, run `nvim --headless -u NONE -i NONE -l tests/visual_studio.lua`.

The full workflow has been exercised on Linux, including a clangd hover check against the newly selected preset. The Windows sample was cross-built and installed as x64 PE executables and DLLs with LLVM-MinGW. The plugin's File API lookup located the `.exe`, and the binaries' import tables confirmed the dependency chain. Native Windows terminal interaction and an MSVC build still need verification on a Windows host.
