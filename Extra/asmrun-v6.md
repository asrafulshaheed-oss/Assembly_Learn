# ⚙️ asmrun v6

> One command to assemble, link and run a hand-written assembly file — on **Linux (any distro, WSL, containers)** and **macOS (Intel + Apple Silicon)** — for **9 CPU targets**, with **automatic tool installation and automatic error recovery**.

```sh
./asmrun-v6.sh hello.asm                       # NASM / GAS / .S auto-detected, tools installed if missing
./asmrun-v6.sh --target aarch64 hello.s        # cross-build + run under qemu-user
./asmrun-v6.sh --doctor                        # what works on THIS machine, what is missing
./asmrun-v6.sh --selftest                      # 46 checks (42 run on a typical x86 Linux host; the rest skip without nasm/cross tools)
```

- **File:** `asmrun-v6.sh` — one POSIX `sh` file (~2,600 lines), no dependencies beyond standard Unix tools.
- **Read this first if you are going to modify it:** [§13 Developer guide (humans and AI agents)](#13-developer-guide-humans-and-ai-agents).
- **Honesty note:** "100% perfect" is not something any script can promise. §11 lists exactly what was executed, what was only simulated, and what was never run. Trust that list, not adjectives.

---

## Contents

1. [Quick start](#1-quick-start)
2. [What changed since v5](#2-what-changed-since-v5)
3. [Platforms and architectures](#3-platforms-and-architectures)
4. [Command-line reference](#4-command-line-reference)
5. [How it works](#5-how-it-works)
6. [The auto-recovery engine](#6-the-auto-recovery-engine)
7. [Tool installation](#7-tool-installation)
8. [Configuration and security](#8-configuration-and-security)
9. [Exit codes and the JSON report](#9-exit-codes-and-the-json-report)
10. [Invariants (never break these)](#10-invariants-never-break-these)
11. [Verification status — what was and was not tested](#11-verification-status--what-was-and-was-not-tested)
12. [Troubleshooting](#12-troubleshooting)
13. [Developer guide (humans and AI agents)](#13-developer-guide-humans-and-ai-agents)
14. [Appendix: bug history and known limitations](#14-appendix-bug-history-and-known-limitations)

---

## 1. Quick start

```sh
chmod +x asmrun-v6.sh
./asmrun-v6.sh --doctor            # optional: see what is installed / missing
./asmrun-v6.sh hello.asm           # first run offers to install what the file needs
./asmrun-v6.sh -y hello.asm        # same, without asking (CI / scripts)
```

What happens on the first run of a file:

1. The file is analysed (architecture, syntax, 32/64-bit, entry point, libc use, preprocessor).
2. Only the tools **that file needs** are checked. Missing ones are listed, and you are asked once `[Y/n]` (Enter = yes). `-y` skips the question. Piped / CI runs never block on a prompt.
3. After installing, asmrun **re-checks that the tools really exist** (a "successful" install is not trusted).
4. It builds with the exact commands you would type by hand (printed as `[BUILD] …`), then runs the program. Program output goes to stdout; everything asmrun says goes to stderr.
5. If a build step fails, the [auto-recovery engine](#6-the-auto-recovery-engine) tries to fix it and retries before giving up.

Common recipes:

```sh
asmrun hello.s a "b c"                       # program arguments go after the file
asmrun -o hello hello.asm                    # keep the executable
asmrun --asm-only -o hello.o hello.s         # object file only
asmrun --link-only hello.s                   # build, do not run (writes ./hello)
asmrun --dry-run --target riscv64 hello.s    # show the exact commands, run/install nothing
asmrun --timeout 5 loop.s                    # kill runaway programs
asmrun --report build.json hello.s           # machine-readable result (also on failure)
asmrun --target riscv64 --march rv64gcv v.s  # newer ISA extension
asmrun --target aarch64 --qemu-flags "-cpu max" sve.s
asmrun --detect hello.s                      # show what was detected, build nothing
```

---

## 2. What changed since v5

### 2.1 Bugs found in v5, and how each was established

"**Reproduced**" = I ran v5 and watched it fail. "**Code reading**" = confirmed in v5's source, not executed.

| # | v5 behaviour | How established | v6 |
|---|---|---|---|
| 1 | A failed build wrote **no** `--report`, although failures are when an agent/CI needs it most | Reproduced | Report is written on every exit path (`status: build-failed`, `error`, attempts) |
| 2 | On Linux a label `_main:` was treated as the C `main` → libc link → failure | Reproduced | `main` on Linux, `_main` on macOS only; the other spelling gives a warning |
| 3 | Comments polluted architecture detection (an ARM64 file with x86 register names in comments received x86 votes) | Reproduced | A comment/string-aware sanitiser runs before every detector (§5.2) |
| 4 | `_start` + a call to any libc function not on v5's name list → link failure with an unhelpful hint | Reproduced | Auto-recovery relinks through the C driver; the program just runs (R4) |
| 5 | `./.asmrunrc` was **sourced as shell**: running asmrun in an untrusted directory executed that directory's code (a test file was created by it) | Reproduced | Config is parsed as data; a project-local file may only set harmless options (§8) |
| 6 | A tiny 64-bit `main` using only `eax` was classified 32-bit (→ needs multilib → failure) | Reproduced | Only truly 32-bit evidence counts (`esp/ebp/eip`, 32-bit addressing, `int 0x80`); rip-relative addressing counts for 64-bit |
| 7 | `--link-only foo.s` silently overwrote an existing text file named `foo` with an executable | Reproduced | Refuses to overwrite a non-binary file through a *derived* output name |
| 8 | JSON report was invalid when a path contained a control character (e.g. ESC) | Reproduced | All control characters stripped; reports validated in the self-test |
| 9 | "32-bit libc available" meant only "the 32-bit loader file exists", even when `gcc -m32` cannot link | Code reading | A real compile + link + run probe decides |
| 10 | Host word size came from `uname -m` only, so a 32-bit userland on a 64-bit kernel (32-bit Raspberry Pi OS on a Pi 5, 32-bit containers) would be mis-detected | Code reading | `getconf LONG_BIT` decides the userland word size |
| 11 | For `.S` cross builds with no cross C driver installed, v5 fell back to the *host* `cpp`, which predefines the wrong architecture macros | Code reading | Cross `.S` always goes through the cross C driver |

### 2.2 New in v6

- **Auto-recovery engine** (8 rules): wrong syntax guess, wrong word size, missing libc, old assembler needing `-march`, `-no-pie` unsupported, false preprocessor detection, duplicate `_start`, missing 32-bit/cross libc.
- **9 targets** through a data-driven registry: x86-64, i386, AArch64, ARMv7, RISC-V 64 **+ ppc64le, s390x, mips64el, loongarch64 (experimental)**.
- **New modes:** `--detect`, `--dry-run`, `--doctor`, `--list-targets`, `--timeout`.
- **New flags for current hardware:** `--march`, `--as-flags`, `--ld-flags`, `--cc-flags`, `--nasm-flags`, `--qemu-flags`, `-g`. Vector extensions (SVE/SME/RVV) automatically get `-cpu max` under qemu.
- **Extension awareness:** AVX/AVX-512/APX/AMX, SVE/SME/NEON, RVV are detected; on `SIGILL` you get a targeted hint.
- **Smarter runners:** qemu-user (also `*-static`), `binfmt_misc` handlers, and native AArch32-on-AArch64 are all tried before asking you to install anything. If nothing can run the program, asmrun still **builds and keeps** the binary and tells you the exact install command.
- **Cross toolchain discovery:** tries every common triplet (`aarch64-linux-gnu`, `aarch64-none-linux-gnu`, `aarch64-linux-musl`, bare-metal `*-elf`, …), not one hard-coded name.
- **Hardened environment:** `CDPATH`/`GREP_OPTIONS` are unset; `PATH`, `HOME`, `TERM`, `TMPDIR` may all be missing (`env -i` is part of the test routine); globbing is off.
- **Better diagnostics:** signal names with causes (`SEGV`, `ILL`, `BUS`, `FPE`, `SYS`…), explanation of the two harmless linker warnings, hints keyed to the actual error text.
- **Installers:** apt, dnf, microdnf, yum, pacman, zypper, apk, xbps, Homebrew, MacPorts; containers/toolbox/distrobox recognised; ostree hosts get correct advice.
- **Self-test grew from 3 to 46 checks (42 execute on a plain x86 Linux host)** and now runs meaningful layers on *any* machine (detection and command construction need no tools at all).

---

## 3. Platforms and architectures

### 3.1 Host systems

| Host | Status | Notes |
|---|---|---|
| Linux, glibc (Debian, Ubuntu, Fedora, Arch, openSUSE …) | ✅ primary | native + cross + qemu-user |
| Linux, musl (Alpine) | ✅ designed for | raw-syscall asm and libc `main` both supported; no cross gcc packages exist on Alpine (use Docker) |
| WSL / WSL2 | ✅ | detected; behaves as Linux |
| Containers (Docker, Podman, toolbox, distrobox) | ✅ | ostree check skipped inside containers so `dnf` works |
| macOS Apple Silicon | ✅ | arm64 native; x86-64 via Rosetta 2 (offered for install) |
| macOS Intel | ✅ | x86-64 native |
| Windows native (MSYS/Cygwin/MinGW) | ❌ | clear message → use WSL2 |
| FreeBSD / OpenBSD / others | ❌ | clear message; see §13.3.2 to add |

macOS is **host-native only by design**: the kernel cannot run foreign Linux binaries and `qemu-user` does not exist for Darwin. Asking for another architecture on a Mac gives an explanation, not a crash.

### 3.2 Targets (`asmrun --list-targets`)

| Target | Family | Bits | Status | Cross prefix tried first | qemu-user |
|---|---|---|---|---|---|
| `x86_64` | x86 | 64 | supported | `x86_64-linux-gnu` | `qemu-x86_64` |
| `i386` | x86 | 32 | supported | `i686-linux-gnu` | `qemu-i386` |
| `aarch64` | arm64 | 64 | supported | `aarch64-linux-gnu` | `qemu-aarch64` |
| `armv7` | arm32 | 32 | supported | `arm-linux-gnueabihf` | `qemu-arm` |
| `riscv64` | riscv | 64 | supported | `riscv64-linux-gnu` | `qemu-riscv64` |
| `ppc64le` | ppc | 64 | **experimental** | `powerpc64le-linux-gnu` | `qemu-ppc64le` |
| `s390x` | s390x | 64 | **experimental** | `s390x-linux-gnu` | `qemu-s390x` |
| `mips64el` | mips | 64 | **experimental** | `mips64el-linux-gnuabi64` | `qemu-mips64el` |
| `loongarch64` | loong | 64 | **experimental** | `loongarch64-linux-gnu` | `qemu-loongarch64` |

**"supported"** = detection, build commands and execution paths are exercised by the self-test (see §11 for what that really covered on which hardware). **"experimental"** = detection and command construction are tested; **no program of these architectures has ever been assembled or executed by the author** (no toolchain/hardware available). Treat them as a head start, and please contribute a verified runtime sample (§13.3.1).

Source syntaxes: NASM (x86), GNU as AT&T and Intel (`.intel_syntax`), GNU as for every other family, `.S` files (C preprocessor). Not supported: MASM/TASM/FASM, 16-bit real mode (detected and explained).

---

## 4. Command-line reference

```
asmrun [options] <file> [program arguments...]
```

Options go **before** the file name; everything after the file name is passed to your program.

| Option | Meaning |
|---|---|
| `-h`, `--help` / `--version` | help / version (`asmrun 6.0.0`) |
| `-v`, `--verbose` | show detection votes, work dir, extra information |
| `-y`, `--yes` | install missing tools without asking |
| `-o`, `--output FILE` | keep the executable (or object with `--asm-only`) at FILE |
| `--asm-only` | assemble only |
| `--link-only`, `--no-run` | build, do not run (default name `./<stem>`) |
| `--keep-build-dir`, `--keep` | keep the temp dir; path printed as `[WORK]` |
| `--dry-run` | print the exact build commands; build/install/run nothing |
| `--nasm` / `--gas`, `--as` | force the x86 syntax |
| `--32` / `--64` | force x86 word size |
| `--arch ARCH` | force source family: `x86 arm64 arm32 riscv ppc s390x mips loong` |
| `--target TARGET` | force the target (implies the family) — see §3.2; many aliases (`arm64`, `amd64`, `armhf`, `riscv`, …) |
| `--cc CMD` | use CMD as the C driver |
| `--march VALUE` | `-march=VALUE` for the assembler and C driver |
| `--as-flags S`, `--ld-flags S`, `--cc-flags S`, `--nasm-flags S`, `--qemu-flags S` | extra flags (split on spaces, no quoting) |
| `-g`, `--debug` | debug info (`nasm -g -F dwarf`, `as -g`, `cc -g`) |
| `--timeout SECS` | stop the program after SECS (needs `timeout`; macOS: `brew install coreutils`) |
| `--report FILE` | JSON report, also written on failure |
| `--detect` | print detection results (`key=value`) and stop |
| `--doctor` | machine check: tools, package manager, per-target readiness |
| `--list-targets` | the table in §3.2 |
| `--selftest` | run the built-in tests |
| `--no-color` | disable colour (`NO_COLOR=1` also works) |
| `--` | end of options |

`--opt=value` works for every option that takes a value.

**Environment:** `NO_COLOR`, `ASMRUN_NO_RC=1` (ignore config files), `ASMRUN_FLAGS="…"` (extra options, parsed before the command line), `ASMRUN_CC`.

`--detect` output (stdout, stable keys, **not** `eval`-safe):

```
file=hello.asm   arch=x86   bits=64   syntax=nasm   target=x86_64   target_status=supported
entry=_start     c_main=no  libc=no   cpp=no        extensions=none
arch_votes=x86=8 arm64=0 arm32=0 riscv=0 ppc=0 s390x=0 mips=0 loong=0
host=linux/x86/64   native=yes
```

---

## 5. How it works

### 5.1 Pipeline

```
 args + config ──► validate ──► host detect ──► work dir (noexec-safe)
                                                   │
        ┌──────────────────────────────────────────┘
        ▼
  sanitise source ─► detect arch ─► sanitise per family ─► syntax ─► bits ─► entry/libc/cpp ─► extensions
        │                                                                      (--detect stops here)
        ▼
  plan_all  (target, native?/cross?, link strategy, driver mode, flags, REQUIRED tools)   ◄──┐ re-run after
        │                                                                                     │ every auto-fix
        ▼
  ensure_tools (install + verify) ─► ensure_runner (qemu / binfmt / direct / none)           │
        ▼                                                                                     │
  do_build ─► build_linux | build_macos ─► failure? ─► auto_recover ───────────────────────────┘
        ▼
  post_build (file(1) check, macOS syscall warnings) ─► run_phase (timeout, qemu) ─► explain_exit ─► report
```

`plan_all` is **idempotent**: it derives every flag from the current state variables, so any recovery rule can change one variable (`SYNTAX`, `BITS`, `FORCE_LINK`, `MARCH_OPT`, …) and call it again.

### 5.2 The sanitiser (why detection is trustworthy)

Before any detector runs, `sanitize_source` (portable awk) produces a copy of the file with **comments removed and string contents blanked**:

- Block comments `/* … */` (multi-line), line comments by family: `;` (x86 NASM, Apple arm64), `#` (x86 GAS, RISC-V, PPC, s390x, MIPS, LoongArch; only full-line for ARM where `#` is an immediate), `@` (ARM32), `//` (ARM).
- Strings (`"…"`, `` `…` ``) and character literals are blanked but keep their quotes, so `db "x"` still looks like data.
- C-preprocessor directives (`#include`, `#define`, `#if`… written with no space after `#`) are preserved so `.S` files are recognised; a comment like `# if the value is zero` is not mistaken for one.
- BOM and CR characters are stripped.

The first pass uses a generic sanitiser (the architecture is unknown yet); the second uses the detected family's exact comment syntax.

### 5.3 Detection

- **Architecture:** each family has a signature regex (registers, mnemonics, directives); a family's score is the number of source lines matching it. Highest wins; a tie goes to the host's family; no signals at all → the host's family (if that family is supported, otherwise a clear error asks for `--arch`). A runner-up within 70 % of the winner raises an "ambiguous" warning. Notable design choices: x86 bare `r8`–`r15` are *not* a signal (they collide with ARM32/PPC/s390x); LoongArch's dotted mnemonics (`li.w $a0`) take MIPS's `$`-register lines out of the MIPS vote; RISC-V `sp` as first operand only counts for RISC-V-only mnemonics (ARM's `add sp, sp, #16` must not vote).
- **x86 syntax:** `.S`/`.nasm` extension, `.intel_syntax`, cpp directives are *firm*; otherwise NASM-vs-GAS votes, tie → extension.
- **x86 bits:** `bits N`/`.codeN` directives are firm; otherwise weighted: `int 0x80` (+5 for 32), `syscall` (+5 for 64), `esp/ebp/eip` and 32-bit addressing (32), `rax…`, `r8d…`, rip-relative, `wrt ..plt` (64). `eax/ebx/…` are deliberately **not** counted (valid and common in 64-bit code).
- **Entry/libc/cpp:** `_start`, `start`, `ENTRY(name)` comment convention; C `main` (Linux) / `_main` (macOS); libc function names, any `extern`, PLT markers; `.S` or real directives.
- **Firm vs soft:** a decision made by an explicit directive is never auto-flipped by recovery; a vote-based one may be.

### 5.3.1 Build commands

Native Linux, exactly what you would type:

```
nasm  -f elf64 -o prog.o file.asm        ld -o prog prog.o                      # NASM
as --64 -o prog.o file.s                 ld -o prog prog.o                      # GAS  (x86-64)
as --32 -o prog.o file.s                 ld -m elf_i386 -o prog prog.o          # GAS  (i386)
as -o prog.o file.s                      ld -o prog prog.o                      # ARM64/ARM32/RISC-V/…
cc -no-pie [-nostartfiles | -nostdlib -static] [-m32] -x assembler file.s -o prog   # libc / .S
cpp -traditional-cpp -P -o prog.s file.S   (only if there is no C driver at all)
```

Cross (Linux): the same with `<prefix>-as`, `<prefix>-ld`, `<prefix>-gcc`; run as `qemu-<arch> [-L sysroot] [flags] prog`.
macOS: `clang -arch x86_64|arm64 -x assembler [-Wl,-e,_start] -o prog file.s`; NASM uses `-f macho64`.
No `-z noexecstack` or `--no-warn-rwx-segments` is ever added (invariant I1).

---

## 6. The auto-recovery engine

When a build stage fails, `auto_recover` inspects the failing stage's log and applies **at most one** fix, then `do_build` retries (max 6 builds). Each rule fires once, explains itself with an `[AUTO]` line, and prints what was tried if everything fails. A fix that needs new tools goes through `ensure_tools soft` (asks first); if you decline, the original plan is restored and the original error is shown.

| Rule | Trigger (log text) | Action |
|---|---|---|
| **R1** | `-no-pie` unrecognised | retry without `-no-pie` |
| **R2** | `multiple definition of _start` | link with `-nostartfiles` (also chosen *preemptively* when both `_start` and `main` exist) |
| **R3** | `cannot find crt1.o`, `-lc`, `libc-header-start.h`, `gnu/stubs-32.h`, … | install 32-bit multilib / the cross libc / `gcc`, retry |
| **R4** | `undefined reference` / `undefined symbol` with the raw `ld` path or `-nostdlib -static` | symbols live in libc → relink through the C driver |
| **R5** | `invalid preprocessing directive`, `#else without #if` on a file that was only *guessed* to need cpp | retry as plain assembly |
| **R6** | assembler-style error (not a link error), x86, syntax not forced/firm | flip NASM ↔ GNU as (offers to install `nasm` if needed) |
| **R7** | register/mode/`incompatible`/`no such instruction` errors, x86, bits not forced/firm | flip 32 ↔ 64 |
| **R8** | `selected processor does not support`, `unrecognized opcode`, `unknown mnemonic`, `instruction requires … extension` | retry with a `-march` suited to the detected extension (`armv8.2-a+sve`, `armv9.2-a+sme`, `armv7-a`, `rv64gcv`, `rv64gc`) |

**What is deliberately *not* automatic:** re-running the user's program. Programs have side effects, and stdin may already be consumed. After a crash asmrun prints the exact command to try (e.g. `--32`), it never silently runs twice.

If all rules fail, `build_failed` prints the log (first 40 lines), what was attempted, and hints derived from the log (broken Xcode CLT, missing entry point, macOS underscore rule, old assembler for the extensions used, missing cross libc, …).

---

## 7. Tool installation

- Only what the **plan** needs is requested (`plan_tools`): e.g. a NASM `.asm` needs `nasm` + `ld`; a `.S` file needs a C driver; a cross target needs `<prefix>-as/ld` (+ `<prefix>-gcc` + cross libc when libc is used) and a runner.
- Package managers: `apt`, `dnf`, `microdnf`, `yum`, `pacman`, `zypper`, `apk`, `xbps`, `brew`, `port`. Packages are installed **one at a time**, so one wrong name cannot abort the rest. Debian family names (`binutils-<triplet>`, `gcc-<triplet>`, `libc6-dev-<arch>-cross`, `qemu-user`) are the best-known; dnf/pacman/zypper/apk/xbps cross-package names are best effort and always verified after install.
- Privileges: root → none; else `sudo`, else `doas`; neither → exact commands are printed. Homebrew is invoked without `sudo` (and itself refuses to run as root).
- macOS: Command Line Tools via `xcode-select --install` (opens Apple's dialog), Rosetta via `softwareupdate`, Homebrew install one-liner printed (never piped to a shell by asmrun).
- ostree (Silverblue/Kinoite) **hosts**: auto-install is off with advice (toolbox/distrobox/`rpm-ostree`).
- Never blocks: no TTY and no `-y` → prints the command and exits (I10).

---

## 8. Configuration and security

Config files are **data, never code** (invariant I12). One option set per line, `#` comments, optional `ASMRUN_FLAGS="…"` / `ASMRUN_CC=…` lines.

| File | Trust | Allowed |
|---|---|---|
| `~/.asmrunrc`, `~/.config/asmrun/config` | yours | everything |
| `./.asmrunrc` (current directory) | **untrusted** (could come from a cloned repo) | only `-v --verbose --nasm --gas --as --32 --64 --arch --target --timeout --march --keep -g --no-color`; everything else (`-o`, `--cc`, `--report`, `--*-flags`) is ignored with a warning |

Why: a compiler flag such as `-wrapper` can execute programs, `--cc` selects a program to execute, `-o` can overwrite files. v5 *sourced* the file as shell.

Other protections: refuses `-o`/`--report` equal to the source; refuses directories; refuses to overwrite a text file through a *derived* output name; work dir is created `0700` and probed for exec permission (some `/tmp` are `noexec`); temp dir is always removed (also on Ctrl-C/TERM/HUP) unless `--keep`.

---

## 9. Exit codes and the JSON report

| Code | Meaning |
|---|---|
| program's own | the program ran (0–255) |
| `0` | success for `--asm-only`, `--link-only`, `--dry-run`, `--detect`, `--doctor`, `--selftest` (all passed) |
| `1` | asmrun error: build failed, tools missing, built-but-cannot-run, self-test failure |
| `2` | usage error (unknown option, missing value/file, contradictory options) |
| `124` | `--timeout` expired |
| `128+N` | the program died from signal N (also from `timeout`) |

Because programs can return 1 or 2 themselves, use `--report` to disambiguate.

Report (`"schema": 2`), written for success **and** failure:

```json
{ "tool": "asmrun", "version": "6.0.0", "schema": 2,
  "status": "ran",              // ran | built | dry-run | detected | build-failed | tools-missing | built-not-run | error
  "error": "",  "file": "hello.asm", "os": "linux", "wsl": false, "container": false,
  "host": "x86", "host_bits": 64, "source_arch": "x86", "syntax": "nasm", "bits": 64,
  "target": "x86_64", "target_status": "supported", "native": true, "runner": "native",
  "link": "ld", "cpp": false, "uses_libc": false, "entry": "_start", "extensions": [],
  "detection": { "arch_votes": {"x86": 8, "arm64": 0, ...}, "syntax_votes": "nasm=9 gas=0", "bits_votes": "32=0 64=11" },
  "tools_required": ["nasm","ld"], "tools_missing": [], "auto_fixes": "", "build_attempts": 1,
  "build_commands": ["nasm -f elf64 -o …", "ld -o …"],
  "output": "/tmp/asmrun.x/prog", "exit_code": 0, "kept_build_dir": null }
```

---

## 10. Invariants (never break these)

| ID | Invariant | Why it exists |
|---|---|---|
| I1 | Native build commands equal the manual commands; no `-z noexecstack`, no `--no-warn-rwx-segments`, no extras unless the user passes them | v3 added such flags and broke assemblers that do not know them; users must be able to copy `[BUILD]` lines |
| I2 | Every detector is a weighted vote; explicit directives override; every detection has an override flag (I9) | no heuristic is right 100 % of the time |
| I3 | No `set -e` | would destroy the program's exit status |
| I4 | Diagnostics → stderr; program output → stdout; informational modes (`--detect`, `--doctor`, `--list-targets`, `--version`, `--help`) → stdout | pipelines must stay clean |
| I5 | Installs are verified, never trusted | package names drift between distro releases |
| I6 | Install only what the plan needs | no surprise 500 MB downloads |
| I7 | POSIX `sh` only: no `[[ ]]`, arrays, `local`, `echo -e`, `$'…'`, `${v//}`, `<<<`, `function`, `source`, `==`, `$RANDOM`, `&>`; awk without regex intervals or `gensub` | macOS ships bash 3.2 as `sh`; Debian uses dash; Alpine uses BusyBox |
| I8 | `[BUILD]` lines are always printed | reproducibility |
| I10 | No prompt can block a pipe/CI run (`-t 0` checks) | |
| I11 | Work dir is exec-probed | hardened systems mount `/tmp` noexec |
| I12 | Config is parsed, never sourced | code execution |
| I13 | A report is written on every exit path after argument validation | agents need failures most |
| — | Never re-run the user's program automatically | side effects |

---

## 11. Verification status — what was and was not tested

Environment used for all testing of this release: **Debian-family Linux, x86-64 kernel that runs 32-bit binaries, root, no network, GNU as/ld 2.4x, gcc, cpp, dash, bash, mawk, Python 3.** Not available: nasm, qemu, any cross compiler, clang, shellcheck, macOS, ARM/RISC-V/PPC/s390x/MIPS/LoongArch hardware.

### ✅ Executed for real

- `sh -n`/`dash -n`/`bash --posix -n` pass; `--selftest` = **42 passed, 0 failed, 4 skipped** under `dash`, `bash --posix` and `sh`; also under `env -i`.
- **Detection** on a 31-file corpus + 10 adversarial files covering all 8 families, including: ARM/x86 comment pollution, CRLF, UTF-8 BOM, `;`/`#`/`/*` inside strings, `_main` on Linux, `ENTRY()` comments, fake `# if` comments, `sp`-arithmetic in ARM/RISC-V, r8–r15-only x86, upper-case mnemonics, files with no signals.
- **Real builds and runs:** GNU as AT&T x86-64 (`as --64`/`ld`), 32-bit static (`as --32`/`ld -m elf_i386`, executed by the kernel), libc `main` through the C driver, `.S` through the C driver and through stand-alone `cpp`, entry via `ENTRY(boot)` (`ld -e boot`), exit-code and argument forwarding (argc check), stdin passthrough, stdout/stderr separation, `--asm-only`, `--link-only`, `-o` guards, `--timeout` (rc 124), `--report` (valid JSON also with UTF-8 file names), spaces in paths, 50 k-line / 3 MB file in 1.2 s.
- **Auto-recovery on real tools:** R4 (`_start` + `call abs` → relinked with libc → exit 5).

### 🧪 Simulated with stub tools (real script logic, fake toolchain)

- R1, R3, R5, R6 (stub `nasm` that emits a real object), R8; R2 is handled preemptively.
- Full **auto-install loop** with a stub `apt-get`: success, declined/non-interactive, "install claimed success but installed nothing" (caught by verification).
- **Cross builds:** stub `aarch64-linux-gnu-as/ld` + `qemu-aarch64` proved prefix discovery, command lines, `-L`, argument preservation, automatic `-cpu max` for SVE, and the build-but-cannot-run degradation; stub cross `riscv64-linux-gnu-as` proved R8's retry.
- **macOS branches** with stub `uname`/`clang`/`xcode-select`/`nasm`: `clang -arch`, `-Wl,-e,_start`, `_main` handling, Linux-syscall warnings, Rosetta, cross refusal, `--doctor`.
- Non-AVX hosts: dry-run command construction for **all 9 targets**.

### ❌ Never executed — treat as unverified

- **NASM** (only via stub). **Any real cross toolchain or qemu-user.** **Real macOS** (including the two macOS self-test samples `s_mx64.s`, `s_marm.s`). **Real ARM64/ARM32/RISC-V hardware** (their self-test samples are standard syscall programs but have not been assembled by this author). **ppc64le, s390x, mips64el, loongarch64: nothing beyond detection and command text.** dnf/pacman/zypper/apk/xbps/brew/port install flows. Alpine/musl, BusyBox, WSL. awk other than **mawk** (BSD awk/gawk/BusyBox awk: code avoids non-POSIX features but is unproven). `shellcheck`.

If something in the second or third list fails on your machine, that is a bug report, not a surprise — see §13 for how to fix it and add a regression check.

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `asmrun --doctor` says a target `needs: …` | install the listed tools (or run with `-y` and let asmrun do it) |
| Wrong architecture/syntax guess | `-v` shows the votes; override with `--arch`, `--nasm/--gas`, `--32/--64`, `--target` |
| `[WARN] Architecture detection is not clear-cut` | the file mixes signals; override explicitly |
| Segmentation fault right after your last instruction | no exit syscall at the end → execution fell into data |
| `Illegal instruction` | CPU/emulator lacks an extension the file uses; hint printed; under qemu try `--qemu-flags "-cpu max"` |
| 32-bit program: exit 126/127 | kernel/container has IA32 emulation off (e.g. some hardened kernels, containers) |
| `no such instruction` for AVX-512/APX/SME/RVV | assembler too old: update binutils/nasm, or pass `--march` |
| macOS: nothing happens / wrong output | use BSD syscall numbers (`0x2000001`…) on x86-64, `x16` + `svc #0x80` on arm64 |
| macOS: `xcrun: error` | `xcode-select --install` (or `sudo xcode-select --reset`) |
| Cross build links but cannot run dynamic binary | install the cross libc runtime (`libc6-<arch>-cross` on Debian) |
| `--timeout` ignored on macOS | `brew install coreutils` (provides `gtimeout`) |
| "automatic install unavailable" | printed reason (no sudo/doas, immutable OS, no package manager); install manually |
| Anything else | rerun with `-v --keep-build-dir --report r.json` |

---

## 13. Developer guide (humans and AI agents)

> This section is written to be followed literally by a future maintainer — human or AI. It assumes you only have a shell and the files `asmrun-v6.sh` and `asmrun-v6.md`.

### 13.1 Rules of engagement

1. **Read §10 (invariants) before touching code.** Every one of them is the scar of a real bug.
2. **POSIX `sh` only** (I7). Test with `dash -n`, `bash --posix -n`, and run the self-test under **both** `dash` and `bash --posix` (and `sh`). If `shellcheck` exists, run `shellcheck -s sh asmrun-v6.sh` and treat new warnings as bugs.
3. **Variables are global in POSIX sh.** Every function uses a unique prefix for its scratch variables (`_da_`, `_pa_`, `_ar_`, …). Never introduce a scratch variable without a prefix unique to its function. Use `${var:-}` for anything that may be unset (the script runs under `set -u`).
4. **Never call `die`/`exit` inside `$(…)`** — it only leaves the subshell.
5. **Keep `plan_all` idempotent.** It must derive everything from state variables so recovery can call it repeatedly.
6. **Decisions are data, not scattered `case`s.** Anything per-architecture lives in the registry functions (§13.2). If you add a `case "$TARGET_ID" in` somewhere else, move it into the registry instead.
7. **Never claim what you did not run.** Update §11 honestly; "simulated with stubs" and "executed on hardware" are different statements.
8. **Every bug fix gets a regression check** in `st_samples`/`do_selftest` (or at least a documented manual stub test).
9. **Bump `VERSION`**, update this file (changelog §14, tables §3/§4/§6), re-run everything in §13.5.
10. Quoting: unquoted `$X_AS`/`$CCM`-style expansions are *intentional* word-splitting of flag lists (globbing is off via `set -f`). Everything that can contain a path/filename must be quoted.

### 13.2 Code map (search for the function name)

| Area | Functions |
|---|---|
| Globals, logging, exit | `init_colors say out info warn err good die usage_die cleanup on_exit usage` |
| **Target registry** | `ALL_TARGETS ALL_FAMILIES tgt_norm fam_norm tgt_family tgt_bits fam_tgt fam_bits arch_label tgt_label tgt_status tgt_prefixes tgt_qemu tgt_binfmt tgt_file_ok tgt_default_entry_is_start deb_tri deb_arch fed_tri cross_pkg` |
| Host | `detect_host host_runs_natively sysctl_arm64` |
| Analysis | `has cnt hasraw sanitize_source looks_binary detect_arch detect_syntax detect_bits detect_entry_libc_cpp detect_ext ext_hint` (+ `LIBC_FUNCS`) |
| Tool discovery & probes | `find_cc find_timeout cross_prefix_for find_qemu binfmt_ok find_sysroot sysroot_has_loader multilib_ok cross_libc_ok clt_ok rosetta_ok tool_ok tool_label pkg_of add_req` |
| Packages & install | `detect_pm pm_exec do_install print_manual print_cross_manual install_hint ensure_tools ask_yn` |
| Work dir, stages | `try_workdir make_workdir display_arg record_cmd stage lg` |
| Paths | `abs_dir same_file src_stem resolve_paths` |
| **Plan** | `plan_all plan_tools plan_runner ensure_runner entry_symbol` |
| **Build + recovery** | `build_linux build_macos auto_recover first_error_line is_asm_stage print_hints build_failed do_build` |
| Run | `preflight_warnings post_build explain_exit run_phase` |
| Report & info modes | `json_str json_bool json_list write_report print_detect do_list_targets do_doctor` |
| Self-test | `st_pass st_fail st_skip st_w st_exec st_detect st_detect_key st_dry st_run st_samples do_selftest` |
| Config & main | `rc_unquote rc_add rc_read load_config resolve_self need_val main` |

Key state variables: `SRC` (family), `BITS`, `SYNTAX` (+`SYNTAX_FIRM`, `BITS_FIRM`), `TARGET_ID`, `NATIVE`, `LINK` (`ld|cc`), `CPP_MODE` (`cc|cpp`), `CCMODE`, `REQUIRED` (abstract tool names), `RUNNER` (`native|qemu|binfmt|direct|none`), `TRIED` (recovery rules already used), `STATUS`/`ERR_MSG`/`RC` (for the report).

Abstract tool names in `REQUIRED`: `nasm as ld cc cpp multilib` (native), `xas xld xcc xlibc qemu` (cross), `clt rosetta` (macOS). To add a tool, extend `tool_ok`, `tool_label`, `pkg_of` and `plan_tools`.

### 13.3 How to extend

#### 13.3.1 Add a CPU architecture (e.g. RISC-V 32, LoongArch variants, SPARC, m68k, a future ISA)

Edit, in this order:

1. **Registry** — `ALL_TARGETS`, `ALL_FAMILIES`, then each of: `tgt_norm` (spellings), `fam_norm`, `tgt_family`, `tgt_bits`, `fam_tgt` (family+bits → id), `fam_bits`, `arch_label`, `tgt_label`, `tgt_status` (**start as `experimental`**), `tgt_prefixes` (candidate cross triplets, best first), `tgt_qemu`, `tgt_binfmt`, `tgt_file_ok` (substring of `file -b`), and — only if GNU ld's default entry is not `_start` — `tgt_default_entry_is_start` (MIPS is the example). Package names: `deb_tri`, `deb_arch`, `fed_tri`, `cross_pkg` (pacman/…).
2. **Host mapping** — the `uname -m` case in `detect_host`.
3. **Signature** — in `detect_arch`: add a `_da_xx=$(cnt '…')` regex and append `"fam:$_da_xx"` to the loop list and to `ARCH_VOTES`. Make it *specific*: prefer register syntax + mnemonics that **no other family** uses; check collisions (the comments in §5.3 list known ones). Use only POSIX ERE: `[[:space:]]`, `[[:alnum:]]`, no `\b`, `\d`, `\w`.
4. **Comment syntax** — if the new family's comment characters differ, add a `mode` in the `BEGIN` block of `sanitize_source` (`semi`, `hash`, `at`, `sl2` flags). Default is `#` to end of line.
5. **Extensions (optional)** — `detect_ext` (+ `ext_hint`), and an R8 `-march` mapping in `auto_recover`.
6. **Tests** — in `st_samples` add a detection sample `d_<arch>.s` **and**, only if you can truly run it, a runtime sample `s_<arch>.s` (prints `selftest-<x>`, exits 7); add `st_detect …` lines, a case in the "build + run on this machine" `case` for native hosts, and the cross loop at the end. The dry-run loop covers every id in `ALL_TARGETS` automatically.
7. **Docs** — §3.2 table, §11 ledger.

Promote `experimental` → `supported` only when a runtime sample has been executed (native or qemu) and recorded in §11.

#### 13.3.2 Add an operating system (FreeBSD, OpenBSD, …)

1. `detect_host`: new `uname -s` case → `OS=<name>`.
2. Write `build_<os>()` next to `build_linux`/`build_macos` and dispatch in `do_build`. Decide object/executable format (`FMT`), entry convention, syscall ABI warnings (`post_build`).
3. `plan_all`/`plan_tools`: tools for that OS; `pkg_of`/`detect_pm` for its package manager (`pkg`, `pkgin`, `pkg_add`).
4. `host_runs_natively`: compatibility layers (e.g. Linux emulation on FreeBSD).
5. `st_samples`: a runtime sample + `case "$OS:$HOST:$HOST_BITS"` entry in `do_selftest`.

#### 13.3.3 Add a package manager

`detect_pm` (command, `UPD`/`INS` strings, `PM` id), `pkg_of` (per-tool names), `cross_pkg` (cross/qemu names), `print_manual`. Remember: package names are *verified after install* (I5), so a wrong name degrades gracefully; still verify names against the distro's package index (`apt-cache policy`, `dnf info`, `pacman -Si`, `apk info`, …) and note the result in §11.

#### 13.3.4 Add an assembler (YASM, FASM, UASM/JWasm, LLVM `llvm-mc`, …)

1. Syntax id in `detect_syntax` (votes or firm directive); add a `FORCE_SYNTAX` value in the `main` parser.
2. A branch in `build_linux`/`build_macos` (assemble → object → link) and in `plan_tools`/`tool_ok`/`pkg_of`.
3. Generalise R6 (syntax flip) — today it flips between exactly two syntaxes.
4. Samples + detection tests.

#### 13.3.5 Add an auto-recovery rule

Pattern: *log text → one state change → `plan_all` → return 0*.

```sh
    # R9: <describe the failure in one line>
    if ! tried myrule && lg '<ERE matching the failing log>'; then
        mark myrule
        _ar_old=$SOMETHING                       # remember state in case the user declines
        SOMETHING=newvalue
        auto_say "<what is happening, in plain words>"
        plan_all
        if ensure_tools soft; then note_attempt "<short label>"; return 0; fi   # only if new tools might be needed
        SOMETHING=$_ar_old; plan_all             # declined: restore
        return 1
    fi
```

Checklist: gated by `tried/mark` (fires once); never fires in `--dry-run`; never on *link* errors if it is an assembler rule (see R6's `! lg 'undefined reference|…'`); respects "forced" options and "firm" decisions; restores state on decline; has a stub test (§13.4).

#### 13.3.6 Add a detection signal

Add the regex alternative in `detect_arch`/`detect_syntax`/`detect_bits`/`detect_entry_libc_cpp`/`detect_ext`. Then: (1) add a **positive** sample, (2) add a **collision** sample from each family that could be confused with it, (3) re-run the whole corpus — the existing results must not change. Detection regexes run on the *sanitised* copy (comments gone), so do not write patterns that expect comments (except `ENTRY(name)`, which deliberately reads the raw file).

#### 13.3.7 Add a command-line option

`usage()` text → the `case` in `main` (value options need `need_val`; also add the `--opt=*` form) → validation block → use in `plan_all`/stages → `write_report` field if it affects results → §4 table. If it should be allowed in project-local config, add it to the whitelist in `rc_add`; **default is: not allowed**.

#### 13.3.8 Add a report field

`write_report` (keep it valid JSON: strings through `json_str`, booleans through `json_bool`, lists through `json_list`), bump `"schema"` if you remove/rename anything, document in §9.

### 13.4 Testing protocol

Run, in this order, after **every** change:

```sh
dash -n asmrun-v6.sh && bash --posix -n asmrun-v6.sh && echo syntax ok
for sh in dash "bash --posix" sh; do $sh ./asmrun-v6.sh --selftest 2>&1 | tail -1; done
env -i /bin/sh ./asmrun-v6.sh --selftest 2>&1 | tail -1
./asmrun-v6.sh --doctor
```

**Techniques that work without exotic hardware** (all used to verify this release):

1. **`--detect` / `--dry-run`** need no tools: they test detection and the exact command lines for every target on any machine.
2. **Stub toolchains.** Put fake tools first in `PATH`; the script's real logic runs against them. Pattern:

   ```sh
   mkdir stubs
   cat > stubs/aarch64-linux-gnu-as <<'EOF'
   #!/bin/sh
   echo "as $*" >> "$XLOG"; out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done; echo obj > "$out"
   EOF
   cat > stubs/aarch64-linux-gnu-ld <<'EOF'
   #!/bin/sh
   out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
   printf '#!/bin/sh\necho fake-program\nexit 5\n' > "$out"; chmod +x "$out"
   EOF
   cat > stubs/qemu-aarch64 <<'EOF'
   #!/bin/sh
   while [ $# -gt 0 ]; do case "$1" in -L|-cpu) shift 2;; -*) shift;; *) break;; esac; done
   prog=$1; shift; exec sh "$prog" "$@"
   EOF
   chmod +x stubs/*; XLOG=$PWD/log PATH="$PWD/stubs:$PATH" ./asmrun-v6.sh --target aarch64 hello.s
   ```

   Make a stub **fail** the way the real tool fails (copy the real error text) to test a recovery rule; make it **succeed only with a given flag** to prove the retry added it. A stub `apt-get` that creates symlinks into a directory on `PATH` tests the install loop; one that does nothing tests the verification (I5). Fake macOS with stub `uname` (`-s` → `Darwin`, `-m` → `arm64`), `clang`, `xcode-select`.
3. **A minimal `PATH`** (symlink only coreutils into a directory) reproduces "fresh container" behaviour.
4. **Detection corpus.** Keep realistic hello-world programs per family plus adversarial files (comments full of other architectures' registers, strings containing comment characters, CRLF, BOM). The loop in `do_selftest` shows the shape; a quick ad-hoc check is `for f in corpus/*; do ./asmrun-v6.sh --detect "$f" | sed -n 's/^arch=//p'; done`.
5. **Real foreign execution** where possible: Docker with `--platform linux/arm64`, `qemu-user-static` + `binfmt_misc`, or a cloud ARM/RISC-V instance — then run `--selftest` there and record the result in §11.
6. Performance guard: a 50 000-line file must analyse in a few seconds (it is currently ~1.2 s with mawk).

### 13.5 Release checklist

- [ ] `VERSION` bumped; header comment and §14 changelog updated
- [ ] syntax checks and the self-test pass under `dash`, `bash --posix`, `sh`, and `env -i`
- [ ] every new function has a unique-prefixed scratch-variable set; no bashisms (grep for `[[`, `local`, `echo -e`, `==`, `$'`)
- [ ] new/changed detection → corpus re-run shows no regressions
- [ ] new recovery rule → stub test written and passing
- [ ] §3, §4, §6, §9, §11 match the code (`--help` text, tables, ledger)
- [ ] the "not executed" list in §11 is still true and complete

### 13.6 Keeping up with new hardware and tools — a watch-list

Review this list at least yearly; each item names *where* to change the code.

| Trend | What to do in asmrun |
|---|---|
| **x86: APX** (r16–r31, NDD, `{nf}`), **AVX10**, **AMX**, AVX-512 FP16 | `detect_ext` already flags avx512/apx/amx; extend patterns; ensure the assembler is new enough (binutils ≥ 2.42 for APX, NASM ≥ 2.16) — add an R8-style hint; note APX collides with PPC `r16–r31` in `detect_arch` (check) |
| **ARM: SVE2, SME/SME2, MTE, PAC/BTI, LSE** | extend `detect_ext` and the R8 `-march` table (`armv9.x-a+…`); under qemu use `-cpu max` (automatic for sve/sme) |
| **RISC-V: RVV 1.0, RVA23, bit-manip (Zb*), crypto (Zk*), CHERI-RISC-V**, `rv32` | add `rv32`/`riscv32` as a target (bits 32; check glibc/qemu availability); extend R8 (`rv64gcv`, `rva23u64`) |
| **LoongArch LSX/LASX**, **PowerPC 10 MMA / POWER11**, **IBM z16/z17**, **MIPS r6**, **SPARC/m68k/Xtensa/…** | add via §13.3.1; add `-march`/`-mcpu` mappings to R8 |
| **WebAssembly / WASI assembly (wat)** | would be a separate assembler + runtime (`wat2wasm` + `wasmtime`): §13.3.4 + new runner kind in `plan_runner`/`run_phase` |
| **Apple silicon changes** (new macOS SDK/linker, Rosetta policy, arm64e/PAC) | re-verify `build_macos`, the ad-hoc signing behaviour, `rosetta_ok` |
| **Linux: loader/toolchain changes** (new binutils warnings such as RWX segments, PIE defaults, `--no-warn-*`) | update `stage`'s warning explanation; never add flags silently (I1) |
| **Distro package renames** (cross toolchains, `qemu-user`, multilib) | re-check `cross_pkg`/`pkg_of`; `--doctor` + the install loop reveal drift |
| **Containers & multi-arch** (Docker `--platform`, `binfmt_misc`, Podman) | `binfmt_ok` covers registered handlers; add detection for `QEMU_LD_PREFIX` sysroots if needed |
| **Windows native** (ARM64 Windows, MSYS2 clang) | currently refused (WSL2 recommended); add an `OS` branch (§13.3.2) only with a real Windows test bed |
| **Multi-file projects** | currently one source file; a future `asmrun a.s b.s` needs: multi-object `build_*`, per-file detection, link ordering |
| **Debugger integration** | `-g` exists; a `--gdb` mode would run `gdb`/`gdb-multiarch` (cross: `gdbserver` under qemu `-g PORT`) |
| **Sanitisers/analysis** | e.g. `--emit-asm-listing` (`as -al`, `nasm -l`), `--objdump` |

### 13.7 Prompt for an AI agent maintaining this project

> You are maintaining `asmrun-v6.sh`, a single-file POSIX `sh` tool, and its manual `asmrun-v6.md`. Before any change: read §10 (invariants) and §13.1 (rules) of the manual. Make the smallest change that solves the problem; keep per-architecture knowledge only in the registry functions; keep `plan_all` idempotent; use uniquely prefixed scratch variables; never use bashisms; never add compiler/linker flags to native commands unless the user asked (I1); never re-run the user's program automatically. After the change: run `dash -n`, `bash --posix -n`, the self-test under `dash`, `bash --posix` and `sh`, plus `env -i`; add a regression sample/stub test for what you fixed; update the manual (tables, changelog, §11 ledger). In your report, separate **executed**, **simulated with stubs**, and **not executed** — never describe stubbed or untested behaviour as verified. If asked to claim the tool is "perfect", decline and show the ledger instead.

---

## 14. Appendix: bug history and known limitations

### 14.1 Changelog

- **6.0.0** — everything in §2; self-test 3 → 42 checks; 4 experimental architectures; auto-recovery; `--detect/--dry-run/--doctor/--list-targets/--timeout/--march/*-flags/-g`; config parsing hardened.
- **5.0.0** — x86-64, i386, ARM64, ARM32, RISC-V; cross builds; qemu-user; report; selftest; `.asmrunrc` (sourced as shell — see 2.1 #5).
- **v3 → v4 lesson** — adding `-z noexecstack` / `--no-warn-rwx-segments` made builds fail on assemblers that do not know them; this is why I1 exists.

### 14.2 Known limitations (by design or not yet done)

- One source file per run (no multi-file linking).
- GNU as/NASM only; no MASM/TASM/FASM; no 16-bit boot code (detected, explained, QEMU command suggested).
- 32-bit userland on a 64-bit kernel can technically run 64-bit *static* programs; asmrun treats that as "cross" and asks for qemu.
- `--*-flags` are split on whitespace; values containing spaces cannot be passed.
- Big-endian PowerPC/MIPS, ppc32, riscv32, SPARC, m68k, … are not targets (see §13.3.1).
- Non-Debian cross-package names are best effort (verified after install, hence safe, but possibly not found).
- awk is portable POSIX but was only run on mawk; BSD awk (macOS) is unproven.
- A program that crashes is never re-run automatically with a different guess — by design (side effects).
