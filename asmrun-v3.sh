#!/bin/sh
# ==============================================================================
#  asmrun - assemble, link and run a hand-written assembly file in one command
# ==============================================================================
#  Usage   : asmrun [options] <file> [program arguments...]
#
#  Systems : Linux (apt, dnf, yum, pacman, zypper, apk, xbps, ostree) + macOS
#  Syntax  : NASM | GAS AT&T | GAS Intel | .S (C preprocessor)
#  CPUs    : x86-64, i386 (Linux), ARM64, ARM32, RISC-V
#            x86-64 on Apple Silicon runs through Rosetta 2
#  Installs: only the tools the given file actually needs
#
#  Install : sudo install -d /usr/local/bin
#            sudo install -m 755 asmrun-v3.sh /usr/local/bin/asmrun
# ==============================================================================

set -u

VERBOSE=0
ASSUME_YES=0
OUT=""
FORCE_SYNTAX=""
FORCE_BITS=""
FORCE_ARCH=""
FILE=""
WORK=""
LOG=""
WORK_PARENT=""

# ---------- colours -----------------------------------------------------------
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

cleanup() { if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

usage() {
cat <<'EOF'
Usage: asmrun [options] <file> [program arguments...]

  -v, --verbose       show detection details and every command that runs
  -y, --yes           install missing tools without prompting
  -o, --output FILE   keep the built executable as FILE
      --nasm          force NASM syntax          --gas  force GNU as syntax
      --32 | --64     force 32-bit / 64-bit (x86 only)
      --arch ARCH     force x86 | arm64 | arm32 | riscv
  -h, --help          this help

Anything after the file name is passed to your program.
EOF
}

# ==============================================================================
#  1. Arguments
# ==============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        -v|--verbose) VERBOSE=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -o|--output)  [ $# -ge 2 ] || die "Option $1 needs a file name."
                      OUT=$2; shift ;;
        --nasm)       FORCE_SYNTAX=nasm ;;
        --gas|--as)   FORCE_SYNTAX=gas ;;
        --32)         FORCE_BITS=32 ;;
        --64)         FORCE_BITS=64 ;;
        --arch)       [ $# -ge 2 ] || die "Option --arch needs a value."
                      FORCE_ARCH=$2; shift ;;
        --)           shift; break ;;
        -*)           die "Unknown option: $1 (try --help)" ;;
        *)            break ;;
    esac
    shift
done

[ $# -ge 1 ] || { usage >&2; exit 2; }
FILE=$1; shift

[ -e "$FILE" ] || die "File '$FILE' does not exist."
[ -d "$FILE" ] && die "'$FILE' is a directory."
[ -r "$FILE" ] || die "File '$FILE' is not readable."
[ -s "$FILE" ] || die "File '$FILE' is empty."
case "$FILE" in -*) FILE="./$FILE" ;; esac
if [ -n "$OUT" ] && [ "$OUT" = "$FILE" ]; then die "Refusing to overwrite the source with -o."; fi

case "$FORCE_ARCH" in
    "") ;;
    x86|x86_64|x86-64|amd64|i386|i686) FORCE_ARCH=x86 ;;
    arm64|aarch64)                     FORCE_ARCH=arm64 ;;
    arm|arm32|armv7)                   FORCE_ARCH=arm32 ;;
    riscv|riscv64)                     FORCE_ARCH=riscv ;;
    *) die "Unknown --arch '$FORCE_ARCH' (x86 | arm64 | arm32 | riscv)." ;;
esac

# ==============================================================================
#  2. Host system
# ==============================================================================
case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *)      die "Unsupported OS '$(uname -s)' (Linux and macOS only)." ;;
esac

if [ "$OS" = macos ]; then
    for _d in /opt/homebrew/bin /usr/local/bin; do
        [ -d "$_d" ] && PATH="$_d:$PATH"
    done
    export PATH
fi

case "$(uname -m)" in
    x86_64|amd64)  HOST=x86;   HOST_BITS=64 ;;
    i?86)          HOST=x86;   HOST_BITS=32 ;;
    aarch64|arm64) HOST=arm64; HOST_BITS=64 ;;
    arm*)          HOST=arm32; HOST_BITS=32 ;;
    riscv64)       HOST=riscv; HOST_BITS=64 ;;
    *)             HOST=$(uname -m); HOST_BITS=64 ;;
esac
if [ "$OS" = macos ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
    HOST=arm64; HOST_BITS=64
fi

arch_label() {
    case "$1" in
        x86)   echo "x86 / x86-64" ;;
        arm64) echo "ARM64 (AArch64)" ;;
        arm32) echo "32-bit ARM" ;;
        riscv) echo "RISC-V" ;;
        *)     echo "$1" ;;
    esac
}

# ==============================================================================
#  3. Source analysis
# ==============================================================================
has() { grep -Eiq -- "$1" "$FILE" 2>/dev/null; }
cnt() { _n=$(grep -Eic -- "$1" "$FILE" 2>/dev/null); printf '%s' "${_n:-0}"; }

detect_arch() {
    _x=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|bp|sp)|e(ax|bx|cx|dx|si|di|bp|sp)|r(8|9|1[0-5])[dwb]?|[xy]mm[0-9]+)([^[:alnum:]_]|$)|^[[:space:]]*([[:alnum:]_.]+:)?[[:space:]]*syscall([[:space:]]|$)|int[[:space:]]+[$]?(0x80|80h)|[.]intel_syntax|[.]code(32|64)|(^|[[:space:]])bits[[:space:]]+(32|64)|^[[:space:]]*(global|extern|section|segment)[[:space:]]')
    _a=$(cnt '(^|[^[:alnum:]_])([xw]([0-9]|[12][0-9]|30)|xzr|wzr)[[:space:]]*(,|$)|(^|[^[:alnum:]_.])(stp|ldp|adrp|cbz|cbnz|tbz|tbnz|csel|cset)[[:space:]]|[.]arch[[:space:]]+armv8|aarch64')
    _b=$(cnt '(^|[^[:alnum:]_])r[0-7][[:space:]]*(,|[}]|-|$)|(push|pop|stmfd|ldmfd|stmdb|ldmia)[[:space:]]*[{]|[.]syntax[[:space:]]+unified|(^|[[:space:]])(bx|blx)[[:space:]]+(lr|r[0-9]+)|[.](thumb|thumb_func|arm|cpu)([[:space:]]|$)|(^|[[:space:]])swi[[:space:]]')
    _r=$(cnt '(^|[^[:alnum:]_.])(ecall|ebreak)([^[:alnum:]_]|$)|(^|[[:space:]])(li|addi|jal|jalr|lui|auipc|lw|sw|ld|sd)[[:space:]]+(a[0-7]|t[0-6]|s[0-9]|sp|ra|zero)[[:space:]]*,|[.]option[[:space:]]+(rvc|norvc|push|pop)')
    SRC=$HOST; _best=0
    for _pair in "x86:$_x" "arm64:$_a" "arm32:$_b" "riscv:$_r"; do
        _fam=${_pair%%:*}; _num=${_pair##*:}
        if [ "$_num" -gt "$_best" ]; then
            SRC=$_fam; _best=$_num
        elif [ "$_num" -eq "$_best" ] && [ "$_num" -gt 0 ] && [ "$_fam" = "$HOST" ]; then
            SRC=$_fam
        fi
    done
}

detect_syntax() {
    if has '[.]intel_syntax|[.]att_syntax'; then SYNTAX=gas; return; fi
    _nasm=$(cnt '^[[:space:]]*(section|segment)[[:space:]]+[.]|^[[:space:]]*(global|extern)[[:space:]]+[A-Za-z_.$]|(^|[[:space:]]|:)(db|dw|dd|dq|dt|resb|resw|resd|resq|equ|times)[[:space:]]|^[[:space:]]*%[[:space:]]*(define|macro|endmacro|include|assign|if|ifdef|ifndef|else|endif|rep|endrep|xdefine|undef|imacro|strlen|ifidn|ifnum)|(^|[[:space:]])bits[[:space:]]+(16|32|64)|^[[:space:]]*default[[:space:]]+rel|(byte|word|dword|qword)[[:space:]]+[[]')
    _gas=$(cnt '^[[:space:]]*[.](globl|global|section|text|data|bss|ascii|asciz|string|quad|long|byte|word|short|int|skip|space|zero|equ|set|align|balign|p2align|type|size|macro|endm|code32|code64|file|ident|rodata|comm|lcomm|fill|rept|endr)([[:space:]]|$)|%[re]?(ax|bx|cx|dx|si|di|bp|sp)([^[:alnum:]_]|$)|%r(8|9|1[0-5])[dwb]?([^[:alnum:]_]|$)|%[abcd][lh]([^[:alnum:]_]|$)|%[xy]?mm[0-9]+|(^|[[:space:]])(mov|add|sub|push|pop|lea|cmp|xor|and|or|test|inc|dec|imul|idiv|shl|shr|call|ret|jmp)[bwlq][[:space:]]|[$][-]?(0x[0-9a-f]+|[0-9]+)')
    if   [ "$_gas" -gt "$_nasm" ]; then SYNTAX=gas
    elif [ "$_nasm" -gt "$_gas" ]; then SYNTAX=nasm
    else
        case "$FILE" in
            *.s|*.S|*.sx) SYNTAX=gas ;;
            *)            SYNTAX=nasm ;;
        esac
    fi
}

# ---------- FIXED bitness detection -----------------------------------------
# Weights:  an explicit directive wins outright.  Otherwise we score signals.
#   int 0x80 / int 80h           -> +5 to 32-bit  (32-bit syscall entry)
#   syscall                      -> +5 to 64-bit  (64-bit syscall entry)
#   each eax/ebx/ecx/edx/...     -> +1 to 32-bit
#   each rax/rbx/.../r8-r15      -> +1 to 64-bit
# Ties fall back to host bitness.
detect_bits() {
    if   has '(^|[^[:alnum:]_])bits[[:space:]]+32|[.]code32'; then BITS=32; return; fi
    if   has '(^|[^[:alnum:]_])bits[[:space:]]+64|[.]code64'; then BITS=64; return; fi

    _b32=0; _b64=0

    has 'int[[:space:]]+[$]?(0x80|80h)([^[:alnum:]_]|$)'   && _b32=$((_b32 + 5))
    has '(^|[^[:alnum:]_])syscall([^[:alnum:]_]|$)'         && _b64=$((_b64 + 5))

    _r32=$(cnt '(^|[^[:alnum:]_])e(ax|bx|cx|dx|si|di|sp|bp|ip)([^[:alnum:]_]|$)')
    _r64=$(cnt '(^|[^[:alnum:]_])(r(ax|bx|cx|dx|si|di|sp|bp|ip)|r([8-9]|1[0-5])[dwb]?)([^[:alnum:]_]|$)')
    _b32=$((_b32 + _r32))
    _b64=$((_b64 + _r64))

    info "bitness signals: 32-bit=$_b32 (int80=$([ "$_r32" -ge 0 ] && echo incl) r32=$_r32)  64-bit=$_b64 (r64=$_r64)"

    if   [ "$_b64" -gt "$_b32" ]; then BITS=64
    elif [ "$_b32" -gt "$_b64" ]; then BITS=32
    elif [ "$HOST_BITS" -eq 32 ]; then BITS=32
    else BITS=64
    fi
}

if [ -n "$FORCE_ARCH" ]; then SRC=$FORCE_ARCH; else detect_arch; fi

can_run() {
    [ "$SRC" = "$HOST" ] && return 0
    [ "$OS" = macos ] && [ "$HOST" = arm64 ] && [ "$SRC" = x86 ] && return 0
    return 1
}
if ! can_run; then
    err "This looks like $(arch_label "$SRC") assembly, but this machine is $(arch_label "$HOST")."
    say "asmrun builds and runs natively only."
    say "${DIM}Force with: --arch $HOST${NC}"
    exit 1
fi

if [ "$SRC" != x86 ]; then
    [ "$FORCE_SYNTAX" = nasm ] && die "NASM is x86 only — use GNU as for $(arch_label "$SRC")."
    SYNTAX=gas
elif [ -n "$FORCE_SYNTAX" ]; then
    SYNTAX=$FORCE_SYNTAX
else
    if has '[.]model[[:space:]]|(^|[[:space:]])endp([[:space:]]|$)|^[[:space:]]*(invoke|includelib)[[:space:]]'; then
        die "This looks like MASM/TASM (Windows) — not supported (NASM or GNU as only)."
    fi
    if has '^[[:space:]]*format[[:space:]]+(elf|elf64|pe|pe64|ms|mz|binary)|segment[[:space:]]+readable|^[[:space:]]*entry[[:space:]]+[A-Za-z_.]'; then
        die "This looks like FASM — not supported (NASM or GNU as only)."
    fi
    detect_syntax
fi
case "$SYNTAX" in nasm) SYNTAX_LABEL="NASM (Intel)" ;; *) SYNTAX_LABEL="GNU as" ;; esac

BITS=64
if [ "$SRC" = x86 ]; then
    if has '(^|[^[:alnum:]_])bits[[:space:]]+16|[.]code16|(^|[[:space:]])org[[:space:]]+(0x)?7c00h?([[:space:]]|$)'; then
        err "16-bit / boot-sector code — asmrun only runs normal user-space programs."
        exit 1
    fi
    if [ -n "$FORCE_BITS" ]; then BITS=$FORCE_BITS; else detect_bits; fi
    if [ "$BITS" -eq 64 ] && [ "$HOST_BITS" -eq 32 ]; then
        die "Source is 64-bit but this system is 32-bit x86."
    fi
    if [ "$OS" = macos ] && [ "$BITS" -eq 32 ]; then
        err "Source looks 32-bit, but macOS cannot build or run 32-bit programs (dropped in 10.15)."
        say "${DIM}Port to 64-bit (rax/rdi/… + syscall), or run it on Linux.${NC}"
        exit 1
    fi
fi

# entry / libc / preprocessor
HAS_START=0; HAS_PSTART=0; HAS_MAIN=0; USES_LIBC=0; CPP=0
has '^[[:space:]]*_start[[:space:]]*:'  && HAS_START=1
has '^[[:space:]]*start[[:space:]]*:'   && HAS_PSTART=1
has '^[[:space:]]*_?main[[:space:]]*:'  && HAS_MAIN=1
has '^[[:space:]]*[.]?extern[[:space:]]+[A-Za-z_]|@plt([^[:alnum:]_]|$)|wrt[[:space:]]+[.][.]plt|(call|bl)[[:space:]]+_?(printf|puts|putchar|scanf|getchar|malloc|free|strlen|memcpy|memset|fprintf|sprintf|atoi|fopen|fclose|fgets|fputs)([^[:alnum:]_]|$)' && USES_LIBC=1
case "$FILE" in *.S) CPP=1 ;; esac
has '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"]|^[[:space:]]*#[[:space:]]*(define|ifdef|ifndef)[[:space:]]' && [ "$SYNTAX" = gas ] && CPP=1
if [ "$CPP" -eq 1 ]; then XLANG=assembler-with-cpp; else XLANG=assembler; fi

if [ "$OS" = macos ]; then
    LINK=cc
elif [ "$CPP" -eq 1 ] || [ "$HAS_MAIN" -eq 1 ] || [ "$USES_LIBC" -eq 1 ]; then
    LINK=cc
else
    LINK=ld
fi

REQUIRED=""
add_req() { case " $REQUIRED " in *" $1 "*) ;; *) REQUIRED="$REQUIRED $1" ;; esac; }
if [ "$OS" = macos ]; then
    add_req clt
    [ "$SYNTAX" = nasm ] && add_req nasm
    [ "$HOST" = arm64 ] && [ "$SRC" = x86 ] && add_req rosetta
else
    [ "$SYNTAX" = nasm ] && add_req nasm
    if [ "$LINK" = cc ]; then
        add_req cc
    else
        [ "$SYNTAX" = gas ] && add_req as
        add_req ld
    fi
fi

info "Host: $OS/$(arch_label "$HOST")   Source: $(arch_label "$SRC") $SYNTAX_LABEL $BITS-bit   Link: $LINK$( [ "$CPP" -eq 1 ] && echo ' + cpp')"
info "Tools:${REQUIRED}"

# ==============================================================================
#  4. Dependency check / installation
# ==============================================================================
CC=""
find_cc() {
    CC=""
    for _c in gcc cc clang; do
        if command -v "$_c" >/dev/null 2>&1; then CC=$_c; return 0; fi
    done
    return 1
}

clt_ok() { _p=$(xcode-select -p 2>/dev/null) && [ -x "$_p/usr/bin/clang" ]; }
rosetta_ok() { /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; }

tool_ok() {
    case "$1" in
        clt)     clt_ok ;;
        rosetta) rosetta_ok ;;
        cc)      find_cc ;;
        *)       command -v "$1" >/dev/null 2>&1 ;;
    esac
}

tool_label() {
    case "$1" in
        nasm)    echo "nasm      - NASM assembler" ;;
        as)      echo "as        - GNU assembler (binutils)" ;;
        ld)      echo "ld        - linker (binutils)" ;;
        cc)      echo "gcc       - C compiler/linker (for main(), libc, .S)" ;;
        clt)     echo "Xcode Command Line Tools - clang, as, ld" ;;
        rosetta) echo "Rosetta 2 - runs x86-64 on Apple Silicon" ;;
        *)       echo "$1" ;;
    esac
}

pkg_of() {
    if [ "$OS" = macos ]; then
        case "$1" in clt) echo xcode-clt ;; rosetta) echo rosetta ;; nasm) echo nasm ;; esac
    else
        case "$1" in
            nasm)  echo nasm ;;
            as|ld) echo binutils ;;
            cc)    if [ "$PM" = apk ]; then echo "gcc musl-dev"; else echo gcc; fi ;;
        esac
    fi
}

setup_pm() {
    PM=""; UPD=""; INS=""; SUDO=""; S=""; CAN_AUTO=1; WHY=""
    if [ "$OS" = macos ]; then PM=brew; INS="brew install"; return 0; fi
    if [ -e /run/ostree-booted ]; then
        PM=ostree; CAN_AUTO=0; WHY="Immutable (ostree) system; layering needs a reboot."
    else
        for _c in apt apt-get dnf yum pacman zypper apk xbps-install; do
            if command -v "$_c" >/dev/null 2>&1; then PM=$_c; break; fi
        done
        case "$PM" in
            apt|apt-get)  _a=$PM; PM=apt; UPD="$_a update"; INS="$_a install -y" ;;
            dnf)          INS="dnf install -y" ;;
            yum)          INS="yum install -y" ;;
            pacman)       INS="pacman -S --needed --noconfirm" ;;
            zypper)       UPD="zypper --non-interactive refresh"; INS="zypper --non-interactive install" ;;
            apk)          UPD="apk update"; INS="apk add" ;;
            xbps-install) PM=xbps; INS="xbps-install -Sy" ;;
            *)            PM=unknown; CAN_AUTO=0; WHY="Package manager not recognised." ;;
        esac
        if [ "$(id -u)" -ne 0 ]; then
            if   command -v sudo >/dev/null 2>&1; then SUDO=sudo
            elif command -v doas >/dev/null 2>&1; then SUDO=doas
            else
                 [ "$CAN_AUTO" -eq 1 ] && { CAN_AUTO=0; WHY="Neither root nor sudo/doas available; run as root."; }
            fi
        fi
    fi
    [ -n "$SUDO" ] && S="$SUDO "
    return 0
}

sys_label() {
    if [ "$OS" = macos ]; then
        echo "macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    else
        _pn=""
        if [ -r /etc/os-release ]; then _pn=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-}}" ); fi
        echo "${_pn:-Linux}"
    fi
}

print_manual() {
    if [ "$OS" = macos ]; then
        for _p in $PKGS; do
            case "$_p" in
                xcode-clt) say "  ${CYAN}xcode-select --install${NC}" ;;
                rosetta)   say "  ${CYAN}sudo softwareupdate --install-rosetta --agree-to-license${NC}" ;;
                nasm)
                    command -v brew >/dev/null 2>&1 || say "  ${CYAN}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}  ${DIM}# installs Homebrew first${NC}"
                    say "  ${CYAN}brew install nasm${NC}" ;;
            esac
        done
    else
        case "$PM" in
            unknown) say "  Install with your package manager: ${CYAN}$PKGS${NC}" ;;
            ostree)  say "  ${CYAN}rpm-ostree install $PKGS${NC}   ${DIM}# then reboot${NC}" ;;
            *)       _cmd=""
                     [ -n "$UPD" ] && _cmd="${S}${UPD} && "
                     say "  ${CYAN}${_cmd}${S}${INS} $PKGS${NC}" ;;
        esac
    fi
}

ask_yn() {
    while :; do
        if [ -t 0 ]; then
            printf '%s' "$1" >&2; IFS= read -r _ans || return 2
        elif { true </dev/tty; } 2>/dev/null; then
            printf '%s' "$1" >&2; IFS= read -r _ans </dev/tty || return 2
        else
            return 2
        fi
        case "$_ans" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)    return 1 ;;
            *) say "Please type y or n and press Enter." ;;
        esac
    done
}

install_clt() {
    xcode-select --install >/dev/null 2>&1
    say "A macOS dialog should have appeared - click ${BOLD}Install${NC} and wait."
    say "${DIM}(Waiting for CLT… Ctrl-C to cancel)${NC}"
    _w=0
    while ! clt_ok; do
        sleep 5; _w=$((_w + 5))
        [ "$_w" -ge 3600 ] && return 1
    done
    return 0
}

install_pkg() {
    case "$OS:$1" in
        macos:xcode-clt) install_clt ;;
        macos:rosetta)   sudo softwareupdate --install-rosetta --agree-to-license ;;
        macos:nasm)      brew install nasm ;;
        *)               $SUDO $INS "$1" ;;
    esac
}

do_install() {
    if [ -n "$UPD" ]; then
        say ""; say "${BOLD}\$ ${S}${UPD}${NC}"
        $SUDO $UPD || warn "Package list update failed; trying installs anyway."
    fi
    for _p in $PKGS; do
        say ""; say "${BOLD}\$ installing ${_p}${NC}"
        install_pkg "$_p" || warn "Installer for '$_p' reported an error."
    done
    hash -r 2>/dev/null

    STILL=""
    for _t in $MISSING; do tool_ok "$_t" || STILL="$STILL $_t"; done
    OKP=""; FAILP=""
    for _p in $PKGS; do
        _bad=0
        for _t in $STILL; do
            case " $(pkg_of "$_t") " in *" $_p "*) _bad=1 ;; esac
        done
        if [ "$_bad" -eq 1 ]; then FAILP="$FAILP $_p"; else OKP="$OKP $_p"; fi
    done

    say ""
    if [ -z "$OKP" ]; then
        err "None of the required packages could be installed."
    else
        good "Successfully installed:${OKP}"
    fi
    if [ -n "$FAILP" ]; then
        printf '%s[FAIL]%s Failed:%s%s  — please install it yourself:%s\n' "$RED" "$BOLD" "$FAILP" "$RED" "$NC" >&2
        PKGS=${FAILP# }; print_manual
        [ "$PM" = pacman ] && say "${DIM}(On Arch, 404s mean stale lists: run 'sudo pacman -Syu' first.)${NC}"
        return 1
    fi
    return 0
}

ensure_tools() {
    MISSING=""
    for _t in $REQUIRED; do tool_ok "$_t" || MISSING="$MISSING $_t"; done
    if [ -z "$MISSING" ]; then return 0; fi

    setup_pm
    PKGS=""
    for _t in $MISSING; do
        for _p in $(pkg_of "$_t"); do
            case " $PKGS " in *" $_p "*) ;; *) PKGS="$PKGS $_p" ;; esac
        done
    done
    PKGS=${PKGS# }
    if [ "$OS" = macos ]; then
        case " $PKGS " in
            *" nasm "*) if ! command -v brew >/dev/null 2>&1; then CAN_AUTO=0; WHY="Homebrew is not installed (needed for nasm)."; fi ;;
        esac
    fi

    say ""
    say "${YELLOW}${BOLD}To run $(basename "$FILE") you still need:${NC}"
    for _t in $MISSING; do say "  - $(tool_label "$_t")"; done
    say "System detected : ${BOLD}$(sys_label)${NC}${PM:+  ($PM)}"
    say "Packages needed : ${BOLD}${PKGS}${NC}"
    say ""

    if [ "$CAN_AUTO" -eq 0 ]; then
        say "${WHY} Please install manually:"
        print_manual
        return 1
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then
        _r=0
    else
        ask_yn "Want me to install them automatically?  [y = automatic / n = manual] "; _r=$?
    fi
    case "$_r" in
        0) do_install; return $? ;;
        1) say "OK — install them yourself with:"; print_manual; say "then run asmrun again."; return 1 ;;
        *) say "No terminal to ask on. Install them with:"; print_manual; say "(or re-run with -y)"; return 1 ;;
    esac
}

ensure_tools || exit 1
if [ "$OS" = macos ]; then CC=clang; elif [ "$LINK" = cc ]; then find_cc; fi

# ==============================================================================
#  5. Build directory – noexec-safe fallback
# ==============================================================================
pick_workdir() {
    for _d in "${TMPDIR:-}" /tmp "$HOME/.cache" "$(pwd)"; do
        [ -n "$_d" ] || continue
        [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null || continue
        _probe="$_d/.asmrun_probe.$$"
        if { printf '#!/bin/sh\nexit 0\n' > "$_probe"; } 2>/dev/null \
           && chmod +x "$_probe" 2>/dev/null \
           && "$_probe" >/dev/null 2>&1; then
            rm -f "$_probe"
            WORK_PARENT=$_d
            return 0
        fi
        rm -f "$_probe" 2>/dev/null
    done
    return 1
}
pick_workdir || die "No executable directory found for the build."
WORK=$(mktemp -d "$WORK_PARENT/asmrun.XXXXXX") || die "Could not create temp dir."
LOG="$WORK/build.log"
OBJ="$WORK/prog.o"
if [ -n "$OUT" ]; then EXE=$OUT; else EXE="$WORK/prog"; fi

stage() {
    _label=$1; shift
    [ "$VERBOSE" -eq 1 ] && printf '%s$ %s%s\n' "$DIM" "$*" "$NC" >&2
    if "$@" >"$LOG" 2>&1; then
        [ -s "$LOG" ] && { printf '%s' "$YELLOW" >&2; cat "$LOG" >&2; printf '%s' "$NC" >&2; }
        return 0
    fi
    err "$_label failed:"
    cat "$LOG" >&2
    return 1
}

build_failed() {
    if grep -Eiq 'undefined (reference|symbol)|entry point .* undefined' "$LOG" 2>/dev/null; then
        say "${DIM}Hint: a symbol is not defined — e.g. a libc function like printf. Define 'main' (not '_start')"
        say "      so asmrun links against libc, or fix the entry-point name.${NC}"
    fi
    if [ "$OS" = macos ] && [ "$1" = link ]; then
        say "${DIM}Hint (macOS): global symbols need a leading underscore (_main / _start); syscalls differ from Linux.${NC}"
    fi
    if [ "$1" = assemble ] && [ -z "$FORCE_SYNTAX" ] && [ "$SRC" = x86 ]; then
        say "${DIM}Hint: syntax was auto-detected as ${SYNTAX_LABEL}. Force with --nasm or --gas if wrong.${NC}"
    fi
    exit 1
}

# ==============================================================================
#  6. Assemble + link
# ==============================================================================
if [ "$OS" = macos ]; then
    case "$SRC" in x86) MARCH=x86_64 ;; *) MARCH=arm64 ;; esac
    ENTRY=""
    if   [ "$HAS_MAIN" -eq 1 ];   then ENTRY=""
    elif [ "$HAS_START" -eq 1 ];  then ENTRY="-Wl,-e,_start"
    elif [ "$HAS_PSTART" -eq 1 ]; then ENTRY="-Wl,-e,start"
    fi
    if [ "$SYNTAX" = nasm ]; then
        stage "Assembling (nasm)" nasm -f macho64 -o "$OBJ" "$FILE" || build_failed assemble
        stage "Linking (clang)"   clang -arch "$MARCH" $ENTRY -o "$EXE" "$OBJ" || build_failed link
    else
        stage "Assembling/linking (clang)" clang -arch "$MARCH" -x "$XLANG" $ENTRY -o "$EXE" "$FILE" || build_failed assemble
    fi
    if [ "$SRC" = x86 ] && has '^[[:space:]]*([[:alnum:]_.]+:)?[[:space:]]*syscall([[:space:]]|$)' && ! has '0x20000[0-9a-f]{2}|2000[0-9a-f]{3}h|335544[0-9]{2}'; then
        warn "Uses 'syscall' without the 0x2000000 prefix — macOS numbers differ (write = 0x2000004, exit = 0x2000001)."
    fi
    if [ "$SRC" = arm64 ] && has '(^|[^[:alnum:]_])svc[[:space:]]' && ! has '(^|[^[:alnum:]_])x16([^[:alnum:]_]|$)'; then
        warn "Uses 'svc' but never sets x16 — macOS arm64 wants the syscall number in x16 with 'svc #0x80'."
    fi
else
    LDX="-z noexecstack"; CCX="-Wl,-z,noexecstack"
    if ld --help 2>/dev/null | grep -q -- '--no-warn-rwx-segments'; then
        LDX="$LDX --no-warn-rwx-segments"; CCX="$CCX -Wl,--no-warn-rwx-segments"
    fi
    ASF=""; LDM=""; CCM=""; FMT=elf64
    if [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ]; then ASF="--32"; LDM="-m elf_i386"; CCM="-m32"; FMT=elf32
    elif [ "$SRC" = x86 ]; then ASF="--64"
    fi
    CCMODE=""
    if [ "$HAS_START" -eq 1 ] && [ "$HAS_MAIN" -eq 0 ]; then
        if [ "$USES_LIBC" -eq 1 ]; then CCMODE="-nostartfiles"; else CCMODE="-nostdlib -static"; fi
    fi

    if [ "$SYNTAX" = nasm ]; then
        stage "Assembling (nasm -f $FMT)" nasm -f "$FMT" -o "$OBJ" "$FILE" || build_failed assemble
        if [ "$LINK" = ld ]; then
            stage "Linking (ld)" ld $LDM $LDX -o "$EXE" "$OBJ" || build_failed link
        else
            stage "Linking ($CC)" "$CC" $CCM -no-pie $CCMODE $CCX -o "$EXE" "$OBJ" || build_failed link
        fi
    else
        if [ "$LINK" = ld ]; then
            stage "Assembling (as)" as $ASF -o "$OBJ" "$FILE" || build_failed assemble
            stage "Linking (ld)"    ld $LDM $LDX -o "$EXE" "$OBJ" || build_failed link
        else
            stage "Assembling/linking ($CC)" "$CC" $CCM -no-pie $CCMODE $CCX -x "$XLANG" "$FILE" -o "$EXE" || build_failed assemble
        fi
    fi
fi
[ -n "$OUT" ] && info "Executable kept as: $OUT"

# post-build sanity check (catches any remaining bitness surprise)
if command -v file >/dev/null 2>&1; then
    _type=$(file -b "$EXE" 2>/dev/null || true)
    case "$_type" in
        *ELF*32-bit*|*Mach-O*32-bit*) _built=32 ;;
        *ELF*64-bit*|*Mach-O*64-bit*) _built=64 ;;
        *)                            _built="" ;;
    esac
    if [ -n "$_built" ] && [ "$_built" != "$BITS" ]; then
        warn "Built binary is ${_built}-bit but source was detected as ${BITS}-bit. Force with --32 or --64."
    fi
fi

# ==============================================================================
#  7. Run
# ==============================================================================
RUN=$EXE
case "$RUN" in */*) ;; *) RUN="./$RUN" ;; esac
[ -x "$RUN" ] || chmod +x "$RUN" 2>/dev/null

"$RUN" "$@"
rc=$?

case "$rc" in
    0) ;;
    126) err "Could not execute (permission denied — is $WORK_PARENT mounted noexec?)." ;;
    127) if [ "$OS" = linux ] && [ "$SRC" = x86 ] && [ "$BITS" -eq 32 ]; then
             err "32-bit program could not start (kernel without 32-bit support, or missing loader)."
         else
             printf '%s[exit code %s]%s\n' "$DIM" "$rc" "$NC" >&2
         fi ;;
    137) if [ "$OS" = macos ]; then
             err "Killed. On Apple Silicon try:  codesign -s - -f ${OUT:-<exe>}"
         else
             printf '%s[exit code %s - killed]%s\n' "$DIM" "$rc" "$NC" >&2
         fi ;;
    139) err "Segmentation fault."
         if [ "$SRC" = x86 ] && [ "$BITS" -eq 64 ] && has 'int[[:space:]]+[$]?(0x80|80h)([^[:alnum:]_]|$)'; then
             say "       ${BOLD}This file uses 'int 0x80/80h' — that is 32-bit code. asmrun built it as 64-bit"
             say "       (no explicit BITS 32 directive was found). Re-run with:  asmrun --32 $FILE${NC}"
         else
             say "       Common causes: no exit syscall (ran off the end of _start),"
             say "       misaligned stack at a 'call', or a bad pointer/address."
         fi ;;
    132) err "Illegal instruction (wrong CPU mode, or execution ran into data)." ;;
    *)   if [ "$rc" -gt 128 ]; then
             _sig=$(kill -l $((rc - 128)) 2>/dev/null || echo "?")
             printf '%s[terminated by signal %s (%s)]%s\n' "$DIM" "$((rc - 128))" "$_sig" "$NC" >&2
         else
             printf '%s[exit code %s]%s\n' "$DIM" "$rc" "$NC" >&2
         fi ;;
esac
exit "$rc"
