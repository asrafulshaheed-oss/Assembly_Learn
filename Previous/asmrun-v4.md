# `README.md`

```markdown
# asmrun

> Assemble, link, and run any hand‑written assembly file — on any Linux or macOS —
> with **one command**, and only install the tools that file actually needs.

```bash
asmrun hello.s      # works
asmrun -v hello.asm # works, with detection details
asmrun --32 boot.s  # works, forces 32-bit
```

No Makefile. No CMake. No "wait, do I need `-f elf32` or `-f elf64` today?"
`asmrun` figures out everything from the source and builds the exact command
you would have typed by hand.

---

## Table of contents

1. [Why this exists](#why-this-exists)
2. [Quick start](#quick-start)
3. [Feature summary](#feature-summary)
4. [Supported environments](#supported-environments)
5. [How it works (deep dive)](#how-it-works-deep-dive)
   1. [Phase 1 — Argument parsing](#phase-1--argument-parsing)
   2. [Phase 2 — Host detection](#phase-2--host-detection)
   3. [Phase 3 — Source analysis](#phase-3--source-analysis)
   4. [Phase 4 — Dependency check and installation](#phase-4--dependency-check-and-installation)
   5. [Phase 5 — Build](#phase-5--build)
   6. [Phase 6 — Run](#phase-6--run)
6. [CLI reference](#cli-reference)
7. [Exit codes](#exit-codes)
8. [Troubleshooting](#troubleshooting)
9. [Design principles and invariants](#design-principles-and-invariants)
10. [Extending asmrun](#extending-asmrun)
11. [Roadmap](#roadmap)
12. [Known limitations](#known-limitations)

---

## Why this exists

If you write assembly by hand — hobby, coursework, real firmware, teaching —
you spend a lot of time typing the same two commands:

```bash
nasm -f elf32 -o hello.o hello.s && ld -m elf_i386 -o hello hello.o
```

…and getting them slightly wrong. Forget `-f elf32` and your 32-bit
`int 0x80` code silently assembles as 64-bit and segfaults at runtime.
Forget `-m elf_i386` and the linker produces a binary the kernel refuses to
load. Forget that macOS uses `macho64`, not `elf64`, and everything breaks.

Then a friend on Fedora wants to run your program, but they don't have `nasm`,
and the "install" instruction is "run `sudo apt install nasm`" — which doesn't
work on Fedora. Or they're on Alpine, where the package is a different name
again. Or on Apple Silicon, where half of the examples in every tutorial were
written for Intel Macs that no longer exist.

**`asmrun` collapses all of that into one command.**

```bash
asmrun hello.s
```

It detects the syntax (NASM vs. GAS AT&T vs. GAS `.intel_syntax`), the
architecture (x86-64, i386, ARM64, ARM32, RISC-V), the bitness (32 vs. 64),
whether the program needs libc or uses raw syscalls, and whether it needs the
C preprocessor (`.S` files). Then it checks that the required tools exist,
offers to install only what's missing, builds the program with **exactly the
same command you would have typed manually**, and runs it.

No more `elf32` vs. `elf64` guessing.

---

## Quick start

```bash
# 1. Save the script somewhere
curl -fsSL https://example.com/asmrun -o asmrun
chmod +x asmrun

# 2. (optional) Put it on your PATH
sudo install -m 755 asmrun /usr/local/bin/asmrun

# 3. Run any assembly file
asmrun hello.s
asmrun program.asm
asmrun myprog.S arg1 arg2

# See what it's doing
asmrun -v hello.s

# Force a specific bitness if detection gets it wrong
asmrun --32 hello.s
```

The first time you run it on a fresh system, it will offer to install the
missing toolchain:

```
[WARN] Missing tools: nasm ld
The following command(s) will install the missing dependencies:
  sudo apt update -y && sudo apt install -y nasm binutils
Do you want me to run it automatically? [y/n]
```

Answer `y`, enter your password when prompted, and `asmrun` will print a
per‑package summary:

```
[ OK ] Successfully installed: nasm binutils
Hello World!
```

If some packages fail and others succeed, you get a per‑package report with
the failures in red so you know exactly what to install yourself.

---

## Feature summary

### Detection

- **Assembler / syntax** — NASM (Intel), GAS AT&T, GAS `.intel_syntax noprefix`
- **Architecture** — x86-64, i386, ARM64 (AArch64), ARM32 (ARMv7), RISC-V
- **Bitness** — 32‑bit vs 64‑bit, with weighted scoring from register names
  and `int 0x80` / `syscall` instructions
- **Entry point** — `_start`, `start`, or `main`, automatically
- **libc** — detects `extern printf` / `call puts@PLT` and links against libc
  via `gcc`/`clang` instead of raw `ld`
- **Preprocessor** — detects `.S` extension and `#include`/`#define`
- **Unsupported dialects** — detects MASM, TASM, FASM, and 16‑bit boot‑sector
  code and explains why it can't help instead of failing cryptically

### Installation

- **Package manager detection** — probes `command -v` for
  `apt` / `apt-get` / `dnf` / `yum` / `pacman` / `zypper` / `apk` / `xbps-install`
- **Immutable systems** — detects rpm‑ostree and tells you to use
  `rpm-ostree install` + reboot
- **Privilege** — respects `root` (no sudo needed), uses `sudo` or `doas` if
  available, and explains what to do if neither exists
- **Only what's needed** — a NASM x86 file installs `nasm` + `binutils` only;
  a GAS ARM file installs `as` + `ld` only; a libc file installs `gcc` only;
  a `.S` file installs `gcc` (for the preprocessor) only
- **Per‑package results** — "Successfully installed: X Y Z" in green,
  "Failed: Q" in red, "None of the required packages could be installed" if
  everything fails
- **Verification** — after installation it re‑runs `command -v` on each tool,
  because package managers lie (especially on macOS, where `/usr/bin/clang` is
  a shim that exists even when CLT isn't installed)

### macOS specifics

- **Xcode Command Line Tools** — detects them, opens the GUI installer, and
  *waits* for the install to finish (up to 1 hour) instead of continuing
  immediately and failing
- **Rosetta 2** — detects it; offers to install it if x86-64 code is being run
  on Apple Silicon
- **Apple Silicon native** — ARM64 assembly compiles natively via
  `clang -arch arm64`; no Rosetta needed
- **32-bit x86** — detected early and refused with an explanation (dropped in
  macOS 10.15)

### Portability

- **POSIX `sh`** — works on macOS's stock bash 3.2, Alpine's `ash`, Debian's
  `dash`, and BusyBox
- **No bash-4 features** — no associative arrays, no `readarray`
- **Noexec‑safe workdir** — probes `$TMPDIR`, `/tmp`, `~/.cache`, `$PWD`, and
  uses the first one where a test executable actually runs
- **Stream separation** — all `[INFO]`/`[WARN]`/`[ERROR]`/`[BUILD]` output
  goes to `stderr`; the program's own output goes to `stdout`, so `asmrun
  hello.s > out.txt` captures only the program's output

### Developer ergonomics

- **`-v` / `--verbose`** — full detection details and every command that runs
- **`--nasm` / `--gas` / `--32` / `--64` / `--arch`** — force any detection
- **`-o FILE`** — keep the built executable at a known path
- **`--`** — pass anything to the program itself
- **`[BUILD]` lines always printed** — so you can copy them into a shell and
  reproduce exactly
- **`[FILE]` line after build** — shows `file(1)`'s verdict on the binary, so
  you can confirm the bitness before it runs

---

## Supported environments

| OS | Arch | Supported? | Notes |
|---|---|---|---|
| Linux | x86-64 | ✅ | Most common case |
| Linux | i386 | ✅ | Requires 32-bit loader or kernel support |
| Linux | ARM64 | ✅ | Raspberry Pi 4/5, ARM servers |
| Linux | ARM32 | ✅ | Older Pi, ARMv7 boards |
| Linux | RISC-V 64 | ✅ | Native RISC-V distros |
| macOS | arm64 (Apple Silicon) | ✅ | Native ARM64 + Rosetta 2 for x86-64 |
| macOS | x86-64 (Intel) | ✅ | 64-bit only |
| macOS | i386 | ❌ | Dropped in macOS 10.15 — detected early |

| Package manager | Distros |
|---|---|
| `apt` / `apt-get` | Ubuntu, Debian, Mint, Pop!_OS, elementary, Kali, … |
| `dnf` | Fedora 22+, RHEL 8+, Rocky, Alma, … |
| `yum` | CentOS 7, RHEL 7, older Fedora |
| `pacman` | Arch, Manjaro, EndeavourOS, Artix, … |
| `zypper` | openSUSE Leap, Tumbleweed, SLES |
| `apk` | Alpine, postmarketOS |
| `xbps-install` | Void Linux |
| `rpm-ostree` | Fedora Silverblue, Kinoite, Bazzite |
| `brew` | macOS (via Homebrew) |

| Assembler / syntax | Extensions |
|---|---|
| NASM (Intel) | `.asm`, `.s`, `.nasm` |
| GAS AT&T | `.s`, `.S` |
| GAS Intel (`.intel_syntax noprefix`) | `.s`, `.S` |
| GAS with C preprocessor | `.S` |

---

## How it works (deep dive)

The script is a linear pipeline of six phases, each with its own detection or
action. Every phase is skippable via a CLI flag, so any wrong guess is
correctable in one command.

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Parse CLI flags                                               │
│ 2. Detect host OS + arch                                         │
│ 3. Analyse source: arch → syntax → bitness → entry → libc → cpp  │
│ 4. Verify tools; offer to install what's missing                 │
│ 5. Assemble + link (exact manual commands)                       │
│ 6. Run the binary                                                │
└──────────────────────────────────────────────────────────────────┘
```

### Phase 1 — Argument parsing

Reads flags before the filename, saves the filename, and stores everything
after the filename to pass to the program unchanged.

| Flag | Effect |
|---|---|
| `-v`, `--verbose` | Enable `[INFO]` lines and print every build command |
| `-y`, `--yes` | Skip the install prompt and install automatically |
| `-o FILE`, `--output FILE` | Keep the built binary at `FILE` instead of a temp file |
| `--nasm` | Force NASM (Intel) syntax |
| `--gas`, `--as` | Force GNU `as` syntax (AT&T or `.intel_syntax`) |
| `--32` | Force 32-bit build (x86 only) |
| `--64` | Force 64-bit build (x86 only) |
| `--arch ARCH` | Force `x86` / `arm64` / `arm32` / `riscv` |
| `--` | Everything after this goes to the program, not to `asmrun` |
| `-h`, `--help` | Print usage |

Any flag can be combined. The parser is strict — unknown flags are errors,
not silently ignored.

### Phase 2 — Host detection

Runs `uname -s` to pick `linux` vs. `macos` and `uname -m` to pick
`x86` / `arm64` / `arm32` / `riscv`. On Apple Silicon, terminals launched
under Rosetta report `x86_64` even though the hardware is ARM64 — the script
detects this via `sysctl -n hw.optional.arm64` and sets `HOST=arm64`.

### Phase 3 — Source analysis

This is the heart of the tool. Every heuristic is a **weighted vote** rather
than a single regex match, because single signals are almost always wrong
(see "Design principles" below for why).

#### 3a. Architecture detection

Counts lines matching x86-like, ARM64-like, ARM32-like, and RISC-V-like
patterns. The family with the most matches wins. Ties go to the host
architecture. This is why an x86 hello-world on an ARM Mac is correctly
identified as x86 (it has `eax`, `ebx`, `int 0x80` etc.), while an ARM file
with `x0`, `x1`, `svc` is correctly identified as ARM64.

If detection is wrong, override with `--arch`.

#### 3b. Syntax detection (x86 only)

Compares NASM-signature and GAS-signature match counts:

**NASM signatures:**
- `section .text` / `segment .data` (bare, no leading dot)
- `global foo` / `extern foo` (bare, no leading dot)
- `db` / `dw` / `dd` / `dq` / `resb` / `resw` / `resd` / `resq` / `equ` / `times`
- `%define` / `%macro` / `%include` / `%ifdef` / etc.
- `BITS 32` / `BITS 64`
- `default rel`
- `byte [rsp]` / `dword [rbp]` etc.

**GAS signatures:**
- `.globl` / `.section` / `.text` / `.data` / `.bss` (leading dot)
- `.ascii` / `.asciz` / `.string` / `.quad` / `.long` etc.
- `%rax` / `%rbx` / `%eax` etc.
- `%r8` – `%r15`
- `%mm0` – `%mm7`
- `movl` / `addq` / `pushq` etc. (AT&T suffix)
- `$0x10` / `$-1` etc. (AT&T immediate)

Explicit markers always win: a file starting with `.intel_syntax noprefix`
is GAS, and a file containing `%define` is NASM, no matter what else is
present. `.S` extension forces GAS with the C preprocessor.

If detection is wrong, override with `--nasm` or `--gas`.

#### 3c. Bitness detection (x86 only)

Explicit directives win outright:
- `BITS 32` or `.code32` → **32-bit**
- `BITS 64` or `.code64` → **64-bit**

Otherwise a weighted score is computed:

| Signal | Weight |
|---|---|
| `int 0x80` or `int 80h` | **+5 to 32-bit** |
| `syscall` instruction | **+5 to 64-bit** |
| Each `eax`/`ebx`/`ecx`/`edx`/`esi`/`edi`/`esp`/`ebp`/`eip` | +1 to 32-bit |
| Each `rax`/`rbx`/…/`r8`-`r15` | +1 to 64-bit |

Ties fall back to host bitness. This is why a classic 32-bit hello world
with two `int 0x80` calls and six 32-bit register uses reliably scores 16
for 32-bit and 0 for 64-bit — the exact case that caused the very first
bug in this project.

If detection is wrong, override with `--32` or `--64`.

#### 3d. Entry-point detection

Looks for a top-level label at the start of a line:

| Pattern | Meaning |
|---|---|
| `_start:` | Raw syscall entry point (Linux + macOS raw) |
| `start:` | Somewhat rare, but supported |
| `main:` or `_main:` | libc entry point — triggers libc linking |

If none is found, the script warns (but proceeds; some files define the entry
via linker scripts or inline globals).

#### 3e. libc detection

Any of these triggers libc linking:
- `extern printf` / `.extern printf` / `extern _printf`
- `call printf` / `call puts` / `call malloc` / etc.
- `call printf@PLT` (ELF PIC)
- `wrt ..plt` (some GAS dialects)

If libc is needed:
- **macOS** — links via `clang`, which correctly wires up libc/libSystem
- **Linux** — links via `gcc -no-pie`, since libc symbols are absolute

#### 3f. Preprocessor detection

Any of these triggers `.S` preprocessing via `clang`/`gcc -x assembler-with-cpp`:
- `.S` extension (capital S)
- `#include <…>` / `#include "…"`
- `#define` / `#ifdef` / `#ifndef` (only if syntax is GAS)

#### 3g. Unsupported-dialect detection

Before doing any work, the script checks for MASM/TASM/FASM signatures and
refuses with a clear error, rather than trying to assemble and producing
confusing errors from `nasm`:

- `.model small` / `endp` / `invoke` / `includelib` → MASM/TASM
- `format elf64` / `format pe64` / `segment readable` / `entry foo` → FASM
- `BITS 16` / `.code16` / `org 0x7c00` → 16-bit boot sector

### Phase 4 — Dependency check and installation

For each required tool, `command -v` is called. Missing tools trigger
per‑tool mapping to package names:

| Tool | Debian/Ubuntu | Fedora | Arch | openSUSE | Alpine | Void |
|---|---|---|---|---|---|---|
| `nasm` | `nasm` | `nasm` | `nasm` | `nasm` | `nasm` | `nasm` |
| `as` / `ld` | `binutils` | `binutils` | `binutils` | `binutils` | `binutils` | `binutils` |
| `gcc` | `gcc` | `gcc` | `gcc` | `gcc` | `gcc musl-dev` | `gcc` |

On macOS, `as` and `ld` come from the **Xcode Command Line Tools**, not
Homebrew. The script polls `xcode-select -p` and `[ -x "$pkg/usr/bin/clang" ]`
to confirm CLT is really installed (`/usr/bin/clang` is a shim that exists
even without CLT, so that alone is not enough).

The user is then prompted:

```
Want me to install them automatically?  [y = automatic / n = manual]
```

- **`y`** — runs the platform-appropriate install command, prints per-package
  results in green/red, and re-checks that every required tool is now present.
- **`n`** — prints the exact install command the user can run manually,
  adapted to their package manager.
- **No terminal** (piped stdin, CI) — defaults to `n` and prints the manual
  command. Also handles the case where a user runs `echo y | asmrun` (piped
  input) by falling back to `/dev/tty`.

### Phase 5 — Build

This is where the single most important invariant lives: **the build
commands must match what you would type by hand.**

Linux x86-64 NASM + libc:

```bash
nasm -f elf64 -o /tmp/asmrun.XXX/prog.o hello.s
gcc -no-pie -nostartfiles -o /tmp/asmrun.XXX/prog /tmp/asmrun.XXX/prog.o
```

Linux i386 NASM + raw syscalls:

```bash
nasm -f elf32 -o /tmp/asmrun.XXX/prog.o hello.s
ld -m elf_i386 -o /tmp/asmrun.XXX/prog /tmp/asmrun.XXX/prog.o
```

macOS ARM64 GAS:

```bash
clang -arch arm64 -x assembler -Wl,-e,_start -o /tmp/asmrun.XXX/prog hello.s
```

macOS x86-64 NASM + libc:

```bash
nasm -f macho64 -o /tmp/asmrun.XXX/prog.o hello.s
clang -arch x86_64 -o /tmp/asmrun.XXX/prog /tmp/asmrun.XXX/prog.o
```

**Do not add extra flags** (like `-z noexecstack` or
`--no-warn-rwx-segments`) unless you have tested them on every supported
`ld` version. In particular, `-z noexecstack` combined with `-m elf_i386`
inserts a `.note.GNU-stack` section that shifts the segment layout in a way
that breaks absolute `mov ecx, msg` addressing on some `ld` builds. This is
the bug that broke v3 and drove the rewrite to v4.

Every build command is prefixed with `[BUILD]` and printed to stderr, so you
can always copy it out and reproduce manually.

### Phase 6 — Run

The binary is executed with the remaining CLI arguments forwarded. Exit codes
are interpreted:

| Code | Meaning | Hint printed |
|---|---|---|
| 0 | success | — |
| 126 | permission denied | check if `$TMPDIR` is noexec |
| 127 | command not found | missing 32-bit loader if 32-bit build |
| 132 | SIGILL | wrong CPU mode or execution ran into data |
| 137 | SIGKILL | macOS: suggest `codesign -s - -f` |
| 139 | SIGSEGV | detailed hint including `[BUILD]` commands to reproduce |

If the file uses `int 0x80` but was built as 64-bit (which should never
happen with correct detection), the segfault message points at `--32`.

---

## CLI reference

```
Usage: asmrun [options] <file> [program arguments...]

  -v, --verbose       show detection details and every command
  -y, --yes           install missing tools without prompting
  -o, --output FILE   keep the built executable as FILE
      --nasm          force NASM syntax
      --gas           force GNU as syntax
      --32            force 32-bit build (x86 only)
      --64            force 64-bit build (x86 only)
      --arch ARCH     force x86 | arm64 | arm32 | riscv
  -h, --help          this help

Anything after the file name is passed to your program.
```

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Program ran and exited 0 |
| 1 | Error in `asmrun` (bad args, missing file, install failed, build failed) |
| 2 | Usage error (missing file argument) |
| 126 | Program could not be executed (permission / noexec) |
| 127 | Program not found (missing loader) |
| 128+N | Program died from signal N (139 = SIGSEGV, 132 = SIGILL, 137 = SIGKILL) |
| Other | Program's own exit code, forwarded unchanged |

`asmrun` **always** returns the program's exit code, so it composes cleanly
with `&&`, `||`, and CI scripts.

---

## Troubleshooting

### Segfault on a program that works when run manually

The single most common cause is that `asmrun` built the file as a
different bitness than your manual command. Check the `[BUILD]` lines:

```bash
asmrun -v hello.s
```

Compare to your manual one-liner. If they differ, force the correct bitness:

```bash
asmrun --32 hello.s    # for int 0x80 code
asmrun --64 hello.s    # for syscall code
```

### "This looks like MASM/FASM/16-bit"

`asmrun` supports NASM and GAS only. If you have MASM/TASM/FASM source,
convert it first, or use the appropriate toolchain directly.

### macOS: "Xcode Command Line Tools are not installed"

Run `xcode-select --install` and let the GUI finish before re-running.
`asmrun` will wait for the install to complete.

### macOS: "CLT dialog appeared but nothing installed"

The dialog is non-blocking. `asmrun` polls for up to 1 hour. If it times
out, install manually and re-run.

### Apple Silicon: x86-64 program fails to launch

Rosetta 2 may not be installed. `asmrun` will offer to install it via
`softwareupdate --install-rosetta`. Or use native ARM64 assembly instead
(`clang -arch arm64` handles it directly).

### `[FILE]` shows `32-bit` but the file clearly has 64-bit registers

The detection might have been influenced by a comment or string that looks
like a register name. Force with `--64`.

### Package manager not recognized

```
[ERROR] Package manager not recognised.
```

Edit `setup_pm()` in the script to add your manager. See
[Extending asmrun](#extending-asmrun) below.

### Alpine: gcc installs but `as`/`ld` still missing

Alpine's `gcc` package depends on `binutils`, so both should install
together. If they don't, `apk add binutils` manually.

---

## Design principles and invariants

**Read this before changing any code.** Every design decision below was made
after a specific bug. Violating these invariants will reintroduce the bug.

### Invariant 1: build commands must match the user's manual command exactly

The script was born because a user was tired of typing
`nasm -f elf32 … && ld -m elf_i386 …` and then discovering it didn't work
on macOS. Adding "helpful" flags like `-z noexecstack` broke that: the
built binary segfaulted even though the manual command worked.

**Rule:** if you add a flag to the `nasm`, `as`, `ld`, `gcc`, or `clang`
invocation, verify it works on **every** supported platform (Ubuntu 20.04,
Fedora 38, Arch current, Alpine, Void, macOS 14 Intel, macOS 14 ARM) before
merging. When in doubt, don't add it.

### Invariant 2: all detection is weighted, never single-signal

The original script checked "does the file contain `BITS 32`?" and if not,
assumed 64-bit. This broke every 32-bit hello world tutorial that doesn't
include a `BITS` directive.

**Rule:** every detector must produce a **score**, not a boolean. Explicit
directives (like `BITS 32`) can override the score, but no single ambiguous
signal can. See `detect_bits()` for the reference implementation.

### Invariant 3: `set -e` is forbidden

`set -e` exits on any non-zero status, including the program's own exit code.
That would make `asmrun hello.s` return 0 even when the program returns 1,
and would make `asmrun crash.s` return 1 without printing why.

**Rule:** use `set -u` (unset variable check) but **never** `set -e`. Handle
each command's failure explicitly with `||` and diagnostic messages.

### Invariant 4: info goes to stderr, program output to stdout

The user must be able to pipe `asmrun hello.s | grep Hello` and get only
the program's output, not `[INFO]` spam.

**Rule:** every `say`, `info`, `warn`, `err`, `good`, and `[BUILD]` line goes
to `>&2`. Only the program's own `printf`/`write` goes to fd 1.

### Invariant 5: install result is verified, not trusted

Package manager exit codes lie. `brew install nasm` can return 0 while
`nasm` is not on PATH (broken symlinks, PATH misconfiguration). macOS
`/usr/bin/clang` is a shim that exists even without CLT.

**Rule:** after installing, re-run `command -v` on every required tool and
fail if any are still missing. For CLT, use `xcode-select -p && [ -x
"$pkg/usr/bin/clang" ]`, not just `command -v clang`.

### Invariant 6: only install what the file actually needs

If a file uses NASM and `ld`, do **not** install `gcc`. If a file uses
`gcc -no-pie`, do **not** install `nasm`. Users should not pay the cost of
a full toolchain for one hello world.

**Rule:** compute `REQUIRED` from the detected syntax, link mode, and
preprocessor needs. `add_req` is a deduplicated append. No tool is added
speculatively.

### Invariant 7: POSIX sh, not bash

macOS ships bash 3.2 (no associative arrays, no `readarray`). Alpine ships
no bash at all. BusyBox users expect sh.

**Rule:** the shebang is `#!/bin/sh`. Do not use bash-specific syntax
(`[[ ]]`, `declare -A`, `readarray`, `${var^^}`, etc.). Test with `dash`,
`ash`, and macOS `/bin/sh`.

### Invariant 8: `[BUILD]` lines are always printed

Users need to see exactly what `asmrun` runs, so they can:
1. Copy the commands into a shell and reproduce manually
2. Compare against their one-liner and see what differs
3. Report bugs with the exact commands

**Rule:** never hide `[BUILD]` output behind `-v`. It's not verbose, it's
essential.

### Invariant 9: detection is overridable

Any heuristic can be wrong. The user must always have a way out.

**Rule:** every detection has a corresponding flag: `--nasm` / `--gas` for
syntax, `--32` / `--64` for bitness, `--arch` for architecture. When the
script fails because of a detection error, the error message must suggest
the override.

### Invariant 10: piped input is never a crash

`echo y | asmrun hello.s` must not crash on `read` hitting EOF. In a CI
environment, no interactive prompt should ever block.

**Rule:** if stdin is not a tty, try `/dev/tty`; if that fails, default to
"no" and print the manual command.

### Invariant 11: noexec-safe workdir

`/tmp` is `noexec` on many systems (Fedora, hardened Ubuntu, corporate
laptops). Building in `$TMPDIR` and trying to execute the binary from there
fails with EACCES.

**Rule:** `pick_workdir()` probes `$TMPDIR` → `/tmp` → `~/.cache` → `$PWD`
and uses the first directory where a test executable actually runs.

---

## Extending asmrun

### Add a new architecture

Say you want to add **MIPS64**.

1. **Detection** — add a `_m` count in `detect_arch()`:
   ```sh
   _m=$(cnt '(^|[^[:alnum:]_])(a[0-3]|v[01]|t[0-9]|s[0-7]|sp|ra)[[:space:]]*,|(^|[[:space:]])(addiu|addu|lui|syscall|jr|jalr)[[:space:]]')
   ```
   Add it to the `for _pair in …` loop.

2. **Host detection** — add `mips64` to the `case "$(uname -m)"` block:
   ```sh
   mips64*) HOST=mips64; HOST_BITS=64 ;;
   ```

3. **Arch label** — add a case to `arch_label()`:
   ```sh
   mips64) echo "MIPS64" ;;
   ```

4. **Build** — add a branch in the Linux build section:
   ```sh
   elif [ "$SRC" = mips64 ]; then
       ASF=""; LDM="-m elf64btsmip"
   ```

5. **Package mapping** — add the cross‑toolchain if needed in `pkg_of()`.

6. **Test** — write a minimal MIPS64 assembly file and add it to the test
   matrix.

### Add a new package manager

Say you want to add **Nix**.

1. **Detection** — add `nix` to the `for _c in apt apt-get …` loop:
   ```sh
   for _c in apt apt-get dnf yum pacman zypper apk xbps-install nix-env; do
   ```

2. **Install command** — add to the `case "$PM"` block in `setup_pm()`:
   ```sh
   nix-env)  PM=nix; INS="nix-env -iA nixpkgs" ;;
   ```
   (Adjust the syntax — `nix-env` uses attribute paths, not package names,
   so `pkg_of()` will need per‑tool mapping.)

3. **Manual command hint** — add to `print_manual()`:
   ```sh
   nix) say "  ${CYAN}nix-env -iA $PKGS${NC}" ;;
   ```

4. **Multilib** — add to the `NEEDS_MULTILIB` `case` if Nix supports 32-bit.

### Add a new assembler

Say you want to support **Yasm** (a NASM alternative).

1. **Detection** — add a signature in `detect_syntax()`:
   ```sh
   if has '^[[:space:]]*%[[:space:]]*(define|macro)' && command -v yasm >/dev/null 2>&1; then
       SYNTAX=yasm
   fi
   ```

2. **Build command** — add a branch in Phase 5:
   ```sh
   elif [ "$SYNTAX" = yasm ]; then
       stage "Assembling (yasm)" yasm -f "$FMT" -o "$OBJ" "$FILE" || build_failed assemble
       # ... link as usual
   ```

3. **Requirement** — add `add_req yasm` in the tool‑requirement block.

4. **Package** — Yasm is usually in the same package as NASM on most
   distros, but check the `pkg_of()` mapping.

### Improve a heuristic

If a user reports "detection got this wrong", the fix is usually:

1. **Reproduce** — get the minimal failing file.
2. **Count** — run the current `cnt()` regex on it and see what score it
   produces.
3. **Add a signal** — if the correct signal is missing, add it to the
   relevant `cnt()` call. Bump the score of ambiguous signals down, or
   strengthen the score of unambiguous ones.
4. **Test on the whole corpus** — every existing test case must still pass.
   Weighted scoring is only safe if you don't break other cases.
5. **Never** add a single-signal override unless it's an explicit directive
   (`BITS 32`, `%define`, `.intel_syntax`).

---

## Roadmap

### Near term (v4.x)

- [ ] **Windows + WSL2** — detect WSL and use WSL's native toolchain; refuse
  natively on Windows with a clear message
- [ ] **`--link-only` / `--asm-only`** — for users who want to keep the `.o`
  or the linked binary without running
- [ ] **`--keep-build-dir`** — don't delete the temp directory, so users can
  inspect intermediate files
- [ ] **`.S` preprocessing without `gcc`** — if `cpp` alone is available,
  use it instead of the full `gcc` package
- [ ] **Better ARM32 detection** — Thumb-2 instructions are currently
  under-detected
- [ ] **32-bit multilib auto-install on Linux** — currently detected but
  requires manual install

### Medium term (v5)

- [ ] **Cross-compilation** — detect `--target aarch64` and use `aarch64-linux-gnu-gcc` if available; refuse gracefully if not
- [ ] **QEMU fallback** — if cross-compiling and `qemu-user` is available, run
  the foreign binary transparently
- [ ] **Inline source-based entry detection** — parse for `ENTRY(foo)` in
  linker scripts
- [ ] **CLI config file** — `.asmrunrc` in `$HOME` or project root, for
  persistent flags
- [ ] **Self-test mode** — `asmrun --selftest` runs the internal test corpus
  and reports pass/fail (useful for CI)
- [ ] **`--machine-readable`** — JSON output of detection, install, and
  build results for tooling integration
- [ ] **Shell completion** — bash/zsh/fish completions for `asmrun`

### Long term (v6+)

- [ ] **Additional architectures** — MIPS64, PowerPC64, s390x
- [ ] **Additional assemblers** — FASM native, Yasm, asm.js
- [ ] **Sandboxed execution** — optional `--sandbox` to run inside a
  seccomp/landlock jail
- [ ] **Syscall compatibility layer** — auto-detect Linux syscall numbers in
  x86-64 code on macOS and translate them (or at least error clearly)
- [ ] **macOS 32-bit through a VM** — optionally launch qemu-system-x86_64
  for 32-bit macOS-only assembly
- [ ] **Web mode** — `asmrun --wasm hello.s` produces WASM instead of
  a native binary (for education)

---

## Known limitations

### Intentional

- **No cross-compilation** — `asmrun` builds and runs code natively. If you
  want to build ARM64 on x86-64, you need a cross-toolchain and `qemu-user`,
  which is a different tool.
- **No MASM/TASM/FASM support** — NASM and GAS only. The error messages
  explain why.
- **No 16-bit / boot-sector** — user-space programs only. Use `qemu-system`
  for bootloaders.
- **macOS i386** — dropped in macOS 10.15; refused at detection.
- **Ubuntu < 20.04 / Debian < 10** — likely works, but not tested.

### Inherited from the toolchain

- **32-bit on modern Linux** — needs `libc6-i386`/`lib32-glibc` and kernel
  `CONFIG_IA32_EMULATION`. `asmrun` detects the missing loader but doesn't
  auto-install multilib (yet).
- **Rosetta 2** — Apple Silicon macOS refuses to run x86-64 without it.
  `asmrun` offers to install it.
- **Apple `ld` version drift** — `-lSystem` path changes between SDKs. The
  macOS path goes through `clang`, which handles this automatically, but if
  you're adding a raw `ld` path, always use `xcrun --show-sdk-path`.

### Environmental

- **`/tmp` noexec** — handled by `pick_workdir()`, but on extremely locked-down
  systems all four fallbacks might be noexec. The error message points at this.
- **Corporate firewalls** — `xcode-select --install` and `brew install` need
  network. `asmrun` prints the exact command if auto-install fails.

---

## Version history

- **v1** — first attempt, bash 4 only, no ARM detection, single-signal bitness
  detection (broke on 32-bit hello world).
- **v2** — POSIX sh rewrite, weighted detection, full package-manager probing,
  per‑package install reports.
- **v3** — added `-z noexecstack` for security hardening (this was a bug — it
  broke 32-bit `int 0x80` addressing on some `ld` builds).
- **v4** — reverted the `-z noexecstack` bug, added `[BUILD]` command output,
  `[FILE]` bitness verification, better segfault hint pointing at `--32`,
  `pick_workdir()` noexec-safe workdir from v2, and full POSIX sh compliance.

---

## Contributing

Contributions welcome. Before opening a PR:

1. **Read the invariants.** Especially "build commands must match the user's
   manual command exactly" and "all detection is weighted."
2. **Test on at least three environments.** Suggested matrix:
   - Ubuntu 22.04 x86-64 (apt, glibc)
   - Fedora 38 x86-64 (dnf, glibc)
   - Alpine 3.18 x86-64 (apk, musl)
   - macOS 14 ARM64 (Apple Silicon)
   - macOS 14 x86-64 (Intel) — optional but useful
3. **Include a test file** for any new detection case.
4. **Update this README** if you change the CLI, add a package manager, or add
   an architecture.

---

## License

MIT. See `LICENSE` (or use the script freely — it's small enough to be
considered public-domain-ish, but the MIT license makes that explicit).
```

---

**A few notes on this README for you as the author:**

1. **The "Design principles and invariants" section is the crown jewel.** That's what future AI agents and humans will read most carefully. Each invariant was documented against the specific bug that motivated it — that's the pattern that keeps contributors from re-breaking things.

2. **The `[BUILD]` line invariant is the single most important thing.** The v3 bug (`-z noexecstack` breaking 32-bit absolute addressing) is documented explicitly so no one reintroduces it. If a future contributor asks "should I add flag X?", this README gives them the framework to test before answering.

3. **The roadmap is honest.** I listed near-term items that are actually tractable (Windows/WSL, `--keep-build-dir`, `--asm-only`), medium-term items that need real design work (cross-compilation + QEMU), and long-term "maybe someday" items. That way a future agent can pick something appropriate for its capability.

4. **The "Extending asmrun" section is step-by-step.** It shows exactly where in the code to add a new architecture, package manager, or assembler, with code snippets. That's the section future agents will grep for when they want to expand it.

5. **The version history** explains v3 → v4 honestly: v3 introduced a bug, v4 reverted it. That's not embarrassing; it's the reality of engineering, and it prevents anyone from "fixing" v4 by re-adding the problematic flag.
