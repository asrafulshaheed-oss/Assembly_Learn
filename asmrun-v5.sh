#!/bin/sh
# ==============================================================================
#  asmrun v5 - assemble, link and run a hand-written assembly file in one shot
# ==============================================================================
#  Usage   : asmrun [options] <file> [program arguments...]
#            asmrun --target aarch64 --link-only file.s
#            asmrun --asm-only -o file.o file.s
#
#  Systems : Linux (apt, dnf, yum, pacman, zypper, apk, xbps, ostree, WSL)
#            macOS (Intel and Apple Silicon; Rosetta 2 for x86-64)
#  Syntax  : NASM | GAS AT&T | GAS Intel (.intel_syntax) | .S (C preprocessor)
#  CPUs    : x86-64, i386, ARM64 (AArch64), ARM32 (ARMv7/Thumb-2), RISC-V 64
#  Cross   : Linux -> aarch64 / armv7 / riscv64 / x86_64 / i386 via
#            *-linux-gnu-gcc, *-linux-gnu-as, *-linux-gnu-ld and qemu-user
#  Installs: only the tools the given file actually needs
#
#  Design invariants (see README.md):
#    * build commands match the manual command exactly (no -z noexecstack)
#    * detection is weighted and every detection has an override flag
#    * set -e is never used, so the program's exit code is preserved
#    * [INFO]/[WARN]/[ERROR]/[BUILD] go to stderr; program output to stdout
#    * POSIX sh only (macOS bash 3.2, Alpine ash, BusyBox)
#    * installation results are verified, not trusted
#    * the work directory is noexec-safe
#
#  v5 highlights:
#    * based on v4 (the only version without the -z noexecstack bug)
#    * --target cross-compilation + qemu-user fallback
#    * --asm-only / --link-only / --keep-build-dir
#    * --report FILE (JSON), optional .asmrunrc, --selftest
#    * better ARM32/Thumb-2 and RISC-V detection, ENTRY() parsing
#    * WSL detection, 32-bit multilib auto-install, cpp fallback
# ==============================================================================

set -u

# Keep the script usable from cron/env -i where PATH may be missing.
PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
export PATH

VERSION="5.0.0"
PROG="asmrun"

VERBOSE=0
ASSUME_YES=0
OUT=""
FORCE_SYNTAX=""
FORCE_BITS=""
FORCE_ARCH=""
FORCE_TARGET=""
FORCE_CC=""
KEEP_BUILD=0
ASM_ONLY=0
LINK_ONLY=0
SELFTEST=0
REPORT=""
FILE=""
WORK=""
LOG=""
WORK_PARENT=""
OS=""
WSL=0
HOST=""
HOST_BITS=64
SRC=""
SYNTAX=""
SYNTAX_LABEL=""
BITS=64
HAS_START=0
HAS_PSTART=0
HAS_MAIN=0
HAS_ENTRY=0
USES_LIBC=0
CPP=0
XLANG="assembler"
LINK=""
CPP_MODE=""
CC=""
CC_BIN=""
AS_BIN="as"
LD_BIN="ld"
NASM_BIN="nasm"
CROSS=""
NATIVE=1
TARGET_ID=""
REQUIRED=""
MISSING=""
PKGS=""
NEEDS_MULTILIB=0
QEMU_BIN=""
SYSROOT=""
OBJ=""
EXE=""
OBJ_OUT=""
EXE_OUT=""
ENTRY_NAME=""
ENTRY_FLAG=""
MARCH=""
ASF=""
LDM=""
CCM=""
FMT="elf64"
CCMODE=""
CMD_COUNT=0
CMD1=""
CMD2=""
CMD3=""
RC=0
PM=""
UPD=""
INS=""
SUDO=""
S=""
CAN_AUTO=1
WHY=""

# ---------- colours (stderr is a terminal, NO_COLOR unset) --------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    E=$(printf '\033')
    RED="${E}[1;31m"; GREEN="${E}[1;32m"; YELLOW="${E}[1;33m"
    BLUE="${E}[1;34m"; CYAN="${E}[1;36m"; DIM="${E}[2m"; BOLD="${E}[1m"; NC="${E}[0m"
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; DIM=""; BOLD=""; NC=""
fi

say()  { printf '%s\n' "$*" >&2; }
info() { if [ "$VERBOSE" -eq 1 ]; then printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*" >&2; fi; return 0; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
good() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
    if [ "$KEEP_BUILD" -eq 0 ] && [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup 0
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

usage() {
cat <<'EOF'
Usage: asmrun [options] <file> [program arguments...]

Assembles, links and runs a hand-written assembly file. Syntax (NASM / GAS
AT&T / GAS Intel), CPU architecture, bitness, entry point, libc use and the
C preprocessor are detected automatically. Only the tools that file needs
are installed.

Options (put them BEFORE the file name):
  -v, --verbose         show detection details and every command
  -y, --yes             install missing native tools without prompting
  -o, --output FILE     keep the output at FILE
      --asm-only        assemble only; write the object file and stop
      --link-only       assemble+link, but do not run (alias: --no-run)
      --keep-build-dir  keep the temporary build directory
      --nasm            force NASM syntax
      --gas, --as       force GNU as syntax
      --32 | --64       force 32-bit / 64-bit (x86 only)
      --arch ARCH       force source arch: x86 | arm64 | arm32 | riscv
      --target TARGET   cross-build for: x86_64 | i386 | aarch64 | armv7 | riscv64
      --cc CMD          use CMD as the C compiler/linker driver
      --report FILE     write a JSON build/run report to FILE
      --selftest        run the built-in self test and exit
      --version         print the version and exit
  -h, --help            this help

Anything after the file name is passed to your program as arguments.

Examples:
  asmrun hello.s
  asmrun --32 boot.s
  asmrun --nasm -o hello hello.asm
  asmrun --asm-only -o hello.o hello.s
  asmrun --target aarch64 --link-only hello.s
  asmrun --target aarch64 hello.s        # needs qemu-aarch64 to run

Environment:
  NO_COLOR=1        disable colours
  ASMRUN_NO_RC=1    do not read ~/.asmrunrc or ./.asmrunrc
  ASMRUN_FLAGS=...  extra options, parsed before the command line
  ASMRUN_CC=...     default C compiler/linker driver
EOF
}

# ==============================================================================
#  Source analysis helpers
# ==============================================================================
has() { grep -Eiq -- "$1" "$FILE" 2>/dev/null; }
cnt() { _cnt_n=$(grep -Eic -- "$1" "$FILE" 2>/dev/null); printf '%s' "${_cnt_n:-0}"; }

arch_label() {
    case "$1" in
        x86)   echo "x86 / x86-64" ;;
        arm64) echo "ARM64 (AArch64)" ;;
        arm32) echo "32-bit ARM" ;;
        riscv) echo "RISC-V" ;;
        *)     echo "$1" ;;
    esac
}

# Compare two paths, normalising ./ and ../ and relative vs absolute names.
same_file() {
    [ "$1" = "$2" ] && return 0
    # -ef catches hard links and symlinks on every shell we target.  Ignore
    # implementations where the primary itself is unsupported.
    if [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ] 2>/dev/null; then
        return 0
    fi
    _sf_a=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")
    _sf_b=$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")
    [ -n "$_sf_a" ] && [ "$_sf_a" = "$_sf_b" ]
}

# Weighted vote between x86, ARM64, ARM32 and RISC-V. Ties go to the host.
detect_arch() {
    _da_x=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|bp|sp|ip)|e(ax|bx|cx|dx|si|di|bp|sp|ip)|r(8|9|1[0-5])[dwb]?|[xy]mm[0-9]+)([^[:alnum:]_]|$)|(^|[[:space:]])syscall([[:space:]]|$)|(^|[[:space:]])sysenter([[:space:]]|$)|int[[:space:]]+[$]?(0x80|80h|0x2e|2eh)|[.]intel_syntax|[.]code(16|32|64)|(^|[[:space:]])bits[[:space:]]+(16|32|64)|(^|[[:space:]])(pushad|popad|pushfd|popfd)([[:space:]]|$)|^[[:space:]]*(global|extern|section|segment)[[:space:]]')
    _da_a=$(cnt '(^|[^[:alnum:]_])([xw]([0-9]|[12][0-9]|30)|xzr|wzr)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])(stp|ldp|adrp|adr|cbz|cbnz|tbz|tbnz|csel|cset|svc|hvc|smc|br|blr|eret|mrs|msr)([[:space:]]|$)|[.]arch[[:space:]]+armv8|aarch64|(^|[[:space:]])[.]xword[[:space:]]')
    _da_b=$(cnt '(^|[^[:alnum:]_])r([0-9]|1[0-2])[[:space:]]*(,|[}]|-|$)|(push|pop|stmfd|ldmfd|stmdb|ldmia|stmia)[[:space:]]*[{]|[.]syntax[[:space:]]+unified|(^|[[:space:]])(bx|blx)[[:space:]]+(lr|r[0-9]+)|[.](thumb|thumb_func|arm|cpu)([[:space:]]|$)|(^|[[:space:]])swi[[:space:]]|(^|[[:space:]])(movs|adds|subs|ldrs?|strs?|ldrb|strb|ldrh|strh|bics?|ands?|orrs?|eors?|lsls?|lsrs?|asrs?|adcs?|sbcs?|rsbs?|muls?)[[:space:]]+(r[0-9]|lr|pc|sp|#)|(^|[[:space:]])(ite|itt|itee|it)[[:space:]]')
    _da_r=$(cnt '(^|[^[:alnum:]_.])(ecall|ebreak)([^[:alnum:]_]|$)|(^|[[:space:]])(li|la|lla|mv|not|neg|seqz|snez|sltz|sgtz|addi|add|sub|and|or|xor|slli|srli|srai|slti|sltiu|slt|sltu|lui|auipc|jal|jalr|j|jr|beq|bne|blt|bge|bltu|bgeu|beqz|bnez|blez|bgez|bltz|bgtz|lw|sw|ld|sd|lh|sh|lb|sb|lbu|lhu|csrr?[a-z]*)[[:space:]]+(a[0-7]|t[0-6]|s([0-9]|1[01])|sp|ra|zero|gp|tp)[[:space:]]*,|[.]option[[:space:]]+(rvc|norvc|push|pop)|(^|[[:space:]])c[.](addi|mv|li|add|sub|lw|sw|ld|sd|j|jal|beqz|bnez|nop)([[:space:]]|$)')
    SRC=$HOST
    _da_best=0
    for _da_pair in "x86:$_da_x" "arm64:$_da_a" "arm32:$_da_b" "riscv:$_da_r"; do
        _da_fam=${_da_pair%%:*}
        _da_num=${_da_pair##*:}
        if [ "$_da_num" -gt "$_da_best" ]; then
            SRC=$_da_fam
            _da_best=$_da_num
        elif [ "$_da_num" -eq "$_da_best" ] && [ "$_da_num" -gt 0 ] && [ "$_da_fam" = "$HOST" ]; then
            SRC=$_da_fam
        fi
    done
    info "arch votes: x86=$_da_x arm64=$_da_a arm32=$_da_b riscv=$_da_r -> $SRC"
}

# x86 only: NASM (Intel) vs GNU as (AT&T / .intel_syntax).
detect_syntax() {
    case "$FILE" in *.S) SYNTAX=gas; return 0 ;; esac
    if has '[.]intel_syntax|[.]att_syntax'; then SYNTAX=gas; return 0; fi
    if has '^[[:space:]]*#[[:space:]]*(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)'; then
        SYNTAX=gas
        return 0
    fi
    _ds_nasm=$(cnt '^[[:space:]]*(section|segment)[[:space:]]+[.]|^[[:space:]]*(global|extern)[[:space:]]+[A-Za-z_.$]|(^|[[:space:]]|:)(db|dw|dd|dq|dt|resb|resw|resd|resq|equ|times)[[:space:]]|^[[:space:]]*%[[:space:]]*(define|macro|endmacro|include|assign|if|ifdef|ifndef|else|endif|rep|endrep|xdefine|undef|imacro|strlen|ifidn|ifnum)|(^|[[:space:]])bits[[:space:]]+(16|32|64)|^[[:space:]]*default[[:space:]]+rel|(byte|word|dword|qword)[[:space:]]+[[]')
    _ds_gas=$(cnt '^[[:space:]]*[.](globl|global|section|text|data|bss|ascii|asciz|string|quad|long|byte|word|short|int|skip|space|zero|equ|set|align|balign|p2align|type|size|macro|endm|code32|code64|file|ident|rodata|comm|lcomm|fill|rept|endr)([[:space:]]|$)|%[re]?(ax|bx|cx|dx|si|di|bp|sp)([^[:alnum:]_]|$)|%r(8|9|1[0-5])[dwb]?([^[:alnum:]_]|$)|%[abcd][lh]([^[:alnum:]_]|$)|%[xy]?mm[0-9]+|(^|[[:space:]])(mov|add|sub|push|pop|lea|cmp|xor|and|or|test|inc|dec|imul|idiv|shl|shr|call|ret|jmp)[bwlq][[:space:]]|[$][-]?(0x[0-9a-f]+|[0-9]+)')
    if [ "$_ds_gas" -gt "$_ds_nasm" ]; then
        SYNTAX=gas
    elif [ "$_ds_nasm" -gt "$_ds_gas" ]; then
        SYNTAX=nasm
    else
        case "$FILE" in
            *.s|*.S|*.sx) SYNTAX=gas ;;
            *)            SYNTAX=nasm ;;
        esac
    fi
    info "syntax votes: nasm=$_ds_nasm gas=$_ds_gas -> $SYNTAX"
}

# Weighted bitness detection (x86 only). Explicit directives win outright.
detect_bits() {
    if has '(^|[^[:alnum:]_])bits[[:space:]]+32|[.]code32'; then BITS=32; return 0; fi
    if has '(^|[^[:alnum:]_])bits[[:space:]]+64|[.]code64'; then BITS=64; return 0; fi

    _db_b32=0
    _db_b64=0
    has 'int[[:space:]]+[$]?(0x80|80h|0x2e|2eh)([^[:alnum:]_]|$)' && _db_b32=$((_db_b32 + 5))
    has '(^|[^[:alnum:]_])syscall([^[:alnum:]_]|$)' && _db_b64=$((_db_b64 + 5))
    has '(^|[^[:alnum:]_])sysenter([^[:alnum:]_]|$)' && _db_b32=$((_db_b32 + 3))
    has '(^|[^[:alnum:]_])(pushad|popad|pushfd|popfd)([^[:alnum:]_]|$)' && _db_b32=$((_db_b32 + 2))
    has '(^|[^[:alnum:]_])(pushfq|popfq)([^[:alnum:]_]|$)' && _db_b64=$((_db_b64 + 2))

    _db_r32=$(cnt '(^|[^[:alnum:]_])e(ax|bx|cx|dx|si|di|sp|bp|ip)([^[:alnum:]_]|$)')
    _db_r64=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|sp|bp|ip)|r([8-9]|1[0-5])[dwb]?)([^[:alnum:]_]|$)')
    _db_b32=$((_db_b32 + _db_r32))
    _db_b64=$((_db_b64 + _db_r64))

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

# ==============================================================================
#  Tool discovery and installation
# ==============================================================================
find_cc() {
    CC=""
    if [ -n "${FORCE_CC:-}" ]; then
        if command -v "$FORCE_CC" >/dev/null 2>&1; then CC=$FORCE_CC; return 0; fi
        return 1
    fi
    for _fc in gcc cc clang; do
        if command -v "$_fc" >/dev/null 2>&1; then CC=$_fc; return 0; fi
    done
    return 1
}

clt_ok() {
    _clt_x=xcode-select
    [ -x /usr/bin/xcode-select ] && _clt_x=/usr/bin/xcode-select
    _clt_p=$("$_clt_x" -p 2>/dev/null) && [ -x "$_clt_p/usr/bin/clang" ]
}
rosetta_ok() { /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; }
sysctl_arm64() {
    if [ -x /usr/sbin/sysctl ]; then
        /usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null
    else
        sysctl -n hw.optional.arm64 2>/dev/null
    fi
}

multilib_ok() {
    [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ] || \
    [ -e /usr/lib32/ld-linux.so.2 ] || [ -e /usr/lib/ld-linux.so.2 ]
}

cc_ok() {
    if [ -n "${FORCE_CC:-}" ]; then
        command -v "$FORCE_CC" >/dev/null 2>&1
        return $?
    fi
    if [ -n "${CC_BIN:-}" ] && command -v "$CC_BIN" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$NATIVE" -eq 1 ] && [ "$OS" != macos ]; then
        find_cc && [ -n "$CC" ]
        return $?
    fi
    return 1
}

tool_ok() {
    case "$1" in
        clt)      clt_ok ;;
        rosetta)  rosetta_ok ;;
        cc)       cc_ok ;;
        multilib) multilib_ok ;;
        qemu)     [ -n "${QEMU_BIN:-}" ] && command -v "$QEMU_BIN" >/dev/null 2>&1 ;;
        *)        command -v "$1" >/dev/null 2>&1 ;;
    esac
}

tool_label() {
    case "$1" in
        nasm)     echo "nasm - NASM assembler" ;;
        as)       echo "as - GNU assembler (binutils)" ;;
        ld)       echo "ld - GNU linker (binutils)" ;;
        cc)
            if [ -n "${CC_BIN:-}" ]; then
                _tl_cc=$CC_BIN
            elif [ "${NATIVE:-1}" -eq 0 ] && [ -n "${CROSS:-}" ]; then
                _tl_cc="$CROSS-gcc"
            else
                _tl_cc=gcc
            fi
            echo "$_tl_cc - C compiler/linker (for main(), libc or .S files)" ;;
        cpp)      echo "cpp - C preprocessor (for .S files without gcc)" ;;
        multilib) echo "32-bit C library and ELF loader (multilib)" ;;
        qemu)     echo "${QEMU_BIN:-qemu-user} - user-mode emulator for cross-built binaries" ;;
        clt)      echo "Xcode Command Line Tools - clang, as, ld" ;;
        rosetta)  echo "Rosetta 2 - runs x86-64 programs on Apple Silicon" ;;
        *)        echo "$1" ;;
    esac
}

pkg_of() {
    case "$1" in
        clt)     echo xcode-clt ;;
        rosetta) echo rosetta ;;
        nasm)    echo nasm ;;
        as|ld)   echo binutils ;;
        cc)
            [ "$OS" = macos ] && return 0
            [ "$NATIVE" -eq 0 ] && return 0
            if [ "${PM:-}" = apk ]; then echo "gcc musl-dev"; else echo gcc; fi ;;
        cpp)
            [ "$OS" = macos ] && return 0
            case "${PM:-}" in
                apt|apt-get) echo cpp ;;
                *)           echo gcc ;;
            esac ;;
        multilib)
            case "${PM:-}" in
                apt)       echo gcc-multilib ;;
                dnf|yum)   echo "glibc-devel.i686 libgcc.i686" ;;
                pacman)    echo "lib32-glibc lib32-gcc-libs" ;;
                zypper)    echo glibc-devel-32bit ;;
                xbps)      echo glibc-32bit ;;
                *)         : ;;
            esac ;;
        qemu)    : ;;
        *)       : ;;
    esac
}

setup_pm() {
    PM=""; UPD=""; INS=""; SUDO=""; S=""; CAN_AUTO=1; WHY=""
    if [ "$OS" = macos ]; then
        PM=brew; INS="brew install"
        return 0
    fi
    if [ -e /run/ostree-booted ]; then
        PM=ostree; CAN_AUTO=0
        WHY="This is an immutable (ostree) system; layering packages needs a reboot."
    else
        for _sp_c in apt apt-get dnf yum pacman zypper apk xbps-install; do
            if command -v "$_sp_c" >/dev/null 2>&1; then PM=$_sp_c; break; fi
        done
        case "$PM" in
            apt|apt-get)  _sp_a=$PM; PM=apt; UPD="$_sp_a update"; INS="$_sp_a install -y" ;;
            dnf)          INS="dnf install -y" ;;
            yum)          INS="yum install -y" ;;
            pacman)       INS="pacman -S --needed --noconfirm" ;;
            zypper)       UPD="zypper --non-interactive refresh"; INS="zypper --non-interactive install" ;;
            apk)          UPD="apk update"; INS="apk add" ;;
            xbps-install) PM=xbps; INS="xbps-install -Sy" ;;
            *)            PM=unknown; CAN_AUTO=0; WHY="Your package manager was not recognised." ;;
        esac
        if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                SUDO=sudo
            elif command -v doas >/dev/null 2>&1; then
                SUDO=doas
            elif [ "$CAN_AUTO" -eq 1 ]; then
                CAN_AUTO=0
                WHY="Neither root nor sudo/doas is available; run the install command as root."
            fi
        fi
    fi
    [ -n "$SUDO" ] && S="$SUDO "
    return 0
}

sys_label() {
    if [ "$OS" = macos ]; then
        _sl_sw=sw_vers
        [ -x /usr/bin/sw_vers ] && _sl_sw=/usr/bin/sw_vers
        printf 'macOS %s (%s)' "$("$_sl_sw" -productVersion 2>/dev/null)" "$(uname -m)"
    else
        _sl_pn=""
        if [ -r /etc/os-release ]; then
            _sl_pn=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-}}" )
        fi
        printf '%s' "${_sl_pn:-Linux}"
        [ "$WSL" -eq 1 ] && printf ' (WSL)'
    fi
}

print_manual() {
    if [ "$OS" = macos ]; then
        for _pm_p in ${PKGS:-}; do
            case "$_pm_p" in
                xcode-clt) say "  ${CYAN}xcode-select --install${NC}" ;;
                rosetta)   say "  ${CYAN}sudo softwareupdate --install-rosetta --agree-to-license${NC}" ;;
                nasm)
                    if ! command -v brew >/dev/null 2>&1; then
                        say "  ${CYAN}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}"
                    fi
                    say "  ${CYAN}brew install nasm${NC}" ;;
                *)         say "  ${CYAN}brew install $_pm_p${NC}" ;;
            esac
        done
        [ -n "${MISSING:-}" ] && [ -z "${PKGS:-}" ] && say "  ${CYAN}Install these tools manually:${NC} ${MISSING# }"
    else
        if [ -z "${PKGS:-}" ]; then
            if [ -n "${MISSING:-}" ]; then
                say "  ${CYAN}Install these tools with your package manager:${NC}"
                for _pm_t in $MISSING; do say "    - $(tool_label "$_pm_t")"; done
            fi
        else
            case "${PM:-unknown}" in
                unknown)
                    say "  ${CYAN}Install with your package manager:${NC} $PKGS" ;;
                ostree)
                    say "  ${CYAN}rpm-ostree install $PKGS${NC}   ${DIM}# then reboot (or use toolbox/distrobox)${NC}" ;;
                *)
                    _pm_cmd=""
                    [ -n "$UPD" ] && _pm_cmd="${S}${UPD} && "
                    _pm_cmd="${_pm_cmd}${S}${INS} $PKGS"
                    say "  ${CYAN}${_pm_cmd}${NC}" ;;
            esac
            case " $PKGS " in
                *" lib32-glibc "*)
                    say "  ${DIM}(On Arch, enable [multilib] in /etc/pacman.conf first.)${NC}" ;;
            esac
        fi
    fi
}

print_cross_manual() {
    say "Cross-building for ${BOLD}${TARGET_ID}${NC} needs a target toolchain:"
    case "$SRC:$BITS" in
        arm64:64) say "  ${CYAN}Debian/Ubuntu: sudo apt install gcc-aarch64-linux-gnu${NC}" ;;
        arm32:32) say "  ${CYAN}Debian/Ubuntu: sudo apt install gcc-arm-linux-gnueabihf${NC}" ;;
        riscv:64) say "  ${CYAN}Debian/Ubuntu: sudo apt install gcc-riscv64-linux-gnu${NC}" ;;
        x86:64)   say "  ${CYAN}Debian/Ubuntu: sudo apt install gcc-x86-64-linux-gnu${NC}" ;;
        x86:32)   say "  ${CYAN}Debian/Ubuntu: sudo apt install gcc-i686-linux-gnu${NC}" ;;
    esac
    say "  ${DIM}Use your distro's equivalent cross-gcc/cross-binutils packages.${NC}"
    if [ "$NATIVE" -eq 0 ] && [ "$ASM_ONLY" -eq 0 ] && [ "$LINK_ONLY" -eq 0 ]; then
        say "To run it here, also install ${CYAN}qemu-user${NC} (the binary is ${QEMU_BIN})."
    fi
    if [ "$LINK_ONLY" -eq 0 ] && [ "$ASM_ONLY" -eq 0 ]; then
        say "To build without running: ${CYAN}asmrun --target $TARGET_ID --link-only FILE${NC}"
    fi
}

ask_yn() {
    _ay_ans=""
    while :; do
        if [ -t 0 ]; then
            printf '%s' "$1" >&2
            IFS= read -r _ay_ans || return 2
        elif { true </dev/tty; } 2>/dev/null; then
            printf '%s' "$1" >&2
            IFS= read -r _ay_ans </dev/tty || return 2
        else
            return 2
        fi
        case "$_ay_ans" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)    return 1 ;;
            *) say "Please type y or n and press Enter." ;;
        esac
    done
}

install_clt() {
    _ic_x=xcode-select
    [ -x /usr/bin/xcode-select ] && _ic_x=/usr/bin/xcode-select
    "$_ic_x" --install >/dev/null 2>&1
    say "A macOS dialog should have appeared - click ${BOLD}Install${NC} and wait for it to finish."
    say "${DIM}(Waiting for the Command Line Tools... press Ctrl-C to cancel)${NC}"
    _ic_w=0
    while ! clt_ok; do
        sleep 5
        _ic_w=$((_ic_w + 5))
        if [ "$_ic_w" -ge 3600 ]; then return 1; fi
    done
    return 0
}

install_pkg() {
    case "$OS:$1" in
        macos:xcode-clt) install_clt ;;
        macos:rosetta)
            if [ -x /usr/sbin/softwareupdate ]; then
                sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license
            else
                sudo softwareupdate --install-rosetta --agree-to-license
            fi ;;
        macos:nasm)      brew install nasm ;;
        *)
            if [ -n "${INS:-}" ]; then
                # shellcheck disable=SC2086
                $SUDO $INS "$1"
            else
                return 1
            fi ;;
    esac
}

do_install() {
    if [ -n "${UPD:-}" ]; then
        say ""
        say "${BOLD}\$ ${S}${UPD}${NC}"
        # shellcheck disable=SC2086
        $SUDO $UPD || warn "Updating the package lists failed - trying to install anyway."
    fi
    for _di_p in $PKGS; do
        say ""
        say "${BOLD}\$ installing ${_di_p}${NC}"
        install_pkg "$_di_p" || warn "The installer for '$_di_p' reported an error."
    done
    hash -r 2>/dev/null

    _di_still=""
    for _di_t in $MISSING; do
        tool_ok "$_di_t" || _di_still="$_di_still $_di_t"
    done
    _di_okp=""
    _di_failp=""
    for _di_p in $PKGS; do
        _di_bad=0
        for _di_t in $_di_still; do
            case " $(pkg_of "$_di_t") " in
                *" $_di_p "*) _di_bad=1 ;;
            esac
        done
        if [ "$_di_bad" -eq 1 ]; then
            _di_failp="$_di_failp $_di_p"
        else
            _di_okp="$_di_okp $_di_p"
        fi
    done

    say ""
    if [ -z "$_di_okp" ]; then
        err "None of the required packages could be installed."
    else
        good "Successfully installed:${_di_okp}"
    fi
    if [ -n "$_di_failp" ]; then
        printf '%s[FAIL]%s Failed to install:%s%s  - please install it yourself:%s\n' \
            "$RED" "$BOLD" "$_di_failp" "$RED" "$NC" >&2
        PKGS=${_di_failp# }
        print_manual
        if [ "$PM" = pacman ]; then
            say "${DIM}(On Arch, 404 errors usually mean stale package lists: run 'sudo pacman -Syu' first.)${NC}"
        fi
        return 1
    fi
    return 0
}

ensure_tools() {
    MISSING=""
    for _et_t in $REQUIRED; do
        tool_ok "$_et_t" || MISSING="$MISSING $_et_t"
    done
    if [ -z "$MISSING" ]; then return 0; fi

    setup_pm
    PKGS=""
    _et_manual=0
    for _et_t in $MISSING; do
        _et_ps=$(pkg_of "$_et_t")
        if [ -z "$_et_ps" ]; then
            _et_manual=1
        else
            for _et_p in $_et_ps; do
                case " $PKGS " in
                    *" $_et_p "*) ;;
                    *) PKGS="$PKGS $_et_p" ;;
                esac
            done
        fi
    done
    PKGS=${PKGS# }

    if [ "$_et_manual" -eq 1 ] && [ "$CAN_AUTO" -eq 1 ]; then
        CAN_AUTO=0
        WHY="Some required tools are not available from the detected package manager."
    fi
    if [ "$OS" = macos ]; then
        case " $PKGS " in
            *" nasm "*)
                if ! command -v brew >/dev/null 2>&1; then
                    CAN_AUTO=0; WHY="Homebrew is not installed (needed to get nasm)."
                fi ;;
        esac
    fi

    say ""
    if [ "$ASM_ONLY" -eq 1 ]; then
        say "${YELLOW}${BOLD}To assemble $(basename "$FILE") you still need:${NC}"
    elif [ "$LINK_ONLY" -eq 1 ]; then
        say "${YELLOW}${BOLD}To build $(basename "$FILE") you still need:${NC}"
    else
        say "${YELLOW}${BOLD}To run $(basename "$FILE") you still need:${NC}"
    fi
    for _et_t in $MISSING; do say "  - $(tool_label "$_et_t")"; done
    say "System detected : ${BOLD}$(sys_label)${NC}${PM:+  ($PM)}"
    if [ -n "$PKGS" ]; then
        say "Packages needed : ${BOLD}${PKGS}${NC}"
    else
        say "Packages needed : ${BOLD}manual installation${NC}"
    fi
    say ""

    if [ "$CAN_AUTO" -eq 0 ]; then
        say "${WHY} Please install them manually:"
        print_manual
        [ "$NATIVE" -eq 0 ] && print_cross_manual
        return 1
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then
        _et_r=0
    else
        ask_yn "Want me to install them automatically?  [y = automatic / n = manual] "
        _et_r=$?
    fi
    case "$_et_r" in
        0)
            do_install
            return $? ;;
        1)
            say "OK - install them yourself with:"
            print_manual
            [ "$NATIVE" -eq 0 ] && print_cross_manual
            say "then run asmrun again."
            return 1 ;;
        *)
            say "No terminal to ask on. Install them with:"
            print_manual
            [ "$NATIVE" -eq 0 ] && print_cross_manual
            say "(or re-run with -y to install automatically)"
            return 1 ;;
    esac
}

# noexec-safe work directory: probe $TMPDIR, /tmp, ~/.cache, then $PWD.
try_workdir() {
    _tw_d=$1
    [ -n "$_tw_d" ] || return 1
    [ -d "$_tw_d" ] || mkdir -p "$_tw_d" 2>/dev/null || return 1
    _tw_probe=$(mktemp "$_tw_d/.asmrun_probe.XXXXXX" 2>/dev/null) || return 1
    if { printf '#!/bin/sh\nexit 0\n' > "$_tw_probe"; } 2>/dev/null \
       && chmod +x "$_tw_probe" 2>/dev/null \
       && "$_tw_probe" >/dev/null 2>&1; then
        rm -f "$_tw_probe"
        WORK_PARENT=$_tw_d
        return 0
    fi
    rm -f "$_tw_probe" 2>/dev/null
    return 1
}

pick_workdir() {
    try_workdir "${TMPDIR:-}" && return 0
    try_workdir /tmp && return 0
    if [ -n "${HOME:-}" ]; then try_workdir "$HOME/.cache" && return 0; fi
    try_workdir "$(pwd)" && return 0
    return 1
}

# ==============================================================================
#  Build helpers
# ==============================================================================
record_cmd() {
    _rc_cmd=""
    for _rc_a in "$@"; do _rc_cmd="$_rc_cmd $(display_arg "$_rc_a")"; done
    _rc_cmd=${_rc_cmd# }
    case "$CMD_COUNT" in
        0) CMD1=$_rc_cmd ;;
        1) CMD2=$_rc_cmd ;;
        2) CMD3=$_rc_cmd ;;
    esac
    CMD_COUNT=$((CMD_COUNT + 1))
}

# Quote one argument for the human-readable [BUILD] line only.
display_arg() {
    case "$1" in
        *[!A-Za-z0-9_./:=+@%-]*) printf "'%s'" "$1" ;;
        *)                        printf '%s' "$1" ;;
    esac
}

# stage LABEL command args...  - prints [BUILD] always, captures output.
stage() {
    _stg_label=$1
    shift
    record_cmd "$@"
    printf '%s[BUILD]%s' "$BLUE" "$NC" >&2
    for _stg_arg in "$@"; do printf ' %s' "$(display_arg "$_stg_arg")" >&2; done
    printf '\n' >&2
    if "$@" >"$LOG" 2>&1; then
        if [ -s "$LOG" ]; then
            printf '%s' "$YELLOW" >&2
            cat "$LOG" >&2
            printf '%s' "$NC" >&2
        fi
        return 0
    fi
    err "$_stg_label failed:"
    cat "$LOG" >&2
    return 1
}

build_failed() {
    if grep -Eiq 'undefined (reference|symbol)|entry point .* undefined|undefined reference to' "$LOG" 2>/dev/null; then
        say "${DIM}Hint: a symbol is not defined - e.g. a C-library function like printf. Define 'main'"
        say "      (instead of '_start') so asmrun links against libc, or check the entry-point name.${NC}"
    fi
    if [ "$1" = link ] && [ "$BITS" -eq 32 ] && [ "$SRC" = x86 ] && [ "$LINK" = cc ]; then
        say "${DIM}Hint: 32-bit libc linking needs multilib (Debian: gcc-multilib; Arch: lib32-glibc lib32-gcc-libs).${NC}"
    fi
    if [ "$1" = assemble ] && [ -z "$FORCE_SYNTAX" ] && [ "$SRC" = x86 ]; then
        say "${DIM}Hint: the syntax was auto-detected as ${SYNTAX_LABEL}. If that is wrong, force it with --nasm or --gas.${NC}"
    fi
    if [ "$OS" = macos ] && [ "$1" = link ]; then
        say "${DIM}Hint (macOS): global symbols usually need a leading underscore (_main / _start), and syscalls differ from Linux.${NC}"
    fi
    if [ "$NATIVE" -eq 0 ]; then
        say "${DIM}Hint: check that the ${TARGET_ID} cross toolchain is installed. Build without running with --link-only.${NC}"
    fi
    exit 1
}

json_str() {
    _js_s=$(printf '%s' "$1" | tr '\012\015\011' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '"%s"' "$_js_s"
}

write_report() {
    [ -n "$REPORT" ] || return 0
    _wr_out=""
    _wr_kind=""
    if [ "$ASM_ONLY" -eq 1 ]; then
        _wr_out=$OBJ_OUT
        _wr_kind=object
    elif [ -n "$EXE" ]; then
        _wr_out=$EXE
        if [ "$LINK_ONLY" -eq 0 ] && [ -z "$OUT" ] && [ "$KEEP_BUILD" -eq 0 ]; then
            _wr_kind=temp
        else
            _wr_kind=executable
        fi
    fi
    if [ -n "$_wr_out" ] && [ -e "$REPORT" ] && [ -e "$_wr_out" ] && same_file "$REPORT" "$_wr_out"; then
        warn "Refusing to overwrite the built output '$_wr_out' with the report '$REPORT'."
        return 0
    fi
    _wr_work=""
    [ "$KEEP_BUILD" -eq 1 ] && _wr_work=$WORK

    {
        printf '{\n'
        printf '  "tool": "asmrun",\n'
        printf '  "version": %s,\n' "$(json_str "$VERSION")"
        printf '  "file": %s,\n' "$(json_str "$FILE")"
        printf '  "os": %s,\n' "$(json_str "$OS")"
        printf '  "wsl": %s,\n' "$([ "$WSL" -eq 1 ] && echo true || echo false)"
        printf '  "host": %s,\n' "$(json_str "$HOST")"
        printf '  "host_bits": %s,\n' "$HOST_BITS"
        printf '  "source_arch": %s,\n' "$(json_str "$SRC")"
        printf '  "syntax": %s,\n' "$(json_str "$SYNTAX")"
        printf '  "bits": %s,\n' "$BITS"
        printf '  "target": %s,\n' "$(json_str "$TARGET_ID")"
        printf '  "native": %s,\n' "$([ "$NATIVE" -eq 1 ] && echo true || echo false)"
        printf '  "link": %s,\n' "$(json_str "$LINK")"
        printf '  "cpp": %s,\n' "$([ "$CPP" -eq 1 ] && echo true || echo false)"
        printf '  "tools_required": ['
        _wr_first=1
        for _wr_t in $REQUIRED; do
            [ "$_wr_first" -eq 1 ] || printf ', '
            _wr_first=0
            json_str "$_wr_t"
        done
        printf '],\n'
        printf '  "build_commands": ['
        _wr_first=1
        for _wr_c in "$CMD1" "$CMD2" "$CMD3"; do
            [ -n "$_wr_c" ] || continue
            [ "$_wr_first" -eq 1 ] || printf ', '
            _wr_first=0
            json_str "$_wr_c"
        done
        printf '],\n'
        printf '  "output": %s,\n' "$(json_str "$_wr_out")"
        printf '  "output_kind": %s,\n' "$(json_str "$_wr_kind")"
        printf '  "exit_code": %s,\n' "$RC"
        printf '  "kept_build_dir": %s\n' "$(json_str "$_wr_work")"
        printf '}\n'
    } >"$REPORT" 2>/dev/null || warn "Could not write report to '$REPORT'."
}

# ==============================================================================
#  Self test
# ==============================================================================
# st_run NAME SOURCE EXPECTED [extra asmrun flags...]
st_run() {
    _sr_name=$1
    _sr_src=$2
    _sr_expect=$3
    shift 3
    _sr_out="$ST_DIR/$_sr_name.out"
    _sr_err="$ST_DIR/$_sr_name.err"
    if ASMRUN_NO_RC=1 ASMRUN_FLAGS= ASMRUN_CC= sh "$SELF" "$@" "$_sr_src" </dev/null >"$_sr_out" 2>"$_sr_err"; then
        _sr_rc=0
    else
        _sr_rc=$?
    fi
    if [ "$_sr_rc" -eq 0 ] && grep -qF -- "$_sr_expect" "$_sr_out"; then
        good "[PASS] $_sr_name"
        ST_PASS=$((ST_PASS + 1))
    else
        err "[FAIL] $_sr_name (exit $_sr_rc, expected '$_sr_expect')"
        sed 's/^/       /' "$_sr_err" >&2
        ST_FAIL=$((ST_FAIL + 1))
    fi
}

selftest() {
    SELF=$0
    case "$SELF" in
        */*) ;;
        *) SELF=$(command -v "$SELF" 2>/dev/null || printf './%s' "$SELF") ;;
    esac

    # Host detection normally happens later in the main flow; the self test
    # runs before that, so detect it here.
    case "$(uname -s)" in
        Darwin) OS=macos ;;
        *)      OS=linux ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  HOST=x86;   HOST_BITS=64 ;;
        i?86)          HOST=x86;   HOST_BITS=32 ;;
        aarch64|arm64) HOST=arm64; HOST_BITS=64 ;;
        arm*)          HOST=arm32; HOST_BITS=32 ;;
        riscv64)       HOST=riscv; HOST_BITS=64 ;;
        *)             HOST=$(uname -m); HOST_BITS=64 ;;
    esac
    if [ "$OS" = macos ] && [ "$(sysctl_arm64 || echo 0)" = 1 ]; then
        HOST=arm64; HOST_BITS=64
    fi

    pick_workdir || die "No executable directory found for the self test."
    ST_DIR=$(mktemp -d "$WORK_PARENT/asmrun-selftest.XXXXXX") || die "Could not create a temporary directory."
    ST_PASS=0
    ST_FAIL=0

    say "${BOLD}asmrun $VERSION self test${NC}"
    say "host: $(uname -s) / $(uname -m)"
    say ""

    cat >"$ST_DIR/nasm64.asm" <<'ASMEOF'
global _start
section .text
_start:
    mov rax, 1
    mov rdi, 1
    lea rsi, [rel msg]
    mov rdx, len
    syscall
    mov rax, 60
    xor rdi, rdi
    syscall
section .data
msg: db "selftest-nasm64", 10
len equ $ - msg
ASMEOF

    cat >"$ST_DIR/gas64.s" <<'ASMEOF'
.globl _start
.text
_start:
    movq $1, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $len, %rdx
    syscall
    movq $60, %rax
    xorq %rdi, %rdi
    syscall
.data
msg: .ascii "selftest-gas64\n"
.set len, . - msg
ASMEOF

    cat >"$ST_DIR/int80.asm" <<'ASMEOF'
global _start
section .text
_start:
    mov eax, 4
    mov ebx, 1
    mov ecx, msg
    mov edx, len
    int 0x80
    mov eax, 1
    xor ebx, ebx
    int 0x80
section .data
msg: db "selftest-int80", 10
len equ $ - msg
ASMEOF

    cat >"$ST_DIR/arm64.s" <<'ASMEOF'
.globl _start
.text
_start:
    mov x0, #1
    adr x1, msg
    mov x2, #15
    mov x8, #64
    svc #0
    mov x0, #0
    mov x8, #93
    svc #0
.data
msg: .ascii "selftest-arm64\n"
ASMEOF

    cat >"$ST_DIR/arm32.s" <<'ASMEOF'
.syntax unified
.arm
.globl _start
.text
_start:
    mov r0, #1
    ldr r1, =msg
    mov r2, #15
    mov r7, #4
    svc #0
    mov r0, #0
    mov r7, #1
    svc #0
.data
msg: .ascii "selftest-arm32\n"
ASMEOF

    cat >"$ST_DIR/riscv64.s" <<'ASMEOF'
.globl _start
.text
_start:
    li a0, 1
    la a1, msg
    li a2, 15
    li a7, 64
    ecall
    li a0, 0
    li a7, 93
    ecall
.data
msg: .ascii "selftest-riscv\n"
ASMEOF

    # macOS has a different syscall ABI, so its samples go through libc.
    cat >"$ST_DIR/macos-nasm.asm" <<'ASMEOF'
global _main
extern _puts
section .text
_main:
    lea rdi, [rel msg]
    call _puts
    xor eax, eax
    ret
section .data
msg: db "selftest-macos-nasm", 0
ASMEOF

    cat >"$ST_DIR/macos-gas.s" <<'ASMEOF'
.globl _main
.extern _puts
.text
_main:
    leaq msg(%rip), %rdi
    call _puts
    xorl %eax, %eax
    ret
.data
msg: .asciz "selftest-macos-gas"
ASMEOF

    cat >"$ST_DIR/macos-arm64.s" <<'ASMEOF'
.globl _main
.extern _puts
.text
_main:
    stp x29, x30, [sp, #-16]!
    adr x0, msg
    bl _puts
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret
.data
msg: .asciz "selftest-macos-arm64"
ASMEOF

    if [ "$OS" = macos ]; then
        _st_nasm=$ST_DIR/macos-nasm.asm; _st_nasm_exp="selftest-macos-nasm"
        _st_gas=$ST_DIR/macos-gas.s;     _st_gas_exp="selftest-macos-gas"
        _st_arm=$ST_DIR/macos-arm64.s;   _st_arm_exp="selftest-macos-arm64"
    else
        _st_nasm=$ST_DIR/nasm64.asm;     _st_nasm_exp="selftest-nasm64"
        _st_gas=$ST_DIR/gas64.s;         _st_gas_exp="selftest-gas64"
        _st_arm=$ST_DIR/arm64.s;         _st_arm_exp="selftest-arm64"
    fi

    case "$HOST" in
        x86)
            if [ "$HOST_BITS" -eq 64 ] && command -v nasm >/dev/null 2>&1 && { { [ "$OS" = macos ] && clt_ok; } || { [ "$OS" = linux ] && command -v ld >/dev/null 2>&1; }; }; then
                st_run nasm64 "$_st_nasm" "$_st_nasm_exp"
            else
                say "${DIM}[SKIP] nasm64 (nasm/ld not installed)${NC}"
            fi
            if [ "$HOST_BITS" -eq 64 ] && command -v as >/dev/null 2>&1 && { { [ "$OS" = macos ] && clt_ok; } || { [ "$OS" = linux ] && command -v ld >/dev/null 2>&1; }; }; then
                st_run gas64 "$_st_gas" "$_st_gas_exp"
            else
                say "${DIM}[SKIP] gas64 (as/ld not installed)${NC}"
            fi
            if [ "$OS" = linux ] && multilib_ok && command -v nasm >/dev/null 2>&1 && command -v ld >/dev/null 2>&1; then
                st_run int80 "$ST_DIR/int80.asm" "selftest-int80"
            else
                say "${DIM}[SKIP] int80 (32-bit loader support not present)${NC}"
            fi
            ;;
        arm64)
            if { [ "$OS" = macos ] && clt_ok; } || { [ "$OS" = linux ] && command -v as >/dev/null 2>&1 && command -v ld >/dev/null 2>&1; }; then
                st_run arm64 "$_st_arm" "$_st_arm_exp"
            else
                say "${DIM}[SKIP] arm64 (as/ld not installed)${NC}"
            fi
            ;;
        arm32)
            if [ "$OS" = linux ] && command -v as >/dev/null 2>&1 && command -v ld >/dev/null 2>&1; then
                st_run arm32 "$ST_DIR/arm32.s" "selftest-arm32"
            else
                say "${DIM}[SKIP] arm32 (as/ld not installed)${NC}"
            fi
            ;;
        riscv)
            if [ "$OS" = linux ] && command -v as >/dev/null 2>&1 && command -v ld >/dev/null 2>&1; then
                st_run riscv64 "$ST_DIR/riscv64.s" "selftest-riscv"
            else
                say "${DIM}[SKIP] riscv64 (as/ld not installed)${NC}"
            fi
            ;;
        *)
            say "${DIM}[SKIP] native runtime tests (host $HOST has no built-in sample)${NC}"
            ;;
    esac

    say ""
    if [ "$ST_FAIL" -eq 0 ]; then
        good "self test: $ST_PASS passed, 0 failed"
        rm -rf "$ST_DIR"
        return 0
    fi
    err "self test: $ST_PASS passed, $ST_FAIL failed (files kept in $ST_DIR)"
    return 1
}

# ==============================================================================
#  Main flow
# ==============================================================================

# ---------- optional config files ---------------------------------------------
if [ -z "${ASMRUN_NO_RC:-}" ]; then
    if [ -n "${HOME:-}" ] && [ -f "$HOME/.asmrunrc" ]; then
        # shellcheck disable=SC1090
        . "$HOME/.asmrunrc"
    fi
    if [ -f "./.asmrunrc" ]; then
        # shellcheck disable=SC1091
        . "./.asmrunrc"
    fi
fi
if [ -n "${ASMRUN_FLAGS:-}" ]; then
    # Intentional word splitting: ASMRUN_FLAGS is a flag list.
    # shellcheck disable=SC2086
    set -- $ASMRUN_FLAGS "$@"
fi
if [ -z "${FORCE_CC:-}" ] && [ -n "${ASMRUN_CC:-}" ]; then
    FORCE_CC=$ASMRUN_CC
fi

# ---------- 1. arguments ------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        --version)    printf 'asmrun %s\n' "$VERSION"; exit 0 ;;
        -v|--verbose) VERBOSE=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -o|--output)  [ $# -ge 2 ] || die "Option $1 needs a file name."
                      OUT=$2; [ -n "$OUT" ] || die "Option $1 needs a file name."; shift ;;
        --output=*)   OUT=${1#*=}; [ -n "$OUT" ] || die "Option --output needs a file name." ;;
        --nasm)       FORCE_SYNTAX=nasm ;;
        --gas|--as)   FORCE_SYNTAX=gas ;;
        --32)         FORCE_BITS=32 ;;
        --64)         FORCE_BITS=64 ;;
        --arch)       [ $# -ge 2 ] || die "Option --arch needs a value."
                      FORCE_ARCH=$2; [ -n "$FORCE_ARCH" ] || die "Option --arch needs a value."; shift ;;
        --arch=*)     FORCE_ARCH=${1#*=}; [ -n "$FORCE_ARCH" ] || die "Option --arch needs a value." ;;
        --target)     [ $# -ge 2 ] || die "Option --target needs a value."
                      FORCE_TARGET=$2; [ -n "$FORCE_TARGET" ] || die "Option --target needs a value."; shift ;;
        --target=*)   FORCE_TARGET=${1#*=}; [ -n "$FORCE_TARGET" ] || die "Option --target needs a value." ;;
        --cc)         [ $# -ge 2 ] || die "Option --cc needs a value."
                      FORCE_CC=$2; [ -n "$FORCE_CC" ] || die "Option --cc needs a value."; shift ;;
        --cc=*)       FORCE_CC=${1#*=}; [ -n "$FORCE_CC" ] || die "Option --cc needs a value." ;;
        --keep-build-dir|--keep) KEEP_BUILD=1 ;;
        --asm-only)   ASM_ONLY=1 ;;
        --link-only|--no-run) LINK_ONLY=1 ;;
        --report)     [ $# -ge 2 ] || die "Option --report needs a file name."
                      REPORT=$2; [ -n "$REPORT" ] || die "Option --report needs a file name."; shift ;;
        --report=*)   REPORT=${1#*=}; [ -n "$REPORT" ] || die "Option --report needs a file name." ;;
        --selftest)   SELFTEST=1 ;;
        --)           shift; break ;;
        -*)           die "Unknown option: $1  (try --help)" ;;
        *)            break ;;
    esac
    shift
done

if [ "$SELFTEST" -eq 1 ]; then
    selftest
    exit $?
fi

[ $# -ge 1 ] || { usage >&2; exit 2; }
FILE=$1
shift

[ -e "$FILE" ] || die "File '$FILE' does not exist."
[ -d "$FILE" ] && die "'$FILE' is a directory, not an assembly file."
[ -r "$FILE" ] || die "File '$FILE' is not readable."
[ -s "$FILE" ] || die "File '$FILE' is empty."
case "$FILE" in -*) FILE="./$FILE" ;; esac

if [ "$ASM_ONLY" -eq 1 ] && [ "$LINK_ONLY" -eq 1 ]; then
    die "--asm-only and --link-only cannot be used together."
fi
if [ -n "$OUT" ] && same_file "$OUT" "$FILE"; then
    die "Refusing to overwrite the source file with -o."
fi
if [ -n "$REPORT" ] && same_file "$REPORT" "$FILE"; then
    die "Refusing to overwrite the source file with --report."
fi
if [ -n "$OUT" ] && [ -n "$REPORT" ] && same_file "$OUT" "$REPORT"; then
    die "-o and --report must not name the same file."
fi
if [ -n "$OUT" ] && [ -d "$OUT" ]; then
    die "Output '$OUT' is a directory."
fi
if [ -n "$OUT" ]; then
    _md_dir=$(dirname "$OUT")
    [ -d "$_md_dir" ] || die "Output directory '$_md_dir' does not exist."
fi
if [ -n "$REPORT" ]; then
    [ -d "$REPORT" ] && die "Report '$REPORT' is a directory."
    _md_rdir=$(dirname "$REPORT")
    [ -d "$_md_rdir" ] || die "Report directory '$_md_rdir' does not exist."
fi
if [ -n "$FORCE_CC" ] && ! command -v "$FORCE_CC" >/dev/null 2>&1; then
    die "C compiler '$FORCE_CC' was not found."
fi

case "$FORCE_ARCH" in
    "") ;;
    x86|x86_64|x86-64|amd64|i386|i486|i586|i686) FORCE_ARCH=x86 ;;
    arm64|aarch64)                              FORCE_ARCH=arm64 ;;
    arm|arm32|armv7|armhf)                      FORCE_ARCH=arm32 ;;
    riscv|riscv64)                              FORCE_ARCH=riscv ;;
    *) die "Unknown --arch '$FORCE_ARCH' (x86 | arm64 | arm32 | riscv)." ;;
esac

case "$FORCE_TARGET" in
    "") ;;
    x86_64|amd64|x86-64) FORCE_TARGET=x86_64 ;;
    i386|i486|i586|i686|x86) FORCE_TARGET=i386 ;;
    aarch64|arm64)       FORCE_TARGET=aarch64 ;;
    arm|arm32|armv7|armhf) FORCE_TARGET=armv7 ;;
    riscv|riscv64)       FORCE_TARGET=riscv64 ;;
    *) die "Unknown --target '$FORCE_TARGET' (x86_64 | i386 | aarch64 | armv7 | riscv64)." ;;
esac

TGT_FAM=""
TGT_BITS=""
if [ -n "$FORCE_TARGET" ]; then
    case "$FORCE_TARGET" in
        x86_64)  TGT_FAM=x86;   TGT_BITS=64 ;;
        i386)    TGT_FAM=x86;   TGT_BITS=32 ;;
        aarch64) TGT_FAM=arm64; TGT_BITS=64 ;;
        armv7)   TGT_FAM=arm32; TGT_BITS=32 ;;
        riscv64) TGT_FAM=riscv; TGT_BITS=64 ;;
    esac
    if [ -n "$FORCE_ARCH" ] && [ "$FORCE_ARCH" != "$TGT_FAM" ]; then
        die "--arch $FORCE_ARCH conflicts with --target $FORCE_TARGET."
    fi
    if [ -n "$FORCE_BITS" ] && [ "$FORCE_BITS" != "$TGT_BITS" ]; then
        die "--$FORCE_BITS conflicts with --target $FORCE_TARGET."
    fi
fi

# ---------- 2. host system ----------------------------------------------------
case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *)      die "Unsupported OS '$(uname -s)'. asmrun supports Linux and macOS." ;;
esac

if [ "$OS" = macos ]; then
    for _md_hb in /opt/homebrew/bin /usr/local/bin; do
        [ -d "$_md_hb" ] && PATH="$_md_hb:$PATH"
    done
    export PATH
fi

case "$(uname -m)" in
    x86_64|amd64)   HOST=x86;   HOST_BITS=64 ;;
    i?86)           HOST=x86;   HOST_BITS=32 ;;
    aarch64|arm64)  HOST=arm64; HOST_BITS=64 ;;
    arm*)           HOST=arm32; HOST_BITS=32 ;;
    riscv64)        HOST=riscv; HOST_BITS=64 ;;
    *)              HOST=$(uname -m); HOST_BITS=64 ;;
esac
# A terminal running under Rosetta reports x86_64 on an Apple Silicon Mac.
if [ "$OS" = macos ] && [ "$(sysctl_arm64 || echo 0)" = 1 ]; then
    HOST=arm64
    HOST_BITS=64
fi

WSL=0
if [ "$OS" = linux ]; then
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        WSL=1
    fi
fi

# ---------- 3. source architecture -------------------------------------------
if [ -n "$FORCE_TARGET" ]; then
    detect_arch
    _md_detected=$SRC
    SRC=$TGT_FAM
    BITS=$TGT_BITS
    if [ "$_md_detected" != "$SRC" ]; then
        info "explicit --target $FORCE_TARGET overrides detected $_md_detected source"
    fi
elif [ -n "$FORCE_ARCH" ]; then
    SRC=$FORCE_ARCH
else
    detect_arch
fi

if [ "$SRC" = x86 ]; then
    if [ -n "$FORCE_TARGET" ]; then
        BITS=$TGT_BITS
    elif [ -n "$FORCE_BITS" ]; then
        BITS=$FORCE_BITS
    else
        if has '(^|[^[:alnum:]_])bits[[:space:]]+16|[.]code16|(^|[[:space:]])org[[:space:]]+(0x)?7c00h?([[:space:]]|$)'; then
            err "This is 16-bit / boot-sector code. asmrun only runs normal user-space programs."
            say "${DIM}Try:  nasm -f bin file.asm -o boot.bin && qemu-system-x86_64 -drive format=raw,file=boot.bin${NC}"
            exit 1
        fi
        detect_bits
    fi
else
    if [ -n "$FORCE_BITS" ]; then
        die "--32/--64 only apply to x86; $(arch_label "$SRC") is fixed-width."
    fi
    case "$SRC" in
        arm64) BITS=64 ;;
        arm32) BITS=32 ;;
        riscv) BITS=64 ;;
        *)     BITS=$HOST_BITS ;;
    esac
fi

case "$SRC:$BITS" in
    x86:64)   TARGET_ID=x86_64 ;;
    x86:32)   TARGET_ID=i386 ;;
    arm64:64) TARGET_ID=aarch64 ;;
    arm32:32) TARGET_ID=armv7 ;;
    riscv:64) TARGET_ID=riscv64 ;;
    *)        TARGET_ID=$SRC ;;
esac

# ---------- 4. native or cross? ----------------------------------------------
if [ "$SRC" != x86 ] && [ "$FORCE_SYNTAX" = nasm ]; then
    die "NASM only supports x86; use GNU as syntax for $(arch_label "$SRC")."
fi

NATIVE=1
if [ "$SRC" = "$HOST" ]; then
    if [ "$SRC" = x86 ] && [ "$BITS" -gt "$HOST_BITS" ]; then
        NATIVE=0
    fi
else
    if [ "$OS" = macos ] && [ "$HOST" = arm64 ] && [ "$SRC" = x86 ]; then
        NATIVE=1                    # Rosetta 2
    else
        NATIVE=0
    fi
fi

if [ "$NATIVE" -eq 0 ] && [ -z "$FORCE_TARGET" ]; then
    err "This looks like $(arch_label "$SRC") assembly, but this machine is $(arch_label "$HOST")."
    if [ "$OS" = macos ]; then
        say "asmrun on macOS builds for the host architecture only."
        exit 1
    fi
    say "asmrun builds and runs natively by default."
    say "Cross-build with: ${CYAN}asmrun --target $TARGET_ID $FILE${NC}"
    say "or build without running: ${CYAN}asmrun --target $TARGET_ID --link-only $FILE${NC}"
    say "${DIM}(cross-building needs a target toolchain; running needs qemu-user)${NC}"
    exit 1
fi
if [ "$NATIVE" -eq 0 ] && [ "$OS" = macos ]; then
    die "Cross-compilation is only supported on Linux. On macOS build for the host architecture."
fi

CROSS=""
QEMU_BIN=""
SYSROOT=""
AS_BIN=as
LD_BIN=ld
NASM_BIN=nasm
if [ "$NATIVE" -eq 0 ]; then
    case "$SRC:$BITS" in
        x86:64)   CROSS=x86_64-linux-gnu ;;
        x86:32)   CROSS=i686-linux-gnu ;;
        arm64:64) CROSS=aarch64-linux-gnu ;;
        arm32:32) CROSS=arm-linux-gnueabihf ;;
        riscv:64) CROSS=riscv64-linux-gnu ;;
        *)        die "No cross-toolchain naming rule for $SRC/$BITS." ;;
    esac
    AS_BIN="$CROSS-as"
    LD_BIN="$CROSS-ld"
    case "$SRC:$BITS" in
        x86:64)   QEMU_BIN=qemu-x86_64 ;;
        x86:32)   QEMU_BIN=qemu-i386 ;;
        arm64:64) QEMU_BIN=qemu-aarch64 ;;
        arm32:32) QEMU_BIN=qemu-arm ;;
        riscv:64) QEMU_BIN=qemu-riscv64 ;;
    esac
    case "$SRC:$BITS" in
        arm64:64) SYSROOT=/usr/aarch64-linux-gnu ;;
        arm32:32) SYSROOT=/usr/arm-linux-gnueabihf ;;
        riscv:64) SYSROOT=/usr/riscv64-linux-gnu ;;
        x86:64)   SYSROOT=/usr/x86_64-linux-gnu ;;
        x86:32)
            if [ -d /usr/i686-linux-gnu ]; then
                SYSROOT=/usr/i686-linux-gnu
            else
                SYSROOT=/usr/i386-linux-gnu
            fi ;;
    esac
    [ -d "$SYSROOT" ] || SYSROOT=""
fi

# ---------- 5. syntax ---------------------------------------------------------
case "$FILE" in
    *.S)
        if [ "$FORCE_SYNTAX" = nasm ]; then
            die "A .S file is GAS with the C preprocessor; NASM cannot process it. Use .asm or --gas."
        fi ;;
esac

if [ "$SRC" != x86 ]; then
    if [ "$FORCE_SYNTAX" = nasm ]; then
        die "NASM only supports x86; use GNU as syntax for $(arch_label "$SRC")."
    fi
    SYNTAX=gas
elif [ -n "$FORCE_SYNTAX" ]; then
    SYNTAX=$FORCE_SYNTAX
    if has '[.]model[[:space:]]|(^|[[:space:]])endp([[:space:]]|$)|^[[:space:]]*(invoke|includelib)[[:space:]]'; then
        die "This looks like MASM/TASM (Windows) assembly. asmrun supports NASM and GNU as syntax."
    fi
    if has '^[[:space:]]*format[[:space:]]+(elf|elf64|pe|pe64|ms|mz|binary)|segment[[:space:]]+readable|^[[:space:]]*entry[[:space:]]+[A-Za-z_.]'; then
        die "This looks like FASM assembly, which asmrun does not support (NASM and GNU as only)."
    fi
else
    if has '[.]model[[:space:]]|(^|[[:space:]])endp([[:space:]]|$)|^[[:space:]]*(invoke|includelib)[[:space:]]|(^|[[:space:]])proc([[:space:]]|$)|[.]286|[.]386|[.]486'; then
        die "This looks like MASM/TASM (Windows) assembly. asmrun supports NASM and GNU as syntax."
    fi
    if has '^[[:space:]]*format[[:space:]]+(elf|elf64|pe|pe64|ms|mz|binary)|segment[[:space:]]+readable|^[[:space:]]*entry[[:space:]]+[A-Za-z_.]'; then
        die "This looks like FASM assembly, which asmrun does not support (NASM and GNU as only)."
    fi
    detect_syntax
fi
case "$SYNTAX" in
    nasm) SYNTAX_LABEL="NASM (Intel)" ;;
    *)    SYNTAX_LABEL="GNU as" ;;
esac

if [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ] && [ "$OS" = macos ]; then
    err "This looks like 32-bit x86 code, but macOS cannot build or run 32-bit programs (dropped in 10.15)."
    say "${DIM}Port it to 64-bit (rax/rdi + syscall), or run it on Linux.${NC}"
    exit 1
fi

# ---------- 6. entry point, libc, preprocessor -------------------------------
HAS_START=0; HAS_PSTART=0; HAS_MAIN=0; HAS_ENTRY=0; USES_LIBC=0; CPP=0
ENTRY_NAME=""
has '^[[:space:]]*_start[[:space:]]*:' && HAS_START=1
has '^[[:space:]]*start[[:space:]]*:'   && HAS_PSTART=1
has '^[[:space:]]*_?main[[:space:]]*:'  && HAS_MAIN=1
has '^[[:space:]]*(global|\.globl|\.global)[[:space:]]+_start([[:space:]]|$)' && HAS_START=1
has '^[[:space:]]*(global|\.globl|\.global)[[:space:]]+start([[:space:]]|$)'  && HAS_PSTART=1
has '^[[:space:]]*(global|\.globl|\.global)[[:space:]]+_?main([[:space:]]|$)' && HAS_MAIN=1

ENTRY_NAME=$(sed -n 's/.*[Ee][Nn][Tt][Rr][Yy][[:space:]]*([[:space:]]*\([A-Za-z_.][A-Za-z0-9_.]*\).*/\1/p' "$FILE" 2>/dev/null | head -n 1)
if [ -n "$ENTRY_NAME" ]; then
    case "$ENTRY_NAME" in
        _start)     HAS_START=1 ;;
        start)      HAS_PSTART=1 ;;
        main|_main) HAS_MAIN=1 ;;
        *)          HAS_ENTRY=1 ;;
    esac
fi
if [ "$HAS_START" -eq 0 ] && [ "$HAS_PSTART" -eq 0 ] && [ "$HAS_MAIN" -eq 0 ] && [ -z "$ENTRY_NAME" ]; then
    warn "No entry point (_start, start or main) was found; the linker may reject this file."
fi

has '^[[:space:]]*[.]?extern[[:space:]]+_?(printf|fprintf|sprintf|snprintf|puts|putchar|scanf|sscanf|fscanf|getchar|fgets|fputs|fopen|fclose|fread|fwrite|malloc|calloc|realloc|free|strlen|strcmp|strncmp|strcpy|strncpy|strcat|memcpy|memmove|memset|atoi|atol|strtol|exit|abort|perror|getenv|time|rand|srand|write)(@PLT)?([[:space:]]|$)|@plt([^[:alnum:]_]|$)|wrt[[:space:]]+[.][.]plt|(call[qwl]?|bl|jmp)[[:space:]]+_?(printf|fprintf|sprintf|snprintf|puts|putchar|scanf|sscanf|fscanf|getchar|fgets|fputs|fopen|fclose|fread|fwrite|malloc|calloc|realloc|free|strlen|strcmp|strncmp|strcpy|strncpy|strcat|memcpy|memmove|memset|atoi|atol|strtol|exit|abort|perror|getenv|time|rand|srand|write)(@PLT)?([^[:alnum:]_]|$)' && USES_LIBC=1

case "$FILE" in *.S) CPP=1 ;; esac
if [ "$SYNTAX" = gas ]; then
    has '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"]|^[[:space:]]*#[[:space:]]*(define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)[[:space:]]' && CPP=1
fi
if [ "$CPP" -eq 1 ]; then XLANG=assembler-with-cpp; else XLANG=assembler; fi

# ---------- 7. choose linker + preprocessor strategy -------------------------
if [ "$OS" = macos ]; then
    LINK=cc
    if [ -n "$FORCE_CC" ]; then CC_BIN=$FORCE_CC; else CC_BIN=clang; fi
    if [ "$CPP" -eq 1 ]; then CPP_MODE=cc; else CPP_MODE=""; fi
else
    if [ "$NATIVE" -eq 1 ]; then
        find_cc
        CC_BIN=$CC
    else
        if [ -n "$FORCE_CC" ]; then
            CC_BIN=$FORCE_CC
        else
            CC_BIN="$CROSS-gcc"
        fi
        command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN=""
    fi

    _md_cc_present=0
    if [ -n "$CC_BIN" ] && command -v "$CC_BIN" >/dev/null 2>&1; then
        _md_cc_present=1
    fi

    if [ "$CPP" -eq 1 ]; then
        if [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; then
            LINK=cc
            CPP_MODE=cc
        elif [ "$_md_cc_present" -eq 1 ]; then
            LINK=cc
            CPP_MODE=cc
        elif command -v cpp >/dev/null 2>&1; then
            LINK=ld
            CPP_MODE=cpp
        else
            LINK=cc
            CPP_MODE=cc
        fi
    else
        if [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; then
            LINK=cc
        else
            LINK=ld
        fi
        CPP_MODE=""
    fi
fi

# ---------- 8. the exact tools this file needs -------------------------------
REQUIRED=""
add_req() {
    case " $REQUIRED " in
        *" $1 "*) ;;
        *) REQUIRED="$REQUIRED $1" ;;
    esac
}

if [ "$OS" = macos ]; then
    if [ "$ASM_ONLY" -eq 1 ] && [ "$SYNTAX" = nasm ]; then
        add_req nasm
    else
        add_req clt
        [ "$SYNTAX" = nasm ] && add_req nasm
        if [ "$NATIVE" -eq 1 ] && [ "$HOST" = arm64 ] && [ "$SRC" = x86 ] && [ "$ASM_ONLY" -eq 0 ] && [ "$LINK_ONLY" -eq 0 ]; then
            add_req rosetta
        fi
    fi
else
    if [ "$ASM_ONLY" -eq 1 ]; then
        if [ "$SYNTAX" = nasm ]; then
            add_req nasm
        elif [ "$CPP_MODE" = cpp ]; then
            add_req cpp
            add_req "$AS_BIN"
        elif [ "$CPP_MODE" = cc ]; then
            add_req cc
        else
            add_req "$AS_BIN"
        fi
    else
        if [ "$SYNTAX" = nasm ]; then
            add_req nasm
            if [ "$LINK" = cc ]; then add_req cc; else add_req "$LD_BIN"; fi
        elif [ "$LINK" = cc ]; then
            add_req cc
        else
            add_req "$AS_BIN"
            add_req "$LD_BIN"
            [ "$CPP_MODE" = cpp ] && add_req cpp
        fi
    fi
fi

NEEDS_MULTILIB=0
if [ "$OS" = linux ] && [ "$NATIVE" -eq 1 ] && [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ] && [ "$LINK" = cc ] && [ "$ASM_ONLY" -eq 0 ]; then
    if [ "$HAS_MAIN" -eq 0 ] && [ "$USES_LIBC" -eq 0 ] && { [ "$HAS_START" -eq 1 ] || [ "$HAS_PSTART" -eq 1 ] || [ "$HAS_ENTRY" -eq 1 ]; }; then
        :                                   # -nostdlib -static: no 32-bit libc needed
    elif ! multilib_ok; then
        NEEDS_MULTILIB=1
        add_req multilib
    fi
fi
if [ "$NATIVE" -eq 0 ] && [ "$ASM_ONLY" -eq 0 ] && [ "$LINK_ONLY" -eq 0 ]; then
    add_req qemu
fi

info "Host: $OS$( [ "$WSL" -eq 1 ] && echo ' (WSL)')/$(arch_label "$HOST") ($HOST_BITS-bit)"
info "Source: $(arch_label "$SRC") $SYNTAX_LABEL $BITS-bit   Link: $LINK$( [ "$CPP" -eq 1 ] && echo ' + cpp')"
info "Target: $TARGET_ID   native: $([ "$NATIVE" -eq 1 ] && echo yes || echo no)   cross: ${CROSS:-none}"
info "Tools needed:${REQUIRED}"

# ---------- 9. verify tools (install only what is missing) --------------------
ensure_tools || exit 1
for _bt_t in $REQUIRED; do
    tool_ok "$_bt_t" || die "Tool '$_bt_t' is still not available after installation."
done

if [ "$LINK" = cc ] && [ "$OS" != macos ]; then
    if [ "$NATIVE" -eq 1 ]; then
        find_cc
        CC_BIN=$CC
    else
        if [ -n "$FORCE_CC" ]; then
            CC_BIN=$FORCE_CC
        else
            CC_BIN="$CROSS-gcc"
        fi
        command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN=""
    fi
    [ -n "$CC_BIN" ] || die "No C compiler/linker driver found (tried gcc, cc, clang)."
fi
if [ "$CPP_MODE" = cpp ] && ! command -v cpp >/dev/null 2>&1; then
    die "The C preprocessor 'cpp' is required for this .S file."
fi

# ---------- 10. work directory and output paths ------------------------------
pick_workdir || die "No executable directory found for the build (all candidates are noexec?)."
WORK=$(mktemp -d "$WORK_PARENT/asmrun.XXXXXX") || die "Could not create a temporary build directory."
if [ "$KEEP_BUILD" -eq 1 ]; then
    printf '%s[WORK]%s %s\n' "$CYAN" "$NC" "$WORK" >&2
fi
LOG="$WORK/build.log"
OBJ="$WORK/prog.o"
PRE="$WORK/prog.s"

_md_base=$(basename "$FILE")
_md_stem=${_md_base%.*}
[ -n "$_md_stem" ] || _md_stem=prog

if [ "$ASM_ONLY" -eq 1 ]; then
    if [ -z "$OUT" ]; then OUT="$_md_stem.o"; fi
    same_file "$OUT" "$FILE" && die "Refusing to overwrite the source with the object output; use -o."
    [ -n "$REPORT" ] && same_file "$OUT" "$REPORT" && die "-o and --report must not name the same file."
    OBJ_OUT=$OUT
    EXE=""
else
    if [ "$LINK_ONLY" -eq 1 ] && [ -z "$OUT" ]; then
        OUT="$_md_stem"
        same_file "$OUT" "$FILE" && OUT="${OUT}.out"
    fi
    if [ -n "$OUT" ]; then
        same_file "$OUT" "$FILE" && die "Refusing to overwrite the source with the linked output; use -o."
        [ -n "$REPORT" ] && same_file "$OUT" "$REPORT" && die "-o and --report must not name the same file."
        EXE=$OUT
    else
        EXE="$WORK/prog"
    fi
fi
[ -n "$OUT" ] && [ -d "$OUT" ] && die "Output '$OUT' is a directory."

# ---------- 11. build flags ---------------------------------------------------
FMT=elf64
ASF=""
LDM=""
CCM=""
if [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ]; then
    FMT=elf32
    if [ "$NATIVE" -eq 1 ]; then
        ASF="--32"
        LDM="-m elf_i386"
        CCM="-m32"
    fi
elif [ "$SRC" = x86 ]; then
    FMT=elf64
    if [ "$NATIVE" -eq 1 ]; then
        ASF="--64"
    fi
fi

CCMODE=""
if [ "$HAS_MAIN" -eq 0 ] && { [ "$HAS_START" -eq 1 ] || [ "$HAS_PSTART" -eq 1 ] || [ "$HAS_ENTRY" -eq 1 ]; }; then
    if [ "$USES_LIBC" -eq 1 ]; then
        CCMODE="-nostartfiles"
    else
        CCMODE="-nostdlib -static"
    fi
fi

ENTRY_FLAG=""
CC_ENTRY=""
if [ "$HAS_MAIN" -eq 0 ]; then
    if [ -n "$ENTRY_NAME" ] && [ "$ENTRY_NAME" != "_start" ] && [ "$ENTRY_NAME" != "main" ] && [ "$ENTRY_NAME" != "_main" ]; then
        ENTRY_FLAG="-e $ENTRY_NAME"
        CC_ENTRY="-Wl,-e,$ENTRY_NAME"
    elif [ "$HAS_PSTART" -eq 1 ] && [ "$HAS_START" -eq 0 ]; then
        ENTRY_FLAG="-e start"
        CC_ENTRY="-Wl,-e,start"
    fi
fi

# ---------- 12. assemble and link --------------------------------------------
if [ "$OS" = macos ]; then
    # macOS: clang from the Command Line Tools drives everything.
    case "$SRC" in
        x86) MARCH=x86_64 ;;
        *)   MARCH=arm64 ;;
    esac
    ENTRY=""
    if [ "$HAS_MAIN" -eq 1 ]; then
        ENTRY=""
    elif [ "$HAS_START" -eq 1 ]; then
        ENTRY="-Wl,-e,_start"
    elif [ "$HAS_PSTART" -eq 1 ]; then
        ENTRY="-Wl,-e,start"
    elif [ -n "$ENTRY_NAME" ]; then
        case "$ENTRY_NAME" in
            _*) ENTRY="-Wl,-e,$ENTRY_NAME" ;;
            *)  ENTRY="-Wl,-e,_$ENTRY_NAME" ;;
        esac
    fi

    if [ "$SYNTAX" = nasm ]; then
        if [ "$ASM_ONLY" -eq 1 ]; then
            stage "Assembling (nasm)" "$NASM_BIN" -f macho64 -o "$OBJ_OUT" "$FILE" || build_failed assemble
        else
            stage "Assembling (nasm)" "$NASM_BIN" -f macho64 -o "$OBJ" "$FILE" || build_failed assemble
            # shellcheck disable=SC2086
            stage "Linking (clang)" "$CC_BIN" -arch "$MARCH" $ENTRY -o "$EXE" "$OBJ" || build_failed link
        fi
    else
        if [ "$ASM_ONLY" -eq 1 ]; then
            stage "Assembling (clang)" "$CC_BIN" -arch "$MARCH" -x "$XLANG" -c -o "$OBJ_OUT" "$FILE" || build_failed assemble
        else
            # shellcheck disable=SC2086
            stage "Assembling/linking (clang)" "$CC_BIN" -arch "$MARCH" -x "$XLANG" $ENTRY -o "$EXE" "$FILE" || build_failed assemble
        fi
    fi

    if [ "$SRC" = x86 ] && has '^[[:space:]]*([[:alnum:]_.]+:)?[[:space:]]*syscall([[:space:]]|$)' && ! has '0x20000[0-9a-f]{2}|2000[0-9a-f]{3}h|335544[0-9]{2}'; then
        warn "Uses 'syscall' without the 0x2000000 prefix - macOS syscall numbers differ (write = 0x2000004, exit = 0x2000001)."
    fi
    if [ "$SRC" = arm64 ] && has '(^|[^[:alnum:]_])svc[[:space:]]' && ! has '(^|[^[:alnum:]_])x16([^[:alnum:]_]|$)'; then
        warn "Uses 'svc' but never sets x16 - macOS arm64 wants the syscall number in x16 with 'svc #0x80'."
    fi
else
    # Linux: exact manual commands. No -z noexecstack, no --no-warn-rwx-segments.
    if [ "$ASM_ONLY" -eq 1 ]; then
        if [ "$SYNTAX" = nasm ]; then
            stage "Assembling (nasm)" "$NASM_BIN" -f "$FMT" -o "$OBJ_OUT" "$FILE" || build_failed assemble
        elif [ "$CPP_MODE" = cpp ]; then
            stage "Preprocessing (cpp)" cpp -traditional-cpp -P -o "$PRE" "$FILE" || build_failed assemble
            # shellcheck disable=SC2086
            stage "Assembling (as)" "$AS_BIN" $ASF -o "$OBJ_OUT" "$PRE" || build_failed assemble
        elif [ "$CPP_MODE" = cc ]; then
            # shellcheck disable=SC2086
            stage "Assembling (cc)" "$CC_BIN" $CCM -c -x "$XLANG" -o "$OBJ_OUT" "$FILE" || build_failed assemble
        else
            # shellcheck disable=SC2086
            stage "Assembling (as)" "$AS_BIN" $ASF -o "$OBJ_OUT" "$FILE" || build_failed assemble
        fi
    elif [ "$SYNTAX" = nasm ]; then
        stage "Assembling (nasm)" "$NASM_BIN" -f "$FMT" -o "$OBJ" "$FILE" || build_failed assemble
        if [ "$LINK" = ld ]; then
            # shellcheck disable=SC2086
            stage "Linking (ld)" "$LD_BIN" $LDM $ENTRY_FLAG -o "$EXE" "$OBJ" || build_failed link
        else
            # shellcheck disable=SC2086
            stage "Linking (cc)" "$CC_BIN" $CCM -no-pie $CCMODE $CC_ENTRY -o "$EXE" "$OBJ" || build_failed link
        fi
    else
        if [ "$LINK" = ld ]; then
            if [ "$CPP_MODE" = cpp ]; then
                stage "Preprocessing (cpp)" cpp -traditional-cpp -P -o "$PRE" "$FILE" || build_failed assemble
                # shellcheck disable=SC2086
                stage "Assembling (as)" "$AS_BIN" $ASF -o "$OBJ" "$PRE" || build_failed assemble
            else
                # shellcheck disable=SC2086
                stage "Assembling (as)" "$AS_BIN" $ASF -o "$OBJ" "$FILE" || build_failed assemble
            fi
            # shellcheck disable=SC2086
            stage "Linking (ld)" "$LD_BIN" $LDM $ENTRY_FLAG -o "$EXE" "$OBJ" || build_failed link
        else
            # shellcheck disable=SC2086
            stage "Assembling/linking (cc)" "$CC_BIN" $CCM -no-pie $CCMODE $CC_ENTRY -x "$XLANG" "$FILE" -o "$EXE" || build_failed assemble
        fi
    fi
fi

# ---------- 13. file(1) verification -----------------------------------------
if [ "$ASM_ONLY" -eq 1 ]; then
    _md_target=$OBJ_OUT
else
    _md_target=$EXE
fi
if command -v file >/dev/null 2>&1; then
    _md_ft=$(file -b "$_md_target" 2>/dev/null || echo "?")
    printf '%s[FILE]%s %s\n' "$CYAN" "$NC" "$_md_ft" >&2
    case "$_md_ft" in
        *"ELF 32-bit"*|*"Mach-O 32-bit"*) _md_built=32 ;;
        *"ELF 64-bit"*|*"Mach-O 64-bit"*) _md_built=64 ;;
        *)                                _md_built="" ;;
    esac
    if [ -n "$_md_built" ] && [ "$_md_built" != "$BITS" ]; then
        warn "Built file is ${_md_built}-bit but the source was detected as ${BITS}-bit. Force with --32 or --64."
    fi
fi

# ---------- 14. stop after assembly/link if requested ------------------------
if [ "$ASM_ONLY" -eq 1 ]; then
    printf '%s[OUT]%s object: %s\n' "$GREEN" "$NC" "$OBJ_OUT" >&2
    RC=0
    write_report
    exit 0
fi
if [ "$LINK_ONLY" -eq 1 ]; then
    printf '%s[OUT]%s executable: %s\n' "$GREEN" "$NC" "$EXE" >&2
    RC=0
    write_report
    exit 0
fi

# ---------- 15. run -----------------------------------------------------------
if [ -n "$OUT" ] || [ "$KEEP_BUILD" -eq 1 ]; then
    printf '%s[OUT]%s executable: %s\n' "$GREEN" "$NC" "$EXE" >&2
fi

RUN=$EXE
case "$RUN" in
    */*) ;;
    *)   RUN="./$RUN" ;;
esac
[ -x "$RUN" ] || chmod +x "$RUN" 2>/dev/null

if [ "$NATIVE" -eq 0 ]; then
    if [ -n "$SYSROOT" ] && [ -d "$SYSROOT" ]; then
        printf '%s[RUN]%s %s -L %s %s\n' "$CYAN" "$NC" "$QEMU_BIN" "$SYSROOT" "$RUN" >&2
        "$QEMU_BIN" -L "$SYSROOT" "$RUN" "$@"
    else
        printf '%s[RUN]%s %s %s\n' "$CYAN" "$NC" "$QEMU_BIN" "$RUN" >&2
        "$QEMU_BIN" "$RUN" "$@"
    fi
else
    "$RUN" "$@"
fi
RC=$?

case "$RC" in
    0) ;;
    126)
        err "Could not execute the program (permission denied - is the output filesystem mounted noexec, or is the binary not executable?)." ;;
    127)
        if [ "$NATIVE" -eq 0 ]; then
            err "The cross-built program could not start (qemu-user missing, or the target loader/sysroot is incomplete)."
            say "       Try:  $QEMU_BIN -L ${SYSROOT:-/usr/<target>} $RUN"
        elif [ "$OS" = linux ] && [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ]; then
            err "The 32-bit program could not start (kernel without 32-bit support, or missing 32-bit loader)."
        else
            printf '%s[exit %s]%s\n' "$DIM" "$RC" "$NC" >&2
        fi ;;
    137)
        if [ "$OS" = macos ]; then
            err "Killed by the system. On Apple Silicon try:  codesign -s - -f ${OUT:-$EXE}"
        else
            printf '%s[exit %s - killed]%s\n' "$DIM" "$RC" "$NC" >&2
        fi ;;
    139)
        err "Segmentation fault."
        if [ "$SRC" = x86 ] && [ "$BITS" -eq 64 ] && has 'int[[:space:]]+[$]?(0x80|80h)([^[:alnum:]_]|$)'; then
            say "       ${BOLD}This file uses 'int 0x80/80h' (32-bit). Force a 32-bit build with:"
            say "         asmrun --32 $FILE${NC}"
        else
            say "       ${DIM}Binary: $EXE"
            say "       Built : ${BITS}-bit ${SYNTAX_LABEL} for $TARGET_ID"
            say "       If your manual one-liner works, compare it with the [BUILD] lines above."
            say "       Common causes: no exit syscall, misaligned stack, bad pointer.${NC}"
        fi ;;
    132)
        err "Illegal instruction (wrong CPU mode, or execution ran into data)." ;;
    *)
        if [ "$RC" -gt 128 ]; then
            _md_sig=$(kill -l $((RC - 128)) 2>/dev/null || echo "?")
            printf '%s[signal %s (%s)]%s\n' "$DIM" "$((RC - 128))" "$_md_sig" "$NC" >&2
        else
            printf '%s[exit %s]%s\n' "$DIM" "$RC" "$NC" >&2
        fi ;;
esac

write_report
exit "$RC"




