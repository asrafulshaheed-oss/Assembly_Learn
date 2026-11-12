# 🪟 asmrun for Windows — `asmrun.bat` 1.0.0

> ✅ **No existing project file was modified.** `asmrun.bat` is a new file. It embeds `asmrun-v5.sh` **byte-for-byte** (SHA-256 `187eaf48f106713f5211d933a462b780b240c87bbcaf0639dab18475676f2fe5`) and adds a Windows front end around it.

**One file. Runs from `cmd`, PowerShell, double-click, or drag-and-drop.**

---

## Contents

1. [Quick start](#1-quick-start)
2. [What it does (and how it decides)](#2-what-it-does-and-how-it-decides)
3. [What you need installed](#3-what-you-need-installed)
4. [Command reference](#4-command-reference)
5. [Behaviours worth knowing](#5-behaviours-worth-knowing)
6. [Differences from asmrun v5 on Linux](#6-differences-from-asmrun-v5-on-linux)
7. [Troubleshooting](#7-troubleshooting)
8. [Verification status — what was and was not tested](#8-verification-status--what-was-and-was-not-tested)
9. [Developer guide — for humans and AI agents](#9-developer-guide--for-humans-and-ai-agents)
10. [Appendices (tested tool scripts)](#10-appendices-tested-tool-scripts)

---

## 1. Quick start

Put `asmrun.bat` anywhere. Either keep it **next to your source files**, or put its folder on your `PATH` so you can call it from anywhere.

| How you start it | What happens |
|---|---|
| **cmd:** `asmrun hello.s` | Builds and runs `hello.s`. |
| **PowerShell:** `.\asmrun.bat hello.s` *(PowerShell needs the `.\` unless the folder is on PATH)* | Same. |
| **Double-click `asmrun.bat`** | A terminal opens and asks for a file. **Drag & drop** the file into the window, or type its path, press Enter. After the run you can drop another file; type `q` to quit. |
| **Drag a file onto the `asmrun.bat` icon** | Runs it, and keeps the window open so you can read the output. |
| **`asmrun.bat` and `hello.s` in the same folder** | The name alone is enough: `hello.s`. The extension may even be left off: `hello`. asmrun looks in the current folder first, then in the folder where `asmrun.bat` lives. |

At the `File>` prompt you can also type options: `-v --32 hello.s`, or `--doctor`, or `?` for help.

> **First run on a downloaded file:** if Windows says it "protected your PC", right-click `asmrun.bat` → *Properties* → tick **Unblock**, or run `Unblock-File .\asmrun.bat` in PowerShell.

---

## 2. What it does (and how it decides)

Windows cannot execute Linux system calls (`int 0x80`, `syscall`) natively, and Linux assembly is the main use of asmrun. So `asmrun.bat` has **two routes** and picks one by reading your file:

```
asmrun.bat
 └─ 22-line cmd launcher  → copies the PowerShell part to a temp .ps1 and runs it (-File)
     └─ PowerShell program
         ├─ reads the file, detects arch / syntax / bits, and Windows-vs-Linux
         ├─ WINDOWS route : nasm  or  gcc(MinGW-w64)  →  .exe  →  runs it
         └─ LINUX route   : wsl.exe → the embedded asmrun v5 engine → builds & runs inside Linux
```

### How the route is chosen

| Evidence in the file | Route |
|---|---|
| Win32 API calls (`ExitProcess`, `WriteFile`, `GetStdHandle`, `MessageBox…`), DLL names (`kernel32`…), `WinMain`/CRT-startup entries, `includelib`, COFF directives, stdcall names (`_Name@4`), Win64 shadow space (`sub rsp, 40`), C calls with **`rcx`** as first argument, `_`-prefixed 32-bit C imports | **Windows** (native `.exe`) |
| `int 0x80`, `syscall`, `sysenter`, `@PLT` / `wrt ..plt`, `.note.GNU-stack`, `.rodata`, Linux syscall names, C calls with **`rdi`** as first argument | **Linux** (WSL) |
| ARM64 / ARM32 / RISC-V source, or `--target …` | **Linux** (WSL has the cross tools) |
| No clear evidence | **Linux** if WSL is installed (that is what asmrun was made for), otherwise **Windows** |
| `--wsl` / `--native` | Forced |

Comments are ignored for this decision. Every run prints one line telling you what was chosen and why, e.g.
`[INFO] hello.s -> through WSL (Linux)  [Linux program (int 0x80, _start)]`. Use `-v` to see the scores.

Detection of **architecture, NASM-vs-GNU-as syntax, 32/64-bit, entry point (`main` / `_start` / `start`), libc use and `.S` preprocessing** uses exactly the same patterns as asmrun v5 (generated from it mechanically — see §9).

---

## 3. What you need installed

| You run… | You need | Who installs it |
|---|---|---|
| **Windows** programs (Win32 API / MinGW C runtime), x86 / x64 | **NASM** (for NASM syntax) and **MinGW-w64 GCC** (linker driver; also assembles GNU-as files) | asmrun offers to install them with **winget** — NASM: `NASM.NASM`, GCC: `BrechtSanders.WinLibs.POSIX.UCRT` — after asking (`-y` = don't ask). |
| **Linux** programs, ARM, RISC-V, `--target` | **WSL** with a Linux distribution (e.g. Ubuntu) | **You, once:** in an Administrator PowerShell run `wsl --install`, restart if asked, open *Ubuntu* once and create a user. Everything *inside* Linux (`nasm`, `binutils`, `gcc`, cross tools, `qemu-user`…) is then installed by the v5 engine, after asking, using your Linux package manager. |

`asmrun --doctor` shows exactly what was found on this PC.

Windows PowerShell 5.1 (built into Windows 10/11) is all the launcher needs. If it is missing, the launcher falls back to `pwsh.exe` (PowerShell 7) on PATH.

---

## 4. Command reference

```
asmrun [options] <file> [program arguments...]
```
Options go **before** the file name. Everything after the file name is passed to your program.

### Options shared with asmrun v5 (forwarded to the Linux engine, used directly by the Windows route)

| Option | Meaning |
|---|---|
| `-v`, `--verbose` | Show detection details, scores and every command. |
| `-y`, `--yes` | Install missing tools without asking. |
| `-o`, `--output FILE` | Keep the output at `FILE`. (Windows route: `.exe` is added if you give no extension.) |
| `--asm-only` | Assemble only. Windows route writes `<name>.obj`; Linux route writes `<name>.o`. |
| `--link-only`, `--no-run` | Assemble + link, don't run. |
| `--keep-build-dir`, `--keep` | Keep the temporary build directory. |
| `--nasm` / `--gas`, `--as` | Force NASM / GNU as syntax. |
| `--32` / `--64` | Force 32- or 64-bit (x86 only). |
| `--arch ARCH` | `x86`, `arm64`, `arm32`, `riscv`. |
| `--target TARGET` | Cross-build a **Linux** program: `x86_64`, `i386`, `aarch64`, `armv7`, `riscv64` (runs through WSL). |
| `--cc CMD` | Compiler/linker driver to use. |
| `--report FILE` | Write a JSON build/run report. |
| `--selftest` | Run the self test (Windows samples + the engine's own self test in WSL). |
| `--version`, `-h`, `--help` | |
| `--` | End of options. |

### Windows-only options

| Option | Meaning |
|---|---|
| `--wsl` | Force the Linux route. |
| `--native`, `--windows` | Force the Windows route. |
| `--distro NAME` | Use this WSL distribution (default: your default distro). |
| `--engine FILE` | Use `FILE` (a POSIX asmrun script) instead of the embedded one. |
| `--engine-help` | Show the embedded engine's own help. |
| `--engine-info` | Print the embedded engine's version, size and SHA-256. |
| `--dump-engine` | Print the embedded engine to stdout. |
| `--dry-run`, `--plan` | Show what would be done; build and run nothing. |
| `--doctor` | Check this PC: Windows, PowerShell, WSL (+ tools inside it), NASM, MinGW, winget, temp dir. |
| `--workdir DIR` | Build in `DIR` instead of `%TEMP%` (useful if security software blocks `%TEMP%`). |
| `--pause` / `--no-pause` | Always / never wait for a key at the end. |

Unknown `--flags` are **passed through** to the Linux engine (so a newer engine's new options work without changing `asmrun.bat`); the Windows route rejects them.

### Environment variables

| Variable | Effect |
|---|---|
| `NO_COLOR=1` | No colours. |
| `ASMRUN_FLAGS="-v --64"` | Extra options, parsed before the command line. |
| `ASMRUN_NO_RC=1` | Don't read `.asmrunrc.win` files. |
| `ASMRUN_CC`, `ASMRUN_NASM` | Default compiler driver / full path of `nasm.exe` (Windows route). |
| `ASMRUN_NOPAUSE=1` | Never wait for a key at the end. |
| `ASMRUN_ENGINE` | Same as `--engine`. |
| `ASMRUN_PSHOST` | PowerShell executable the launcher should use (e.g. `pwsh.exe`). |
| `ASMRUN_NO_INSTALL=1` | Forbid installing tools (used by `--selftest`; handy in CI). |
| `ASMRUN_RUNNER` | Test hook: launch the built program through this command (e.g. `wine`). Leave unset normally. |

### Config files

`%USERPROFILE%\.asmrunrc.win` and `.\.asmrunrc.win` — plain lists of options (several per line, `#` comments). Example:

```
# always verbose, and always use my compiler
-v
--cc C:\tools\winlibs\mingw64\bin\gcc.exe
```
> This is **not** the shell-script `~/.asmrunrc` of asmrun v5. That file still works *inside WSL* for the Linux engine, from your Linux home directory.

### Exit codes

| Code | Meaning |
|---|---|
| your program's code | passed straight through (Windows route and Linux route) |
| `1` | asmrun error (bad file, missing tools, build failed) |
| `2` | usage error (bad option, no file and no terminal) |
| `126` | the built program could not be started (antivirus / AppLocker?) |

---

## 5. Behaviours worth knowing

* **Output streams.** `[INFO]`, `[WARN]`, `[BUILD]`, `[FILE]`… go to **stderr**; your program's output stays on **stdout**, untouched (the program inherits the console directly, so interactive programs and exact bytes work). `asmrun hello.s > out.txt` captures only the program's output.
* **Files saved with a BOM or as UTF-16.** Notepad, Visual Studio and PowerShell's `>` can save assembly files with a UTF-8 BOM or as UTF-16; **NASM and GNU as reject both** (verified: *"instruction expected"* / *"invalid character (0xef)"*). asmrun builds from a clean UTF-8 copy for that run and tells you; **your file is never changed**. If the file also uses `%include`/`.include`, it can't be copied safely, so asmrun warns and tells you how to re-save it.
* **CRLF line endings** are fine; both assemblers accept them (tested, including `.S` preprocessing and macros).
* **Crash codes.** On Windows a crash is an NTSTATUS exit code. asmrun prints it and explains the common ones (the Windows counterpart of v5's *"139 = segfault"*):

  | Exit code | Meaning |
  |---|---|
  | `0xC0000005` | access violation (segfault): bad pointer, or stack not 16-byte aligned at a call on x64 |
  | `0xC000001D` | illegal instruction |
  | `0xC0000094` | integer divide by zero |
  | `0xC00000FD` | stack overflow |
  | `0xC0000135` | a required DLL was not found |
  | `0xC000013A` | interrupted (Ctrl+C) |
* **Windows-route build commands** are the plain manual commands, printed as `[BUILD]` lines:
  * NASM + `main` (C runtime): `nasm -f win64 -o prog.obj file.asm` → `gcc -o prog.exe prog.obj`
  * NASM + custom entry (`_start`, `start`, `Start`…): adds `-nostartfiles -Wl,-e,<label>` (the label keeps its exact spelling)
  * `WinMain`: adds `-mwindows` · 32-bit: `-f win32`, and `-m32` unless the compiler is already an `i686` one
  * GNU as: `gcc -x assembler[-with-cpp] file.s -o prog.exe` (same extra flags)
* **WSL paths.** Windows paths are translated with `wslpath` (`C:\code\a.s` → `/mnt/c/code/a.s`; `\\wsl$\…` shares work too). `-o` and `--report` are translated as well. Arguments with spaces and apostrophes arrive intact.
* **Which compiler?** The Windows route checks `gcc -dumpmachine`; if it targets Linux it warns you (a Linux gcc would silently build the wrong thing).
* **`--selftest`** builds and runs small known-good programs (C-runtime, raw Win32 API, GNU as, exit-code pass-through, a BOM file) and then runs the v5 engine's own self test inside WSL. Missing tools → `SKIP`, not failure.
* **Double-click behaviour.** When started from Explorer (double-click, or a file dropped on the icon) the window stays open at the end. From `cmd`/PowerShell/scripts it never waits. `--pause` / `--no-pause` override.

---

## 6. Differences from asmrun v5 on Linux

| | asmrun v5 (Linux/macOS) | asmrun.bat (Windows) |
|---|---|---|
| Executables | ELF, run directly | Windows: PE `.exe`; Linux code: ELF inside WSL |
| Tool installs | your Linux package manager | winget (Windows tools) + the v5 engine (inside WSL) |
| Config file | `~/.asmrunrc` (shell) | `.asmrunrc.win` (option list) + the Linux one inside WSL |
| Default `--asm-only` / `--link-only` names | `x.o` / `x` | Windows route: `x.obj` / `x.exe`; Linux route unchanged |
| `--target` | cross-build | cross-build through WSL |
| Source encoding | must be plain | BOM / UTF-16 handled automatically |
| Crash hints | signals (139…) | NTSTATUS (0xC0000005…) |
| New | — | route selection, `--wsl/--native/--distro/--doctor/--dry-run/--engine*`, drag-and-drop prompt |

---

## 7. Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| *"This file needs Linux (WSL) to run, but WSL is not ready"* | Run `wsl --install` in an **Administrator** PowerShell, restart, open *Ubuntu* once. Check with `asmrun --doctor`. |
| Linux file got built as a Windows program (or the reverse) | See the `[INFO]` line for the reason; override with `--wsl` / `--native`. |
| WSL "ready" but the build fails with missing tools | You may be using the `docker-desktop` distro. Choose a real one: `--distro Ubuntu`. |
| *"Missing tools … nasm, cc"* and no installer | winget is missing (Microsoft Store → **App Installer**) — or install NASM and WinLibs/MSYS2 yourself (the message lists links). Then `asmrun --doctor`. |
| Installed a tool, still "not found" | The installer changed PATH for **new** windows only. asmrun also searches the usual folders, but if it still fails, open a new terminal. |
| *"The compiler targets 'x86_64-linux-gnu'"* | A non-Windows gcc is first on PATH. Install MinGW-w64 or pass `--cc C:\…\gcc.exe`. |
| 32-bit Windows build fails to link | You need a 32-bit (i686) MinGW toolchain — see https://winlibs.com/ — or use `--wsl` for a 32-bit **Linux** program. |
| *"Could not start the program"* / exit `126` | Antivirus / AppLocker blocked `%TEMP%`. Build elsewhere: `--workdir D:\build` or `-o D:\bin\prog.exe`. |
| `0xC0000005` | Access violation: check pointers; on x64 keep `RSP` 16-byte aligned at each `call` and reserve 32 bytes of shadow space. |
| *"No terminal to ask on"* | You are in a script/CI with no keyboard. Use `-y`, or install the tools first. |
| Running from PowerShell: *"asmrun is not recognized"* | Use `.\asmrun.bat hello.s`, or add its folder to PATH. |
| Group Policy blocks scripts / "constrained language mode" | `asmrun.bat` runs PowerShell with `-ExecutionPolicy Bypass`, which a machine policy can override. Ask IT, or use WSL directly with `asmrun-v5.sh`. |
| File name contains `%` or `^` | `cmd.exe` treats these specially when it forwards arguments. Rename the file, or start `asmrun.bat` with no arguments and type the path at the prompt. |
| Non-English folder names look wrong in messages | Cosmetic (console code page). Paths typed/dropped at the `File>` prompt are read as Unicode. |

---

## 8. Verification status — what was and was not tested

`asmrun.bat` was built and tested on a **Linux** machine, because no Windows PC was available. Here is exactly what that does and does not prove.

### ✅ Verified (executed, results observed)

| Area | How it was verified |
|---|---|
| **Embedded engine is byte-exact** | `--engine-info` / `--dump-engine` match `asmrun-v5.sh`: 1905 lines, 68384 bytes, same SHA-256. |
| **Detection port equals v5** | 29 patterns × 26 sample files = **754 comparisons, 0 mismatches** between v5's `grep -E` patterns and the converted .NET patterns (`Test-Patterns.py`, Appendix B). |
| **Windows route, real binaries** | NASM 2.16 + MinGW-w64 GCC 13 built real **PE32+** executables, run under **Wine 9**: C-runtime `main`+`puts`, raw Win32 API with a custom `Start` entry, CRLF source, GNU-as AT&T, exit-code pass-through (7), `.exe` auto-extension, `--asm-only`, `--link-only`, `--report`, `--keep-build-dir`. |
| **32-bit Windows build** | Links to `PE32 … Intel 80386`; the entry address equals the `_start` symbol (checked with `objdump`/`nm`). *Not executed* (this Wine has no 32-bit support). |
| **Linux route, real v5 engine** | Run end-to-end with a stand-in `wsl.exe` (this Linux box acting as the distro): output, exit-code pass-through, flag forwarding, `-o`/`--report` path translation, program arguments with spaces, a path containing a space *and* an apostrophe. |
| **BOM / UTF-16 fix** | Confirmed v5 alone fails on a real UTF-8 BOM and on UTF-16 (`nasm` and `as`); confirmed asmrun.bat builds them via a clean copy. |
| **Interactive prompt** | Driven through a real pseudo-terminal: quoted drag-and-drop path, PowerShell-style `& 'path'`, wrong name then continue, options typed at the prompt, name-only lookup beside the bat without extension, unquoted path with spaces, help, clean `q`. Stable over repeated runs. |
| **Launcher** | Final 22-line header run in Wine's `cmd.exe` with a stub PowerShell: arguments with spaces, `&`, `(`, `'`, `--32`, `-v`, `--` arrive verbatim; exit code passes through; the temp `.ps1` is deleted. The extracted PowerShell is byte-identical to the tested program. |
| **Argument quoting** | Round-trip test, 16 nasty cases (empty, trailing backslash, embedded quotes…): 0 failures. |
| **Failure paths** | No tools / installs disabled, no WSL, no winget, MASM and boot-sector sources, missing file, overwrite-the-source guard, unknown future flag. |
| **Static checks** | AST lint: no PowerShell-7-only syntax (so it should run on 5.1); no case-insensitive variable clashes (this lint caught two real bugs). |
| **Regression suite** | 30 checks, all passing on the final build (§9.7). |

### ⚠️ Not executable here — verify these on a real Windows PC first

| Not tested | Why it matters | Quick check |
|---|---|---|
| **Windows PowerShell 5.1 itself** | Everything ran on PowerShell 7.5 (Linux). 5.1 compatibility rests on the lint + review. | `asmrun --version`, `asmrun --selftest` |
| **Real `findstr /v /b /c:"@@"`** | The launcher's one extraction line. Wine's `findstr` ignores `/v` and `/b`, so a stand-in was used. These switches are documented for Windows `findstr`. | `asmrun --version` prints a version |
| **Real `wsl.exe`** | Its argument handling, UTF-16 messages, `-e`, `-d`, `-l -v`, `wslpath`, `WSLENV`. The stand-in only proves *our* logic. | `asmrun --doctor` |
| **winget installs** | The two package IDs exist in public winget listings, but an actual install, its PATH effects and install folders were not exercised. | `asmrun --native --dry-run x.asm`, then a real run |
| **PATH refresh and tool-folder search** after an install | Registry/`Get-ExtraToolDirs` code only runs on Windows. | install NASM, then `asmrun --doctor` |
| **Explorer double-click detection** | Uses the parent-process chain (`cmd /c` ← `explorer.exe`). | double-click `asmrun.bat`, drop a file on the icon |
| **Console details** | `$Host.UI.ReadLine()` Unicode input, `[Console]::ForegroundColor`, drag-and-drop quoting by *your* terminal. | double-click and drop a file with a non-English folder name |
| **32-bit program execution**, Windows-on-ARM, AppLocker/WDAC/SmartScreen behaviour | Depend on the machine. | `asmrun --32 --native x.asm` |
| **`%` and `^` in file names** | In Wine's `cmd` these were altered; real `cmd` may differ. | — |

If any of these fail, §9.8 says which function to change.

---

## 9. Developer guide — for humans and AI agents

### 9.1 Agent brief (read this first)

1. **`asmrun.bat` is the source of truth.** It is a single file with three layers (§9.2). Edit it directly; there is no separate build system you must keep in sync.
2. **Never hand-edit** the text between `# BEGIN GENERATED PATTERNS` / `# END GENERATED PATTERNS`, or the engine between the here-string markers in section 9 of the program. Change them only with `Update-AsmrunEngine.ps1` (Appendix A).
3. **Respect the file format:** pure ASCII, CRLF line endings, no BOM, and **no PowerShell line may start with `@@`** (§9.3).
4. **Stay compatible with Windows PowerShell 5.1 *and* PowerShell 7.** Run both lints (Appendix C, D) after every edit.
5. **PowerShell variable names are case-insensitive:** `$L` and `$l` are the same variable. This already caused real bugs here.
6. **Test before you claim.** Use the kit in §9.7. Say plainly what you could not run (§8 is the model).
7. When a Windows or tool behaviour changes, use the **assumption register** (§9.8) to find the one function to change.

### 9.2 Anatomy of `asmrun.bat`

| Layer | Where | What it is |
|---|---|---|
| **Launcher** | the first 22 lines, each starting with `@@` | cmd code. Picks a PowerShell host, copies **all lines that do not start with `@@`** into `%TEMP%\asmrun_<random>.ps1` with `findstr /v /b /c:"@@"`, runs it with `-NoProfile -ExecutionPolicy Bypass -File … %*`, deletes it, returns its exit code. `-File` is what lets spaces, `&`, quotes and `(` in file names arrive unchanged. |
| **PowerShell program** | everything else, sections 1–8 and 10 | the real logic (index below) |
| **Embedded engine** | section 9, inside `function Get-EngineText { $t = @' … '@ }` | `asmrun-v5.sh` verbatim, written to a temp file and run by `wsl.exe -e sh`. |

Two useful consequences:

* The PowerShell program **runs standalone**: `findstr /v /b /c:"@@" asmrun.bat > asmrun.ps1` then `powershell -File asmrun.ps1 hello.s`. This is also the fallback if a future Windows breaks the launcher (§9.8, row 1).
* The program is runnable and testable under PowerShell on Linux (every Windows-only call is guarded by `$script:OnWindows`).

### 9.3 Preserved invariants

1. **One file, ASCII only, CRLF, no BOM.** `cmd` mis-parses labels in LF-only batch files; a BOM breaks its first line; PowerShell 5.1 reads BOM-less files as ANSI.
2. **`@@` = launcher.** No PowerShell line (including inside the embedded engine) may start with `@@`; the engine may not contain a line starting with `'@` (it would end the here-string). The updater refuses both.
3. **The engine is embedded verbatim** and verified by SHA-256 (`--engine-info`). Behaviour changes belong in the engine, not in a patched copy.
4. **Detection patterns come from the engine** (generated), so Windows and Linux agree. Differences exist only in the *new* Windows/Linux route scoring, kept separate after the `END GENERATED PATTERNS` marker.
5. **Diagnostics → stderr; the program's output → stdout, untouched.** Programs and the engine run with the **console inherited** (never captured), so prompts, `sudo`, colours and exact bytes work. Only build tools are captured.
6. **Exit codes pass through.** Own codes: `1` error, `2` usage, `126` cannot start program.
7. **No silent installs.** Ask first (`-y` skips the question); after an install, **re-find the tool** and only then claim success; refresh PATH from the registry; never trust the installer's exit code.
8. **Honest commands.** What runs is shown as `[BUILD]` lines and is the plain manual command; the only extra flags are the documented `-nostartfiles -Wl,-e,<label>`, `-mwindows`, `-m32`.
9. **Never modify the user's source.** BOM/UTF-16 are handled with a temp copy.
10. **One exit point.** `Die` / `Stop-Run` `throw 'ASMRUN_EXIT'`; `Main` catches it; cleanup runs in `finally`. Don't call `exit` elsewhere.
11. **Arguments are arrays**, quoted once by `ConvertTo-ArgString` (Windows `CommandLineToArgvW` rules). Never build command lines by string concatenation; never use `Invoke-Expression`.
12. **Windows-only calls are guarded** (`$script:OnWindows`) so the program stays testable on Linux.
13. **Unknown `--flags` pass through** to the engine; the Windows route rejects them. (Only `--flag` / `--flag=value` forms can pass through; a new engine option that takes a *separate* value must be added to `$script:ValueOpts`.)
14. **Temp directories are removed** in `finally`, except with `--keep-build-dir`.

### 9.4 One run, step by step

1. cmd launcher → PowerShell program starts (`Main` → `Invoke-Guarded` → `Invoke-Once`).
2. Options: config files, `ASMRUN_FLAGS`, command line (`Read-Options`).
3. Single-purpose options end the run here (`--help`, `--version`, `--doctor`, `--selftest`, `--engine-info`, …).
4. Find the file (`Resolve-SourceFile`: as given → next to `asmrun.bat` → extension guesses), read it (`Read-SourceFile` handles BOM/UTF-16).
5. Profile (`Get-SourceProfile`): arch, bits, syntax, entry, plus the Windows/Linux scores. 16-bit, MASM and FASM are rejected exactly as in v5.
6. Route (`Select-Route`). Print the `[INFO]` line.
7. If the file has a BOM/UTF-16: make the clean copy (`Get-AssemblerInput`).
8. **Windows route** (`Invoke-NativeRoute`): find tools (`Get-NativeTools`) → offer winget install (`Install-MissingTools`) → build (`Invoke-Stage`) → describe the PE (`Get-PeSummary`) → run with the console inherited → explain the exit status (`Format-ExitStatus`) → `--report`.
   **Linux route** (`Invoke-WslRoute`): check WSL (`Get-WslState`) → write the engine to a temp file → translate paths (`ConvertTo-WslPath`) → `wsl.exe -e sh <engine> <flags> -- <file> <args>` with the console inherited.
9. Cleanup; if started from Explorer, wait for a key.

### 9.5 Function index

| Section | Functions |
|---|---|
| **1 core** | `Write-Tag`, `Say`/`Info`/`VInfo`/`Warn`/`Fail`/`Good`/`Show-Cmd`, `Die`, `Stop-Run`, `ConvertTo-ArgString(1)`, `Format-Arg`, `Format-Command`, `Invoke-Native`, `Repair-WslText`, `Resolve-FullPath`, `New-TempDir`, `Invoke-Cleanup`, `Write-Utf8Lf`, `Test-Interactive`, `Read-Line`, `Confirm-Yes` |
| **2 options** | `New-Opt`, `Split-Tokens`, `Read-Options`, `Read-ConfigFlags`, `Read-EnvFlags`, `Get-ArchName`, `Get-TargetName`, `Show-Usage` |
| **3 source** | `Get-Re`, `Measure-Src`, `Test-Src`, `Get-HostInfo`, `Read-SourceFile`, `Get-CodeLines`, `Get-SourceProfile`, `Get-Syntax`, `Select-Route` |
| **4 tools** | `Get-ExtraToolDirs`, `Find-Tool`, `Add-ToSessionPath`, `Update-SessionPath`, `Get-NativeTools`, `Get-WindowsLabel`, `Install-MissingTools` |
| **5 native** | `Invoke-Stage`, `Get-PeSummary`, `Get-StartLabel`, `Write-Report`, `Format-ExitStatus`, `Invoke-NativeRoute` |
| **6 wsl** | `Get-WslArgsBase`, `Get-WslState`, `Show-WslHelp`, `ConvertTo-WslPath`, `Write-EngineFile`, `Get-EngineSha256`, `Invoke-WslRoute`, `Get-AssemblerInput` |
| **7 extras** | `Get-ToolVersionLine`, `Invoke-Doctor`, `Invoke-SelfTest` |
| **8 main** | `Write-Stdout`, `Resolve-SourceFile`, `Invoke-Once`, `Invoke-Guarded`, `Test-LaunchedFromExplorer`, `Wait-Close`, `ConvertFrom-PromptLine`, `Show-Banner`, `Invoke-PromptLoop`, `Main` |
| **9 engine** | `Get-EngineText` (+ the verbatim engine) |
| **10 entry** | one `try { Main @($args) }` block — **must stay last** |

Search for the banner `#  N. NAME` to jump to a section. Data you will most often change: `$script:WingetIds` (section 4), `Get-ExtraToolDirs` (section 4), `$script:NtStatus` (section 5), the `$script:SrcPat['Win…']` route-scoring patterns (section 3).

### 9.6 Recipes

**Add a command-line option.** Add its default to `New-Opt`; add a `switch` case in `Read-Options` (and the name to `$script:ValueOpts` if it takes a separate value); add it to `Show-Usage`; use `$O.YourOption`. Add it to `$O.Fwd` **only** if the Linux engine understands it.

**Change a winget package.** Edit `$script:WingetIds` and, if its install folder changed, `Get-ExtraToolDirs`. Check with `winget search --id <id>` and a real install + `asmrun --doctor`.

**Add another package manager (Chocolatey, Scoop).** Extend `Install-MissingTools`: detect it with `Find-Tool`, show the exact command, ask, run it with `Invoke-Native` (console inherited), then call `Update-SessionPath` and re-run `Get-NativeTools` to verify.

**Add a linker backend (e.g. MSVC `link.exe`, GoLink).** In `Get-NativeTools` locate it; in `Invoke-NativeRoute` add the link step next to the `gcc` one, keep printing `[BUILD]` lines, and add a self-test sample to `$script:SelfTestSamples`.

**Add or tune a Windows-vs-Linux signal.** Add the regex to the `$script:SrcPat['…']` lines *after* the `END GENERATED PATTERNS` marker, give it a weight in `Get-SourceProfile`, and add a sample + expected route to your test corpus. Check borderline files with `asmrun -v --dry-run file.asm` (it prints both scores and their reasons).

**Add an architecture or target.** v5 does the Linux side; add it to `Get-ArchName` / `Get-TargetName`, forward it, and make sure `Select-Route` sends it to WSL. A *native Windows* ARM64 route would be a new function modelled on `Invoke-NativeRoute` (GNU as + `aarch64-w64-mingw32-gcc`).

**Update the embedded engine (e.g. a new `asmrun-v6.sh`).**

```powershell
powershell -NoProfile -File Update-AsmrunEngine.ps1 -Bat .\asmrun.bat -Engine .\asmrun-v6.sh
.\asmrun.bat --engine-info        # version, lines, bytes, SHA-256 must match: (Get-FileHash .\asmrun-v6.sh).Hash
.\asmrun.bat --selftest
```
The updater (Appendix A) refuses unsafe engines, replaces the engine, **regenerates the 29 detection patterns from the engine's own code**, and refreshes the version and SHA comments. If the engine's `detect_*` code was restructured, it stops with *"detection pattern 'X' was not found"* and **leaves the file unchanged** — then read the new `detect_*` functions, port any logic change into `Get-SourceProfile` by hand, and adjust the anchor table inside the updater. Always re-run the pattern test (Appendix B) after an engine update. Also re-read the engine's `--help` / option parsing: new options with a separate value need `$script:ValueOpts`.

Tested properties of the updater: idempotent (same engine → byte-identical file); round trip v5 → v5.1 → v5 returns the byte-identical original; a changed pattern flows into the table; moved detection code fails loudly without touching the file.

### 9.7 Testing kit

Run after **every** change. All of it works on Linux/WSL with PowerShell 7 (`pwsh`); on Windows run the lints directly.

| Check | How |
|---|---|
| Parse + case-clash lint | `pwsh -File lint_case.ps1 asmrun.ps1` (Appendix C) |
| PowerShell-7-only syntax lint | `pwsh -File lint_ps51.ps1 asmrun.ps1` (Appendix D) |
| Layout invariants | extract: `tr -d '\r' < asmrun.bat \| grep -v '^@@' > asmrun.ps1`; check ASCII-only, CRLF, no BOM, 0 lines starting `@@` in the extract |
| Engine integrity | `asmrun.bat --engine-info` vs `sha256sum asmrun-v5.sh` |
| Detection equivalence | `python3 Test-Patterns.py asmrun.bat Update-AsmrunEngine.ps1 <corpus>` (Appendix B). Corpus = small sample files: NASM and GNU-as, 32/64-bit, `int 0x80` / `syscall`, ARM64/ARM32/Thumb/RISC-V, Windows API and CRT, CRLF variants, 16-bit boot, MASM, FASM, macOS |
| Routing | a table of `file → expected route`; `asmrun -v --dry-run` prints the scores |
| Windows route, real binaries | install `nasm` and `gcc-mingw-w64-x86-64`/`-i686` and `wine`; then `ASMRUN_CC=x86_64-w64-mingw32-gcc ASMRUN_RUNNER=/path/wine-run.sh pwsh -File asmrun.ps1 --native sample.asm` |
| Linux route without Windows | put the two stand-ins (Appendix E) first on `PATH`; the "WSL" is then your Linux box and the **real engine** runs |
| Launcher | run the 22 header lines in Wine's `cmd` with a stub PowerShell that logs its `argv`; compare the stub's extracted `.ps1` with `asmrun.ps1` |
| Interactive prompt | drive `pwsh -File asmrun.ps1` through a pseudo-terminal (Python `pty`); answer cursor-position queries (`ESC[6n`) like a real terminal |
| Updater | idempotence, round trip, changed pattern, moved code (§9.6) |

Windows-only code (`Install-MissingTools`, `Update-SessionPath`, `Get-ExtraToolDirs`, `Test-LaunchedFromExplorer`, real `wsl.exe` behaviour) must be tested **on Windows** — use the right-hand column of §8.

### 9.8 Staying current — assumption register (Windows 12/13, new tools)

Everything this tool assumes about its environment, where it lives, how a break shows up, and what to do. New Windows versions should be checked against this table before release.

| # | Assumption | Where | How a break shows up | Fix / fallback |
|---|---|---|---|---|
| 1 | `cmd.exe` runs `.bat`; `findstr /v /b /c:` works | launcher (22 lines) | `asmrun --version` prints nothing / PowerShell "file not found" | Ship the extracted program: `findstr /v /b /c:"@@" asmrun.bat > asmrun.ps1`, plus a 2-line `.cmd`: `@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0asmrun.ps1" %*`. (Untested alternative extraction if `findstr` ever disappears: a first PowerShell call that writes the lines not starting with `@@` to the temp file.) |
| 2 | Windows PowerShell 5.1 is built in | launcher host selection | "PowerShell could not be started" (exit 9009) | The launcher already falls back to `pwsh.exe` on PATH; or set `ASMRUN_PSHOST`. Keep the code 5.1-compatible *and* 7-compatible. |
| 3 | `-ExecutionPolicy Bypass -File` is allowed | launcher | blocked by Group Policy / constrained language mode | Sign the script, or run the engine in WSL directly. |
| 4 | winget exists; package IDs are valid | `$script:WingetIds`, `Install-MissingTools` | "winget … no package found" | `winget search nasm`, `winget search winlibs`; update the IDs; for another manager see §9.6. |
| 5 | `wsl.exe -e`, `-d`, `-l -v`; `wslpath -a -u`; `WSLENV` | `Get-WslState`, `ConvertTo-WslPath`, `Invoke-WslRoute`, `Invoke-Doctor` | "WSL not ready" although WSL works; wrong paths | Only these functions talk to `wsl.exe`. The engine itself needs only `sh`. Manual fallback exists: `C:\x` → `/mnt/c/x`. |
| 6 | Linux 32-bit ELF runs in WSL | engine (`--32`) | 32-bit Linux programs fail | Engine's own multilib hints; unrelated to the Windows layer. |
| 7 | x64 programs run on ARM64 Windows (emulation) | native route builds x64 | native `.exe` won't start on ARM64 | Add an ARM64 native route (§9.6) and use `$script:HostInfo`. |
| 8 | 32-bit PE files run (WoW64) | `--32` native | `0xC000007B` / cannot start | In `Invoke-NativeRoute` print a message and suggest `--wsl`. |
| 9 | MinGW-w64 GCC accepts `-m32`, `-nostartfiles`, `-Wl,-e,<sym>`, `-mwindows`, `-dumpmachine` | `Invoke-NativeRoute`, `Get-NativeTools` | link errors | Adjust the link step; keep `[BUILD]` honest. |
| 10 | NASM output formats `win64` / `win32` | `Invoke-NativeRoute` | assemble errors | Change `$fmt`. |
| 11 | Standard folders for NASM/MinGW (`Program Files\NASM`, WinGet `Packages`/`Links`, MSYS2, Scoop, Chocolatey) | `Get-ExtraToolDirs` | installed but "not found" | Add the folder; `asmrun --doctor` shows the result. |
| 12 | Explorer starts `.bat` files as `explorer.exe → cmd.exe /c …` | `Test-LaunchedFromExplorer` | window closes before you can read it | Use `--pause` / config file; update the process-chain check. |
| 13 | Terminal drag-and-drop pastes a quoted path, or `& 'path'` in PowerShell | `ConvertFrom-PromptLine` | "file does not exist" with odd characters | Extend the clean-up there. |
| 14 | Colours via `[Console]::ForegroundColor`; Unicode input via `$Host.UI.ReadLine()` | `Write-Tag`, `Read-Line` | no colour / `?` in names | Adjust those two functions. |
| 15 | `%TEMP%` may run executables | `New-TempDir` | `Could not start the program` / exit 126 | `--workdir`; or default to a safer folder. |
| 16 | NASM / GNU as reject BOM and UTF-16 | `Get-AssemblerInput` | — | If assemblers learn to accept them, delete the warning path. |
| 17 | Script is unsigned | whole file | SmartScreen / Smart App Control warning | `Unblock-File`; consider code signing. |
| 18 | `$script:NtStatus` meanings | section 5 | — | Add new codes there. |

**Rule of thumb for a new Windows release:** (1) run `asmrun --doctor`, `asmrun --selftest`; (2) run the §9.7 kit; (3) walk down this table; (4) fix the one function the table names; (5) record the result in the release notes (§9.9).

### 9.9 Release checklist

- [ ] All §9.7 checks pass; nothing in §8 "not executable here" has gone untested **without being stated**.
- [ ] `$script:Version` bumped (semantic versioning: patch = fix, minor = feature, major = behaviour change). The engine version is tracked separately (`$script:EngineVersion`, set by the updater).
- [ ] If the engine changed: updater run, `--engine-info` matches `Get-FileHash`, pattern test = 0 mismatches, `--selftest` passes.
- [ ] Re-checked on a real Windows PC: double-click, drag-and-drop, `cmd`, PowerShell, a Linux sample (WSL) and a Windows sample (native).
- [ ] This document updated (options table, §8, §9.8).

### 9.10 Roadmap ideas

MSVC `link.exe` / `vswhere` and GoLink backends · native ARM64 Windows route · MASM via `ml64.exe` · a compiled `asmrun.exe` launcher (no cmd/PowerShell dependency) · code signing · a winget manifest for asmrun itself · `-I` include-path support so BOM-cleaned copies can keep `%include` working · offer to run `wsl --install` · report schema shared with v5.

---

## 10. Appendices (tested tool scripts)

Everything below was executed during development; the files are reproduced verbatim.

### Appendix A — `Update-AsmrunEngine.ps1`

Embeds a new engine and regenerates the detection patterns. Works on PowerShell 5.1 and 7.

```powershell
# Update-AsmrunEngine.ps1
#   Embeds a POSIX asmrun engine (asmrun-vN.sh) into asmrun.bat AND regenerates the detection-pattern
#   table (POSIX ERE -> .NET regex) from that engine.  Works on Windows PowerShell 5.1 and PowerShell 7.
#
#   powershell -NoProfile -File Update-AsmrunEngine.ps1 -Bat .\asmrun.bat -Engine .\asmrun-v6.sh
param(
    [Parameter(Mandatory = $true)][string]$Bat,
    [Parameter(Mandatory = $true)][string]$Engine
)
$ErrorActionPreference = 'Stop'
$nl = "`r`n"

# name ;; text that identifies the engine line holding the pattern (first matching line wins)
$Anchors = @'
ArchX86        ;; _da_x=$(cnt '
ArchArm64      ;; _da_a=$(cnt '
ArchArm32      ;; _da_b=$(cnt '
ArchRiscv      ;; _da_r=$(cnt '
SynMarker      ;; has '[.]intel_syntax
SynCpp         ;; has '^[[:space:]]*#[[:space:]]*(include|define|ifdef
SynNasm        ;; _ds_nasm=$(cnt '
SynGas         ;; _ds_gas=$(cnt '
Bits32Dir      ;; bits[[:space:]]+32|[.]code32
Bits64Dir      ;; bits[[:space:]]+64|[.]code64
BitInt80       ;; has 'int[[:space:]]+[$]?(0x80
BitSyscall     ;; syscall([^[:alnum:]_]|$)' && _db_b64
BitSysenter    ;; sysenter([^[:alnum:]_]|$)' && _db_b32
Bit32Ops       ;; (pushad|popad|pushfd|popfd)([^[:alnum:]_]|$)' && _db_b32
Bit64Ops       ;; (pushfq|popfq)([^[:alnum:]_]|$)' && _db_b64
Reg32          ;; _db_r32=$(cnt '
Reg64          ;; _db_r64=$(cnt '
Boot16         ;; bits[[:space:]]+16|[.]code16
MasmForced     ;; includelib)[[:space:]]'
MasmAuto       ;; [.]386|[.]486
FasmLike       ;; has '^[[:space:]]*format[[:space:]]+(elf
EntryStartLbl  ;; has '^[[:space:]]*_start[[:space:]]*:'
EntryPStartLbl ;; has '^[[:space:]]*start[[:space:]]*:'
EntryMainLbl   ;; has '^[[:space:]]*_?main[[:space:]]*:'
EntryStartGlob ;; +_start([[:space:]]|$)'
EntryPStartGlob;; +start([[:space:]]|$)'
EntryMainGlob  ;; +_?main([[:space:]]|$)'
Libc           ;; has '^[[:space:]]*[.]?extern[[:space:]]+_?(printf
CppDirective   ;; include[[:space:]]*[<"]
'@

$batPath = (Resolve-Path -LiteralPath $Bat).ProviderPath
$text = [IO.File]::ReadAllText($batPath)
$eng  = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Engine).ProviderPath).Replace("`r`n", "`n")
if (-not $eng.EndsWith("`n")) { $eng += "`n" }

# ---- 1. the engine must be safe to embed -------------------------------------------------------
foreach ($l in $eng.Split("`n")) {
    if ($l.StartsWith("'@")) { throw "engine has a line starting with '@ (it would end the here-string): $l" }
    if ($l.StartsWith('@@')) { throw "engine has a line starting with @@ (reserved for the cmd launcher): $l" }
}
if ($eng -match '[^\x09\x0A\x20-\x7E]') { throw 'engine must be plain ASCII' }

# ---- 2. regenerate the detection patterns from the engine -------------------------------------
$engLines = $eng.Split("`n")
$quoted = New-Object System.Text.RegularExpressions.Regex("(?:cnt|has) '((?:[^'\\]|\\.)*)'")
$rows = New-Object System.Collections.ArrayList
foreach ($a in $Anchors.Split("`n")) {
    if ($a.Trim() -eq '') { continue }
    $parts = $a -split ';;', 2
    $name = $parts[0].Trim(); $anchor = $parts[1].Trim()
    $found = $null
    foreach ($line in $engLines) {
        if ($line.Contains($anchor)) {
            $m = $quoted.Match($line)
            if ($m.Success) { $found = $m.Groups[1].Value; break }
        }
    }
    if ($null -eq $found) { throw "detection pattern '$name' was not found in the engine (anchor: $anchor). The engine's detect_* code changed: port it by hand, then update the anchor table in this script." }
    if ($found.Contains("'")) { throw "pattern '$name' contains a single quote" }
    $net = $found.Replace('[:alnum:]', 'A-Za-z0-9').Replace('[:space:]', '\s')
    if ($net -match '\[:[a-z]+:\]') { throw "pattern '$name' uses an unsupported POSIX class: $($Matches[0])" }
    [void]$rows.Add(('    {0,-16} = ''{1}''' -f $name, $net))
}
$block = '# BEGIN GENERATED PATTERNS  (written by Update-AsmrunEngine.ps1 from the engine; POSIX ERE -> .NET; do not edit)' + $nl +
         '$script:SrcPat = @{' + $nl + ($rows -join $nl) + $nl + '}' + $nl +
         '# END GENERATED PATTERNS'
$b0 = $text.IndexOf('# BEGIN GENERATED PATTERNS')
$b1 = $text.IndexOf('# END GENERATED PATTERNS')
if ($b0 -lt 0 -or $b1 -lt 0) { throw 'pattern markers not found in the .bat' }
$text = $text.Substring(0, $b0) + $block + $text.Substring($b1 + '# END GENERATED PATTERNS'.Length)

# ---- 3. replace the embedded engine ----------------------------------------------------------
$open  = "    `$t = @'" + $nl
$close = $nl + "'@" + $nl + '    return ($t.Replace('
$i = $text.IndexOf($open)
if ($i -lt 0) { throw 'start marker of the engine block not found' }
$j = $text.IndexOf($close, $i)
if ($j -lt 0) { throw 'end marker of the engine block not found' }
$body = $eng.Substring(0, $eng.Length - 1).Replace("`n", $nl)       # a here-string value has no final newline
$sha  = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::ASCII.GetBytes($eng))
$sha  = ($sha | ForEach-Object { $_.ToString('x2') }) -join ''
$ver  = '?'
if ($eng -match "(?m)^VERSION=['""]?([0-9][0-9.]*)") { $ver = $Matches[1] }
$text = $text.Substring(0, $i + $open.Length) + $body + $text.Substring($j)
$text = [regex]::Replace($text, '(?m)^#  Source file : [^\r\n]*', ('#  Source file : ' + (Split-Path -Leaf $Engine) + '   (asmrun v' + $ver + ')'))
$text = [regex]::Replace($text, '(?m)^#  SHA-256     : [^\r\n]*', ('#  SHA-256     : ' + $sha))
$text = [regex]::Replace($text, "(?m)^(\`$script:EngineVersion\s*=\s*')[^']*(')", ('${1}' + $ver + '${2}'))

[IO.File]::WriteAllText($batPath, $text, (New-Object System.Text.ASCIIEncoding))
Write-Host ("Embedded {0} (asmrun v{1}, sha256 {2}) and regenerated {3} detection patterns in {4}" -f (Split-Path -Leaf $Engine), $ver, $sha, $rows.Count, $Bat)
Write-Host 'Now verify:  asmrun.bat --engine-info (same sha256),  asmrun.bat --selftest,  and re-test the detection (see asmrunForWindows.md).'
```

### Appendix B — `Test-Patterns.py`

Proves the detection port equals the engine's own patterns. Needs `python3`, `grep`, `pwsh`; on Windows run it inside WSL.

```python
#!/usr/bin/env python3
"""Differential test of the detection patterns inside asmrun.bat.
For every pattern: count matching lines with GNU grep (original POSIX pattern from the engine)
and with .NET (converted pattern inside asmrun.bat). Both counts must be equal for every sample file.
usage: python3 Test-Patterns.py asmrun.bat Update-AsmrunEngine.ps1 <corpus-dir>
Needs: python3, grep, pwsh (PowerShell 7)  -  on Windows run it inside WSL."""
import re, subprocess, sys, glob, os, json, tempfile
bat, updater, corpus = sys.argv[1:4]
bat_text = open(bat, newline='').read().replace('\r\n', '\n')
# 1. the embedded engine, exactly as the bat holds it
m = re.search(r"    \$t = @'\n(.*?)\n'@\n    return", bat_text, re.S)
engine = m.group(1) + "\n"
# 2. anchors: single source of truth = the updater script
anchors = re.search(r"\$Anchors = @'\n(.*?)\n'@", open(updater).read(), re.S).group(1)
quoted = re.compile(r"(?:cnt|has) '((?:[^'\\]|\\.)*)'")
posix = {}
for row in anchors.splitlines():
    name, anchor = [s.strip() for s in row.split(';;', 1)]
    for line in engine.split('\n'):
        if anchor in line and quoted.search(line):
            posix[name] = quoted.search(line).group(1); break
# 3. .NET side, from the patterns inside the bat
blk = bat_text[bat_text.index('# BEGIN GENERATED PATTERNS'):bat_text.index('# END GENERATED PATTERNS')]
ps = tempfile.NamedTemporaryFile('w', suffix='.ps1', delete=False)
ps.write(blk + r'''
$out = @{}
foreach ($f in Get-ChildItem -LiteralPath $args[0] -File) {
    $lines = [IO.File]::ReadAllLines($f.FullName); $out[$f.Name] = @{}
    foreach ($k in $script:SrcPat.Keys) {
        $re = New-Object Text.RegularExpressions.Regex($script:SrcPat[$k], 'IgnoreCase')
        $n = 0; foreach ($l in $lines) { if ($re.IsMatch($l)) { $n++ } }
        $out[$f.Name][$k] = $n } }
$out | ConvertTo-Json -Depth 4''')
ps.close()
actual = json.loads(subprocess.run(['pwsh', '-NoProfile', '-File', ps.name, corpus], capture_output=True, text=True, check=True).stdout)
bad = total = nonzero = 0
for f in sorted(os.listdir(corpus)):
    data = open(os.path.join(corpus, f), 'rb').read().replace(b'\r\n', b'\n')   # grep sees LF, like the .NET reader
    open('/tmp/_norm', 'wb').write(data)
    for k, p in posix.items():
        exp = int(subprocess.run(['grep', '-Eic', '--', p, '/tmp/_norm'], capture_output=True, text=True).stdout.strip() or 0)
        total += 1; nonzero += exp > 0
        if exp != actual[f][k]: bad += 1; print(f"MISMATCH {f} {k}: grep={exp} .NET={actual[f][k]}")
print(f"{len(posix)} patterns x {len(actual)} files = {total} comparisons ({nonzero} non-zero); mismatches: {bad}")
sys.exit(1 if bad else 0)
```

### Appendix C — `lint_case.ps1`

```powershell
# Flags variables that appear with different capitalisation inside the same function
# (PowerShell variable names are case-insensitive, so $L and $l are ONE variable).
param([string]$Path)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { "PARSE ERROR: $($_.Message) at line $($_.Extent.StartLineNumber)" }; exit 2 }
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$bad = 0
foreach ($f in $funcs) {
    $vars = $f.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    $groups = $vars | Where-Object { $_.VariablePath.UserPath -notmatch '^(script|global|env):' -and $_.VariablePath.UserPath -ne '_' } |
        Group-Object { $_.VariablePath.UserPath.ToLower() }
    foreach ($g in $groups) {
        $spellings = $g.Group | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique -CaseSensitive
        if (@($spellings).Count -gt 1) { $bad++; "CASE CLASH in $($f.Name): $($spellings -join ' vs ')" }
    }
}
# Top-level script scope too
$top = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
    Where-Object { $p = $_.Parent; $in = $false; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $in = $true; break }; $p = $p.Parent }; -not $in }
$top | Where-Object { $_.VariablePath.UserPath -notmatch '^(script|global|env):' } | Group-Object { $_.VariablePath.UserPath.ToLower() } | ForEach-Object {
    $s = $_.Group | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique -CaseSensitive
    if (@($s).Count -gt 1) { $bad++; "CASE CLASH at top level: $($s -join ' vs ')" } }
"lint: $bad case clash(es) in $(@($funcs).Count) functions"
```

### Appendix D — `lint_ps51.ps1`

```powershell
# Flags syntax that only exists in PowerShell 7 (the program must also run on Windows PowerShell 5.1).
param([string]$Path)
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
$bad = 0
function Flag($msg, $node) { $script:bad++; "PS7-ONLY: $msg at line $($node.Extent.StartLineNumber): $($node.Extent.Text.Split([char]10)[0].Trim())" }
foreach ($n in $ast.FindAll({ $true }, $true)) {
    $t = $n.GetType().Name
    if ($t -eq 'TernaryExpressionAst') { Flag 'ternary ?:' $n }
    if ($t -eq 'PipelineChainAst')     { Flag 'pipeline chain && / ||' $n }
    if ($t -eq 'BinaryExpressionAst' -and "$($n.Operator)" -match 'QuestionQuestion') { Flag 'null-coalescing ??' $n }
    if (($t -eq 'MemberExpressionAst' -or $t -eq 'InvokeMemberExpressionAst' -or $t -eq 'IndexExpressionAst') -and $n.PSObject.Properties['NullConditional'] -and $n.NullConditional) { Flag 'null-conditional ?.' $n }
    if ($t -eq 'CommandAst') {
        $name = $n.GetCommandName()
        $paramNames = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        if ($name -eq 'ForEach-Object' -and $paramNames -contains 'Parallel') { Flag 'ForEach-Object -Parallel' $n }
        if ($name -eq 'Get-Content' -and $paramNames -contains 'AsByteStream') { Flag 'Get-Content -AsByteStream' $n }
        if ($name -eq 'ConvertFrom-Json' -and $paramNames -contains 'AsHashtable') { Flag 'ConvertFrom-Json -AsHashtable' $n }
        if ($name -eq 'Join-Path') { $pos = @($n.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] }); if ($pos.Count -gt 2) { Flag 'Join-Path with >2 segments' $n } }
        if ($name -in @('Test-Json','Get-Error','Join-String','Remove-Alias')) { Flag "cmdlet $name" $n }
    }
}
foreach ($v in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    if ($v.VariablePath.UserPath -in @('IsWindows','IsLinux','IsMacOS','IsCoreCLR')) { Flag "automatic variable `$$($v.VariablePath.UserPath) (undefined in 5.1)" $v }
}
"ps5.1-compat lint: $bad finding(s)"
```

### Appendix E — stand-ins for testing the Linux route without Windows

Put both files in a folder that comes first on `PATH` (and `chmod +x` them). `wsl.exe`:

```sh
#!/bin/sh
# Test double for wsl.exe: "WSL" is this Linux machine.
echo "wsl.exe $*" >> /tmp/wsl-shim.log
[ "$1" = "-d" ] && shift 2
case "$1" in
  -l) echo "  NAME      STATE           VERSION"; echo "* Ubuntu    Running         2"; exit 0 ;;
  -e) shift; exec "$@" ;;
esac
exit 1
```
`wslpath`:

```sh
#!/bin/sh
# Test double for wslpath: input is already a Linux path.
[ "$1" = "-a" ] && shift
[ "$1" = "-u" ] && shift
realpath -m "$1"
```
