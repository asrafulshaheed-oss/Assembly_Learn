#!/bin/sh
# ==============================================================================
#  asmrun v6 - assemble, link and run a hand-written assembly file in one shot
# ==============================================================================
#  Usage   : asmrun [options] <file> [program arguments...]
#            asmrun hello.asm                    # NASM, GAS, .S - auto-detected
#            asmrun --target aarch64 hello.s     # cross-build + run via qemu-user
#            asmrun --doctor                     # what works on THIS machine?
#
#  Systems : Linux (apt, dnf, microdnf, yum, pacman, zypper, apk, xbps, ostree,
#            containers, WSL)  and  macOS (Intel + Apple Silicon, Rosetta 2)
#  Syntax  : NASM | GAS AT&T | GAS Intel (.intel_syntax) | .S (C preprocessor)
#  Targets : x86_64, i386, aarch64, armv7 (ARM32/Thumb-2), riscv64   [supported]
#            ppc64le, s390x, mips64el, loongarch64                   [experimental]
#
#  Design invariants (details and the bug behind each one: asmrun-v6.md):
#    I1  native build commands equal the manual commands (no -z noexecstack,
#        no --no-warn-rwx-segments, no "helpful" extras unless the user asks)
#    I2  every detector is a weighted vote; explicit directives may override
#    I3  set -e is never used, so the program's exit code is preserved
#    I4  diagnostics ([INFO] [WARN] [ERROR] [BUILD] ...) go to stderr, the
#        program's own output to stdout; informational modes print to stdout
#    I5  installs are verified, never trusted
#    I6  only the tools the given file needs are installed
#    I7  POSIX sh only (macOS bash 3.2, dash, ash, BusyBox) - no bashisms
#    I8  [BUILD] lines are always printed
#    I9  every detection has an override flag
#    I10 no interactive prompt can block a pipe/CI run
#    I11 the work directory is noexec-safe
#    I12 config files are parsed as data, never sourced as shell code
#    I13 a --report is written for failures too
#
#  Map of this file (search for the banner text):
#    1 globals & logging    2 target registry   3 host detection
#    4 source analysis      5 tools & install   6 build helpers
#    7 report               8 doctor/list/selftest   9 main flow (phases)
#  Adding an architecture/OS/package manager: see "Extending" in asmrun-v6.md.
# ==============================================================================

set -u
set -f                      # no globbing: unquoted flag lists must stay literal
unset CDPATH GREP_OPTIONS GREP_COLOR GREP_COLORS ENV BASH_ENV 2>/dev/null

# Keep the script usable from cron/env -i where PATH may be missing.
PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
export PATH

VERSION="6.0.0"
PROG="asmrun"

# ==============================================================================
#  1. Globals
# ==============================================================================
# --- command line ---
VERBOSE=0; ASSUME_YES=0; OUT=""; FORCE_SYNTAX=""; FORCE_BITS=""; FORCE_ARCH=""
FORCE_TARGET=""; FORCE_CC=""; KEEP_BUILD=0; ASM_ONLY=0; LINK_ONLY=0; SELFTEST=0
DRY_RUN=0; DETECT_ONLY=0; DO_DOCTOR=0; LIST_TARGETS=0; NO_COLOR_FLAG=0
REPORT=""; TIMEOUT=0; DEBUG_INFO=0; MARCH_OPT=""
X_NASM=""; X_AS=""; X_LD=""; X_CC=""; X_QEMU=""
FILE=""
# --- environment ---
OS=""; WSL=0; HOST=""; HOST_BITS=64; CONTAINER=0
# --- analysis results ---
ANA=""; ANA_GEN=""
SRC=""; SYNTAX=""; SYNTAX_LABEL=""; BITS=64; TARGET_ID=""
HAS_START=0; HAS_PSTART=0; HAS_MAIN=0; HAS_UMAIN=0; HAS_ENTRY=0; USES_LIBC=0
CPP=0; XLANG="assembler"; ENTRY_NAME=""; EXTS=""
ARCH_VOTES=""; SYNTAX_VOTES=""; BITS_VOTES=""
# --- plan ---
NATIVE=1; LINK=""; CPP_MODE=""; CC=""; CC_BIN=""
AS_BIN="as"; LD_BIN="ld"; NASM_BIN="nasm"
CROSS=""; QEMU_BIN=""; SYSROOT=""; RUNNER="native"
REQUIRED=""; MISSING=""; PKGS=""; NEEDS_MULTILIB=0
ENTRY_FLAG=""; CC_ENTRY=""; CCMODE=""; FMT="elf64"; ASF=""; LDM=""; CCM=""
# --- build state ---
WORK=""; WORK_PARENT=""; LOG=""; OBJ=""; PRE=""; EXE=""; OBJ_OUT=""; RUN=""
CMDS=""; CMD_COUNT=0; DERIVED_OUT=0; WORK_NOTED=0
# --- result state ---
RC=0; STATUS="starting"; ERR_MSG=""; REPORT_READY=0; REPORT_DONE=0; EXIT_NOTE=""
# --- package manager ---
PM=""; UPD=""; INS=""; SUDO=""; S=""; CAN_AUTO=1; WHY=""; NONINT=""

# ---------- colours -----------------------------------------------------------
init_colors() {
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "$NO_COLOR_FLAG" -eq 0 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        E=$(printf '\033')
        RED="${E}[1;31m"; GREEN="${E}[1;32m"; YELLOW="${E}[1;33m"
        BLUE="${E}[1;34m"; CYAN="${E}[1;36m"; DIM="${E}[2m"; BOLD="${E}[1m"; NC="${E}[0m"
    else
        RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; DIM=""; BOLD=""; NC=""
    fi
}
init_colors

# ---------- logging (stderr) --------------------------------------------------
say()  { printf '%s\n' "$*" >&2; }
out()  { printf '%s\n' "$*"; }                       # stdout: informational modes only
info() { if [ "$VERBOSE" -eq 1 ]; then printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*" >&2; fi; return 0; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
good() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
die()  { ERR_MSG="$*"; err "$*"; exit 1; }
usage_die() { ERR_MSG="$*"; err "$*"; say "Try: $PROG --help"; exit 2; }

# ---------- exit handling -----------------------------------------------------
cleanup() {
    if [ "$KEEP_BUILD" -eq 0 ] && [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    elif [ "$KEEP_BUILD" -eq 1 ] && [ -n "$WORK" ] && [ -d "$WORK" ] && [ "${WORK_NOTED:-0}" -eq 0 ]; then
        WORK_NOTED=1; say "${DIM}[WORK] kept build directory: $WORK${NC}"
    fi
    if [ -n "${ST_DIR:-}" ] && [ "${ST_KEEP:-0}" -eq 0 ] && [ -d "$ST_DIR" ]; then
        rm -rf "$ST_DIR"
    fi
}
on_exit() {
    _ox_rc=$?
    # I13: a report is written for failures too.
    if [ -n "$REPORT" ] && [ "$REPORT_READY" -eq 1 ] && [ "$REPORT_DONE" -eq 0 ]; then
        RC=$_ox_rc
        case "$STATUS" in
            starting|analysing|planning|building) [ "$_ox_rc" -ne 0 ] && STATUS=error ;;
            running) [ "$_ox_rc" -ge 128 ] && [ -z "$ERR_MSG" ] && { STATUS=error; ERR_MSG="interrupted (exit $_ox_rc)"; } ;;
        esac
        write_report
    fi
    cleanup
    return 0
}
trap on_exit 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

usage() {
cat <<'EOF'
Usage: asmrun [options] <file> [program arguments...]

Assembles, links and runs a hand-written assembly file. Syntax (NASM / GAS
AT&T / GAS Intel), CPU architecture, bitness, entry point, libc use and the
C preprocessor are detected automatically. Only the tools that file needs
are installed.

Options (put them BEFORE the file name; everything after it goes to your program):
  -v, --verbose         show detection details and extra information
  -y, --yes             install missing tools without prompting
  -o, --output FILE     keep the output at FILE
      --asm-only        assemble only; write the object file and stop
      --link-only       assemble+link, but do not run (alias: --no-run)
      --keep-build-dir  keep the temporary build directory (alias: --keep)
      --dry-run         show the build commands only; run nothing, install nothing
      --nasm            force NASM syntax
      --gas, --as       force GNU as syntax
      --32 | --64       force 32-bit / 64-bit (x86 only)
      --arch ARCH       force source arch: x86 | arm64 | arm32 | riscv | ppc | s390x | mips | loong
      --target TARGET   cross-build for: x86_64 | i386 | aarch64 | armv7 | riscv64
                        | ppc64le | s390x | mips64el | loongarch64
      --cc CMD          use CMD as the C compiler/linker driver
      --march VALUE     pass -march=VALUE to the assembler / C driver
      --as-flags STR    extra flags for as            (split on spaces)
      --ld-flags STR    extra flags for ld
      --cc-flags STR    extra flags for the C driver
      --nasm-flags STR  extra flags for nasm
      --qemu-flags STR  extra flags for qemu-user (e.g. "-cpu max")
  -g, --debug           add debug info (nasm -g -F dwarf, as/cc -g)
      --timeout SECS    stop the program after SECS seconds (needs timeout/gtimeout)
      --report FILE     write a JSON build/run report to FILE (also on failure)
      --detect          print what was detected and stop (nothing is built)
      --doctor          check this machine: tools, targets, what is missing
      --list-targets    list supported targets and their toolchain names
      --selftest        run the built-in self test and exit
      --no-color        disable colours
      --version         print the version and exit
  -h, --help            this help

Examples:
  asmrun hello.s
  asmrun --32 boot.s
  asmrun --nasm -o hello hello.asm
  asmrun --asm-only -o hello.o hello.s
  asmrun --dry-run --target riscv64 hello.s
  asmrun --target aarch64 --qemu-flags "-cpu max" sve.s
  asmrun --timeout 5 loop.s

Exit status: the program's own status when it ran; 1 asmrun/build error;
2 usage error; 124 --timeout expired; 128+N program killed by signal N.

Environment:
  NO_COLOR=1          disable colours
  ASMRUN_NO_RC=1      do not read config files
  ASMRUN_FLAGS=...    extra options, parsed before the command line
  ASMRUN_CC=...       default C compiler/linker driver
Config files (options as on the command line, one or more per line, # comments):
  ~/.asmrunrc, ~/.config/asmrun/config   all options
  ./.asmrunrc                            safe options only (no -o/--cc/--report/...)
EOF
}

# ==============================================================================
#  2. Target registry - ONE place per architecture
# ==============================================================================
#  A *target id* is the user-facing name (--target aarch64).  A *family* is what
#  source detection votes on (arm64).  To add an architecture, extend every
#  tgt_* / fam_* function below, add a detection signature in detect_arch(), add
#  the host mapping in detect_host() and a sample to the selftest.  Nothing else
#  in the script has per-architecture knowledge.  (asmrun-v6.md, "Extending".)
# ==============================================================================
ALL_TARGETS="x86_64 i386 aarch64 armv7 riscv64 ppc64le s390x mips64el loongarch64"
ALL_FAMILIES="x86 arm64 arm32 riscv ppc s390x mips loong"

# Normalise any user spelling to a target id (empty = unknown).
tgt_norm() {
    case "$1" in
        x86_64|amd64|x86-64|x64)              echo x86_64 ;;
        i386|i486|i586|i686|x86|ia32)         echo i386 ;;
        aarch64|arm64|armv8|armv8-a)          echo aarch64 ;;
        armv7|armv7l|armv7-a|arm|arm32|armhf) echo armv7 ;;
        riscv64|riscv|rv64|riscv64gc)         echo riscv64 ;;
        ppc64le|powerpc64le|ppc64el|ppc)      echo ppc64le ;;
        s390x)                                echo s390x ;;
        mips64el|mips64|mips)                 echo mips64el ;;
        loongarch64|loongarch|loong64|la64)   echo loongarch64 ;;
        *)                                    echo "" ;;
    esac
}
fam_norm() {
    case "$1" in
        x86|x86_64|x86-64|amd64|i386|i486|i586|i686) echo x86 ;;
        arm64|aarch64)                echo arm64 ;;
        arm|arm32|armv7|armhf)        echo arm32 ;;
        riscv|riscv64)                echo riscv ;;
        ppc|ppc64|ppc64le|powerpc)    echo ppc ;;
        s390x)                        echo s390x ;;
        mips|mips64|mips64el)         echo mips ;;
        loong|loongarch|loongarch64)  echo loong ;;
        *)                            echo "" ;;
    esac
}
tgt_family() {
    case "$1" in
        x86_64|i386) echo x86 ;;   aarch64) echo arm64 ;;  armv7) echo arm32 ;;
        riscv64)     echo riscv ;; ppc64le) echo ppc ;;    s390x) echo s390x ;;
        mips64el)    echo mips ;;  loongarch64) echo loong ;;
    esac
}
tgt_bits() { case "$1" in i386|armv7) echo 32 ;; *) echo 64 ;; esac; }
fam_tgt() {    # family + bits -> target id (empty if unsupported)
    case "$1:$2" in
        x86:64) echo x86_64 ;;  x86:32) echo i386 ;;   arm64:64) echo aarch64 ;;
        arm32:32) echo armv7 ;; riscv:64) echo riscv64 ;; ppc:64) echo ppc64le ;;
        s390x:64) echo s390x ;; mips:64) echo mips64el ;; loong:64) echo loongarch64 ;;
        *) echo "" ;;
    esac
}
fam_bits() { case "$1" in arm32) echo 32 ;; *) echo 64 ;; esac; }   # fixed width families
arch_label() {
    case "$1" in
        x86)   echo "x86 / x86-64" ;;      arm64) echo "ARM64 (AArch64)" ;;
        arm32) echo "32-bit ARM" ;;        riscv) echo "RISC-V" ;;
        ppc)   echo "PowerPC64 LE" ;;      s390x) echo "IBM Z (s390x)" ;;
        mips)  echo "MIPS64 LE" ;;         loong) echo "LoongArch" ;;
        *)     echo "$1" ;;
    esac
}
tgt_label() {
    case "$1" in
        x86_64) echo "x86-64" ;;            i386) echo "i386 (32-bit x86)" ;;
        aarch64) echo "AArch64 (ARM64)" ;;  armv7) echo "ARMv7 (ARM32 / Thumb-2)" ;;
        riscv64) echo "RISC-V 64" ;;        ppc64le) echo "PowerPC64 little-endian" ;;
        s390x) echo "IBM Z (s390x)" ;;      mips64el) echo "MIPS64 little-endian (n64)" ;;
        loongarch64) echo "LoongArch64" ;;  *) echo "$1" ;;
    esac
}
# supported = commands + detection tested and used; experimental = detection and
# command construction tested, never executed on real hardware by the author.
tgt_status() {
    case "$1" in
        x86_64|i386|aarch64|armv7|riscv64) echo supported ;;
        *) echo experimental ;;
    esac
}
# Cross toolchain triplet prefixes, best first.  Bare-metal *-elf toolchains are
# last: they are fine for static, libc-free programs that use Linux syscalls.
tgt_prefixes() {
    case "$1" in
        x86_64)  echo "x86_64-linux-gnu x86_64-unknown-linux-gnu x86_64-pc-linux-gnu x86_64-linux-musl x86_64-elf" ;;
        i386)    echo "i686-linux-gnu i386-linux-gnu i586-linux-gnu i686-pc-linux-gnu i686-elf" ;;
        aarch64) echo "aarch64-linux-gnu aarch64-unknown-linux-gnu aarch64-none-linux-gnu aarch64-linux-musl aarch64-none-elf aarch64-elf" ;;
        armv7)   echo "arm-linux-gnueabihf arm-linux-gnueabi arm-linux-gnu arm-unknown-linux-gnueabihf arm-none-linux-gnueabihf arm-none-eabi" ;;
        riscv64) echo "riscv64-linux-gnu riscv64-unknown-linux-gnu riscv64-unknown-elf riscv64-elf" ;;
        ppc64le) echo "powerpc64le-linux-gnu powerpc64le-unknown-linux-gnu ppc64le-linux-gnu" ;;
        s390x)   echo "s390x-linux-gnu s390x-unknown-linux-gnu" ;;
        mips64el) echo "mips64el-linux-gnuabi64 mips64el-linux-gnu mips64el-unknown-linux-gnu" ;;
        loongarch64) echo "loongarch64-linux-gnu loongarch64-unknown-linux-gnu" ;;
    esac
}
# qemu-user binary (we also try "<name>-static", used by qemu-user-static).
tgt_qemu() {
    case "$1" in
        x86_64) echo qemu-x86_64 ;;   i386) echo qemu-i386 ;;    aarch64) echo qemu-aarch64 ;;
        armv7) echo qemu-arm ;;       riscv64) echo qemu-riscv64 ;; ppc64le) echo qemu-ppc64le ;;
        s390x) echo qemu-s390x ;;     mips64el) echo qemu-mips64el ;; loongarch64) echo qemu-loongarch64 ;;
    esac
}
# qemu-user ELF binfmt_misc handler names to look for in /proc/sys/fs/binfmt_misc
tgt_binfmt() {
    case "$1" in
        x86_64) echo "qemu-x86_64" ;; i386) echo "qemu-i386" ;; aarch64) echo "qemu-aarch64" ;;
        armv7) echo "qemu-arm" ;; riscv64) echo "qemu-riscv64" ;; ppc64le) echo "qemu-ppc64le" ;;
        s390x) echo "qemu-s390x" ;; mips64el) echo "qemu-mips64el" ;; loongarch64) echo "qemu-loongarch64" ;;
    esac
}
# Does `file -b` output look like it matches target $1?  (return 0 = matches)
tgt_file_ok() {
    case "$1:$2" in
        x86_64:*"x86-64"*|x86_64:*"x86_64"*)          return 0 ;;
        i386:*"Intel 80386"*|i386:*"i386"*)           return 0 ;;
        aarch64:*"aarch64"*|aarch64:*"arm64"*)        return 0 ;;
        armv7:*"ARM, "*)                              return 0 ;;
        riscv64:*"RISC-V"*)                           return 0 ;;
        ppc64le:*"PowerPC"*)                          return 0 ;;
        s390x:*"S/390"*)                              return 0 ;;
        mips64el:*"MIPS"*)                            return 0 ;;
        loongarch64:*"LoongArch"*)                    return 0 ;;
    esac
    return 1
}
# GNU ld on MIPS defaults to the entry symbol __start, not _start.
tgt_default_entry_is_start() { case "$1" in mips64el) return 1 ;; *) return 0 ;; esac; }

# ---- distro package names for cross toolchains (best effort; always verified) --
deb_tri() {
    case "$1" in
        x86_64) echo x86-64-linux-gnu ;;  i386) echo i686-linux-gnu ;;
        aarch64) echo aarch64-linux-gnu ;; armv7) echo arm-linux-gnueabihf ;;
        riscv64) echo riscv64-linux-gnu ;; ppc64le) echo powerpc64le-linux-gnu ;;
        s390x) echo s390x-linux-gnu ;;     mips64el) echo mips64el-linux-gnuabi64 ;;
        loongarch64) echo loongarch64-linux-gnu ;;
    esac
}
deb_arch() {
    case "$1" in
        x86_64) echo amd64 ;; i386) echo i386 ;; aarch64) echo arm64 ;; armv7) echo armhf ;;
        riscv64) echo riscv64 ;; ppc64le) echo ppc64el ;; s390x) echo s390x ;;
        mips64el) echo mips64el ;; loongarch64) echo loong64 ;;
    esac
}
fed_tri() {
    case "$1" in
        x86_64) echo x86_64-linux-gnu ;; aarch64) echo aarch64-linux-gnu ;;
        armv7) echo arm-linux-gnu ;;     riscv64) echo riscv64-linux-gnu ;;
        ppc64le) echo powerpc64le-linux-gnu ;; s390x) echo s390x-linux-gnu ;;
        *) echo "" ;;
    esac
}
# cross_pkg KIND TARGET  (KIND: binutils | gcc | libc | qemu) - prints package
# names for the current $PM, or nothing when we do not know a package.
cross_pkg() {
    _cp_k=$1; _cp_t=$2
    case "${PM:-}" in
        apt)
            case "$_cp_k" in
                binutils) echo "binutils-$(deb_tri "$_cp_t")" ;;
                gcc)      echo "gcc-$(deb_tri "$_cp_t")" ;;
                libc)     echo "libc6-dev-$(deb_arch "$_cp_t")-cross" ;;
                qemu)     echo qemu-user ;;
            esac ;;
        dnf|yum|microdnf)
            _cp_f=$(fed_tri "$_cp_t")
            case "$_cp_k" in
                binutils) [ -n "$_cp_f" ] && echo "binutils-$_cp_f" ;;
                gcc)      [ -n "$_cp_f" ] && echo "gcc-$_cp_f" ;;
                qemu)     echo qemu-user ;;
            esac ;;
        pacman)
            case "$_cp_t" in
                aarch64|riscv64)
                    case "$_cp_k" in
                        binutils) echo "$(tgt_prefixes "$_cp_t" | cut -d' ' -f1)-binutils" ;;
                        gcc)      echo "$(tgt_prefixes "$_cp_t" | cut -d' ' -f1)-gcc" ;;
                        libc)     echo "$(tgt_prefixes "$_cp_t" | cut -d' ' -f1)-glibc" ;;
                        qemu)     echo qemu-user ;;
                    esac ;;
                *) [ "$_cp_k" = qemu ] && echo qemu-user ;;
            esac ;;
        zypper) [ "$_cp_k" = qemu ] && echo qemu-linux-user ;;
        apk)    [ "$_cp_k" = qemu ] && echo "$(tgt_qemu "$_cp_t")" ;;
        xbps)   [ "$_cp_k" = qemu ] && echo qemu-user-static ;;
    esac
    return 0
}

# ==============================================================================
#  3. Host detection
# ==============================================================================
sysctl_arm64() {
    if [ -x /usr/sbin/sysctl ]; then /usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null
    else sysctl -n hw.optional.arm64 2>/dev/null; fi
}

# Sets OS, HOST (family), HOST_BITS, WSL, CONTAINER.  Pure detection, no output.
detect_host() {
    case "$(uname -s 2>/dev/null)" in
        Linux)  OS=linux ;;
        Darwin) OS=macos ;;
        MINGW*|MSYS*|CYGWIN*)
            die "Native Windows shells are not supported. Install WSL2 (wsl --install) and run asmrun inside it." ;;
        *)  die "Unsupported OS '$(uname -s 2>/dev/null)'. asmrun supports Linux and macOS." ;;
    esac

    _dh_m=$(uname -m 2>/dev/null)
    case "$_dh_m" in
        x86_64|amd64)               HOST=x86;   HOST_BITS=64 ;;
        i?86|x86)                   HOST=x86;   HOST_BITS=32 ;;
        aarch64|arm64|aarch64_be)   HOST=arm64; HOST_BITS=64 ;;
        arm*)                       HOST=arm32; HOST_BITS=32 ;;
        riscv64)                    HOST=riscv; HOST_BITS=64 ;;
        ppc64le|ppc64|powerpc64*)   HOST=ppc;   HOST_BITS=64 ;;
        s390x)                      HOST=s390x; HOST_BITS=64 ;;
        mips64*)                    HOST=mips;  HOST_BITS=64 ;;
        loongarch64)                HOST=loong; HOST_BITS=64 ;;
        *)                          HOST=$_dh_m; HOST_BITS=64 ;;
    esac

    if [ "$OS" = macos ]; then
        # A terminal running under Rosetta reports x86_64 on an Apple Silicon Mac.
        if [ "$(sysctl_arm64 || echo 0)" = 1 ]; then HOST=arm64; HOST_BITS=64; fi
    else
        # 32-bit userland on a 64-bit kernel (e.g. 32-bit Raspberry Pi OS on a Pi 5,
        # 32-bit containers): the toolchain is what counts, not uname -m.
        _dh_lb=$(getconf LONG_BIT 2>/dev/null)
        if [ "$_dh_lb" = 32 ] && [ "$HOST_BITS" -eq 64 ]; then
            case "$HOST" in
                x86)   HOST_BITS=32 ;;
                arm64) HOST=arm32; HOST_BITS=32 ;;
            esac
        fi
    fi

    WSL=0
    if [ "$OS" = linux ]; then
        if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
            WSL=1
        fi
    fi
    CONTAINER=0
    if [ -f /.dockerenv ] || [ -e /run/.containerenv ]; then CONTAINER=1; fi
    return 0
}

# Can the host run target $1 natively?  (sets nothing; used by plan + doctor)
host_runs_natively() {
    _hr_f=$(tgt_family "$1"); _hr_b=$(tgt_bits "$1")
    if [ "$_hr_f" = "$HOST" ]; then
        if [ "$_hr_f" = x86 ] && [ "$_hr_b" -gt "$HOST_BITS" ]; then return 1; fi
        return 0
    fi
    # Rosetta 2: Apple Silicon runs x86-64 (not i386)
    if [ "$OS" = macos ] && [ "$HOST" = arm64 ] && [ "$1" = x86_64 ]; then return 0; fi
    return 1
}

# ==============================================================================
#  4. Source analysis  (comment/string-aware, weighted, overridable)
# ==============================================================================
# has/cnt look at the *sanitised* copy ($ANA): comments removed, string contents
# blanked.  Without this, "; compare with rax/eax" in an ARM file votes for x86.
has()    { LC_ALL=C grep -Eiq -- "$1" "${ANA:-$FILE}" 2>/dev/null; }
cnt()    { _cnt_n=$(LC_ALL=C grep -Eic -- "$1" "${ANA:-$FILE}" 2>/dev/null); printf '%s' "${_cnt_n:-0}"; }
hasraw() { LC_ALL=C grep -Eiq -- "$1" "$FILE" 2>/dev/null; }

# sanitize_source MODE IN OUT  -  MODE: generic | x86 | arm64 | arm32 | riscv | ...
# Portable awk (no intervals, no gensub): runs on mawk, gawk, BSD/macOS awk, BusyBox.
sanitize_source() {
    awk -v mode="$1" '
    function isdirective(s) {
        return (s ~ /^[ \t]*#(include|define|undef|ifdef|ifndef|if|elif|else|endif|pragma|error|warning|line)([ \t(<"]|$)/)
    }
    BEGIN {
        sq = "\047"; semi = 0; hash = 0; at = 0; sl2 = 0; inblk = 0
        if (mode == "x86")          { semi = 1; hash = 1 }
        else if (mode == "arm64")   { semi = 1; hash = 2; sl2 = 1 }
        else if (mode == "arm32")   { at = 1;   hash = 2; sl2 = 1 }
        else if (mode == "generic") { semi = 2; hash = 3; at = 2; sl2 = 1 }
        else                        { hash = 1 }
    }
    {
        line = $0
        gsub(/\r/, "", line)
        if (NR == 1 && substr(line, 1, 3) == "\357\273\277") line = substr(line, 4)
        if (!inblk && isdirective(line)) { print line; next }
        out = ""; n = length(line); i = 1
        while (i <= n) {
            if (inblk) {
                j = index(substr(line, i), "*/")
                if (j == 0) { i = n + 1; break }
                i = i + j + 1; inblk = 0; out = out " "; continue
            }
            c = substr(line, i, 1); c2 = substr(line, i, 2)
            p = (i == 1) ? " " : substr(line, i - 1, 1)
            ws = (p == " " || p == "\t")
            nx = substr(line, i + 1, 1)
            wsnx = (nx == "" || nx == " " || nx == "\t")
            if (c2 == "/*") { inblk = 1; i += 2; continue }
            if (sl2 && c2 == "//") break
            if (c == ";" && semi && (semi == 1 || ws)) break
            if (c == "@" && at && (at == 1 || (ws && wsnx))) break
            if (c == "#" && hash) {
                if (hash == 1) break
                if (out ~ /^[ \t]*$/) break
                if (hash == 3 && ws && wsnx) break
            }
            if (c == "\"" || c == "`") {
                j = i + 1
                while (j <= n) {
                    d = substr(line, j, 1)
                    if (d == "\\" && c == "\"") { j += 2; continue }
                    if (d == c) break
                    j++
                }
                out = out c c
                i = (j <= n) ? j + 1 : n + 1
                continue
            }
            if (c == sq) {
                j = index(substr(line, i + 1), sq)
                if (j > 0) { out = out sq sq; i = i + j + 1; continue }
            }
            out = out c; i++
        }
        print out
    }' "$2" >"$3" 2>/dev/null
}

# Binary file (NUL bytes)?  Assembly source never contains them.
looks_binary() {
    _lb_a=$(( $(LC_ALL=C tr -d '\000' <"$1" | wc -c) + 0 ))
    _lb_b=$(( $(wc -c <"$1") + 0 ))
    [ "$_lb_a" -ne "$_lb_b" ]
}

# --- weighted architecture vote ----------------------------------------------
detect_arch() {
    _da_x=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|bp|sp|ip)|e(ax|bx|cx|dx|si|di|bp|sp|ip)|r(8|9|1[0-5])[dwb]|[xyz]mm[0-9]+)([^[:alnum:]_]|$)|(^|[[:space:]])syscall[[:space:]]*$|(^|[[:space:]])sysenter([[:space:]]|$)|(^|[[:space:]])int[[:space:]]+[$]?(0x80|80h|0x2e|2eh)([^[:alnum:]_]|$)|[.]intel_syntax|[.]att_syntax|[.]code(16|32|64)([[:space:]]|$)|(^|[[:space:]])bits[[:space:]]+(16|32|64)|(^|[[:space:]])(pushad|popad|pushfd|popfd|pushfq|popfq)([[:space:]]|$)|^[[:space:]]*(global|extern|section|segment)[[:space:]]|(^|[[:space:]]|:)(db|dw|dd|dq|resb|resw|resd|resq|equ|times)[[:space:]]|^[[:space:]]*%[[:space:]]*(define|macro|include|ifdef|ifndef|if|else|endif|assign|rep|xdefine)([[:space:]]|$)|(^|[[:space:]])(lea|movzx|movsx|movsxd|cpuid|rdtsc|cqo|cdq|cltq|cltd|cwde|leaveq?|movabs[qlwb]?)([[:space:]]|$)')
    _da_a=$(cnt '(^|[^[:alnum:]_.])([xw]([0-9]|[12][0-9]|30)|xzr|wzr)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])(stp|ldp|adrp|adr|cbz|cbnz|tbz|tbnz|csel|cset|hvc|smc|eret|mrs|msr|ldur|stur|ldrsw|movk|movz|movn|ubfx|sbfx|ccmp|cinc|csinc|madd|msub|umulh|smulh)[[:space:]]|(^|[[:space:]])svc[[:space:]]+#|(^|[[:space:]])(blr|br)[[:space:]]+x[0-9]+|[.]arch[[:space:]]+armv8|aarch64|(^|[[:space:]])[.]xword[[:space:]]|[.]arch_extension|(^|[^[:alnum:]_])v([0-9]|[12][0-9]|3[01])[.][0-9]*[bhsd]([^[:alnum:]_]|$)|(^|[^[:alnum:]_])z([0-9]|[12][0-9]|3[01])[.][bhsdq]|@(page|pageoff|gotpage|gotpageoff)([^[:alnum:]_]|$)')
    _da_b=$(cnt '(^|[[:space:]])(push|pop|stmfd|ldmfd|stmdb|ldmia|stmia|ldmdb|stm|ldm)[[:space:]]*[{]|[.]syntax[[:space:]]+unified|(^|[[:space:]])(bx|blx)[[:space:]]+(lr|r[0-9]+)|[.](thumb|thumb_func|arm|fpu|eabi_attribute|thumb_set|code[[:space:]]+(16|32))([[:space:]]|$)|[.]cpu[[:space:]]+(cortex-[amr][0-9]+|arm[0-9a-z]+|xscale)|(^|[[:space:]])swi[[:space:]]|(^|[[:space:]])(mov|movs|movw|movt|mvn|orr|eor|bic|cmp|cmn|tst|teq|rsb|rsc|ldr|str|ldrb|strb|ldrh|strh|ldrsb|ldrsh|lsl|lsr|asr|ror|mul|mla|adds|subs|add|sub|and)[a-z]?[a-z]?[[:space:]]+(r([0-9]|1[0-2])|lr|pc)[[:space:]]*,|(^|[^[:alnum:]_])r([0-9]|1[0-2])[[:space:]]*,[[:space:]]*#|[[]r([0-9]|1[0-2])[],]|[{][[:space:]]*r[0-9]|(^|[[:space:]])(ite|itt|itee|ittt)[[:space:]]+[a-z][a-z]|(^|[[:space:]])cbn?z[[:space:]]+r[0-7]')
    _da_r=$(cnt '(^|[^[:alnum:]_.])(ecall|ebreak)([^[:alnum:]_]|$)|(^|[[:space:]])(li|la|lla|mv|not|neg|seqz|snez|sltz|sgtz|addi|add|sub|and|or|xor|slli|srli|srai|slti|sltiu|slt|sltu|lui|auipc|jal|jalr|beq|bne|blt|bge|bltu|bgeu|beqz|bnez|blez|bgez|bltz|bgtz|lw|sw|ld|sd|lh|sh|lb|sb|lbu|lhu|lwu|csrr?[a-z]*)[[:space:]]+(a[0-7]|t[0-6]|s([0-9]|1[01])|ra|zero|gp|tp)[[:space:]]*,|(^|[[:space:]])(addi|ld|sd|lw|sw|lwu|lb|sb|lh|sh|fld|fsd)[[:space:]]+(sp|fp)[[:space:]]*,|[.]option[[:space:]]+(rvc|norvc|push|pop|arch|relax|norelax)|(^|[[:space:]])c[.](addi|mv|li|add|sub|lw|sw|ld|sd|j|jal|beqz|bnez|nop)([[:space:]]|$)|[.]attribute[[:space:]]+(arch|stack_align|unaligned_access)|(^|[[:space:]])vset(i?)vli[[:space:]]')
    _da_p=$(cnt '(^|[[:space:]])(mflr|mtlr|mtctr|mfctr|bctr|bctrl|bdnz|bdz|lwz|lwzu|stwu|stdu|lwzx|stwx|ldx|stdx|addis|addic|cmpwi|cmpdi|cmplwi|cmpldi|rlwinm|rldicl|rldicr|rlwimi|extsw|extsb|extsh|srawi|sradi|slwi|srwi|lis|mfcr|mtcr|mfspr|mtspr|stbu|lbzu|ldu|lhz|lbz)[[:space:]]|(^|[[:space:]])blr[[:space:]]*$|(^|[[:space:]])sc[[:space:]]*$|(^|[[:space:]])(li|addi|ori|oris|ld|std|stw|mr|cmpw|cmpd|mulld|divd|subf|neg)[[:space:]]+%?r?([0-9]|[12][0-9]|3[01])[[:space:]]*,|[.](localentry|abiversion)|[.]machine[[:space:]]+(power|ppc|pwr)|@(ha|toc)([^[:alnum:]_]|$)|@l([^[:alnum:]_]|$)|[.]TOC[.]|(^|[^[:alnum:]_])%?r(1[6-9]|2[0-9]|3[01])[[:space:]]*(,|$|[)])')
    _da_s=$(cnt '(^|[[:space:]])(lghi|lgr|stmg|lmg|larl|brasl|basr|bras|aghi|lgfr|llgc|llgf|cgr|cghi|cgfi|ltgr|lgf|stg|lg|lhi|stam|lam|clgr|clg|sllg|srlg|slag|srag|agr|sgr|msgr|dsgr|lcgr|lngr|lpgr|ngr|ogr|xgr)[[:space:]]+%?r?[0-9]|(^|[[:space:]])br[[:space:]]+%r14|[.]machine[[:space:]]+(z[0-9]+|zarch)|(^|[^[:alnum:]_])%r[0-7]([^[:alnum:]_]|$)')
    _da_m=$(cnt '^[[:space:]]*([A-Za-z_.$][A-Za-z0-9_.$]*:[[:space:]]*)?[a-z][a-z0-9]*[[:space:]]+[^;]*[$](zero|at|v[01]|a[0-7]|t[0-9]|s[0-8]|k[01]|gp|sp|fp|ra|f[0-9]+)([^[:alnum:]_]|$)|[.]set[[:space:]]+(noreorder|reorder|noat|at|mips[0-9]+|nomacro|macro)|[.](ent|frame|mask|fmask|cpload|cprestore|cpsetup|cplocal)([[:space:]]|$)|(^|[[:space:]])(addiu|daddiu|daddu|dsubu|subu|dsll|dsll32|dsra|dsrl|mfhi|mflo|mthi|mtlo|multu?|dmultu?|bgezal|bltzal|dla|dli)([[:space:]]|$)|(^|[[:space:]])jr[[:space:]]+[$]ra')
    _da_l=$(cnt '(^|[[:space:]])[a-z][a-z0-9]*[.][a-z0-9.]+[[:space:]]+[$]|(^|[[:space:]])(jirl|pcalau12i|pcaddu12i|pcaddi|bstrpick|bstrins)[[:space:]]|(^|[[:space:]])la[.](local|global|pcrel|abs|got)|(^|[[:space:]])syscall[[:space:]]+(0x)?[0-9]+|[$]r([0-9]|[12][0-9]|3[01])([^[:alnum:]_]|$)')

    _da_hostbest=0
    SRC=$HOST
    _da_best=0
    _da_second=0
    for _da_pair in "x86:$_da_x" "arm64:$_da_a" "arm32:$_da_b" "riscv:$_da_r" "ppc:$_da_p" "s390x:$_da_s" "mips:$_da_m" "loong:$_da_l"; do
        _da_fam=${_da_pair%%:*}
        _da_num=${_da_pair##*:}
        if [ "$_da_num" -gt "$_da_best" ]; then
            _da_second=$_da_best
            SRC=$_da_fam
            _da_best=$_da_num
        elif [ "$_da_num" -eq "$_da_best" ] && [ "$_da_num" -gt 0 ] && [ "$_da_fam" = "$HOST" ]; then
            SRC=$_da_fam
            _da_second=$_da_num
        elif [ "$_da_num" -gt "$_da_second" ]; then
            _da_second=$_da_num
        fi
    done
    ARCH_VOTES="x86=$_da_x arm64=$_da_a arm32=$_da_b riscv=$_da_r ppc=$_da_p s390x=$_da_s mips=$_da_m loong=$_da_l"
    info "arch votes: $ARCH_VOTES -> $SRC"
    # Ambiguity warning: a close runner-up means the guess deserves a second look.
    if [ "$_da_best" -gt 0 ] && [ $((_da_second * 10)) -ge $((_da_best * 7)) ] && [ "$_da_second" -gt 0 ]; then
        ARCH_AMBIGUOUS=1
    else
        ARCH_AMBIGUOUS=0
    fi
}
ARCH_AMBIGUOUS=0

# --- x86 only: NASM (Intel) vs GNU as (AT&T / .intel_syntax) -----------------
SYNTAX_FIRM=0; BITS_FIRM=0     # 1 = decided by an explicit directive/extension, never auto-flipped
detect_syntax() {
    SYNTAX_FIRM=1
    case "$FILE" in *.S) SYNTAX=gas; SYNTAX_VOTES="by-extension(.S)"; return 0 ;; esac
    case "$FILE" in *.nasm) SYNTAX=nasm; SYNTAX_VOTES="by-extension(.nasm)"; return 0 ;; esac
    if has '[.]intel_syntax|[.]att_syntax'; then SYNTAX=gas; SYNTAX_VOTES="directive(.intel_syntax)"; return 0; fi
    if has '^#(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)([[:space:]<"(]|$)'; then
        SYNTAX=gas; SYNTAX_VOTES="directive(cpp)"; return 0
    fi
    SYNTAX_FIRM=0
    _ds_nasm=$(cnt '^[[:space:]]*(section|segment)[[:space:]]+[.]|^[[:space:]]*(global|extern)[[:space:]]+[A-Za-z_.$]|(^|[[:space:]]|:)(db|dw|dd|dq|dt|resb|resw|resd|resq|equ|times)[[:space:]]|^[[:space:]]*%[[:space:]]*(define|macro|endmacro|include|assign|if|ifdef|ifndef|else|endif|rep|endrep|xdefine|undef|imacro|strlen|ifidn|ifnum)|(^|[[:space:]])bits[[:space:]]+(16|32|64)|^[[:space:]]*default[[:space:]]+rel|(byte|word|dword|qword)[[:space:]]+[[]')
    _ds_gas=$(cnt '^[[:space:]]*[.](globl|global|section|text|data|bss|ascii|asciz|string|quad|long|byte|word|short|int|skip|space|zero|equ|set|align|balign|p2align|type|size|macro|endm|code32|code64|file|ident|rodata|comm|lcomm|fill|rept|endr)([[:space:]]|$)|%[re]?(ax|bx|cx|dx|si|di|bp|sp)([^[:alnum:]_]|$)|%r(8|9|1[0-5])[dwb]?([^[:alnum:]_]|$)|%[abcd][lh]([^[:alnum:]_]|$)|%[xy]?mm[0-9]+|(^|[[:space:]])(mov|add|sub|push|pop|lea|cmp|xor|and|or|test|inc|dec|imul|idiv|shl|shr|call|ret|jmp)[bwlq][[:space:]]|[$][-]?(0x[0-9a-f]+|[0-9]+)')
    SYNTAX_VOTES="nasm=$_ds_nasm gas=$_ds_gas"
    if [ "$_ds_gas" -gt "$_ds_nasm" ]; then
        SYNTAX=gas
    elif [ "$_ds_nasm" -gt "$_ds_gas" ]; then
        SYNTAX=nasm
    else
        case "$FILE" in
            *.s|*.sx) SYNTAX=gas ;;
            *)        SYNTAX=nasm ;;
        esac
    fi
    info "syntax votes: $SYNTAX_VOTES -> $SYNTAX"
}

# --- x86 only: weighted bitness. Explicit directives win outright. -----------
detect_bits() {
    BITS_FIRM=1
    if has '(^|[^[:alnum:]_])bits[[:space:]]+32|[.]code32'; then BITS=32; BITS_VOTES="directive(32)"; return 0; fi
    if has '(^|[^[:alnum:]_])bits[[:space:]]+64|[.]code64'; then BITS=64; BITS_VOTES="directive(64)"; return 0; fi
    BITS_FIRM=0

    _db_b32=0
    _db_b64=0
    has '(^|[[:space:]])int[[:space:]]+[$]?(0x80|80h|0x2e|2eh)([^[:alnum:]_]|$)' && _db_b32=$((_db_b32 + 5))
    has '(^|[[:space:]])syscall[[:space:]]*$'                                    && _db_b64=$((_db_b64 + 5))
    has '(^|[^[:alnum:]_])sysenter([^[:alnum:]_]|$)'                              && _db_b32=$((_db_b32 + 3))
    has '(^|[^[:alnum:]_])(pushad|popad|pushfd|popfd)([^[:alnum:]_]|$)'           && _db_b32=$((_db_b32 + 2))
    has '(^|[^[:alnum:]_])(pushfq|popfq|cqo|cltq|movabs[qlwb]?)([^[:alnum:]_]|$)' && _db_b64=$((_db_b64 + 2))

    # eax/ebx/ecx/edx/esi/edi are valid (and very common) in 64-bit code, so they are
    # NOT evidence of 32-bit.  Only esp/ebp/eip and 32-bit *addressing* are.
    _db_r32=$(cnt '(^|[^[:alnum:]_])e(sp|bp|ip)([^[:alnum:]_]|$)|[[]e(ax|bx|cx|dx|si|di|bp|sp)|[(]%e(ax|bx|cx|dx|si|di|bp|sp)')
    _db_r64=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|sp|bp|ip)|r([8-9]|1[0-5])[dwb]?)([^[:alnum:]_]|$)|[(]%rip|[[]rel[[:space:]]|default[[:space:]]+rel|wrt[[:space:]]+[.][.]plt')
    _db_b32=$((_db_b32 + _db_r32))
    _db_b64=$((_db_b64 + _db_r64))
    BITS_VOTES="32=$_db_b32 64=$_db_b64"
    info "bitness signals: 32-bit=$_db_b32 (r32=$_db_r32)  64-bit=$_db_b64 (r64=$_db_r64)"
    if [ "$_db_b64" -gt "$_db_b32" ]; then
        BITS=64
    elif [ "$_db_b32" -gt "$_db_b64" ]; then
        BITS=32
    elif [ "$HOST_BITS" -eq 32 ]; then
        BITS=32
    else
        BITS=64
    fi
}

# --- entry point, libc use, C preprocessor -----------------------------------
LIBC_FUNCS='printf|fprintf|sprintf|snprintf|vprintf|puts|putchar|fputs|fputc|putc|getchar|fgetc|getc|gets|fgets|scanf|sscanf|fscanf|fopen|fclose|fread|fwrite|fflush|fseek|ftell|perror|malloc|calloc|realloc|free|strlen|strnlen|strcmp|strncmp|strcpy|strncpy|strcat|strncat|strchr|strrchr|strstr|memcpy|memmove|memset|memcmp|memchr|atoi|atol|atof|strtol|strtoul|strtod|exit|_exit|abort|atexit|getenv|setenv|time|rand|srand|random|qsort|bsearch|sleep|usleep|nanosleep|clock_gettime|gettimeofday|getpid|getppid|open|close|read|write|lseek|mmap|munmap|isatty|signal|raise|kill|fork|execve|waitpid|pipe|dup|dup2|toupper|tolower|isalpha|isdigit|isspace|sin|cos|sqrt|pow|exp|log|floor|ceil|fabs|pthread_create|pthread_join'

detect_entry_libc_cpp() {
    HAS_START=0; HAS_PSTART=0; HAS_MAIN=0; HAS_UMAIN=0; HAS_ENTRY=0; USES_LIBC=0; CPP=0
    ENTRY_NAME=""
    has '^[[:space:]]*_start[[:space:]]*(:|$)' && HAS_START=1
    has '^[[:space:]]*start[[:space:]]*:'      && HAS_PSTART=1
    has '^[[:space:]]*(global|[.]globl|[.]global)[[:space:]]+_start([[:space:]]|$)' && HAS_START=1
    has '^[[:space:]]*(global|[.]globl|[.]global)[[:space:]]+start([[:space:]]|$)'  && HAS_PSTART=1
    # The C entry point is "main" on Linux and "_main" on macOS.  A "_main" label
    # on Linux is just a function name (v5 wrongly linked libc for it).
    if [ "$OS" = macos ]; then
        has '^[[:space:]]*_main[[:space:]]*(:|$)'                              && HAS_MAIN=1
        has '^[[:space:]]*(global|[.]globl|[.]global)[[:space:]]+_main([[:space:]]|$)' && HAS_MAIN=1
        has '^[[:space:]]*main[[:space:]]*:' && [ "$HAS_MAIN" -eq 0 ] && HAS_UMAIN=1
    else
        has '^[[:space:]]*main[[:space:]]*(:|$)'                               && HAS_MAIN=1
        has '^[[:space:]]*(global|[.]globl|[.]global)[[:space:]]+main([[:space:]]|$)' && HAS_MAIN=1
        has '^[[:space:]]*_main[[:space:]]*:' && [ "$HAS_MAIN" -eq 0 ] && HAS_UMAIN=1
    fi

    # ENTRY(name) convention (read from the RAW file: it usually lives in a comment)
    ENTRY_NAME=$(LC_ALL=C sed -n 's/.*[Ee][Nn][Tt][Rr][Yy][[:space:]]*([[:space:]]*\([A-Za-z_.][A-Za-z0-9_.]*\).*/\1/p' "$FILE" 2>/dev/null | head -n 1)
    if [ -n "$ENTRY_NAME" ]; then
        case "$ENTRY_NAME" in
            _start)     HAS_START=1 ;;
            start)      HAS_PSTART=1 ;;
            main|_main) HAS_MAIN=1 ;;
            *)          HAS_ENTRY=1 ;;
        esac
    fi

    # libc: known function names, any "extern", or PLT-style references.
    has "^[[:space:]]*[.]?extern[[:space:]]+_?($LIBC_FUNCS)(@PLT)?([[:space:]]|\$)|(call[qwl]?|bl|jmp|jal|b|tail)[[:space:]]+_?($LIBC_FUNCS)(@PLT)?([^[:alnum:]_]|\$)|@plt([^[:alnum:]_]|\$)|wrt[[:space:]]+[.][.]plt|[%]plt\(" && USES_LIBC=1
    has '^[[:space:]]*[.]?extern[[:space:]]+[A-Za-z_]' && USES_LIBC=1

    case "$FILE" in *.S) CPP=1 ;; esac
    if [ "$SYNTAX" = gas ]; then
        has '^#(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error|warning)([[:space:]<"(]|$)' && CPP=1
    fi
    if [ "$CPP" -eq 1 ]; then XLANG=assembler-with-cpp; else XLANG=assembler; fi
}

# --- instruction-set extensions the source uses (hints for SIGILL / old tools)
detect_ext() {
    EXTS=""
    case "$SRC" in
        x86)
            has '(^|[^[:alnum:]_])zmm[0-9]+|[{][[:space:]]*%?k[1-7][[:space:]]*[}]' && EXTS="$EXTS,avx512"
            has '(^|[^[:alnum:]_])ymm[0-9]+' && EXTS="$EXTS,avx"
            has '(^|[^[:alnum:]_])xmm[0-9]+' && EXTS="$EXTS,sse"
            has '(^|[^[:alnum:]_])%?r(1[6-9]|2[0-9]|3[01])[dwb]?([^[:alnum:]_]|$)' && EXTS="$EXTS,apx"
            has '(^|[^[:alnum:]_])tmm[0-7]' && EXTS="$EXTS,amx" ;;
        arm64)
            has '(^|[^[:alnum:]_])z([0-9]|[12][0-9]|3[01])[.][bhsdq]|(^|[[:space:]])(ptrue|whilelt|ld1[bhwd]|st1[bhwd])[[:space:]]' && EXTS="$EXTS,sve"
            has '(^|[[:space:]])(smstart|smstop)|(^|[^[:alnum:]_])za([^[:alnum:]_]|$)' && EXTS="$EXTS,sme"
            has '(^|[^[:alnum:]_])v([0-9]|[12][0-9]|3[01])[.][0-9]*[bhsd]' && EXTS="$EXTS,neon" ;;
        arm32)
            has '(^|[^[:alnum:]_])(q([0-9]|1[0-5])|d([0-9]|[12][0-9]|3[01]))([^[:alnum:]_]|$)|(^|[[:space:]])v(add|sub|mul|ld1|st1|mov)[.]' && EXTS="$EXTS,neon" ;;
        riscv)
            has '(^|[[:space:]])vset(i?)vli[[:space:]]|(^|[[:space:]])v[ls]e[0-9]+[.]v' && EXTS="$EXTS,rvv"
            has '[.](option|attribute)[[:space:]]+arch.*(zb|zk)' && EXTS="$EXTS,bitmanip" ;;
    esac
    EXTS=${EXTS#,}
    return 0
}

# Hints printed on SIGILL, keyed on what the source seems to use.
ext_hint() {
    [ -n "$EXTS" ] || return 0
    say "       ${DIM}This source uses: ${EXTS}. Your CPU (or emulator) may not implement it.${NC}"
    case "$EXTS" in
        *avx512*|*avx*|*apx*|*amx*) say "       ${DIM}Check:  grep -o -w -E 'avx2|avx512[a-z]*|apx[a-z_]*' /proc/cpuinfo | sort -u   (macOS: sysctl machdep.cpu.features)${NC}" ;;
    esac
    case "$EXTS" in
        *sve*|*sme*|*rvv*) [ "$NATIVE" -eq 0 ] && say "       ${DIM}Under qemu-user try:  --qemu-flags \"-cpu max\"${NC}" ;;
    esac
}

# ==============================================================================
#  5. Tools, discovery and installation
# ==============================================================================
ask_yn() {      # ask_yn "question" -> 0 = yes.  Enter = yes.  Never blocks a pipe (I10).
    if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
    if [ -t 0 ] && [ -t 2 ]; then
        printf '%s [Y/n] ' "$1" >&2
        read _ay_a || return 1
        case "$_ay_a" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
    fi
    return 1
}

# ---- discovery ---------------------------------------------------------------
find_cc() {
    CC_BIN=""
    for _fc in "$FORCE_CC" "${ASMRUN_CC:-}" cc gcc clang; do
        [ -n "$_fc" ] || continue
        if command -v "$_fc" >/dev/null 2>&1; then CC_BIN=$_fc; return 0; fi
    done
    return 1
}
find_timeout() {
    TIMEOUT_BIN=""
    for _ft in timeout gtimeout; do
        if command -v "$_ft" >/dev/null 2>&1; then TIMEOUT_BIN=$_ft; return 0; fi
    done
    return 1
}
# cross_prefix_for TARGET TOOL -> prints the first installed prefix that has
# <prefix>-TOOL, else the first candidate (used for messages/installs).
cross_prefix_for() {
    _cf_first=""
    for _cf_p in $(tgt_prefixes "$1"); do
        [ -n "$_cf_first" ] || _cf_first=$_cf_p
        if command -v "$_cf_p-$2" >/dev/null 2>&1; then printf '%s' "$_cf_p"; return 0; fi
    done
    printf '%s' "$_cf_first"
    return 1
}
# find_qemu TARGET -> sets QEMU_BIN (qemu-user, also the *-static flavour)
find_qemu() {
    QEMU_BIN=""
    _fq=$(tgt_qemu "$1")
    [ -n "$_fq" ] || return 1
    for _fq_c in "$_fq" "$_fq-static"; do
        if command -v "$_fq_c" >/dev/null 2>&1; then QEMU_BIN=$_fq_c; return 0; fi
    done
    return 1
}
# binfmt_misc handler registered for the target (foreign binaries then just run)
binfmt_ok() {
    _bf=$(tgt_binfmt "$1")
    [ -n "$_bf" ] || return 1
    for _bf_n in "$_bf" "$_bf-static"; do
        if [ -r "/proc/sys/fs/binfmt_misc/$_bf_n" ] && grep -q '^enabled' "/proc/sys/fs/binfmt_misc/$_bf_n" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}
# find_sysroot PREFIX -> sets SYSROOT (dynamic cross binaries need the target libc)
find_sysroot() {
    SYSROOT=""
    for _fs in "/usr/$1" "/usr/$1/sys-root" "/usr/$1/sysroot" "/usr/local/$1" "/opt/$1/sysroot" "/usr/lib/$1"; do
        if [ -d "$_fs/lib" ] || [ -d "$_fs/lib64" ] || [ -d "$_fs/usr/lib" ]; then SYSROOT=$_fs; return 0; fi
    done
    return 1
}
sysroot_has_loader() {
    [ -n "${1:-}" ] || return 1
    for _sl in "$1"/lib/ld-* "$1"/lib64/ld-* "$1"/usr/lib/ld-* "$1"/lib/*/ld-* "$1"/usr/lib/*/ld-*; do
        [ -e "$_sl" ] && return 0
    done
    return 1
}

# ---- authoritative probes (compile + link + run a trivial program) ----------
probe_dir_ok() { [ -n "$WORK" ] && [ -d "$WORK" ]; }
multilib_ok() {     # can this machine link AND run a 32-bit libc program?
    if find_cc && probe_dir_ok; then
        printf 'int main(void){return 0;}\n' >"$WORK/m32.c" 2>/dev/null || return 1
        _ml_ok=1
        if "$CC_BIN" -m32 -no-pie -o "$WORK/m32" "$WORK/m32.c" >/dev/null 2>&1 \
           || "$CC_BIN" -m32 -o "$WORK/m32" "$WORK/m32.c" >/dev/null 2>&1; then
            "$WORK/m32" >/dev/null 2>&1 && _ml_ok=0
        fi
        rm -f "$WORK/m32" "$WORK/m32.c"
        return $_ml_ok
    fi
    [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ] || [ -e /usr/lib32/ld-linux.so.2 ] \
        || [ -e /lib/i386-linux-gnu/ld-linux.so.2 ] || [ -e /usr/i386-linux-gnu/lib/ld-linux.so.2 ]
}
cross_libc_ok() {   # can the cross C driver link a libc program for $TARGET_ID?
    [ -n "$CROSS" ] && probe_dir_ok && command -v "$CROSS-gcc" >/dev/null 2>&1 || return 1
    printf 'int main(void){return 0;}\n' >"$WORK/xl.c" 2>/dev/null || return 1
    "$CROSS-gcc" -no-pie -o "$WORK/xl" "$WORK/xl.c" >/dev/null 2>&1 || "$CROSS-gcc" -o "$WORK/xl" "$WORK/xl.c" >/dev/null 2>&1
    _xl=$?
    rm -f "$WORK/xl" "$WORK/xl.c"
    return $_xl
}
clt_ok()      { xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; }
rosetta_ok()  { /usr/bin/pgrep -q oahd >/dev/null 2>&1 || [ -f /Library/Apple/usr/share/rosetta/rosetta ]; }

# ---- abstract tool names used in $REQUIRED -------------------------------------
#   nasm as ld cc cpp multilib          (native Linux)
#   xas xld xcc xlibc qemu              (cross; need $CROSS / $TARGET_ID)
#   clt rosetta                         (macOS)
tool_ok() {
    case "$1" in
        nasm)     command -v nasm >/dev/null 2>&1 ;;
        as|ld)    command -v "$1" >/dev/null 2>&1 ;;
        cc)       find_cc ;;
        cpp)      command -v cpp >/dev/null 2>&1 || find_cc ;;
        multilib) multilib_ok ;;
        clt)      clt_ok ;;
        rosetta)  rosetta_ok ;;
        xas)      CROSS=$(cross_prefix_for "$TARGET_ID" as);  command -v "$CROSS-as"  >/dev/null 2>&1 ;;
        xld)      CROSS=$(cross_prefix_for "$TARGET_ID" ld);  command -v "$CROSS-ld"  >/dev/null 2>&1 ;;
        xcc)      CROSS=$(cross_prefix_for "$TARGET_ID" gcc); command -v "$CROSS-gcc" >/dev/null 2>&1 ;;
        xlibc)    CROSS=$(cross_prefix_for "$TARGET_ID" gcc); cross_libc_ok ;;
        qemu)     find_qemu "$TARGET_ID" ;;
        *)        command -v "$1" >/dev/null 2>&1 ;;
    esac
}
tool_label() {
    case "$1" in
        cc)       echo "a C compiler (gcc/clang)" ;;
        cpp)      echo "cpp (C preprocessor)" ;;
        multilib) echo "32-bit libc support (multilib)" ;;
        clt)      echo "Xcode Command Line Tools" ;;
        rosetta)  echo "Rosetta 2" ;;
        xas)      echo "$(cross_prefix_for "$TARGET_ID" as)-as" ;;
        xld)      echo "$(cross_prefix_for "$TARGET_ID" ld)-ld" ;;
        xcc)      echo "$(cross_prefix_for "$TARGET_ID" gcc)-gcc" ;;
        xlibc)    echo "$TARGET_ID C library (cross sysroot)" ;;
        qemu)     echo "$(tgt_qemu "$TARGET_ID") (qemu-user)" ;;
        *)        echo "$1" ;;
    esac
}
# distro package(s) for an abstract tool; empty = no known package (manual)
pkg_of() {
    case "$1" in
        nasm) echo nasm ;;
        file) echo file ;;
        timeout) [ "$PM" = brew ] && echo coreutils ;;
        as|ld) case "$PM" in brew|port|"") : ;; *) echo binutils ;; esac ;;
        cc|cpp)
            case "$PM" in
                apk) echo "gcc musl-dev" ;;
                apt|dnf|microdnf|yum|pacman|zypper|xbps) echo gcc ;;
            esac ;;
        multilib)
            case "$PM" in
                apt)    echo gcc-multilib ;;
                dnf|yum) echo "glibc-devel.i686 libgcc.i686" ;;
                pacman) echo "lib32-glibc lib32-gcc-libs" ;;
                zypper) echo "gcc-32bit glibc-devel-32bit" ;;
            esac ;;
        xas|xld) cross_pkg binutils "$TARGET_ID" ;;
        xcc)     cross_pkg gcc "$TARGET_ID" ;;
        xlibc)   cross_pkg libc "$TARGET_ID" ;;
        qemu)    cross_pkg qemu "$TARGET_ID" ;;
    esac
}
add_req() {
    case " $REQUIRED " in *" $1 "*) return 0 ;; esac
    REQUIRED="$REQUIRED $1"
}

# ---- package manager ----------------------------------------------------------
detect_pm() {
    PM=""; UPD=""; INS=""; SUDO=""; CAN_AUTO=1; WHY=""
    if [ "$OS" = macos ]; then
        for _dp in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
            if [ -x "$_dp/brew" ]; then
                case ":$PATH:" in *":$_dp:"*) : ;; *) PATH="$_dp:$PATH"; export PATH ;; esac
            fi
        done
        if command -v brew >/dev/null 2>&1; then PM=brew; INS="brew install"
        elif command -v port >/dev/null 2>&1; then PM=port; INS="port install"
        else CAN_AUTO=0; WHY="Homebrew is not installed (https://brew.sh)"; fi
    else
        for _dp in apt-get dnf microdnf yum pacman zypper apk xbps-install; do
            if command -v "$_dp" >/dev/null 2>&1; then PM=$_dp; break; fi
        done
        case "$PM" in
            apt-get)      PM=apt; UPD="apt-get update"; INS="apt-get install -y" ;;
            dnf)          INS="dnf install -y" ;;
            microdnf)     INS="microdnf install -y" ;;
            yum)          INS="yum install -y" ;;
            pacman)       INS="pacman -S --needed --noconfirm" ;;
            zypper)       UPD="zypper --non-interactive refresh"; INS="zypper --non-interactive install" ;;
            apk)          UPD="apk update"; INS="apk add" ;;
            xbps-install) PM=xbps; UPD="xbps-install -S"; INS="xbps-install -y" ;;
            *)            CAN_AUTO=0; WHY="no supported package manager found (apt, dnf, yum, pacman, zypper, apk, xbps)" ;;
        esac
    fi
    if [ "$CAN_AUTO" -eq 1 ] && [ "$PM" != brew ]; then
        if [ "$(id -u 2>/dev/null)" = 0 ]; then SUDO=""
        elif command -v sudo >/dev/null 2>&1; then SUDO=sudo
        elif command -v doas >/dev/null 2>&1; then SUDO=doas
        else CAN_AUTO=0; WHY="you are not root and neither sudo nor doas is installed"; fi
    fi
    if [ "$OS" = linux ] && [ -e /run/ostree-booted ] && [ "$CONTAINER" -eq 0 ] && [ -z "${TOOLBOX_PATH:-}" ]; then
        CAN_AUTO=0; WHY="immutable (ostree) system: use a toolbox/distrobox container, or 'rpm-ostree install'"
    fi
    S=""; [ -n "$SUDO" ] && S="$SUDO "
    return 0
}

pm_exec() {     # run a package-manager command (with privileges when needed)
    say "${DIM}\$ ${S}$*${NC}"
    if [ "$PM" = apt ]; then $SUDO env DEBIAN_FRONTEND=noninteractive "$@"; else $SUDO "$@"; fi
}

do_install() {      # install $PKGS (one at a time: a bad name must not abort the rest)
    if [ -n "$UPD" ]; then
        pm_exec $UPD || warn "'$UPD' failed - continuing with the install anyway"
    fi
    for _di_p in $PKGS; do
        # shellcheck disable=SC2086
        pm_exec $INS $_di_p || warn "Installing '$_di_p' failed"
    done
}

# manual instructions when we cannot (or may not) install by ourselves
print_manual() {
    say ""
    say "${BOLD}Install these yourself, then run asmrun again:${NC}"
    for _pm_t in $MISSING; do
        _pm_p=$(pkg_of "$_pm_t")
        if [ -n "$_pm_p" ] && [ -n "$PM" ]; then
            say "  - $(tool_label "$_pm_t")   ->   ${S}$INS $_pm_p"
        else
            say "  - $(tool_label "$_pm_t")"
        fi
    done
    case " $MISSING " in
        *" clt "*)      say "  macOS: run  xcode-select --install   (a dialog appears; wait for it, then re-run)" ;;
    esac
    case " $MISSING " in
        *" rosetta "*)  say "  macOS: run  sudo softwareupdate --install-rosetta --agree-to-license" ;;
    esac
    if [ "$OS" = macos ] && [ -z "$PM" ]; then
        say "  Homebrew:  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    fi
    case " $MISSING " in
        *" xas "*|*" xld "*|*" xcc "*|*" qemu "*|*" xlibc "*) print_cross_manual ;;
    esac
    if [ "$OS" = linux ] && [ -z "$PM" ]; then
        say "  Generic: install binutils (as, ld), gcc, nasm [x86 NASM syntax] with your distribution's package manager."
    fi
    if [ -n "$WHY" ]; then say "  (automatic install unavailable: $WHY)"; fi
}
print_cross_manual() {
    say ""
    say "  Cross toolchain for ${BOLD}$(tgt_label "$TARGET_ID")${NC}:"
    say "    Debian/Ubuntu : sudo apt install binutils-$(deb_tri "$TARGET_ID") gcc-$(deb_tri "$TARGET_ID") libc6-dev-$(deb_arch "$TARGET_ID")-cross qemu-user"
    _pcm_f=$(fed_tri "$TARGET_ID")
    [ -n "$_pcm_f" ] && say "    Fedora        : sudo dnf install binutils-$_pcm_f gcc-$_pcm_f qemu-user"
    case "$TARGET_ID" in
        aarch64|riscv64) say "    Arch          : sudo pacman -S $(tgt_prefixes "$TARGET_ID" | cut -d' ' -f1)-gcc $(tgt_prefixes "$TARGET_ID" | cut -d' ' -f1)-glibc qemu-user" ;;
    esac
    say "    Alpine        : apk add $(tgt_qemu "$TARGET_ID")      (no cross gcc packages: use Debian/Fedora/Docker)"
    say "    Any distro    : docker run --rm -it --platform linux/$(deb_arch "$TARGET_ID") ...   (runs the target natively via qemu)"
}

# install_hint KIND -> a human-readable "how to install the KIND package for $TARGET_ID"
install_hint() {
    [ -n "$PM" ] || detect_pm
    _ih_p=$(cross_pkg "$1" "$TARGET_ID")
    if [ -n "$_ih_p" ] && [ -n "$INS" ]; then printf '%s%s %s' "$S" "$INS" "$_ih_p"
    else printf 'install the %s package for %s with your package manager' "$1" "$(tgt_label "$TARGET_ID")"; fi
}

# Make sure every tool in $REQUIRED exists; install what is missing (with consent).
# Returns 0 when everything is there, exits 1 otherwise (unless $1 = soft -> returns 1).
ensure_tools() {
    _et_soft=${1:-hard}
    MISSING=""
    for _et_t in $REQUIRED; do
        tool_ok "$_et_t" || MISSING="$MISSING $_et_t"
    done
    MISSING=${MISSING# }
    [ -z "$MISSING" ] && return 0

    _et_labels=""
    for _et_t in $MISSING; do _et_labels="$_et_labels, $(tool_label "$_et_t")"; done
    warn "Missing tools: ${_et_labels#, }"

    detect_pm
    PKGS=""
    _et_manual=0
    for _et_t in $MISSING; do
        case "$_et_t" in
            clt|rosetta) : ;;
            *)  _et_p=$(pkg_of "$_et_t")
                if [ -n "$_et_p" ]; then
                    for _et_one in $_et_p; do
                        case " $PKGS " in *" $_et_one "*) : ;; *) PKGS="$PKGS $_et_one" ;; esac
                    done
                else _et_manual=1; fi ;;
        esac
    done
    PKGS=${PKGS# }

    # macOS: CLT and Rosetta have their own installers.
    if [ "$OS" = macos ]; then
        case " $MISSING " in
            *" clt "*)
                if ask_yn "Install the Xcode Command Line Tools now? (a macOS dialog will open)"; then
                    xcode-select --install >/dev/null 2>&1
                    say "Finish the installer dialog, then run asmrun again."
                fi ;;
        esac
        case " $MISSING " in
            *" rosetta "*)
                if ask_yn "Install Rosetta 2 now (needed to run x86-64 code on Apple Silicon)?"; then
                    sudo softwareupdate --install-rosetta --agree-to-license || warn "Rosetta installation failed"
                fi ;;
        esac
    fi

    if [ -n "$PKGS" ] && [ "$CAN_AUTO" -eq 1 ]; then
        say "I can install:  ${BOLD}$PKGS${NC}   (using ${PM}${SUDO:+, via $SUDO})"
        if ask_yn "Install now?"; then
            do_install
            hash -r 2>/dev/null
            # refresh and verify (I5): trust nothing, check again
            MISSING=""
            for _et_t in $REQUIRED; do tool_ok "$_et_t" || MISSING="$MISSING $_et_t"; done
            MISSING=${MISSING# }
            if [ -z "$MISSING" ]; then good "All required tools are now available."; return 0; fi
            warn "Still missing after install: $MISSING"
        else
            say "${DIM}Skipped. Re-run with -y to install without asking.${NC}"
        fi
    fi
    print_manual
    if [ "$_et_soft" = soft ]; then return 1; fi
    ERR_MSG="missing tools: $MISSING"
    STATUS=tools-missing
    exit 1
}

# ---- noexec-safe work directory (I11) ----------------------------------------
try_workdir() {
    _tw_d=$1
    if [ -n "$_tw_d" ] && [ -d "$_tw_d" ] && [ -w "$_tw_d" ]; then :; else return 1; fi
    _tw_f=$(mktemp "$_tw_d/.asmrun_probe.XXXXXX" 2>/dev/null) || return 1
    printf '#!/bin/sh\nexit 0\n' >"$_tw_f" 2>/dev/null
    chmod +x "$_tw_f" 2>/dev/null
    "$_tw_f" >/dev/null 2>&1
    _tw_rc=$?
    rm -f "$_tw_f"
    [ "$_tw_rc" -eq 0 ] || return 1
    WORK_PARENT=$_tw_d
    return 0
}
make_workdir() {
    WORK_PARENT=""
    _pw_home=${HOME:-}
    for _pw_d in "${TMPDIR:-}" /tmp /var/tmp /dev/shm "${_pw_home:+$_pw_home/.cache}" "$(pwd)"; do
        if [ -n "$_pw_home" ] && [ "$_pw_d" = "$_pw_home/.cache" ]; then mkdir -p "$_pw_d" 2>/dev/null; fi
        if try_workdir "$_pw_d"; then break; fi
    done
    [ -n "$WORK_PARENT" ] || die "No writable, executable temp directory found (tried \$TMPDIR, /tmp, /var/tmp, /dev/shm, ~/.cache, cwd)."
    WORK=$(mktemp -d "$WORK_PARENT/asmrun.XXXXXX" 2>/dev/null) || die "Cannot create a work directory in $WORK_PARENT"
    chmod 700 "$WORK" 2>/dev/null
    LOG="$WORK/stage.log"
    info "work dir: $WORK"
}

# ==============================================================================
#  6. Build helpers
# ==============================================================================
display_arg() {
    case "$1" in
        ''|*[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}
record_cmd() {
    _rc_line=""
    for _rc_a in "$@"; do _rc_line="$_rc_line $(display_arg "$_rc_a")"; done
    _rc_line=${_rc_line# }
    printf '%s[BUILD]%s %s\n' "$CYAN" "$NC" "$_rc_line" >&2
    CMDS="$CMDS$(printf '%s' "$_rc_line" | tr '\n' ' ')
"
    CMD_COUNT=$((CMD_COUNT + 1))
}
# stage LABEL cmd args...  - run one build command; output captured in $LOG.
# Returns the command's status (callers decide; the auto-recovery engine reads $LOG).
STAGE_LABEL=""; STAGE_RC=0
stage() {
    STAGE_LABEL=$1; shift
    record_cmd "$@"
    if [ "$DRY_RUN" -eq 1 ]; then STAGE_RC=0; return 0; fi
    "$@" >"$LOG" 2>&1
    STAGE_RC=$?
    if [ "$STAGE_RC" -eq 0 ] && [ -s "$LOG" ]; then
        printf '%s' "$YELLOW" >&2; cat "$LOG" >&2; printf '%s' "$NC" >&2
        if LC_ALL=C grep -Eiq 'missing [.]note[.]GNU-stack|LOAD segment with RWX' "$LOG"; then
            say "${DIM}       (these two linker warnings are normal for hand-written assembly; the program works)${NC}"
        fi
    fi
    return "$STAGE_RC"
}
lg() { LC_ALL=C grep -Eiq -- "$1" "$LOG" 2>/dev/null; }     # does the last failed stage's log match?

# ==============================================================================
#  Paths and guards
# ==============================================================================
abs_dir() { ( cd "$1" 2>/dev/null && pwd -P ); }
same_file() {   # same_file A B -> 0 when both name the same file/path
    if [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ] 2>/dev/null; then return 0; fi
    _sf_da=$(abs_dir "$(dirname -- "$1")"); _sf_db=$(abs_dir "$(dirname -- "$2")")
    [ -n "$_sf_da" ] && [ -n "$_sf_db" ] || return 1
    [ "$_sf_da/$(basename -- "$1")" = "$_sf_db/$(basename -- "$2")" ]
}
src_stem() {
    _ss=$(basename -- "$FILE")
    _ss_s=${_ss%.*}
    [ -n "$_ss_s" ] || _ss_s=$_ss          # ".s" style names keep the whole name
    printf '%s' "$_ss_s"
}

# Decide where every artefact goes.  Output defaults never silently clobber text files.
resolve_paths() {
    OBJ="$WORK/prog.o"; PRE="$WORK/prog.s"; EXE="$WORK/prog"; OBJ_OUT=""; RUN=""
    _rp_stem=$(src_stem)
    if [ "$ASM_ONLY" -eq 1 ]; then
        if [ -n "$OUT" ]; then OBJ_OUT=$OUT; else OBJ_OUT="./$_rp_stem.o"; DERIVED_OUT=1; fi
        RUN=$OBJ_OUT
    elif [ -n "$OUT" ]; then
        EXE=$OUT; RUN=$OUT
    elif [ "$LINK_ONLY" -eq 1 ]; then
        EXE="./$_rp_stem"; DERIVED_OUT=1
        if same_file "$EXE" "$FILE"; then EXE="./$_rp_stem.out"; fi    # extension-less source
        RUN=$EXE
    else
        RUN=$EXE
    fi
    _rp_chk=$RUN
    [ -n "$_rp_chk" ] || return 0
    if [ "$ASM_ONLY" -eq 0 ] && [ "$LINK_ONLY" -eq 0 ] && [ -z "$OUT" ]; then return 0; fi
    if [ -d "$_rp_chk" ]; then die "Output path '$_rp_chk' is a directory."; fi
    if same_file "$_rp_chk" "$FILE"; then die "Output path '$_rp_chk' is the source file - refusing to overwrite it. Use -o."; fi
    _rp_dir=$(dirname -- "$_rp_chk")
    if [ ! -d "$_rp_dir" ]; then die "Output directory '$_rp_dir' does not exist."; fi
    if [ ! -w "$_rp_dir" ]; then die "Output directory '$_rp_dir' is not writable."; fi
    if [ "$DERIVED_OUT" -eq 1 ] && [ -f "$_rp_chk" ]; then
        # a derived name that already holds someone's text file/script: refuse
        _rp_ft=$(file -b "$_rp_chk" 2>/dev/null)
        case "$_rp_ft" in
            *text*|*script*|*empty*|*JSON*|*document*)
                die "Default output '$_rp_chk' already exists and is not a binary ($_rp_ft). Use -o to choose another name." ;;
        esac
    fi
    return 0
}

# ==============================================================================
#  Plan  (idempotent: re-run after any auto-fix changed SYNTAX/BITS/LINK/...)
# ==============================================================================
FORCE_LINK=""; FORCE_NOSTART=0; NOPIE_FLAG="-no-pie"; TRIED=" "; ATTEMPTS=""
NO_RUN=0; TIMEOUT_BIN=""; TIMEOUT_FG=""; MARCH_FLAG=""; NASM_DBG=""; AS_DBG=""; CC_DBG=""
AUTO_QEMU=""; BUILD_TRIES=0

tried() { case "$TRIED" in *" $1 "*) return 0 ;; esac; return 1; }
mark()  { TRIED="$TRIED$1 "; }
auto_say() { printf '%s[AUTO]%s %s\n' "$CYAN" "$NC" "$*" >&2; }
note_attempt() { ATTEMPTS="$ATTEMPTS$1; "; }

entry_symbol() {
    if [ "$HAS_START" -eq 1 ]; then printf '_start'
    elif [ "$HAS_ENTRY" -eq 1 ]; then printf '%s' "$ENTRY_NAME"
    elif [ "$HAS_PSTART" -eq 1 ]; then printf 'start'
    fi
}

plan_all() {
    # ---- target ------------------------------------------------------------
    if [ -z "$FORCE_TARGET" ]; then
        TARGET_ID=$(fam_tgt "$SRC" "$BITS")
        if [ -z "$TARGET_ID" ]; then
            die "Detected $(arch_label "$SRC") with $BITS-bit code, which asmrun cannot build (supported targets: $ALL_TARGETS)."
        fi
    fi
    if host_runs_natively "$TARGET_ID"; then NATIVE=1; else NATIVE=0; fi

    if [ "$OS" = macos ]; then
        case "$TARGET_ID" in
            x86_64|aarch64) : ;;
            i386) die "32-bit x86 programs cannot run on macOS (support ended with macOS 10.14). Use Linux, a VM, or Docker." ;;
            *)    die "macOS can only build and run x86-64 and arm64 programs; '$(tgt_label "$TARGET_ID")' needs Linux (cross-compilation + qemu-user is Linux-only by design)." ;;
        esac
        if [ "$NATIVE" -eq 0 ]; then
            die "This Mac is $HOST; it cannot run $(tgt_label "$TARGET_ID") code (only Apple Silicon can run x86-64 via Rosetta). Use Linux/Docker for cross-architecture work."
        fi
    fi

    # ---- toolchain names ----------------------------------------------------
    CROSS=""; QEMU_BIN=""; SYSROOT=""; RUNNER=native
    AS_BIN=as; LD_BIN=ld; NASM_BIN=nasm
    if [ "$OS" = linux ]; then
        if [ "$NATIVE" -eq 0 ]; then
            CROSS=$(cross_prefix_for "$TARGET_ID" as)
            AS_BIN="$CROSS-as"; LD_BIN="$CROSS-ld"
        fi
    fi

    # ---- x86 word-size switches (native x86 only; cross toolchains default correctly)
    FMT=elf64; ASF=""; LDM=""; CCM=""
    if [ "$SRC" = x86 ]; then
        if [ "$OS" = macos ]; then FMT=macho64
        elif [ "$BITS" -eq 32 ]; then FMT=elf32; fi
        if [ "$OS" = linux ] && [ "$NATIVE" -eq 1 ]; then
            if [ "$BITS" -eq 32 ]; then ASF="--32"; LDM="-m elf_i386"; CCM="-m32"
            else ASF="--64"; fi
        fi
    fi

    # ---- link strategy --------------------------------------------------------
    # LINK=ld : as + ld (the exact manual commands)     LINK=cc : the C driver links
    # CPP_MODE: cc  = the driver preprocesses (-x assembler-with-cpp)
    #           cpp = stand-alone cpp, then as          (only when no C driver exists)
    CPP_MODE=""
    _pa_needcc=0
    if [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; then _pa_needcc=1; fi
    if [ "$OS" = macos ]; then
        LINK=cc
    else
        if [ "$CPP" -eq 1 ] && [ "$SYNTAX" = gas ]; then
            if [ "$NATIVE" -eq 0 ]; then CPP_MODE=cc; _pa_needcc=1      # host cpp predefines the WRONG arch macros
            elif [ "$_pa_needcc" -eq 1 ]; then CPP_MODE=cc
            elif find_cc; then CPP_MODE=cc; _pa_needcc=1
            elif command -v cpp >/dev/null 2>&1; then CPP_MODE=cpp
            else CPP_MODE=cc; _pa_needcc=1; fi
        fi
        if [ -n "$FORCE_LINK" ]; then LINK=$FORCE_LINK
        elif [ "$_pa_needcc" -eq 1 ]; then LINK=cc
        else LINK=ld; fi
    fi

    # ---- the C driver ---------------------------------------------------------------
    if [ "$OS" = linux ] && [ "$NATIVE" -eq 0 ]; then
        CC_BIN="$(cross_prefix_for "$TARGET_ID" gcc)-gcc"
    else
        find_cc || CC_BIN=${FORCE_CC:-${ASMRUN_CC:-cc}}
    fi

    # ---- entry point and driver mode ---------------------------------------------
    _pa_sym=$(entry_symbol)
    ENTRY_FLAG=""; CC_ENTRY=""
    if [ "$OS" = macos ]; then
        [ -n "$_pa_sym" ] && CC_ENTRY="-Wl,-e,$_pa_sym"
    elif [ -n "$_pa_sym" ]; then
        if [ "$_pa_sym" != _start ] || ! tgt_default_entry_is_start "$TARGET_ID"; then
            ENTRY_FLAG="-e $_pa_sym"; CC_ENTRY="-Wl,-e,$_pa_sym"
        fi
    fi
    _pa_custom=0
    if [ "$HAS_START" -eq 1 ] || [ "$HAS_PSTART" -eq 1 ] || [ "$HAS_ENTRY" -eq 1 ] || [ "$FORCE_NOSTART" -eq 1 ]; then _pa_custom=1; fi
    CCMODE=""
    if [ "$OS" = linux ]; then
        if [ "$HAS_MAIN" -eq 1 ] && [ "$_pa_custom" -eq 0 ]; then CCMODE=""
        elif [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; then CCMODE="-nostartfiles"
        else CCMODE="-nostdlib -static"; fi
    fi
    [ "$LINK" = cc ] || CC_ENTRY=""

    # ---- optional flag groups ----------------------------------------------------
    MARCH_FLAG=""; [ -n "$MARCH_OPT" ] && MARCH_FLAG="-march=$MARCH_OPT"
    NASM_DBG=""; AS_DBG=""; CC_DBG=""
    if [ "$DEBUG_INFO" -eq 1 ]; then NASM_DBG="-g -F dwarf"; AS_DBG="-g"; CC_DBG="-g"; fi
    # Newer vector extensions only exist under qemu with "-cpu max"
    AUTO_QEMU=""
    case "$EXTS" in *sve*|*sme*|*rvv*) AUTO_QEMU="-cpu max" ;; esac

    plan_tools
}

# Which tools does THIS plan need?  (I6: nothing more than that.)
plan_tools() {
    REQUIRED=""
    if [ "$OS" = macos ]; then
        add_req clt
        [ "$SYNTAX" = nasm ] && add_req nasm
        if [ "$HOST" = arm64 ] && [ "$TARGET_ID" = x86_64 ] && [ "$ASM_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then add_req rosetta; fi
        return 0
    fi
    if [ "$NATIVE" -eq 1 ]; then _pt_a=as; _pt_l=ld; _pt_c=cc; else _pt_a=xas; _pt_l=xld; _pt_c=xcc; fi
    [ "$SYNTAX" = nasm ] && add_req nasm
    if [ "$ASM_ONLY" -eq 1 ]; then
        if [ "$SYNTAX" = gas ]; then
            case "$CPP_MODE" in cc) add_req "$_pt_c" ;; cpp) add_req cpp; add_req "$_pt_a" ;; *) add_req "$_pt_a" ;; esac
        fi
    elif [ "$LINK" = cc ]; then
        add_req "$_pt_c"
        if [ "$NATIVE" -eq 0 ] && { [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; }; then add_req xlibc; fi
        if [ "$NATIVE" -eq 1 ] && [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ] && [ "$CCMODE" != "-nostdlib -static" ]; then add_req multilib; fi
    else
        add_req "$_pt_l"
        [ "$SYNTAX" = gas ] && add_req "$_pt_a"
        [ "$CPP_MODE" = cpp ] && add_req cpp
    fi
    return 0
}

# How will the program be executed?  (called after build tools are settled)
plan_runner() {
    RUNNER=native; QEMU_BIN=""; SYSROOT=""
    [ "$NATIVE" -eq 1 ] && return 0
    if [ -n "$CROSS" ]; then find_sysroot "$CROSS"; fi
    if find_qemu "$TARGET_ID"; then RUNNER=qemu
    elif binfmt_ok "$TARGET_ID"; then RUNNER=binfmt
    elif [ "$HOST" = arm64 ] && [ "$TARGET_ID" = armv7 ]; then RUNNER=direct     # many AArch64 CPUs/kernels run AArch32 natively
    else RUNNER=none; fi
}
ensure_runner() {
    [ "$NATIVE" -eq 1 ] && return 0
    plan_runner
    if [ "$RUNNER" = none ]; then
        REQUIRED=" qemu"
        if ensure_tools soft; then plan_runner; else NO_RUN=1; fi
    fi
    return 0
}

# ==============================================================================
#  Build
# ==============================================================================
build_linux() {
    if [ "$SYNTAX" = nasm ]; then
        _bl_o=$OBJ; [ "$ASM_ONLY" -eq 1 ] && _bl_o=$OBJ_OUT
        stage "Assembling (NASM)" "$NASM_BIN" $X_NASM $NASM_DBG -f "$FMT" -o "$_bl_o" "$FILE" || return $?
        [ "$ASM_ONLY" -eq 1 ] && return 0
        if [ "$LINK" = cc ]; then
            stage "Linking (C driver)" "$CC_BIN" $CCM $NOPIE_FLAG $CCMODE $CC_ENTRY $CC_DBG $MARCH_FLAG $X_CC -o "$EXE" "$OBJ" || return $?
        else
            stage "Linking" "$LD_BIN" $LDM $ENTRY_FLAG $X_LD -o "$EXE" "$OBJ" || return $?
        fi
        return 0
    fi
    # ---- GNU as ---------------------------------------------------------------
    _bl_src=$FILE
    if [ "$CPP_MODE" = cpp ]; then
        stage "Preprocessing" cpp -traditional-cpp -P -o "$PRE" "$FILE" || return $?
        _bl_src=$PRE
    fi
    if [ "$ASM_ONLY" -eq 1 ]; then
        if [ "$CPP_MODE" = cc ]; then
            stage "Assembling" "$CC_BIN" $CCM $CC_DBG $MARCH_FLAG $X_CC -c -x "$XLANG" -o "$OBJ_OUT" "$FILE" || return $?
        else
            stage "Assembling" "$AS_BIN" $ASF $AS_DBG $MARCH_FLAG $X_AS -o "$OBJ_OUT" "$_bl_src" || return $?
        fi
    elif [ "$LINK" = cc ]; then
        stage "Assembling + linking (C driver)" "$CC_BIN" $CCM $NOPIE_FLAG $CCMODE $CC_ENTRY $CC_DBG $MARCH_FLAG $X_CC -x "$XLANG" "$FILE" -o "$EXE" || return $?
    else
        stage "Assembling" "$AS_BIN" $ASF $AS_DBG $MARCH_FLAG $X_AS -o "$OBJ" "$_bl_src" || return $?
        stage "Linking" "$LD_BIN" $LDM $ENTRY_FLAG $X_LD -o "$EXE" "$OBJ" || return $?
    fi
    return 0
}

build_macos() {
    case "$TARGET_ID" in x86_64) _bm_arch=x86_64 ;; *) _bm_arch=arm64 ;; esac
    if [ "$SYNTAX" = nasm ]; then
        _bm_o=$OBJ; [ "$ASM_ONLY" -eq 1 ] && _bm_o=$OBJ_OUT
        stage "Assembling (NASM)" "$NASM_BIN" $X_NASM $NASM_DBG -f macho64 -o "$_bm_o" "$FILE" || return $?
        [ "$ASM_ONLY" -eq 1 ] && return 0
        stage "Linking (clang)" "$CC_BIN" -arch "$_bm_arch" $CC_ENTRY $CC_DBG $X_CC -o "$EXE" "$OBJ" || return $?
        return 0
    fi
    if [ "$ASM_ONLY" -eq 1 ]; then
        stage "Assembling (clang)" "$CC_BIN" -arch "$_bm_arch" $CC_DBG $MARCH_FLAG $X_CC -c -x "$XLANG" -o "$OBJ_OUT" "$FILE" || return $?
    else
        stage "Assembling + linking (clang)" "$CC_BIN" -arch "$_bm_arch" -x "$XLANG" $CC_ENTRY $CC_DBG $MARCH_FLAG $X_CC -o "$EXE" "$FILE" || return $?
    fi
    return 0
}

# ==============================================================================
#  Auto-recovery engine: failure pattern -> fix -> retry.   Returns 0 = retry.
#  Rules are ordered; each fires at most once (tried/mark).  Add new rules here.
# ==============================================================================
first_error_line() {
    LC_ALL=C grep -Ei -m 1 'error|undefined|cannot|fatal|unknown|invalid|not found' "$LOG" 2>/dev/null | cut -c1-110
}
is_asm_stage() { case "$STAGE_LABEL" in Assembling*|Preprocessing*) return 0 ;; esac; return 1; }

auto_recover() {
    [ "$DRY_RUN" -eq 0 ] || return 1
    _ar_err=$(first_error_line)

    # R1: old compilers do not know -no-pie
    if [ -n "$NOPIE_FLAG" ] && lg 'no-pie' && lg 'unrecogni[sz]ed|unknown (argument|option)|unsupported option|invalid option|not recogni[sz]ed'; then
        NOPIE_FLAG=""; mark nopie
        auto_say "This compiler does not accept -no-pie - retrying without it."
        note_attempt "no -no-pie"; return 0
    fi

    # R2: both a custom _start and main: the C runtime must not add a second _start
    if ! tried nostart && lg 'multiple definition of .?_start'; then
        mark nostart; FORCE_NOSTART=1
        auto_say "Both _start and main are defined - linking with -nostartfiles."
        plan_all; note_attempt "-nostartfiles"; return 0
    fi

    # R3: C library development files missing (cross sysroot / 32-bit multilib / plain)
    if ! tried libdev && lg 'cannot find crt1[.]o|cannot find crti[.]o|crt1[.]o: No such|cannot find -lc([^a-z]|$)|libc-header-start[.]h|gnu/stubs-(32|64)[.]h|stdio[.]h: No such file|cannot find -lgcc|cannot find .*libgcc'; then
        mark libdev
        if [ "$NATIVE" -eq 0 ]; then REQUIRED=" xcc xlibc"
        elif [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ]; then REQUIRED=" cc multilib"
        else REQUIRED=" cc"; fi
        auto_say "C library development files are missing - installing them."
        if ensure_tools soft; then plan_all; note_attempt "installed libc dev files"; return 0; fi
        return 1
    fi

    # R4: ld/driver could not resolve symbols -> they live in libc: link through the C driver
    if ! tried libc && lg 'undefined reference to|undefined symbol|unresolved symbol'; then
        if [ "$OS" = linux ] && { [ "$LINK" = ld ] || [ "$CCMODE" = "-nostdlib -static" ]; }; then
            mark libc; USES_LIBC=1; FORCE_LINK=cc
            auto_say "Unresolved symbols (probably C library functions) - retrying with the C library linked in."
            plan_all
            if ensure_tools soft; then note_attempt "linked libc"; return 0; fi
            return 1
        fi
    fi

    # R5: file only looked like it needed the C preprocessor
    if ! tried nocpp && [ "$CPP" -eq 1 ] && [ "$SYNTAX" = gas ] && lg 'invalid preprocessing directive|#(else|endif|elif) without #if|unterminated #(if|ifdef)|missing terminating'; then
        case "$FILE" in
            *.S) : ;;
            *)  mark nocpp; CPP=0; XLANG=assembler; CPP_MODE=""
                auto_say "The preprocessor choked - the file is plain assembly; retrying without it."
                plan_all; note_attempt "no cpp"; return 0 ;;
        esac
    fi

    # R6: wrong x86 syntax guess (NASM <-> GNU as).  Only for assembler-style errors.
    if is_asm_stage && ! tried flipsyntax && [ "$SRC" = x86 ] && [ -z "$FORCE_SYNTAX" ] && [ "$SYNTAX_FIRM" -eq 0 ] \
       && ! lg 'undefined reference|collect2|ld returned|cannot find -l|relocation' \
       && lg 'error|invalid|unknown|junk|parser|expected|no such instruction|unrecogni[sz]ed'; then
        mark flipsyntax
        note_attempt "$SYNTAX failed: $_ar_err"
        _ar_old_syn=$SYNTAX; _ar_old_cpp=$CPP; _ar_old_x=$XLANG
        if [ "$SYNTAX" = nasm ]; then SYNTAX=gas; else SYNTAX=nasm; fi
        CPP=0
        if [ "$SYNTAX" = gas ] && has '^#(include|define|ifdef|ifndef|if|elif|else|endif)'; then CPP=1; fi
        if [ "$CPP" -eq 1 ]; then XLANG=assembler-with-cpp; else XLANG=assembler; fi
        auto_say "The assembler rejected the file - trying the other x86 syntax ($SYNTAX)."
        plan_all
        if ensure_tools soft; then return 0; fi
        SYNTAX=$_ar_old_syn; CPP=$_ar_old_cpp; XLANG=$_ar_old_x; plan_all     # declined: restore the original plan
        return 1
    fi

    # R7: wrong x86 word size guess
    if ! tried flipbits && [ "$SRC" = x86 ] && [ -z "$FORCE_BITS" ] && [ -z "$FORCE_TARGET" ] && [ "$BITS_FIRM" -eq 0 ] \
       && lg '32-bit|64-bit|incompatible|bad register|no such instruction|invalid (operand|combination|register)|not supported in'; then
        _ar_nb=32; [ "$BITS" -eq 32 ] && _ar_nb=64
        if [ "$_ar_nb" -le "$HOST_BITS" ] || [ "$NATIVE" -eq 0 ]; then
            mark flipbits; note_attempt "$BITS-bit failed: $_ar_err"
            _ar_old_bits=$BITS
            BITS=$_ar_nb
            auto_say "That did not assemble as $_ar_old_bits-bit code - trying $BITS-bit."
            plan_all
            if ensure_tools soft; then return 0; fi
            BITS=$_ar_old_bits; plan_all
            return 1
        fi
    fi

    # R8: assembler needs an -march/extension switch for newer instructions (latest ISAs)
    if is_asm_stage && ! tried march && [ -z "$MARCH_OPT" ] && [ -z "$X_AS" ] \
       && lg 'selected processor does not support|unrecogni[sz]ed opcode|unknown mnemonic|instruction requires|requires (the )?[a-z0-9_+.-]+ (extension|feature)|not supported by the current|bad instruction'; then
        _ar_m=""
        case "$SRC" in
            arm64) case "$EXTS" in *sme*) _ar_m="armv9.2-a+sme" ;; *sve*) _ar_m="armv8.2-a+sve" ;; *) _ar_m="armv8.5-a" ;; esac ;;
            arm32) _ar_m="armv7-a" ;;
            riscv) case "$EXTS" in *rvv*) _ar_m="rv64gcv" ;; *) _ar_m="rv64gc" ;; esac ;;
        esac
        if [ -n "$_ar_m" ]; then
            mark march; MARCH_OPT=$_ar_m
            auto_say "The default CPU level lacks those instructions - retrying with -march=$_ar_m."
            note_attempt "-march=$_ar_m"; plan_all; return 0
        fi
    fi
    return 1
}

# Last-resort explanation for failures no rule could fix.
print_hints() {
    say ""
    if lg 'xcrun: error|invalid active developer path|library .?System.? not found|unable to find utility|SDK'; then
        say "  Hint: the Xcode Command Line Tools look broken -> run: xcode-select --install   (or sudo xcode-select --reset)"
    fi
    if lg 'undefined reference|Undefined symbols'; then
        say "  Hint: a symbol is not defined anywhere. Check spelling, .globl/global, and (macOS) the leading underscore (_main, _puts)."
    fi
    if lg 'cannot find entry symbol|symbol.*_main'; then
        say "  Hint: no entry point. Define _start (raw syscalls) or main (C runtime), or name one with an ENTRY(name) comment."
    fi
    if [ "$SRC" = x86 ] && is_asm_stage; then
        say "  Hint: if the syntax guess is wrong force it: --nasm or --gas;  word size: --32 or --64."
    fi
    if [ -n "$EXTS" ]; then
        say "  Hint: this source uses $EXTS. Your assembler may be too old (update binutils/nasm) or need --march=<level>."
    fi
    if [ "$NATIVE" -eq 0 ] && lg 'cannot find|No such file'; then
        say "  Hint: for a cross build you may need the target C library:  $(install_hint libc)"
    fi
    say "  Tip : run again with -v for detection details, or --keep-build-dir to inspect the intermediate files."
}
build_failed() {
    STATUS=build-failed
    ERR_MSG="$STAGE_LABEL failed (exit $STAGE_RC)"
    err "$STAGE_LABEL failed (exit $STAGE_RC)"
    if [ -s "$LOG" ]; then
        printf '%s' "$RED" >&2
        head -n 40 "$LOG" | sed 's/^/    /' >&2
        if [ "$(wc -l <"$LOG")" -gt 40 ]; then printf '    ... (%s more lines; use --keep-build-dir)\n' "$(( $(wc -l <"$LOG") - 40 ))" >&2; fi
        printf '%s' "$NC" >&2
    fi
    if [ -n "$ATTEMPTS" ]; then say "${DIM}Automatic fixes already tried: ${ATTEMPTS%; }${NC}"; fi
    print_hints
    exit 1
}

# The build loop: build -> on failure ask the recovery engine -> rebuild (max 6 times).
do_build() {
    while :; do
        BUILD_TRIES=$((BUILD_TRIES + 1))
        if [ "$OS" = macos ]; then build_macos; else build_linux; fi
        _db_rc=$?
        [ "$_db_rc" -eq 0 ] && return 0
        if [ "$BUILD_TRIES" -lt 6 ] && auto_recover; then
            continue
        fi
        build_failed
    done
}

# ==============================================================================
#  Pre-flight warnings, post-build checks
# ==============================================================================
preflight_warnings() {
    if [ "$ARCH_AMBIGUOUS" -eq 1 ] && [ -z "$FORCE_ARCH" ] && [ -z "$FORCE_TARGET" ]; then
        warn "Architecture detection is not clear-cut ($ARCH_VOTES). Using $(arch_label "$SRC"); override with --arch / --target."
    fi
    if [ "$HAS_UMAIN" -eq 1 ] && [ "$HAS_START" -eq 0 ]; then
        if [ "$OS" = macos ]; then warn "Found 'main:' but the C entry point on macOS is '_main' (leading underscore)."
        else warn "Found '_main:' but the C entry point on Linux is 'main'. Treating '_main' as an ordinary label."; fi
    fi
    if [ "$ASM_ONLY" -eq 0 ] && [ "$HAS_START" -eq 0 ] && [ "$HAS_PSTART" -eq 0 ] && [ "$HAS_MAIN" -eq 0 ] && [ "$HAS_ENTRY" -eq 0 ]; then
        warn "No entry point found (_start, main or ENTRY(name)). The linker will start at the beginning of .text."
    fi
    return 0
}

post_build() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    if [ "$ASM_ONLY" -eq 1 ]; then
        [ -f "$OBJ_OUT" ] || die "The assembler reported success but '$OBJ_OUT' was not created."
        say "${DIM}[OUT] object file: $OBJ_OUT${NC}"
        return 0
    fi
    [ -f "$RUN" ] || die "The linker reported success but '$RUN' was not created."
    chmod +x "$RUN" 2>/dev/null
    if command -v file >/dev/null 2>&1; then
        _pb_ft=$(file -b "$RUN" 2>/dev/null)
        say "${DIM}[FILE] $_pb_ft${NC}"
        case "$_pb_ft" in
            *ELF*|*Mach-O*)
                if ! tgt_file_ok "$TARGET_ID" "$_pb_ft"; then
                    warn "The output does not look like $(tgt_label "$TARGET_ID"): $_pb_ft"
                fi ;;
        esac
    else
        info "'file' is not installed - skipping output verification"
    fi
    # macOS: the classic mistake is using Linux syscall numbers.
    if [ "$OS" = macos ] && [ "$ASM_ONLY" -eq 0 ]; then
        if [ "$TARGET_ID" = x86_64 ] && has '(^|[[:space:]])syscall[[:space:]]*$' && ! hasraw '0x2000000|2000000h|0x200000[0-9a-f]'; then
            warn "macOS BSD syscalls need the 0x2000000 class: exit = 0x2000001, write = 0x2000004 (Linux numbers will not work)."
        fi
        if [ "$TARGET_ID" = aarch64 ] && has '(^|[[:space:]])svc[[:space:]]' && has '(^|[^[:alnum:]_])x8([^[:alnum:]_]|$)' && ! has '(^|[^[:alnum:]_])x16([^[:alnum:]_]|$)'; then
            warn "macOS arm64 passes the syscall number in x16 (with svc #0x80), not x8 as Linux does."
        fi
    fi
    # dynamic cross binaries need the target's libc at run time
    if [ "$NATIVE" -eq 0 ] && [ "$RUNNER" != none ] && [ "$CCMODE" != "-nostdlib -static" ] && [ "$LINK" = cc ]; then
        if ! sysroot_has_loader "$SYSROOT"; then
            warn "No target C library found for running dynamic $(tgt_label "$TARGET_ID") programs${SYSROOT:+ in $SYSROOT}. Install: $(install_hint libc)"
        fi
    fi
    return 0
}

# ==============================================================================
#  Run
# ==============================================================================
explain_exit() {
    _ee_rc=$1
    if [ "$_ee_rc" -eq 0 ]; then return 0; fi
    if [ "$TIMEOUT" -gt 0 ] && [ "$_ee_rc" -eq 124 ]; then
        say "${YELLOW}[timeout]${NC} the program was stopped after ${TIMEOUT}s (--timeout)."
        return 0
    fi
    if [ "$_ee_rc" -gt 128 ] && [ "$_ee_rc" -lt 193 ]; then
        _ee_n=$((_ee_rc - 128))
        _ee_name=$(kill -l "$_ee_n" 2>/dev/null)
        say "${YELLOW}[signal $_ee_n${_ee_name:+ ($_ee_name)}]${NC}"
        case "$_ee_name" in
            SEGV|11)
                say "       ${DIM}Segmentation fault. Common causes: no exit syscall at the end (execution falls into data);${NC}"
                say "       ${DIM}stack not 16-byte aligned at a call; a bad pointer; wrong word size (try --32 / --64).${NC}" ;;
            ILL|4)  say "       ${DIM}Illegal instruction: execution ran into data, or the CPU lacks an extension.${NC}"; ext_hint ;;
            BUS|7)  say "       ${DIM}Bus error: misaligned access or a bad address.${NC}" ;;
            FPE|8)  say "       ${DIM}Arithmetic exception: division by zero or overflow.${NC}" ;;
            SYS|31) say "       ${DIM}Bad system call: wrong syscall number/convention for this OS, or blocked by seccomp.${NC}" ;;
            TRAP|5) say "       ${DIM}Trap: int3/brk executed (a breakpoint was left in).${NC}" ;;
            ABRT|6) say "       ${DIM}Aborted (the C library detected an error, e.g. a bad free or failed assertion).${NC}" ;;
        esac
        return 0
    fi
    if [ "$_ee_rc" -eq 126 ] || [ "$_ee_rc" -eq 127 ]; then
        say "${YELLOW}[exit $_ee_rc]${NC} the program could not be executed."
        case "$RUNNER" in
            direct|binfmt) say "       ${DIM}The kernel cannot run $(tgt_label "$TARGET_ID") binaries directly. Install qemu-user: $(install_hint qemu)${NC}" ;;
            native)
                if [ "$TARGET_ID" = i386 ]; then
                    say "       ${DIM}This kernel/container cannot run 32-bit programs (IA32 emulation disabled?).${NC}"
                fi ;;
        esac
        return 0
    fi
    say "${DIM}[exit $_ee_rc]${NC}"
    # A crash/failure on a program asmrun guessed as 64-bit but that uses int 0x80: suggest, never auto re-run (side effects)
    return 0
}

run_phase() {      # run_phase [program args...]
    STATUS=running
    _rn_cmd=$RUN
    case "$_rn_cmd" in */*) : ;; *) _rn_cmd="./$_rn_cmd" ;; esac
    set -- "$_rn_cmd" "$@"
    case "$RUNNER" in
        qemu)
            _rn_q=$X_QEMU; [ -n "$_rn_q" ] || _rn_q=$AUTO_QEMU
            set -- $_rn_q "$@"
            if [ -n "$SYSROOT" ]; then set -- -L "$SYSROOT" "$@"; fi
            set -- "$QEMU_BIN" "$@" ;;
        binfmt|direct)
            if [ -n "$SYSROOT" ]; then QEMU_LD_PREFIX=$SYSROOT; export QEMU_LD_PREFIX; fi ;;
    esac
    if [ "$TIMEOUT" -gt 0 ]; then
        set -- "$TIMEOUT_BIN" $TIMEOUT_FG "$TIMEOUT" "$@"
    fi
    "$@"
    RC=$?
    STATUS=ran
    explain_exit "$RC"
    return 0
}

# ==============================================================================
#  7. Report (JSON) - written for success AND failure (I13)
# ==============================================================================
json_str() {
    printf '"'
    printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
    printf '"'
}
json_bool() { if [ "$1" = 1 ] || [ "$1" = yes ]; then printf 'true'; else printf 'false'; fi; }
json_list() {      # json_list "a b c" -> ["a","b","c"]   (split on spaces)
    _jl_f=1; printf '['
    for _jl_x in $1; do
        if [ "$_jl_f" -eq 1 ]; then _jl_f=0; else printf ', '; fi
        json_str "$_jl_x"
    done
    printf ']'
}
write_report() {
    REPORT_DONE=1
    _wr_native=0; [ "$NATIVE" -eq 1 ] && _wr_native=1
    {
        printf '{\n'
        printf '  "tool": "asmrun",\n  "version": "%s",\n  "schema": 2,\n' "$VERSION"
        printf '  "status": '; json_str "$STATUS"; printf ',\n'
        printf '  "error": ';  json_str "$ERR_MSG"; printf ',\n'
        printf '  "file": ';   json_str "$FILE"; printf ',\n'
        printf '  "os": ';     json_str "$OS"; printf ',\n'
        printf '  "wsl": %s,\n  "container": %s,\n' "$(json_bool "$WSL")" "$(json_bool "$CONTAINER")"
        printf '  "host": ';   json_str "$HOST"; printf ',\n'
        printf '  "host_bits": %s,\n' "${HOST_BITS:-0}"
        printf '  "source_arch": '; json_str "$SRC"; printf ',\n'
        printf '  "syntax": ';      json_str "$SYNTAX"; printf ',\n'
        printf '  "bits": %s,\n' "${BITS:-0}"
        printf '  "target": ';      json_str "$TARGET_ID"; printf ',\n'
        printf '  "target_status": '; json_str "$(tgt_status "$TARGET_ID" 2>/dev/null)"; printf ',\n'
        printf '  "native": %s,\n' "$(json_bool "$_wr_native")"
        printf '  "runner": ';      json_str "$RUNNER"; printf ',\n'
        printf '  "link": ';        json_str "$LINK"; printf ',\n'
        printf '  "cpp": %s,\n  "uses_libc": %s,\n' "$(json_bool "$CPP")" "$(json_bool "$USES_LIBC")"
        printf '  "entry": ';       json_str "$(entry_symbol)"; printf ',\n'
        printf '  "extensions": ';  json_list "$(printf '%s' "$EXTS" | tr ',' ' ')"; printf ',\n'
        printf '  "detection": {\n    "arch_votes": {'
        _wr_f=1
        for _wr_kv in $ARCH_VOTES; do
            if [ "$_wr_f" -eq 1 ]; then _wr_f=0; else printf ', '; fi
            printf '"%s": %s' "${_wr_kv%%=*}" "${_wr_kv#*=}"
        done
        printf '},\n    "syntax_votes": '; json_str "$SYNTAX_VOTES"
        printf ',\n    "bits_votes": ';    json_str "$BITS_VOTES"
        printf '\n  },\n'
        printf '  "tools_required": '; json_list "$REQUIRED"; printf ',\n'
        printf '  "tools_missing": ';  json_list "$MISSING"; printf ',\n'
        printf '  "auto_fixes": ';     json_str "${ATTEMPTS%; }"; printf ',\n'
        printf '  "build_attempts": %s,\n' "$BUILD_TRIES"
        printf '  "build_commands": ['
        _wr_f=1
        printf '%s\n' "$CMDS" | while IFS= read -r _wr_l; do
            [ -n "$_wr_l" ] || continue
            if [ "$_wr_f" -eq 1 ]; then _wr_f=0; printf '\n    '; else printf ',\n    '; fi
            json_str "$_wr_l"
        done
        printf '\n  ],\n'
        printf '  "output": ';      json_str "$RUN"; printf ',\n'
        printf '  "exit_code": %s,\n' "${RC:-0}"
        printf '  "kept_build_dir": '
        if [ "$KEEP_BUILD" -eq 1 ] && [ -n "$WORK" ]; then json_str "$WORK"; else printf 'null'; fi
        printf '\n}\n'
    } >"$REPORT" 2>/dev/null || warn "Could not write the report to '$REPORT'"
    return 0
}

# ==============================================================================
#  8. Informational modes (stdout): --detect, --list-targets, --doctor
# ==============================================================================
print_detect() {
    out "file=$FILE"
    out "arch=$SRC"
    out "bits=$BITS"
    if [ "$SRC" = x86 ]; then out "syntax=$SYNTAX"; else out "syntax=gas"; fi
    out "target=$TARGET_ID"
    out "target_status=$(tgt_status "$TARGET_ID" 2>/dev/null)"
    _pd_e=$(entry_symbol); out "entry=${_pd_e:-none}"
    if [ "$HAS_MAIN" -eq 1 ]; then out "c_main=yes"; else out "c_main=no"; fi
    if [ "$USES_LIBC" -eq 1 ] || [ "$HAS_MAIN" -eq 1 ]; then out "libc=yes"; else out "libc=no"; fi
    if [ "$CPP" -eq 1 ]; then out "cpp=yes"; else out "cpp=no"; fi
    out "extensions=${EXTS:-none}"
    out "arch_votes=$ARCH_VOTES"
    out "host=$OS/$HOST/$HOST_BITS"
    if [ -n "$TARGET_ID" ] && host_runs_natively "$TARGET_ID"; then out "native=yes"; else out "native=no"; fi
}

do_list_targets() {
    out "TARGET        FAMILY  BITS  STATUS        CROSS PREFIX (first choice)       QEMU-USER"
    for _lt in $ALL_TARGETS; do
        printf '%-13s %-7s %-5s %-13s %-33s %s\n' "$_lt" "$(tgt_family "$_lt")" "$(tgt_bits "$_lt")" "$(tgt_status "$_lt")" \
            "$(tgt_prefixes "$_lt" | cut -d' ' -f1)" "$(tgt_qemu "$_lt")"
    done
    out ""
    out "supported    = detection, build commands and execution exercised by the author"
    out "experimental = detection and command construction tested; never executed on real hardware"
    out "Any target runs natively on a matching host; other targets need a cross toolchain + qemu-user (Linux)."
}

dr_have() { if command -v "$1" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi; }
do_doctor() {
    make_workdir
    detect_pm
    out "asmrun $VERSION - doctor"
    out ""
    out "System"
    out "  OS / CPU       : $OS / $HOST ($HOST_BITS-bit userland)   WSL: $([ "$WSL" -eq 1 ] && echo yes || echo no)   container: $([ "$CONTAINER" -eq 1 ] && echo yes || echo no)"
    if [ -n "$PM" ]; then out "  package manager: $PM${SUDO:+ (via $SUDO)}"; else out "  package manager: none found"; fi
    if [ "$CAN_AUTO" -eq 1 ]; then out "  auto-install   : possible (asmrun asks first; -y skips the question)"
    else out "  auto-install   : not possible - $WHY"; fi
    out "  work directory : $WORK_PARENT (executable)"
    out ""
    out "Tools"
    out "  as: $(dr_have as)   ld: $(dr_have ld)   nasm: $(dr_have nasm)   cc: $(if find_cc; then echo "yes ($CC_BIN)"; else echo no; fi)   cpp: $(dr_have cpp)"
    out "  file: $(dr_have file)   timeout: $(if find_timeout; then echo "yes ($TIMEOUT_BIN)"; else echo no; fi)   awk: $(dr_have awk)   python3: $(dr_have python3)"
    if [ "$OS" = linux ] && [ "$HOST" = x86 ] && [ "$HOST_BITS" -eq 64 ]; then
        out "  32-bit libc programs (gcc -m32): $(if multilib_ok; then echo yes; else echo "no (static 32-bit asm still works; install gcc-multilib for libc)"; fi)"
    fi
    out ""
    out "Targets   (build on this machine -> run)"
    _dr_save=$TARGET_ID
    _dr_allready=1
    for _dr_t in $ALL_TARGETS; do
        TARGET_ID=$_dr_t
        _dr_need=""
        if host_runs_natively "$_dr_t"; then
            _dr_mode=native
            if [ "$OS" = macos ]; then
                clt_ok || _dr_need="$_dr_need clt"
                if [ "$HOST" = arm64 ] && [ "$_dr_t" = x86_64 ]; then _dr_mode="rosetta"; rosetta_ok || _dr_need="$_dr_need rosetta"; fi
            else
                command -v as >/dev/null 2>&1 || _dr_need="$_dr_need as"
                command -v ld >/dev/null 2>&1 || _dr_need="$_dr_need ld"
            fi
        elif [ "$OS" = macos ]; then
            _dr_mode="n/a"; _dr_need=" (Linux only)"
        else
            _dr_mode=cross
            _dr_p=$(cross_prefix_for "$_dr_t" as); command -v "$_dr_p-as" >/dev/null 2>&1 || _dr_need="$_dr_need $_dr_p-as"
            _dr_p=$(cross_prefix_for "$_dr_t" ld); command -v "$_dr_p-ld" >/dev/null 2>&1 || _dr_need="$_dr_need $_dr_p-ld"
            if ! find_qemu "$_dr_t" && ! binfmt_ok "$_dr_t" && ! { [ "$HOST" = arm64 ] && [ "$_dr_t" = armv7 ]; }; then
                _dr_need="$_dr_need $(tgt_qemu "$_dr_t")"
            fi
        fi
        if [ "$_dr_mode" = "n/a" ]; then _dr_v="not available on macOS (use Linux/Docker)"
        elif [ -z "$_dr_need" ]; then _dr_v="ready"
        else _dr_v="needs:${_dr_need}"; [ "$_dr_mode" = native ] && _dr_allready=0; fi
        printf '  %-12s %-8s %-13s %s\n' "$_dr_t" "$_dr_mode" "$(tgt_status "$_dr_t")" "$_dr_v"
    done
    TARGET_ID=$_dr_save
    out ""
    if [ "$_dr_allready" -eq 1 ]; then out "Host-native builds: ready.   Try:  asmrun --selftest"
    else out "Host-native builds need the tools listed above. asmrun installs them for you on first use (asmrun -y file)."; fi
    out "Cross targets: asmrun --target <id> --dry-run file   shows the exact commands; missing tools are offered for install."
    return 0
}

# ==============================================================================
#  10. Self test  (asmrun --selftest)
#      Layers: detection (any host) -> command construction (any host) ->
#      real build+run (host arch) -> auto-recovery -> robustness -> cross runtime
# ==============================================================================
ST_PASS=0; ST_FAIL=0; ST_SKIP=0
st_pass() { ST_PASS=$((ST_PASS + 1)); printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1" >&2; }
st_fail() { ST_FAIL=$((ST_FAIL + 1)); printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1" >&2; [ -n "${2:-}" ] && printf '       %s\n' "$2" >&2; }
st_skip() { ST_SKIP=$((ST_SKIP + 1)); printf '%s[SKIP]%s %s\n' "$YELLOW" "$NC" "$1" >&2; }
st_sect() { printf '\n%s-- %s%s\n' "$BOLD" "$1" "$NC" >&2; }
st_w()    { cat >"$ST_DIR/$1"; }             # st_w NAME <<'EOF' ... EOF

# st_exec ARGS... : run this script in a clean environment inside $ST_DIR
st_exec() {
    ( cd "$ST_DIR" && ASMRUN_NO_RC=1 NO_COLOR=1 sh "$SELF" "$@" ) >"$ST_DIR/out.txt" 2>"$ST_DIR/err.txt" </dev/null
    ST_RC=$?
}
st_peek() { head -c 160 "$1" 2>/dev/null | tr '\n' ' '; }

st_detect() {   # st_detect NAME FILE ARCH BITS SYNTAX
    st_exec --detect "$2"
    _sd_a=$(sed -n 's/^arch=//p' "$ST_DIR/out.txt"); _sd_b=$(sed -n 's/^bits=//p' "$ST_DIR/out.txt"); _sd_s=$(sed -n 's/^syntax=//p' "$ST_DIR/out.txt")
    if [ "$ST_RC" -eq 0 ] && [ "$_sd_a" = "$3" ] && [ "$_sd_b" = "$4" ] && [ "$_sd_s" = "$5" ]; then st_pass "detect  $1 -> $3/$4/$5"
    else st_fail "detect  $1" "expected $3/$4/$5, got $_sd_a/$_sd_b/$_sd_s (rc=$ST_RC) $(st_peek "$ST_DIR/err.txt")"; fi
}
st_detect_key() {   # st_detect_key NAME FILE KEY VALUE
    st_exec --detect "$2"
    _sk=$(sed -n "s/^$3=//p" "$ST_DIR/out.txt")
    if [ "$_sk" = "$4" ]; then st_pass "detect  $1 ($3=$4)"; else st_fail "detect  $1" "expected $3=$4, got '$_sk'"; fi
}
st_dry() {      # st_dry TARGET FILE : the planned commands must use the right toolchain
    st_exec --dry-run --target "$1" "$2"
    if [ "$ST_RC" -ne 0 ]; then st_fail "dry-run $1" "rc=$ST_RC $(st_peek "$ST_DIR/err.txt")"; return 0; fi
    if host_runs_natively "$1"; then
        if grep -Eq '^\[BUILD\] (as|clang|cc|nasm) ' "$ST_DIR/err.txt"; then st_pass "dry-run $1 (native commands)"; else st_fail "dry-run $1" "no native build line"; fi
        return 0
    fi
    _sy_ok=0
    for _sy_p in $(tgt_prefixes "$1"); do
        if grep -q "^\[BUILD\] $_sy_p-as " "$ST_DIR/err.txt"; then _sy_ok=1; fi
    done
    if [ "$_sy_ok" -eq 1 ]; then st_pass "dry-run $1 (cross commands)"; else st_fail "dry-run $1" "no cross assembler line: $(st_peek "$ST_DIR/err.txt")"; fi
}
st_run() {      # st_run NAME FILE EXPECTED_STDOUT EXPECTED_RC [asmrun options...]
    _sr_n=$1; _sr_f=$2; _sr_eo=$3; _sr_rc=$4; shift 4
    st_exec "$@" "$_sr_f"
    if [ "$ST_RC" -eq "$_sr_rc" ] && [ "$(cat "$ST_DIR/out.txt")" = "$_sr_eo" ]; then st_pass "$_sr_n (exit $_sr_rc, output ok)"
    else st_fail "$_sr_n" "expected rc=$_sr_rc out='$_sr_eo'; got rc=$ST_RC out='$(st_peek "$ST_DIR/out.txt")' err: $(st_peek "$ST_DIR/err.txt")"; fi
}

st_samples() {
# ---- detection-only samples (all architectures) ----
st_w d_nasm64.asm <<'EOF'
section .data
msg db "hi", 10
section .text
global _start
_start:
    mov rax, 60
    xor rdi, rdi
    syscall
EOF
st_w d_nasm32.asm <<'EOF'
section .text
global _start
_start:
    mov eax, 1
    xor ebx, ebx
    int 0x80
EOF
st_w d_gas64.s <<'EOF'
.globl _start
_start:
    movq $60, %rax
    xorq %rdi, %rdi
    syscall
EOF
st_w d_gas32.s <<'EOF'
.globl _start
_start:
    movl $1, %eax
    xorl %ebx, %ebx
    int $0x80
EOF
st_w d_intel.s <<'EOF'
.intel_syntax noprefix
.globl _start
_start:
    mov rax, 60
    syscall
EOF
st_w d_arm64.s <<'EOF'
.globl _start
_start:
    mov x0, #0
    mov x8, #93
    svc #0
EOF
st_w d_arm64_polluted.s <<'EOF'
// x86 original: mov rax, 1 ; mov rdi, 1 ; syscall ; eax ebx ecx edx esi edi rsp rbp
/* mov eax, 4 ; int 0x80 ; xmm0 */
.globl _start
_start:
    mov x0, #0
    mov x8, #93
    svc #0
EOF
st_w d_arm32.s <<'EOF'
.globl _start
_start:
    mov r0, #0
    mov r7, #1
    swi 0
EOF
st_w d_thumb.s <<'EOF'
.syntax unified
.thumb
.thumb_func
func:
    push {r4, lr}
    pop {r4, pc}
EOF
st_w d_riscv.s <<'EOF'
.globl _start
_start:
    li a0, 0
    li a7, 93
    ecall
EOF
st_w d_ppc.s <<'EOF'
.globl _start
_start:
    li 0, 1
    li 3, 0
    sc
EOF
st_w d_s390x.s <<'EOF'
.globl _start
_start:
    lghi %r1, 1
    lghi %r2, 0
    svc 0
EOF
st_w d_mips.s <<'EOF'
.set noreorder
.globl _start
_start:
    li $v0, 5058
    li $a0, 0
    syscall
EOF
st_w d_loong.s <<'EOF'
.globl _start
_start:
    li.w $a7, 93
    li.w $a0, 0
    syscall 0
EOF
st_w d_umain.s <<'EOF'
.globl _start
_start:
    call _main
    movq $60, %rax
    xorq %rdi, %rdi
    syscall
_main:
    ret
EOF
# ---- runtime samples: each prints selftest-<x> and exits with status 7 ----
st_w s_gas64.s <<'EOF'
.globl _start
.text
_start:
    movq $1, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $len, %rdx
    syscall
    movq $60, %rax
    movq $7, %rdi
    syscall
.data
msg: .ascii "selftest-gas64\n"
.set len, . - msg
EOF
st_w s_gas32.s <<'EOF'
.globl _start
.text
_start:
    movl $4, %eax
    movl $1, %ebx
    movl $msg, %ecx
    movl $len, %edx
    int $0x80
    movl $1, %eax
    movl $7, %ebx
    int $0x80
.data
msg: .ascii "selftest-int80\n"
.set len, . - msg
EOF
st_w s_nasm64.asm <<'EOF'
section .data
msg db "selftest-nasm64", 10
len equ $ - msg
section .text
global _start
_start:
    mov rax, 1
    mov rdi, 1
    mov rsi, msg
    mov rdx, len
    syscall
    mov rax, 60
    mov rdi, 7
    syscall
EOF
st_w s_nasm32.asm <<'EOF'
section .data
msg db "selftest-nasm32", 10
len equ $ - msg
section .text
global _start
_start:
    mov eax, 4
    mov ebx, 1
    mov ecx, msg
    mov edx, len
    int 0x80
    mov eax, 1
    mov ebx, 7
    int 0x80
EOF
st_w s_libc.s <<'EOF'
.globl main
.text
main:
    subq $8, %rsp
    leaq msg(%rip), %rdi
    call puts
    addq $8, %rsp
    movl $7, %eax
    ret
.data
msg: .asciz "selftest-libc"
EOF
st_w s_cpp.S <<'EOF'
#define EXIT_CODE 7
.globl _start
.text
_start:
    movq $60, %rax
    movq $EXIT_CODE, %rdi
    syscall
EOF
st_w s_recover.s <<'EOF'
.globl _start
.text
_start:
    movl $-5, %edi
    call abs
    movl %eax, %edi
    movl $60, %eax
    syscall
EOF
st_w s_a64.s <<'EOF'
.globl _start
.text
_start:
    mov x0, #1
    adr x1, msg
    mov x2, #15
    mov x8, #64
    svc #0
    mov x0, #7
    mov x8, #93
    svc #0
.data
msg: .ascii "selftest-arm64\n"
EOF
st_w s_a32.s <<'EOF'
.globl _start
.text
_start:
    mov r0, #1
    ldr r1, =msg
    mov r2, #15
    mov r7, #4
    svc #0
    mov r0, #7
    mov r7, #1
    svc #0
.data
msg: .ascii "selftest-arm32\n"
EOF
st_w s_rv64.s <<'EOF'
.globl _start
.text
_start:
    li a0, 1
    la a1, msg
    li a2, 17
    li a7, 64
    ecall
    li a0, 7
    li a7, 93
    ecall
.data
msg: .ascii "selftest-riscv64\n"
EOF
st_w s_mx64.s <<'EOF'
.globl _start
.text
_start:
    movq $0x2000004, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $16, %rdx
    syscall
    movq $0x2000001, %rax
    movq $7, %rdi
    syscall
.data
msg: .ascii "selftest-macx64\n"
EOF
st_w s_marm.s <<'EOF'
.globl _start
.p2align 2
_start:
    mov x0, #1
    adrp x1, msg@PAGE
    add x1, x1, msg@PAGEOFF
    mov x2, #16
    mov x16, #4
    svc #0x80
    mov x0, #7
    mov x16, #1
    svc #0x80
.data
msg: .ascii "selftest-macarm\n"
EOF
st_w s_bad.s <<'EOF'
this is definitely not assembly source !!!
EOF
st_w s_argc.s <<'EOF'
.globl _start
.text
_start:
    movq (%rsp), %rdi
    movq $60, %rax
    syscall
EOF
}

do_selftest() {
    ST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/asmrun-selftest.XXXXXX" 2>/dev/null) || die "Cannot create a self-test directory"
    ST_KEEP=0
    say "$PROG $VERSION self test"
    say "host: $OS / $HOST ($HOST_BITS-bit)"
    st_samples

    st_sect "detection engine (needs no tools)"
    st_detect nasm64          d_nasm64.asm      x86 64 nasm
    st_detect nasm32          d_nasm32.asm      x86 32 nasm
    st_detect gas64           d_gas64.s         x86 64 gas
    st_detect gas32           d_gas32.s         x86 32 gas
    st_detect gas-intel       d_intel.s         x86 64 gas
    st_detect arm64           d_arm64.s         arm64 64 gas
    st_detect arm64+x86-comments d_arm64_polluted.s arm64 64 gas
    st_detect arm32           d_arm32.s         arm32 32 gas
    st_detect thumb           d_thumb.s         arm32 32 gas
    st_detect riscv64         d_riscv.s         riscv 64 gas
    st_detect ppc64le         d_ppc.s           ppc 64 gas
    st_detect s390x           d_s390x.s         s390x 64 gas
    st_detect mips64el        d_mips.s          mips 64 gas
    st_detect loongarch64     d_loong.s         loong 64 gas
    if [ "$OS" = linux ]; then st_detect_key "_main is not C main on Linux" d_umain.s c_main no; fi

    st_sect "command construction (--dry-run; needs no tools)"
    if [ "$OS" = linux ]; then
        st_w d_any.s <<'EOF'
.globl _start
_start:
    nop
EOF
        for _st_t in $ALL_TARGETS; do st_dry "$_st_t" d_any.s; done
        st_exec --dry-run --target mips64el d_mips.s
        if grep -q -- '-e _start' "$ST_DIR/err.txt"; then st_pass "dry-run mips64el passes -e _start"; else st_fail "dry-run mips64el entry flag" "$(st_peek "$ST_DIR/err.txt")"; fi
        st_exec --dry-run --target aarch64 --as-flags "-mcpu=neoverse-n1" --ld-flags "-static" d_arm64.s
        if grep -q -- '-mcpu=neoverse-n1' "$ST_DIR/err.txt" && grep -q -- ' -static ' "$ST_DIR/err.txt"; then st_pass "dry-run passes --as-flags/--ld-flags through"; else st_fail "dry-run extra flags" "$(st_peek "$ST_DIR/err.txt")"; fi
        st_exec --dry-run --target riscv64 --march rv64gcv d_riscv.s
        if grep -q -- '-march=rv64gcv' "$ST_DIR/err.txt"; then st_pass "dry-run --march reaches the assembler"; else st_fail "dry-run --march" "$(st_peek "$ST_DIR/err.txt")"; fi
    else
        st_exec --dry-run --target riscv64 d_riscv.s
        if [ "$ST_RC" -eq 1 ]; then st_pass "cross targets are refused on macOS (by design)"; else st_fail "macOS cross refusal" "rc=$ST_RC"; fi
        st_exec --dry-run d_gas64.s
        if grep -q '^\[BUILD\] clang -arch ' "$ST_DIR/err.txt"; then st_pass "dry-run macOS uses clang -arch"; else st_fail "macOS dry-run" "$(st_peek "$ST_DIR/err.txt")"; fi
    fi

    st_sect "build + run on this machine"
    _st_main=""; _st_main_out=""
    case "$OS:$HOST:$HOST_BITS" in
        linux:x86:64)
            _st_main=s_gas64.s;  _st_main_out="selftest-gas64"
            st_run "gas64 (as + ld)" s_gas64.s "$_st_main_out" 7
            st_exec s_gas32.s
            if [ "$ST_RC" -eq 126 ] || [ "$ST_RC" -eq 127 ]; then st_skip "int80 (this kernel/container cannot run 32-bit programs)"
            elif [ "$ST_RC" -eq 7 ] && [ "$(cat "$ST_DIR/out.txt")" = "selftest-int80" ]; then st_pass "int80 32-bit (as --32 + ld -m elf_i386) (exit 7, output ok)"
            else st_fail "int80 32-bit" "rc=$ST_RC $(st_peek "$ST_DIR/err.txt")"; fi
            if command -v nasm >/dev/null 2>&1; then
                st_run "nasm64" s_nasm64.asm selftest-nasm64 7
                st_exec s_nasm32.asm
                if [ "$ST_RC" -eq 126 ] || [ "$ST_RC" -eq 127 ]; then st_skip "nasm32 (cannot run 32-bit programs here)"
                elif [ "$ST_RC" -eq 7 ] && [ "$(cat "$ST_DIR/out.txt")" = "selftest-nasm32" ]; then st_pass "nasm32 (exit 7, output ok)"
                else st_fail "nasm32" "rc=$ST_RC $(st_peek "$ST_DIR/err.txt")"; fi
            else st_skip "nasm64 / nasm32 (nasm not installed)"; fi
            if find_cc; then
                st_run "libc main via C driver" s_libc.s selftest-libc 7
                st_run ".S with C preprocessor" s_cpp.S "" 7
                st_run "auto-recovery: unresolved libc symbol -> relink with libc" s_recover.s "" 5
            else st_skip "libc / .S / auto-recovery (no C compiler installed)"; fi ;;
        linux:arm64:64) _st_main=s_a64.s; _st_main_out="selftest-arm64"; st_run "aarch64 native" s_a64.s "$_st_main_out" 7 ;;
        linux:arm32:32) _st_main=s_a32.s; _st_main_out="selftest-arm32"; st_run "armv7 native" s_a32.s "$_st_main_out" 7 ;;
        linux:riscv:64) _st_main=s_rv64.s; _st_main_out="selftest-riscv64"; st_run "riscv64 native" s_rv64.s "$_st_main_out" 7 ;;
        linux:x86:32)   _st_main=s_gas32.s; _st_main_out="selftest-int80"; st_run "i386 native" s_gas32.s "$_st_main_out" 7 ;;
        macos:x86:*)    _st_main=s_mx64.s; _st_main_out="selftest-macx64"; st_run "macOS x86-64" s_mx64.s "$_st_main_out" 7 ;;
        macos:arm64:*)
            _st_main=s_marm.s; _st_main_out="selftest-macarm"; st_run "macOS arm64" s_marm.s "$_st_main_out" 7
            if rosetta_ok; then st_run "macOS x86-64 via Rosetta" s_mx64.s selftest-macx64 7 --target x86_64; else st_skip "macOS x86-64 via Rosetta (Rosetta not installed)"; fi ;;
        *) st_skip "no runtime sample for host $OS/$HOST yet (see 'Extending' in asmrun-v6.md - contributions welcome)" ;;
    esac

    if [ -n "$_st_main" ]; then
        st_sect "robustness"
        mkdir -p "$ST_DIR/dir with space"; cp "$ST_DIR/$_st_main" "$ST_DIR/dir with space/my prog.s"
        st_run "path with spaces" "dir with space/my prog.s" "$_st_main_out" 7
        st_exec "$_st_main"
        if [ -s "$ST_DIR/err.txt" ] && [ "$(cat "$ST_DIR/out.txt")" = "$_st_main_out" ] && grep -q '^\[BUILD\]' "$ST_DIR/err.txt"; then st_pass "program output on stdout, [BUILD] diagnostics on stderr"; else st_fail "stdout/stderr separation"; fi
        st_exec -o "$_st_main" "$_st_main"
        if [ "$ST_RC" -ne 0 ] && [ "$(cat "$ST_DIR/$_st_main")" != "" ] && grep -q selftest "$ST_DIR/$_st_main"; then st_pass "refuses -o equal to the source file"; else st_fail "-o == source guard" "rc=$ST_RC"; fi
        st_exec --asm-only -o t.o "$_st_main"
        if [ "$ST_RC" -eq 0 ] && [ -s "$ST_DIR/t.o" ]; then st_pass "--asm-only writes the object file"; else st_fail "--asm-only" "$(st_peek "$ST_DIR/err.txt")"; fi
        st_exec --link-only -o t.exe "$_st_main"
        if [ "$ST_RC" -eq 0 ] && [ -x "$ST_DIR/t.exe" ] && [ ! -s "$ST_DIR/out.txt" ]; then st_pass "--link-only builds without running"; else st_fail "--link-only" "$(st_peek "$ST_DIR/err.txt")"; fi
        st_exec --report ok.json "$_st_main"
        if grep -q '"status": "ran"' "$ST_DIR/ok.json" 2>/dev/null && grep -q '"build_commands"' "$ST_DIR/ok.json"; then st_pass "JSON report on success"; else st_fail "report (success)"; fi
        st_exec --report bad.json s_bad.s
        if [ "$ST_RC" -ne 0 ] && grep -q '"status": "build-failed"' "$ST_DIR/bad.json" 2>/dev/null; then st_pass "JSON report is also written when the build fails"; else st_fail "report (failure)" "rc=$ST_RC"; fi
        if command -v python3 >/dev/null 2>&1; then
            if python3 -c 'import json,sys; json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))' "$ST_DIR/ok.json" "$ST_DIR/bad.json" 2>/dev/null; then st_pass "reports are valid JSON"; else st_fail "report JSON validity"; fi
        fi
        if [ "$OS:$HOST" = linux:x86 ]; then
            st_exec s_argc.s a "b c" d
            if [ "$ST_RC" -eq 4 ]; then st_pass "program arguments are forwarded intact (argc=4)"; else st_fail "argument forwarding" "rc=$ST_RC"; fi
        fi
        printf '\n\n' | ( cd "$ST_DIR" && ASMRUN_NO_RC=1 NO_COLOR=1 sh "$SELF" "$_st_main" >/dev/null 2>&1 ); _st_x=$?
        if [ "$_st_x" -eq 7 ]; then st_pass "no prompt ever blocks a piped run"; else st_fail "piped run" "rc=$_st_x"; fi
    fi

    st_sect "cross execution (needs a cross toolchain + qemu-user; otherwise skipped)"
    if [ "$OS" = linux ]; then
        for _st_t in aarch64 armv7 riscv64; do
            if host_runs_natively "$_st_t"; then continue; fi
            case "$_st_t" in aarch64) _st_s=s_a64.s; _st_o=selftest-arm64 ;; armv7) _st_s=s_a32.s; _st_o=selftest-arm32 ;; riscv64) _st_s=s_rv64.s; _st_o=selftest-riscv64 ;; esac
            _st_p=$(cross_prefix_for "$_st_t" as)
            if command -v "$_st_p-as" >/dev/null 2>&1 && command -v "$(cross_prefix_for "$_st_t" ld)-ld" >/dev/null 2>&1 && { find_qemu "$_st_t" || binfmt_ok "$_st_t"; }; then
                st_run "cross $_st_t" "$_st_s" "$_st_o" 7 --target "$_st_t"
            else st_skip "cross $_st_t (needs $_st_p-as/-ld and $(tgt_qemu "$_st_t"))"; fi
        done
    else st_skip "cross execution (Linux only)"; fi

    say ""
    if [ "$ST_FAIL" -eq 0 ]; then good "self test: $ST_PASS passed, 0 failed, $ST_SKIP skipped"; _st_ret=0
    else err "self test: $ST_PASS passed, $ST_FAIL FAILED, $ST_SKIP skipped"; _st_ret=1; fi
    return $_st_ret
}

# ==============================================================================
#  9. Configuration (parsed as DATA, never sourced - I12) and main flow
# ==============================================================================
RC_FLAGS=""
rc_unquote() {
    case "$1" in
        \"*\") _ru=${1#\"}; printf '%s' "${_ru%\"}" ;;
        \'*\') _ru=${1#\'}; printf '%s' "${_ru%\'}" ;;
        *)     printf '%s' "$1" ;;
    esac
}
# rc_add "LINE" TRUSTED(1|0): a project-local config may only set harmless options.
rc_add() {
    if [ "$2" = 1 ]; then RC_FLAGS="$RC_FLAGS $1"; return 0; fi
    _ra_skip=0
    for _ra_t in $1; do
        case "$_ra_skip" in
            1) RC_FLAGS="$RC_FLAGS $_ra_t"; _ra_skip=0; continue ;;
            2) _ra_skip=0; continue ;;
        esac
        case "$_ra_t" in
            -v|--verbose|--nasm|--gas|--as|--32|--64|--keep-build-dir|--keep|--no-color|-g|--debug) RC_FLAGS="$RC_FLAGS $_ra_t" ;;
            --arch|--target|--timeout|--march) RC_FLAGS="$RC_FLAGS $_ra_t"; _ra_skip=1 ;;
            --arch=*|--target=*|--timeout=*|--march=*) RC_FLAGS="$RC_FLAGS $_ra_t" ;;
            -o|--output|--cc|--report|--as-flags|--ld-flags|--cc-flags|--nasm-flags|--qemu-flags)
                warn "Ignoring '$_ra_t' from ./.asmrunrc (not allowed in a project-local config; use ~/.asmrunrc)"; _ra_skip=2 ;;
            *)  warn "Ignoring '$_ra_t' from ./.asmrunrc (not allowed in a project-local config; use ~/.asmrunrc)" ;;
        esac
    done
}
rc_read() {     # rc_read FILE TRUSTED
    if [ -f "$1" ] && [ -r "$1" ]; then :; else return 0; fi
    while IFS= read -r _rr_l || [ -n "$_rr_l" ]; do
        _rr_l=$(printf '%s' "$_rr_l" | tr -d '\r')
        _rr_l=${_rr_l#"${_rr_l%%[![:space:]]*}"}
        case "$_rr_l" in
            ''|'#'*) continue ;;
            ASMRUN_FLAGS=*) rc_add "$(rc_unquote "${_rr_l#ASMRUN_FLAGS=}")" "$2" ;;
            ASMRUN_CC=*)
                if [ "$2" = 1 ] && [ -z "${ASMRUN_CC:-}" ]; then ASMRUN_CC=$(rc_unquote "${_rr_l#ASMRUN_CC=}"); export ASMRUN_CC; fi ;;
            -*) rc_add "$_rr_l" "$2" ;;
            *)  : ;;
        esac
    done <"$1"
}
load_config() {
    [ -z "${ASMRUN_NO_RC:-}" ] || return 0
    _lc_home=${HOME:-}
    if [ -n "$_lc_home" ]; then
        rc_read "$_lc_home/.asmrunrc" 1
        rc_read "${XDG_CONFIG_HOME:-$_lc_home/.config}/asmrun/config" 1
    fi
    rc_read "./.asmrunrc" 0
}

# Absolute path of this script (the selftest re-invokes it).
resolve_self() {
    SELF=$0
    case "$SELF" in
        */*) _rs_d=$(abs_dir "$(dirname -- "$SELF")"); [ -n "$_rs_d" ] && SELF="$_rs_d/$(basename -- "$SELF")" ;;
        *)   _rs_p=$(command -v "$SELF" 2>/dev/null) && [ -n "$_rs_p" ] && SELF=$_rs_p ;;
    esac
}

# value-taking option helper: sets _ov to the value and _osh to how many args to shift
need_val() { # need_val OPT COUNT_OF_REMAINING_ARGS
    if [ "$2" -lt 2 ]; then usage_die "Option $1 needs a value"; fi
}

main() {
    SELF=$0; ST_DIR=""; ST_KEEP=0
    load_config
    # config files and ASMRUN_FLAGS come first so the command line wins
    set -- $RC_FLAGS ${ASMRUN_FLAGS:-} "$@"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)        usage; exit 0 ;;
            --version)        out "$PROG $VERSION"; exit 0 ;;
            -v|--verbose)     VERBOSE=1; shift ;;
            -y|--yes)         ASSUME_YES=1; shift ;;
            -g|--debug)       DEBUG_INFO=1; shift ;;
            --no-color)       NO_COLOR_FLAG=1; shift ;;
            --asm-only)       ASM_ONLY=1; shift ;;
            --link-only|--no-run) LINK_ONLY=1; shift ;;
            --keep-build-dir|--keep) KEEP_BUILD=1; shift ;;
            --dry-run)        DRY_RUN=1; shift ;;
            --detect)         DETECT_ONLY=1; shift ;;
            --doctor)         DO_DOCTOR=1; shift ;;
            --list-targets)   LIST_TARGETS=1; shift ;;
            --selftest)       SELFTEST=1; shift ;;
            --nasm)           FORCE_SYNTAX=nasm; shift ;;
            --gas|--as)       FORCE_SYNTAX=gas; shift ;;
            --32)             FORCE_BITS=32; shift ;;
            --64)             FORCE_BITS=64; shift ;;
            -o|--output)      need_val "$1" $#; OUT=$2; shift 2 ;;
            --output=*)       OUT=${1#--output=}; shift ;;
            --arch)           need_val "$1" $#; FORCE_ARCH=$2; shift 2 ;;
            --arch=*)         FORCE_ARCH=${1#--arch=}; shift ;;
            --target)         need_val "$1" $#; FORCE_TARGET=$2; shift 2 ;;
            --target=*)       FORCE_TARGET=${1#--target=}; shift ;;
            --cc)             need_val "$1" $#; FORCE_CC=$2; shift 2 ;;
            --cc=*)           FORCE_CC=${1#--cc=}; shift ;;
            --march)          need_val "$1" $#; MARCH_OPT=$2; shift 2 ;;
            --march=*)        MARCH_OPT=${1#--march=}; shift ;;
            --as-flags)       need_val "$1" $#; X_AS=$2; shift 2 ;;
            --as-flags=*)     X_AS=${1#--as-flags=}; shift ;;
            --ld-flags)       need_val "$1" $#; X_LD=$2; shift 2 ;;
            --ld-flags=*)     X_LD=${1#--ld-flags=}; shift ;;
            --cc-flags)       need_val "$1" $#; X_CC=$2; shift 2 ;;
            --cc-flags=*)     X_CC=${1#--cc-flags=}; shift ;;
            --nasm-flags)     need_val "$1" $#; X_NASM=$2; shift 2 ;;
            --nasm-flags=*)   X_NASM=${1#--nasm-flags=}; shift ;;
            --qemu-flags)     need_val "$1" $#; X_QEMU=$2; shift 2 ;;
            --qemu-flags=*)   X_QEMU=${1#--qemu-flags=}; shift ;;
            --timeout)        need_val "$1" $#; TIMEOUT=$2; shift 2 ;;
            --timeout=*)      TIMEOUT=${1#--timeout=}; shift ;;
            --report)         need_val "$1" $#; REPORT=$2; shift 2 ;;
            --report=*)       REPORT=${1#--report=}; shift ;;
            --)               shift; break ;;
            -*)               usage_die "Unknown option: $1" ;;
            *)                break ;;
        esac
    done
    init_colors

    # ---- modes that need no source file ---------------------------------------
    if [ "$LIST_TARGETS" -eq 1 ]; then do_list_targets; exit 0; fi
    resolve_self
    detect_host
    if [ "$DO_DOCTOR" -eq 1 ]; then do_doctor; exit 0; fi
    if [ "$SELFTEST" -eq 1 ]; then do_selftest; exit $?; fi

    # ---- the source file -------------------------------------------------------
    if [ $# -lt 1 ]; then usage >&2; exit 2; fi
    FILE=$1; shift
    if [ ! -e "$FILE" ]; then usage_die "File does not exist: $FILE"; fi
    if [ -d "$FILE" ]; then usage_die "'$FILE' is a directory, not an assembly file."; fi
    if [ ! -r "$FILE" ]; then die "Cannot read '$FILE' (permission denied)."; fi
    if [ ! -s "$FILE" ]; then die "'$FILE' is empty."; fi
    case "$FILE" in -*) FILE="./$FILE" ;; esac
    if looks_binary "$FILE"; then die "'$FILE' looks like a binary file (NUL bytes), not assembly source."; fi

    # ---- option sanity ---------------------------------------------------------------
    case "$TIMEOUT" in ''|*[!0-9]*) usage_die "--timeout needs a whole number of seconds" ;; esac
    if [ "$ASM_ONLY" -eq 1 ] && [ "$LINK_ONLY" -eq 1 ]; then usage_die "--asm-only and --link-only cannot be combined."; fi
    if [ -n "$FORCE_ARCH" ]; then
        _m_a=$(fam_norm "$FORCE_ARCH"); [ -n "$_m_a" ] || usage_die "Unknown --arch '$FORCE_ARCH' (use: $ALL_FAMILIES)"
        FORCE_ARCH=$_m_a
    fi
    if [ -n "$FORCE_TARGET" ]; then
        _m_t=$(tgt_norm "$FORCE_TARGET"); [ -n "$_m_t" ] || usage_die "Unknown --target '$FORCE_TARGET' (use: $ALL_TARGETS)"
        FORCE_TARGET=$_m_t
        if [ -n "$FORCE_ARCH" ] && [ "$FORCE_ARCH" != "$(tgt_family "$FORCE_TARGET")" ]; then
            usage_die "--arch $FORCE_ARCH contradicts --target $FORCE_TARGET"
        fi
        if [ -n "$FORCE_BITS" ] && [ "$FORCE_BITS" != "$(tgt_bits "$FORCE_TARGET")" ]; then
            usage_die "--$FORCE_BITS contradicts --target $FORCE_TARGET"
        fi
    fi
    if [ -n "$OUT" ] && same_file "$OUT" "$FILE"; then die "Output path '$OUT' is the source file - refusing to overwrite it."; fi
    if [ -n "$REPORT" ]; then
        if same_file "$REPORT" "$FILE"; then die "Report path '$REPORT' is the source file - refusing to overwrite it."; fi
        if [ -n "$OUT" ] && same_file "$REPORT" "$OUT"; then die "Report path and output path are the same file."; fi
        _m_rd=$(dirname -- "$REPORT")
        if [ ! -d "$_m_rd" ] || [ ! -w "$_m_rd" ]; then die "Report directory '$_m_rd' does not exist or is not writable."; fi
    fi
    REPORT_READY=1
    STATUS=analysing

    make_workdir

    # ---- analysis ---------------------------------------------------------------------
    ANA_GEN="$WORK/analysis.generic"
    if sanitize_source generic "$FILE" "$ANA_GEN" && [ -f "$ANA_GEN" ]; then ANA=$ANA_GEN; else ANA=""; info "sanitiser unavailable; analysing the raw file"; fi

    if [ -n "$FORCE_TARGET" ]; then SRC=$(tgt_family "$FORCE_TARGET")
    elif [ -n "$FORCE_ARCH" ]; then SRC=$FORCE_ARCH
    else detect_arch; fi
    case " $ALL_FAMILIES " in
        *" $SRC "*) : ;;
        *)  die "No recognisable instructions found, and this machine's CPU ($HOST) is not a supported family. Tell asmrun the architecture with --arch (one of: $ALL_FAMILIES)." ;;
    esac
    if [ -z "$FORCE_TARGET" ] && [ -z "$FORCE_ARCH" ] && [ "${_da_best:-0}" -eq 0 ]; then
        info "no architecture signals in the file - assuming this machine's ($(arch_label "$SRC"))"
    fi

    if [ -n "$ANA" ]; then
        if sanitize_source "$SRC" "$FILE" "$WORK/analysis.family" && [ -f "$WORK/analysis.family" ]; then ANA="$WORK/analysis.family"; fi
    fi

    BITS=$(fam_bits "$SRC")
    SYNTAX=gas
    if [ "$SRC" = x86 ]; then
        BITS=64
        if [ -n "$FORCE_SYNTAX" ]; then SYNTAX=$FORCE_SYNTAX; SYNTAX_FIRM=1; SYNTAX_VOTES="forced"; else detect_syntax; fi
        if [ -n "$FORCE_TARGET" ]; then BITS=$(tgt_bits "$FORCE_TARGET"); BITS_FIRM=1; BITS_VOTES="forced(target)"
        elif [ -n "$FORCE_BITS" ]; then BITS=$FORCE_BITS; BITS_FIRM=1; BITS_VOTES="forced"
        else detect_bits; fi
    else
        if [ "$FORCE_SYNTAX" = nasm ]; then die "NASM only assembles x86 code; this file is $(arch_label "$SRC"). Use --gas or drop --nasm."; fi
        if [ -n "$FORCE_BITS" ]; then warn "--$FORCE_BITS is only meaningful for x86; ignored for $(arch_label "$SRC")."; fi
        SYNTAX_FIRM=1; BITS_FIRM=1
    fi
    if [ "$SYNTAX" = nasm ]; then
        case "$FILE" in *.S) die "NASM cannot read .S files (they need the C preprocessor and GNU as). Use --gas." ;; esac
    fi

    # 16-bit / foreign assemblers: say so instead of failing mysteriously
    if [ "$SRC" = x86 ]; then
        if has '^[[:space:]]*(org[[:space:]]+(0x)?7c00|[[]bits 16[]]|[.]code16|[.]model[[:space:]]|[.](386|486|586|686)[[:space:]]*$|^[[:space:]]*[A-Za-z_@$?][A-Za-z0-9_@$?]*[[:space:]]+(proc|endp)([[:space:]]|$)|^[[:space:]]*(include(lib)?|assume)[[:space:]])'; then
            if [ -z "$FORCE_SYNTAX" ] && [ "$BITS" -ne 16 ]; then
                if has '^[[:space:]]*(org[[:space:]]+(0x)?7c00|[[]bits 16[]])'; then
                    die "This is 16-bit real-mode code (boot sector / DOS). Linux/macOS cannot run it; assemble with 'nasm -f bin' and run it in QEMU: qemu-system-x86_64 -drive format=raw,file=boot.bin"
                fi
                if has '^[[:space:]]*(assume|[.]model|include(lib)?)[[:space:]]|[[:space:]](proc|endp)([[:space:]]|$)'; then
                    die "This looks like MASM/TASM (Windows/DOS) source. asmrun supports NASM and GNU as; port it, or use UASM/JWasm."
                fi
            fi
        fi
        if has '^[[:space:]]*format[[:space:]]+(elf|pe|mz|binary)|^[[:space:]]*segment[[:space:]]+(readable|writeable|executable)'; then
            die "This looks like FASM source, which asmrun does not support. Convert it to NASM or GNU as syntax."
        fi
    fi

    detect_entry_libc_cpp
    detect_ext
    TARGET_ID=${FORCE_TARGET:-$(fam_tgt "$SRC" "$BITS")}
    case "$SYNTAX:$SRC" in
        nasm:*) SYNTAX_LABEL="NASM" ;;
        gas:x86) if has '[.]intel_syntax'; then SYNTAX_LABEL="GNU as (Intel)"; else SYNTAX_LABEL="GNU as (AT&T)"; fi ;;
        *) SYNTAX_LABEL="GNU as" ;;
    esac
    info "detected: $(arch_label "$SRC") $BITS-bit, $SYNTAX_LABEL, entry=$(entry_symbol), libc=$USES_LIBC, cpp=$CPP${EXTS:+, ext=$EXTS}"

    if [ "$DETECT_ONLY" -eq 1 ]; then STATUS=detected; print_detect; exit 0; fi

    # ---- plan ---------------------------------------------------------------------------
    STATUS=planning
    preflight_warnings
    plan_all
    resolve_paths
    if [ "$TIMEOUT" -gt 0 ]; then
        if find_timeout; then
            TIMEOUT_FG=""
            if "$TIMEOUT_BIN" --foreground 1 true >/dev/null 2>&1; then TIMEOUT_FG="--foreground"; fi
        else
            warn "--timeout needs 'timeout' (GNU coreutils); not found, so no time limit is applied.$([ "$OS" = macos ] && echo " Install it with: brew install coreutils")"
            TIMEOUT=0
        fi
    fi

    # ---- tools ----------------------------------------------------------------------------
    if [ "$DRY_RUN" -eq 1 ]; then
        _dr_miss=""
        for _dr_t in $REQUIRED; do tool_ok "$_dr_t" || _dr_miss="$_dr_miss $(tool_label "$_dr_t")"; done
        if [ -n "$_dr_miss" ]; then say "${DIM}[NOTE] dry run - not installed here:${_dr_miss}${NC}"; MISSING=${_dr_miss# }; fi
    else
        ensure_tools
        plan_all                      # tools may have appeared (e.g. a C driver): re-derive the plan
        if [ "$ASM_ONLY" -eq 0 ] && [ "$LINK_ONLY" -eq 0 ]; then ensure_runner; fi
    fi

    # ---- build ------------------------------------------------------------------------------
    STATUS=building
    do_build
    post_build

    if [ "$DRY_RUN" -eq 1 ]; then STATUS=dry-run; exit 0; fi
    if [ "$ASM_ONLY" -eq 1 ]; then STATUS=built; exit 0; fi
    if [ -n "$OUT" ] || [ "$LINK_ONLY" -eq 1 ]; then say "${DIM}[OUT] executable: $RUN${NC}"; fi
    if [ "$LINK_ONLY" -eq 1 ]; then STATUS=built; exit 0; fi
    if [ "$NO_RUN" -eq 1 ]; then
        STATUS=built-not-run
        ERR_MSG="built, but no way to run $(tgt_label "$TARGET_ID") code on this machine"
        warn "Built $RUN but cannot run it here (no qemu-user). Install: $(install_hint qemu)"
        [ -n "$OUT" ] || KEEP_BUILD=1
        exit 1
    fi

    run_phase "$@"
    exit "$RC"
}

main "$@"
