@@rem ======================================================================
@@rem  asmrun-v2.bat - asmrun for Windows. Documentation: asmrunForWindows.md
@@rem  LAYOUT: lines that start with two at-signs are this cmd launcher.
@@rem  Every other line is the PowerShell program. The launcher copies the
@@rem  PowerShell lines to a temp .ps1 and runs it with -File, so names with
@@rem  spaces and special characters reach the program unchanged.
@@rem ======================================================================
@@echo off
@@setlocal EnableExtensions DisableDelayedExpansion
@@set "ASMRUN_BAT=%~f0"
@@set "ASMRUN_HOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
@@if defined ASMRUN_PSHOST set "ASMRUN_HOST=%ASMRUN_PSHOST%"
@@if not exist "%ASMRUN_HOST%" set "ASMRUN_HOST=pwsh.exe"
@@set "ASMRUN_TMP=%TEMP%"
@@if not defined ASMRUN_TMP set "ASMRUN_TMP=%~dp0"
@@set "ASMRUN_PS1=%ASMRUN_TMP%\asmrun_%RANDOM%%RANDOM%.ps1"
@@findstr /v /b /c:"@@" "%~f0" >"%ASMRUN_PS1%"
@@"%ASMRUN_HOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ASMRUN_PS1%" %*
@@set "ASMRUN_RC=%ERRORLEVEL%"
@@del "%ASMRUN_PS1%" >nul 2>&1
@@if "%ASMRUN_RC%"=="9009" echo asmrun: PowerShell could not be started. Install PowerShell or set ASMRUN_PSHOST. 1>&2
@@exit /b %ASMRUN_RC%
# ============================================================================
#  asmrun for Windows - PowerShell program
#  (This is everything in asmrun.bat that does not start with two at-signs.)
#
#  Layout of this program, top to bottom:
#    1. core        output helpers, argument quoting, process runner, prompts
#    2. options     command-line / config-file parsing, help text
#    3. source      reading the source file, detection (ported from asmrun-v5.sh)
#    4. tools       finding / installing Windows tools (winget)
#    5. native      Windows-native build + run (NASM/GAS + MinGW-w64)
#    6. wsl         WSL route: path translation, running the embedded v5 engine
#    7. extras      --doctor, --selftest
#    8. main        file lookup, routing, interactive prompt loop, pause-on-double-click
#    9. engine      the embedded POSIX engine (asmrun-v5.sh, verbatim)
#   10. entry       the single line that starts everything (must stay last)
#
#  PowerShell rules for this file (it must run on Windows PowerShell 5.1 AND 7+):
#    * No ternary (?:), no ?? , no ?. , no && / || pipeline chains, no ForEach -Parallel.
#    * Variable names are CASE-INSENSITIVE: $re and $RE are the same variable.
#    * ASCII only. Lines must never start with two at-signs (reserved for the launcher).
# ============================================================================
# ============================================================================
#  1. CORE  -  output helpers, argument quoting, process runner, prompts
# ============================================================================
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Version       = '2.0.0'
$script:EngineVersion = '6.0.0'     # version of the embedded POSIX engine
$script:OnWindows     = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:SelfPath      = $env:ASMRUN_BAT
if (-not $script:SelfPath) { $script:SelfPath = $PSCommandPath }
$script:SelfDir       = Split-Path -Parent $script:SelfPath
$script:ExitCode      = 0
$script:Cleanup       = New-Object System.Collections.ArrayList   # temp files/dirs removed on exit
$script:KeepWork        = $false
$script:PatCache      = @{}
$script:Verbose       = $false
$script:Commands      = New-Object System.Collections.ArrayList  # commands shown to the user (for --report)

# ---------------------------------------------------------------- output ----
# Diagnostics go to STDERR so that stdout stays clean for the program being run.
function Write-Tag {
    param([string]$Tag, [string]$Color, [string]$Text)
    $e = [Console]::Error
    $useColor = ($Color -and -not [Console]::IsErrorRedirected -and -not $env:NO_COLOR)
    if ($useColor) { try { [Console]::ForegroundColor = $Color } catch { $useColor = $false } }
    $e.Write($Tag)
    if ($useColor) { try { [Console]::ResetColor() } catch { } }
    $e.WriteLine(' ' + $Text)
}
function Say    { param([string]$T) [Console]::Error.WriteLine($T) }
function Info   { param([string]$T) Write-Tag '[INFO]' 'Cyan'   $T }
function VInfo  { param([string]$T) if ($script:Verbose) { Write-Tag '[INFO]' 'Cyan' $T } }
function Warn   { param([string]$T) Write-Tag '[WARN]' 'Yellow' $T }
function Fail   { param([string]$T) Write-Tag '[ERROR]' 'Red'    $T }
function Good   { param([string]$T) Write-Tag '[ OK ]' 'Green'  $T }
function Show-Cmd { param([string]$T) Write-Tag '[BUILD]' 'DarkGray' $T }

# Print an error and leave through the single exit point (see Main).
function Die {
    param([string]$Msg, [int]$Code = 1)
    Fail $Msg
    $script:ExitCode = $Code
    throw 'ASMRUN_EXIT'
}
# Leave quietly (help, version, ...).
function Stop-Run {
    param([int]$Code = 0)
    $script:ExitCode = $Code
    throw 'ASMRUN_EXIT'
}

# ------------------------------------------------------ argument quoting ----
# Quote ONE argument following the rules of CommandLineToArgvW (what every
# Windows program uses to split its command line).
function ConvertTo-ArgString1 {
    param([string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg.IndexOfAny([char[]]@(' ', "`t", "`n", "`v", '"')) -lt 0) { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Arg.Length) {
        $bs = 0
        while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $bs++; $i++ }
        if ($i -eq $Arg.Length) {
            [void]$sb.Append([char]92, $bs * 2)       # backslashes before the closing quote
        } elseif ($Arg[$i] -eq '"') {
            [void]$sb.Append([char]92, $bs * 2 + 1)   # escape them and the quote
            [void]$sb.Append('"')
            $i++
        } else {
            [void]$sb.Append([char]92, $bs)
            [void]$sb.Append($Arg[$i])
            $i++
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function ConvertTo-ArgString {
    param([string[]]$List)
    $parts = New-Object System.Collections.ArrayList
    foreach ($a in @($List)) { [void]$parts.Add((ConvertTo-ArgString1 $a)) }
    return ($parts -join ' ')
}
# Human-readable form of an argument (for the [BUILD] lines): quote only if needed.
function Format-Arg {
    param([string]$A)
    if ($A -match '^[A-Za-z0-9_./:=+@%\\,-]+$') { return $A }
    return '"' + $A.Replace('"', '\"') + '"'
}
function Format-Command {
    param([string]$File, [string[]]$Arguments)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add((Format-Arg ([IO.Path]::GetFileName($File))))
    foreach ($a in @($Arguments)) { [void]$parts.Add((Format-Arg $a)) }
    return ($parts -join ' ')
}

# ------------------------------------------------------- process runner ----
# Capture = $true : stdout/stderr are collected and returned.
# Capture = $false: the child INHERITS this console (stdin, stdout, stderr), so
#                   interactive programs and exact output bytes work untouched.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Capture, [System.Text.Encoding]$OutEncoding, [int]$TimeoutSec = 0)
    $r = @{ Started = $false; ExitCode = -1; Out = ''; Err = ''; Error = ''; TimedOut = $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute = $false
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow = $true
        if ($OutEncoding) { $psi.StandardOutputEncoding = $OutEncoding; $psi.StandardErrorEncoding = $OutEncoding }
    }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { $r.Error = $_.Exception.Message; return $r }
    $r.Started = $true
    if ($Capture) {
        $errTask = $p.StandardError.ReadToEndAsync()
        $r.Out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $r.Err = $errTask.Result
    } elseif ($TimeoutSec -gt 0) {
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $r.TimedOut = $true
            try { $p.Kill() } catch { }
            $p.WaitForExit()
        }
    } else {
        $p.WaitForExit()
    }
    $r.ExitCode = $p.ExitCode
    $p.Dispose()
    return $r
}

# wsl.exe writes its OWN messages as UTF-16; strip the NULs so they read as text.
function Repair-WslText {
    param([string]$T)
    if (-not $T) { return '' }
    return (($T -replace "`0", '') -replace '[\uFFFD\uFEFF]', '').Trim()
}

# ------------------------------------------------------------- paths -------
function Resolve-FullPath {
    param([string]$P)
    if ([IO.Path]::IsPathRooted($P)) { return [IO.Path]::GetFullPath($P) }
    return [IO.Path]::GetFullPath((Join-Path $PWD.ProviderPath $P))
}
function New-TempDir {
    param([string]$Parent)
    if (-not $Parent) { $Parent = [IO.Path]::GetTempPath() }
    $name = 'asmrun.' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $Parent $name
    [void][IO.Directory]::CreateDirectory($dir)
    [void]$script:Cleanup.Add($dir)
    return $dir
}
function Invoke-Cleanup {
    foreach ($item in @($script:Cleanup)) {
        if ($script:KeepWork -and (Test-Path -LiteralPath $item -PathType Container) -and $item -like '*asmrun.*') { continue }
        try { if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }
}
# Write text as UTF-8 WITHOUT a byte-order mark and with LF line endings.
function Write-Utf8Lf {
    param([string]$Path, [string]$Text)
    $t = $Text.Replace("`r`n", "`n")
    [IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------- prompts -------
function Test-Interactive { return (-not [Console]::IsInputRedirected) }
function Read-Line {
    param([string]$Prompt)
    [Console]::Error.Write($Prompt)
    # $Host.UI.ReadLine() reads UTF-16 from the console, so folder names in any language survive
    # drag-and-drop; [Console]::In would squeeze them through the OEM code page.
    if ($script:OnWindows) { try { return $Host.UI.ReadLine() } catch { } }
    return [Console]::In.ReadLine()
}
# Returns $true / $false, or $null when there is no terminal to ask on.
function Confirm-Yes {
    param([string]$Question, [bool]$Default = $true)
    if ($script:Opt.Yes) { return $true }
    if (-not (Test-Interactive)) { return $null }
    $hint = '[Y/n]'; if (-not $Default) { $hint = '[y/N]' }
    while ($true) {
        $a = Read-Line ("$Question $hint ")
        if ($null -eq $a) { return $null }
        $a = $a.Trim().ToLower()
        if ($a -eq '') { return $Default }
        if ($a -eq 'y' -or $a -eq 'yes') { return $true }
        if ($a -eq 'n' -or $a -eq 'no')  { return $false }
        Say 'Please answer y or n.'
    }
}

# ============================================================================
#  2. OPTIONS
# ============================================================================
function New-Opt {
    return @{
        Verbose = $false; Yes = $false; Output = ''; Report = ''
        Syntax = 'auto'; Bits = 0; Arch = ''; Target = ''; Cc = ''
        AsmOnly = $false; LinkOnly = $false; Keep = $false
        SelfTest = $false; Version = $false; Help = $false; EngineHelp = $false; EngineInfo = $false
        Detect = $false; ListTargets = $false; Linker = 'auto'; Timeout = 0
        Mode = 'auto'            # auto | wsl | native
        Distro = ''; Engine = ''; DumpEngine = $false; DryRun = $false; Doctor = $false
        Pause = 'auto'           # auto | yes | no
        Workdir = ''
        Fwd = (New-Object System.Collections.ArrayList)   # options forwarded to the POSIX engine
        UnknownFwd = (New-Object System.Collections.ArrayList)
        File = ''; ProgArgs = @()
    }
}
$script:Opt = New-Opt

# Split a string into tokens, honouring "double" and 'single' quotes.
function Split-Tokens {
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    if (-not $Text) { return ,@() }
    $sb = New-Object System.Text.StringBuilder
    $q = ''; $has = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($q -ne '') {
            if ($ch -eq $q) { $q = '' } else { [void]$sb.Append($ch) }
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $q = [string]$ch; $has = $true
        } elseif ([char]::IsWhiteSpace($ch)) {
            if ($has -or $sb.Length -gt 0) { [void]$out.Add($sb.ToString()); [void]$sb.Clear(); $has = $false }
        } else {
            [void]$sb.Append($ch)
        }
    }
    if ($has -or $sb.Length -gt 0) { [void]$out.Add($sb.ToString()) }
    return ,($out.ToArray())
}

$script:ValueOpts = @('-o', '--output', '--arch', '--target', '--cc', '--report', '--distro', '--engine', '--workdir', '--linker',
                      '--march', '--as-flags', '--ld-flags', '--cc-flags', '--nasm-flags', '--qemu-flags', '--timeout')

# Parses options from $Tokens into $script:Opt.  Stops at the first non-option
# (the file name) or at "--".  Returns the remaining tokens (file + program args).
function Read-Options {
    param([string[]]$Tokens)
    $O = $script:Opt
    $Tokens = @($Tokens)
    $i = 0
    $n = $Tokens.Count
    while ($i -lt $n) {
        $a = $Tokens[$i]
        if ($a -eq '--') { $i++; break }
        if (-not $a.StartsWith('-') -or $a -eq '-') { break }

        $name = $a; $val = $null
        if ($a.StartsWith('--') -and $a.Contains('=')) {
            $name = $a.Substring(0, $a.IndexOf('='))
            $val  = $a.Substring($a.IndexOf('=') + 1)
        }
        if ($script:ValueOpts -contains $name) {
            if ($null -eq $val) {
                $i++
                if ($i -ge $n) { Die "Option $name needs a value." 2 }
                $val = $Tokens[$i]
            }
            if ([string]::IsNullOrEmpty($val)) { Die "Option $name needs a value." 2 }
        }

        switch -CaseSensitive ($name) {
            { $_ -ceq '-h' -or $_ -ceq '--help' }      { $O.Help = $true }
            '--version'                              { $O.Version = $true }
            { $_ -ceq '-v' -or $_ -ceq '--verbose' }   { $O.Verbose = $true; [void]$O.Fwd.Add('-v') }
            { $_ -ceq '-y' -or $_ -ceq '--yes' }       { $O.Yes = $true;     [void]$O.Fwd.Add('-y') }
            { $_ -ceq '-o' -or $_ -ceq '--output' }    { $O.Output = $val }
            '--report'                               { $O.Report = $val }
            '--nasm'                                 { $O.Syntax = 'nasm'; [void]$O.Fwd.Add('--nasm') }
            { $_ -ceq '--gas' -or $_ -ceq '--as' }     { $O.Syntax = 'gas';  [void]$O.Fwd.Add('--gas') }
            '--32'                                   { $O.Bits = 32; [void]$O.Fwd.Add('--32') }
            '--64'                                   { $O.Bits = 64; [void]$O.Fwd.Add('--64') }
            '--arch'                                 { $O.Arch = $val;   [void]$O.Fwd.Add('--arch');   [void]$O.Fwd.Add($val) }
            '--target'                               { $O.Target = $val; [void]$O.Fwd.Add('--target'); [void]$O.Fwd.Add($val) }
            '--cc'                                   { $O.Cc = $val;     [void]$O.Fwd.Add('--cc');     [void]$O.Fwd.Add($val) }
            { $_ -ceq '--keep-build-dir' -or $_ -ceq '--keep' } { $O.Keep = $true; [void]$O.Fwd.Add('--keep-build-dir') }
            '--asm-only'                             { $O.AsmOnly = $true;  [void]$O.Fwd.Add('--asm-only') }
            { $_ -ceq '--link-only' -or $_ -ceq '--no-run' } { $O.LinkOnly = $true; [void]$O.Fwd.Add('--link-only') }
            '--selftest'                             { $O.SelfTest = $true }
            '--masm'                                 { $O.Syntax = 'masm' }
            '--detect'                               { $O.Detect = $true }
            '--list-targets'                         { $O.ListTargets = $true }
            '--linker'                               { if (@('auto', 'builtin', 'gcc') -notcontains $val) { Die "--linker must be auto, builtin or gcc." 2 }; $O.Linker = $val }
            { $_ -eq '-g' -or $_ -eq '--debug' }     { [void]$O.Fwd.Add('-g') }
            '--no-color'                             { $env:NO_COLOR = '1'; [void]$O.Fwd.Add('--no-color') }
            '--timeout'                              { $secs = 0; if (-not [int]::TryParse($val, [ref]$secs) -or $secs -lt 0) { Die '--timeout needs a number of seconds.' 2 }; $O.Timeout = $secs; [void]$O.Fwd.Add('--timeout'); [void]$O.Fwd.Add($val) }
            { 'march', 'as-flags', 'ld-flags', 'cc-flags', 'nasm-flags', 'qemu-flags' -ccontains $_.TrimStart('-') } { [void]$O.Fwd.Add($name); [void]$O.Fwd.Add($val) }
            # ---- Windows-only options (never forwarded to the engine) ----
            '--wsl'                                  { $O.Mode = 'wsl' }
            { $_ -ceq '--native' -or $_ -ceq '--windows' } { $O.Mode = 'native' }
            '--distro'                               { $O.Distro = $val }
            '--engine'                               { $O.Engine = $val }
            '--engine-help'                          { $O.EngineHelp = $true }
            '--dump-engine'                          { $O.DumpEngine = $true }
            '--engine-info'                          { $O.EngineInfo = $true }
            { $_ -ceq '--dry-run' -or $_ -ceq '--plan' } { $O.DryRun = $true }
            '--doctor'                               { $O.Doctor = $true }
            '--pause'                                { $O.Pause = 'yes' }
            '--no-pause'                             { $O.Pause = 'no' }
            '--workdir'                              { $O.Workdir = $val }
            default {
                # Unknown here: the POSIX engine may know it (new engine versions).
                # Only "--flag" / "--flag=value" forms can be passed through safely.
                [void]$O.Fwd.Add($a)
                [void]$O.UnknownFwd.Add($a)
            }
        }
        $i++
    }
    if ($i -ge $n) { return ,@() }
    return ,($Tokens[$i..($n - 1)])
}

# Flags from environment (ASMRUN_FLAGS) and from .asmrunrc.win files.
# NOTE: .asmrunrc.win is a plain list of flags (NOT a shell script like ~/.asmrunrc).
function Read-ConfigFlags {
    if ($env:ASMRUN_NO_RC) { return }
    $files = New-Object System.Collections.ArrayList
    if ($env:USERPROFILE) { [void]$files.Add((Join-Path $env:USERPROFILE '.asmrunrc.win')) }
    [void]$files.Add((Join-Path $PWD.ProviderPath '.asmrunrc.win'))
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $tokens = New-Object System.Collections.ArrayList
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            foreach ($t in (Split-Tokens $l)) { [void]$tokens.Add($t) }
        }
        $rest = Read-Options $tokens.ToArray()
        if (@($rest).Count -gt 0) { Warn "Ignoring non-option text in $f : $(@($rest) -join ' ')" }
    }
}
function Read-EnvFlags {
    if ($env:ASMRUN_FLAGS) {
        $rest = Read-Options (Split-Tokens $env:ASMRUN_FLAGS)
        if (@($rest).Count -gt 0) { Warn "Ignoring non-option text in ASMRUN_FLAGS: $(@($rest) -join ' ')" }
    }
}

# Same normalisation as asmrun-v5.sh, so mistakes are reported early.
function Get-ArchName {
    param([string]$A)
    switch -CaseSensitive ($A) {
        { 'x86', 'x86_64', 'x86-64', 'amd64', 'i386', 'i486', 'i586', 'i686' -ccontains $_ } { return 'x86' }
        { 'arm64', 'aarch64' -ccontains $_ }                  { return 'arm64' }
        { 'arm', 'arm32', 'armv7', 'armhf' -ccontains $_ }    { return 'arm32' }
        { 'riscv', 'riscv64' -ccontains $_ }                  { return 'riscv' }
        { 'ppc', 'ppc64', 'ppc64le', 'powerpc' -ccontains $_ }  { return 'ppc' }
        's390x'                                               { return 's390x' }
        { 'mips', 'mips64', 'mips64el' -ccontains $_ }        { return 'mips' }
        { 'loong', 'loongarch', 'loongarch64' -ccontains $_ } { return 'loong' }
        default { Die "Unknown --arch '$A' (x86 | arm64 | arm32 | riscv | ppc | s390x | mips | loong)." 2 }
    }
}
function Get-TargetName {
    param([string]$T)
    switch -CaseSensitive ($T) {
        { 'x86_64', 'amd64', 'x86-64', 'x64' -ccontains $_ }                              { return 'x86_64' }
        { 'i386', 'i486', 'i586', 'i686', 'x86', 'ia32' -ccontains $_ }                   { return 'i386' }
        { 'aarch64', 'arm64', 'armv8', 'armv8-a' -ccontains $_ }                          { return 'aarch64' }
        { 'armv7', 'armv7l', 'armv7-a', 'arm', 'arm32', 'armhf' -ccontains $_ }           { return 'armv7' }
        { 'riscv64', 'riscv', 'rv64', 'riscv64gc' -ccontains $_ }                         { return 'riscv64' }
        { 'ppc64le', 'powerpc64le', 'ppc64el', 'ppc' -ccontains $_ }                      { return 'ppc64le' }
        's390x'                                                                           { return 's390x' }
        { 'mips64el', 'mips64', 'mips' -ccontains $_ }                                    { return 'mips64el' }
        { 'loongarch64', 'loongarch', 'loong64', 'la64' -ccontains $_ }                   { return 'loongarch64' }
        default { Die "Unknown --target '$T' (x86_64 | i386 | aarch64 | armv7 | riscv64 | ppc64le | s390x | mips64el | loongarch64)." 2 }
    }
}

function Show-Usage {
@"
asmrun for Windows $($script:Version)   (embedded POSIX engine: asmrun v$($script:EngineVersion))

Usage: asmrun [options] <file> [program arguments...]
       asmrun                      (no file: asks for one - you can drag & drop it)

Assembles, links and runs a hand-written assembly file, whatever its syntax or CPU.
asmrun looks at the file and chooses the route by itself:
  * Windows programs, x86 / x64, in NASM, GNU as, MASM (ml64 / UASM / JWasm) or FASM
    syntax -> built natively and run as a normal .exe.  Linking needs no MinGW:
    asmrun has its own PE linker (used whenever gcc cannot do the job, e.g. 32-bit).
  * Linux programs (int 0x80 / syscall), ARM, RISC-V, PowerPC, s390x, MIPS, LoongArch,
    --target ...  -> built and run inside WSL by the full asmrun v$($script:EngineVersion) engine.
If asmrun.bat and your file are in the same folder, the file name alone is enough.

Options (put them BEFORE the file name):
  -v, --verbose         show detection details and every command
  -y, --yes             install missing tools without asking
  -o, --output FILE     keep the output at FILE
      --asm-only        assemble only; write the object file and stop
      --link-only       assemble+link, but do not run (alias: --no-run)
      --keep-build-dir  keep the temporary build directory
      --nasm | --gas (--as) | --masm      force the assembler syntax
      --32 | --64       force 32-bit / 64-bit (x86 only)
      --arch ARCH       force source arch: x86 | arm64 | arm32 | riscv | ppc | s390x | mips | loong
      --target TARGET   cross-build a LINUX program: x86_64 | i386 | aarch64 | armv7 | riscv64 |
                        ppc64le | s390x | mips64el | loongarch64   (runs through WSL)
      --cc CMD          use CMD as the C compiler/linker driver
      --report FILE     write a JSON build/run report to FILE
      --detect          print what asmrun detects about the file (engine-compatible) and stop
      --list-targets    list the Linux targets the engine supports (needs WSL)
      --timeout SEC     stop the program after SEC seconds
  -g, --debug           debug info (Linux route)
      --march/--as-flags/--ld-flags/--cc-flags/--nasm-flags/--qemu-flags VALUE   (Linux route)
      --no-color        no colours
      --selftest        run the built-in self test and exit
      --version         print the version and exit
  -h, --help            this help

Windows-only options:
      --linker WHICH    auto (default) | builtin | gcc.   auto = gcc when it can link this
                        bit size, otherwise the built-in linker; falls back by itself
      --wsl             force the Linux route (WSL)
      --native          force the Windows route (alias: --windows)
      --distro NAME     WSL distribution to use (default: your default distro)
      --engine FILE     use FILE (a POSIX asmrun script) instead of the embedded one
      --engine-help     show the help text of the embedded POSIX engine
      --engine-info     print the embedded engine's version, size and SHA-256, then exit
      --dump-engine     print the embedded POSIX engine to stdout and exit
      --dry-run         show what would be done; build and run nothing (alias: --plan)
      --doctor          check this PC (PowerShell, WSL, assemblers, linker, winget) and exit
      --workdir DIR     build in DIR instead of %TEMP%
      --pause           always wait for a key at the end
      --no-pause        never wait for a key at the end

Anything after the file name is passed to your program as arguments.

Examples:
  asmrun hello.s                      (Linux asm -> WSL;  Windows asm -> native)
  asmrun C:\code\prog.asm
  asmrun --32 win32.asm               (works without any 32-bit MinGW)
  asmrun hello_ml64.asm               (MASM; UASM is offered if no MASM assembler is present)
  asmrun --wsl --32 boot.s
  asmrun --asm-only -o hello.obj win.asm
  asmrun --target aarch64 --link-only hello.s

Environment:
  NO_COLOR=1          disable colours
  ASMRUN_NO_RC=1      do not read .asmrunrc.win files
  ASMRUN_FLAGS=...    extra options, parsed before the command line
  ASMRUN_CC=...       default C compiler/linker driver (native route)
  ASMRUN_NASM=...     full path of nasm.exe        ASMRUN_MASM=...  full path of ml64 / uasm / jwasm
  ASMRUN_NOPAUSE=1    never wait for a key at the end
  ASMRUN_ENGINE=...   same as --engine
  ASMRUN_PSHOST=...   PowerShell executable used by asmrun.bat

Config files (plain list of options, one or more per line, # comments):
  %USERPROFILE%\.asmrunrc.win    and    .\.asmrunrc.win
Double-click asmrun.bat to be asked for a file (drag & drop works).
"@
}

# ============================================================================
#  3. SOURCE  -  read the file, detect arch / syntax / bits / entry / route
# ============================================================================
# Detection patterns, ported mechanically from the engine's detect_* code by Update-AsmrunEngine.ps1:
# BEGIN GENERATED PATTERNS  (written by Update-AsmrunEngine.ps1 from the engine; POSIX ERE -> .NET; do not edit)
$script:SrcPat = @{
    ArchX86          = '(^|[^A-Za-z0-9_])(r(ax|bx|cx|dx|si|di|bp|sp|ip)|e(ax|bx|cx|dx|si|di|bp|sp|ip)|r(8|9|1[0-5])[dwb]|[xyz]mm[0-9]+)([^A-Za-z0-9_]|$)|(^|[\s])syscall[\s]*$|(^|[\s])sysenter([\s]|$)|(^|[\s])int[\s]+[$]?(0x80|80h|0x2e|2eh)([^A-Za-z0-9_]|$)|[.]intel_syntax|[.]att_syntax|[.]code(16|32|64)([\s]|$)|(^|[\s])bits[\s]+(16|32|64)|(^|[\s])(pushad|popad|pushfd|popfd|pushfq|popfq)([\s]|$)|^[\s]*(global|extern|section|segment)[\s]|(^|[\s]|:)(db|dw|dd|dq|resb|resw|resd|resq|equ|times)[\s]|^[\s]*%[\s]*(define|macro|include|ifdef|ifndef|if|else|endif|assign|rep|xdefine)([\s]|$)|(^|[\s])(lea|movzx|movsx|movsxd|cpuid|rdtsc|cqo|cdq|cltq|cltd|cwde|leaveq?|movabs[qlwb]?)([\s]|$)'
    ArchArm64        = '(^|[^A-Za-z0-9_.])([xw]([0-9]|[12][0-9]|30)|xzr|wzr)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.])(stp|ldp|adrp|adr|cbz|cbnz|tbz|tbnz|csel|cset|hvc|smc|eret|mrs|msr|ldur|stur|ldrsw|movk|movz|movn|ubfx|sbfx|ccmp|cinc|csinc|madd|msub|umulh|smulh)[\s]|(^|[\s])svc[\s]+#|(^|[\s])(blr|br)[\s]+x[0-9]+|[.]arch[\s]+armv8|aarch64|(^|[\s])[.]xword[\s]|[.]arch_extension|(^|[^A-Za-z0-9_])v([0-9]|[12][0-9]|3[01])[.][0-9]*[bhsd]([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])z([0-9]|[12][0-9]|3[01])[.][bhsdq]|@(page|pageoff|gotpage|gotpageoff)([^A-Za-z0-9_]|$)'
    ArchArm32        = '(^|[\s])(push|pop|stmfd|ldmfd|stmdb|ldmia|stmia|ldmdb|stm|ldm)[\s]*[{]|[.]syntax[\s]+unified|(^|[\s])(bx|blx)[\s]+(lr|r[0-9]+)|[.](thumb|thumb_func|arm|fpu|eabi_attribute|thumb_set|code[\s]+(16|32))([\s]|$)|[.]cpu[\s]+(cortex-[amr][0-9]+|arm[0-9a-z]+|xscale)|(^|[\s])swi[\s]|(^|[\s])(mov|movs|movw|movt|mvn|orr|eor|bic|cmp|cmn|tst|teq|rsb|rsc|ldr|str|ldrb|strb|ldrh|strh|ldrsb|ldrsh|lsl|lsr|asr|ror|mul|mla|adds|subs|add|sub|and)[a-z]?[a-z]?[\s]+(r([0-9]|1[0-2])|lr|pc)[\s]*,|(^|[^A-Za-z0-9_])r([0-9]|1[0-2])[\s]*,[\s]*#|[[]r([0-9]|1[0-2])[],]|[{][\s]*r[0-9]|(^|[\s])(ite|itt|itee|ittt)[\s]+[a-z][a-z]|(^|[\s])cbn?z[\s]+r[0-7]'
    ArchRiscv        = '(^|[^A-Za-z0-9_.])(ecall|ebreak)([^A-Za-z0-9_]|$)|(^|[\s])(li|la|lla|mv|not|neg|seqz|snez|sltz|sgtz|addi|add|sub|and|or|xor|slli|srli|srai|slti|sltiu|slt|sltu|lui|auipc|jal|jalr|beq|bne|blt|bge|bltu|bgeu|beqz|bnez|blez|bgez|bltz|bgtz|lw|sw|ld|sd|lh|sh|lb|sb|lbu|lhu|lwu|csrr?[a-z]*)[\s]+(a[0-7]|t[0-6]|s([0-9]|1[01])|ra|zero|gp|tp)[\s]*,|(^|[\s])(addi|ld|sd|lw|sw|lwu|lb|sb|lh|sh|fld|fsd)[\s]+(sp|fp)[\s]*,|[.]option[\s]+(rvc|norvc|push|pop|arch|relax|norelax)|(^|[\s])c[.](addi|mv|li|add|sub|lw|sw|ld|sd|j|jal|beqz|bnez|nop)([\s]|$)|[.]attribute[\s]+(arch|stack_align|unaligned_access)|(^|[\s])vset(i?)vli[\s]'
    ArchPpc          = '(^|[\s])(mflr|mtlr|mtctr|mfctr|bctr|bctrl|bdnz|bdz|lwz|lwzu|stwu|stdu|lwzx|stwx|ldx|stdx|addis|addic|cmpwi|cmpdi|cmplwi|cmpldi|rlwinm|rldicl|rldicr|rlwimi|extsw|extsb|extsh|srawi|sradi|slwi|srwi|lis|mfcr|mtcr|mfspr|mtspr|stbu|lbzu|ldu|lhz|lbz)[\s]|(^|[\s])blr[\s]*$|(^|[\s])sc[\s]*$|(^|[\s])(li|addi|ori|oris|ld|std|stw|mr|cmpw|cmpd|mulld|divd|subf|neg)[\s]+%?r?([0-9]|[12][0-9]|3[01])[\s]*,|[.](localentry|abiversion)|[.]machine[\s]+(power|ppc|pwr)|@(ha|toc)([^A-Za-z0-9_]|$)|@l([^A-Za-z0-9_]|$)|[.]TOC[.]|(^|[^A-Za-z0-9_])%?r(1[6-9]|2[0-9]|3[01])[\s]*(,|$|[)])'
    ArchS390x        = '(^|[\s])(lghi|lgr|stmg|lmg|larl|brasl|basr|bras|aghi|lgfr|llgc|llgf|cgr|cghi|cgfi|ltgr|lgf|stg|lg|lhi|stam|lam|clgr|clg|sllg|srlg|slag|srag|agr|sgr|msgr|dsgr|lcgr|lngr|lpgr|ngr|ogr|xgr)[\s]+%?r?[0-9]|(^|[\s])br[\s]+%r14|[.]machine[\s]+(z[0-9]+|zarch)|(^|[^A-Za-z0-9_])%r[0-7]([^A-Za-z0-9_]|$)'
    ArchMips         = '^[\s]*([A-Za-z_.$][A-Za-z0-9_.$]*:[\s]*)?[a-z][a-z0-9]*[\s]+[^;]*[$](zero|at|v[01]|a[0-7]|t[0-9]|s[0-8]|k[01]|gp|sp|fp|ra|f[0-9]+)([^A-Za-z0-9_]|$)|[.]set[\s]+(noreorder|reorder|noat|at|mips[0-9]+|nomacro|macro)|[.](ent|frame|mask|fmask|cpload|cprestore|cpsetup|cplocal)([\s]|$)|(^|[\s])(addiu|daddiu|daddu|dsubu|subu|dsll|dsll32|dsra|dsrl|mfhi|mflo|mthi|mtlo|multu?|dmultu?|bgezal|bltzal|dla|dli)([\s]|$)|(^|[\s])jr[\s]+[$]ra'
    ArchLoong        = '(^|[\s])[a-z][a-z0-9]*[.][a-z0-9.]+[\s]+[$]|(^|[\s])(jirl|pcalau12i|pcaddu12i|pcaddi|bstrpick|bstrins)[\s]|(^|[\s])la[.](local|global|pcrel|abs|got)|(^|[\s])syscall[\s]+(0x)?[0-9]+|[$]r([0-9]|[12][0-9]|3[01])([^A-Za-z0-9_]|$)'
    SynMarker        = '[.]intel_syntax|[.]att_syntax'
    SynCpp           = '^#(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)([\s<"(]|$)'
    SynNasm          = '^[\s]*(section|segment)[\s]+[.]|^[\s]*(global|extern)[\s]+[A-Za-z_.$]|(^|[\s]|:)(db|dw|dd|dq|dt|resb|resw|resd|resq|equ|times)[\s]|^[\s]*%[\s]*(define|macro|endmacro|include|assign|if|ifdef|ifndef|else|endif|rep|endrep|xdefine|undef|imacro|strlen|ifidn|ifnum)|(^|[\s])bits[\s]+(16|32|64)|^[\s]*default[\s]+rel|(byte|word|dword|qword)[\s]+[[]'
    SynGas           = '^[\s]*[.](globl|global|section|text|data|bss|ascii|asciz|string|quad|long|byte|word|short|int|skip|space|zero|equ|set|align|balign|p2align|type|size|macro|endm|code32|code64|file|ident|rodata|comm|lcomm|fill|rept|endr)([\s]|$)|%[re]?(ax|bx|cx|dx|si|di|bp|sp)([^A-Za-z0-9_]|$)|%r(8|9|1[0-5])[dwb]?([^A-Za-z0-9_]|$)|%[abcd][lh]([^A-Za-z0-9_]|$)|%[xy]?mm[0-9]+|(^|[\s])(mov|add|sub|push|pop|lea|cmp|xor|and|or|test|inc|dec|imul|idiv|shl|shr|call|ret|jmp)[bwlq][\s]|[$][-]?(0x[0-9a-f]+|[0-9]+)'
    Bits32Dir        = '(^|[^A-Za-z0-9_])bits[\s]+32|[.]code32'
    Bits64Dir        = '(^|[^A-Za-z0-9_])bits[\s]+64|[.]code64'
    BitInt80         = '(^|[\s])int[\s]+[$]?(0x80|80h|0x2e|2eh)([^A-Za-z0-9_]|$)'
    BitSyscall       = '(^|[\s])syscall[\s]*$'
    BitSysenter      = '(^|[^A-Za-z0-9_])sysenter([^A-Za-z0-9_]|$)'
    Bit32Ops         = '(^|[^A-Za-z0-9_])(pushad|popad|pushfd|popfd)([^A-Za-z0-9_]|$)'
    Bit64Ops         = '(^|[^A-Za-z0-9_])(pushfq|popfq|cqo|cltq|movabs[qlwb]?)([^A-Za-z0-9_]|$)'
    Reg32            = '(^|[^A-Za-z0-9_])e(sp|bp|ip)([^A-Za-z0-9_]|$)|[[]e(ax|bx|cx|dx|si|di|bp|sp)|[(]%e(ax|bx|cx|dx|si|di|bp|sp)'
    Reg64            = '(^|[^A-Za-z0-9_])(r(ax|bx|cx|dx|si|di|sp|bp|ip)|r([8-9]|1[0-5])[dwb]?)([^A-Za-z0-9_]|$)|[(]%rip|[[]rel[\s]|default[\s]+rel|wrt[\s]+[.][.]plt'
    Boot16           = '^[\s]*(org[\s]+(0x)?7c00|[[]bits 16[]])'
    MasmGate         = '^[\s]*(org[\s]+(0x)?7c00|[[]bits 16[]]|[.]code16|[.]model[\s]|[.](386|486|586|686)[\s]*$|^[\s]*[A-Za-z_@$?][A-Za-z0-9_@$?]*[\s]+(proc|endp)([\s]|$)|^[\s]*(include(lib)?|assume)[\s])'
    MasmLike         = '^[\s]*(assume|[.]model|include(lib)?)[\s]|[\s](proc|endp)([\s]|$)'
    FasmLike         = '^[\s]*format[\s]+(elf|pe|mz|binary)|^[\s]*segment[\s]+(readable|writeable|executable)'
    EntryStartLbl    = '^[\s]*_start[\s]*(:|$)'
    EntryPStartLbl   = '^[\s]*start[\s]*:'
    EntryStartGlob   = '^[\s]*(global|[.]globl|[.]global)[\s]+_start([\s]|$)'
    EntryPStartGlob  = '^[\s]*(global|[.]globl|[.]global)[\s]+start([\s]|$)'
    EntryMainLbl     = '^[\s]*main[\s]*(:|$)'
    EntryUMainLbl    = '^[\s]*_main[\s]*:'
    EntryMainGlob    = '^[\s]*(global|[.]globl|[.]global)[\s]+main([\s]|$)'
    LibcExtern       = '^[\s]*[.]?extern[\s]+[A-Za-z_]'
    CppDirective     = '^#(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error|warning)([\s<"(]|$)'
    LibcFunc         = '^[\s]*[.]?extern[\s]+_?(printf|fprintf|sprintf|snprintf|vprintf|puts|putchar|fputs|fputc|putc|getchar|fgetc|getc|gets|fgets|scanf|sscanf|fscanf|fopen|fclose|fread|fwrite|fflush|fseek|ftell|perror|malloc|calloc|realloc|free|strlen|strnlen|strcmp|strncmp|strcpy|strncpy|strcat|strncat|strchr|strrchr|strstr|memcpy|memmove|memset|memcmp|memchr|atoi|atol|atof|strtol|strtoul|strtod|exit|_exit|abort|atexit|getenv|setenv|time|rand|srand|random|qsort|bsearch|sleep|usleep|nanosleep|clock_gettime|gettimeofday|getpid|getppid|open|close|read|write|lseek|mmap|munmap|isatty|signal|raise|kill|fork|execve|waitpid|pipe|dup|dup2|toupper|tolower|isalpha|isdigit|isspace|sin|cos|sqrt|pow|exp|log|floor|ceil|fabs|pthread_create|pthread_join)(@PLT)?([\s]|$)|(call[qwl]?|bl|jmp|jal|b|tail)[\s]+_?(printf|fprintf|sprintf|snprintf|vprintf|puts|putchar|fputs|fputc|putc|getchar|fgetc|getc|gets|fgets|scanf|sscanf|fscanf|fopen|fclose|fread|fwrite|fflush|fseek|ftell|perror|malloc|calloc|realloc|free|strlen|strnlen|strcmp|strncmp|strcpy|strncpy|strcat|strncat|strchr|strrchr|strstr|memcpy|memmove|memset|memcmp|memchr|atoi|atol|atof|strtol|strtoul|strtod|exit|_exit|abort|atexit|getenv|setenv|time|rand|srand|random|qsort|bsearch|sleep|usleep|nanosleep|clock_gettime|gettimeofday|getpid|getppid|open|close|read|write|lseek|mmap|munmap|isatty|signal|raise|kill|fork|execve|waitpid|pipe|dup|dup2|toupper|tolower|isalpha|isdigit|isspace|sin|cos|sqrt|pow|exp|log|floor|ceil|fabs|pthread_create|pthread_join)(@PLT)?([^A-Za-z0-9_]|$)|@plt([^A-Za-z0-9_]|$)|wrt[\s]+[.][.]plt|[%]plt\('
}
# END GENERATED PATTERNS
# ---- extra patterns that exist only on Windows (written in .NET regex syntax) ----
$script:SrcPat['WinApi']   = '(^|[^A-Za-z0-9_@])_?(ExitProcess|GetStdHandle|WriteFile|WriteConsole[AW]?|ReadFile|ReadConsole[AW]?|MessageBox[AW]?|GetCommandLine[AW]?|GetModuleHandle[AW]?|CreateFile[AW]?|CloseHandle|VirtualAlloc|VirtualFree|HeapAlloc|HeapFree|GetProcessHeap|GetLastError|SetConsole[A-Za-z]*|GetConsoleMode|AllocConsole|FreeConsole|LoadLibrary[AW]?|GetProcAddress|ExitThread|CreateThread|GetTickCount(64)?|QueryPerformanceCounter|FlushFileBuffers)(@[0-9]+)?([^A-Za-z0-9_]|$)'
$script:SrcPat['WinDll']   = '(^|[^A-Za-z0-9_])(kernel32|user32|ntdll|msvcrt|ucrtbase|shell32|gdi32|advapi32|comctl32|ws2_32)([^A-Za-z0-9_]|$)'
$script:SrcPat['WinEntry'] = '(^|[^A-Za-z0-9_])_?(WinMain|wWinMain|DllMain|mainCRTStartup|WinMainCRTStartup|wmainCRTStartup)(@[0-9]+)?([^A-Za-z0-9_]|$)'
$script:SrcPat['WinDir']   = '^\s*(includelib|import\s+[A-Za-z_]\w*\s+[A-Za-z0-9_.]+\.dll)|^\s*[.](def|scl|endef|seh_[a-z]+)(\s|$)|^\s*(section|segment)\s+[.](rdata|idata)|^\s*[.]section\s+[.](rdata|idata)|^\s*%\s*include\s+.*(win32|win64|windows|kernel32)'
$script:SrcPat['WinDecor'] = '(^|[^A-Za-z0-9_])_[A-Za-z][A-Za-z0-9_]*@[0-9]{1,3}([^A-Za-z0-9_]|$)'
$script:SrcPat['WinShadow']= '(^|[\s:])(sub|add)\s+rsp\s*,\s*(32|40|48|56|64|72|80|88|(0x)?(20|28|30|38|40|48|50|58)h?)([^A-Za-z0-9_]|$)|(^|[\s:])(sub|add)q?\s+[$](32|40|48|56|64|72|80|88|0x(20|28|30|38|40|48|50|58))\s*,\s*%rsp'
$script:SrcPat['LinElf']   = '@plt([^A-Za-z0-9_]|$)|wrt\s+[.][.](plt|got|gotpc)|[.]type\s+\S+\s*,\s*[@%](function|object)|[.]note[.]GNU-stack|@gotpcrel|@gotpc|^\s*[.]?section\s+[.]rodata|__OUTPUT_FORMAT__\s*,\s*elf'
$script:SrcPat['LinNR']    = '__NR_|(^|[^A-Za-z0-9_])sys_(write|exit|read|open|close|exit_group|brk|mmap)([^A-Za-z0-9_]|$)'
$script:SrcPat['AbiWin']   = '^\s*(lea|mov)[bwlq]?\s+(rcx|ecx)\s*,|^\s*(lea|mov)[bwlq]?\s+[^,;]+,\s*%(rcx|ecx)(\s|$)'
$script:SrcPat['AbiSysV']  = '^\s*(lea|mov)[bwlq]?\s+(rdi|edi)\s*,|^\s*(lea|mov)[bwlq]?\s+[^,;]+,\s*%(rdi|edi)(\s|$)'
$script:SrcPat['WinUnder'] = '^\s*[.]?extern\s+_(printf|puts|putchar|scanf|getchar|malloc|free|strlen|exit|system|fprintf|sprintf)([^A-Za-z0-9_@]|$)|(^|\s)(call|jmp)[lq]?\s+_(printf|puts|putchar|scanf|getchar|malloc|free|strlen|exit|system|fprintf|sprintf)([^A-Za-z0-9_@]|$)'
$script:SrcPat['IncludeDir'] = '^\s*(%\s*include|[.]include|#\s*include|[.]?incbin)(\s|$)'
$script:SrcPat['EntryDecl']  = 'entry\s*\(\s*([A-Za-z_.][A-Za-z0-9_.]*)'
# MASM / UASM / JWasm / ml64 details (MASM is a Windows syntax, supported on the native route)
$script:SrcPat['MasmFlat']  = '^\s*[.]model\s+flat'
$script:SrcPat['Masm386']   = '^\s*[.](386|486|586|686)[a-z]?\s*$'
$script:SrcPat['MasmEnd']   = '^\s*end\s+([A-Za-z_@$?][A-Za-z0-9_@$?]*)\s*$'
$script:SrcPat['MasmMainProc'] = '^\s*_?main\s+proc(\s|$)|^\s*public\s+_?main(\s|$)'
$script:SrcPat['EntryUMainGlob'] = '^\s*(global|[.]globl|[.]global)\s+_main(\s|$)'
$script:SrcPat['EntryDecl'] = 'entry\s*\(\s*([A-Za-z_.][A-Za-z0-9_.]*)'

function Get-Re {
    param([string]$Name)
    if (-not $script:PatCache.ContainsKey($Name)) {
        $script:PatCache[$Name] = New-Object System.Text.RegularExpressions.Regex($script:SrcPat[$Name], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $script:PatCache[$Name]
}
# has / cnt as in the engine: number of LINES matching.
function Measure-Src {
    param([string]$Name, [string[]]$Lines)
    $re = Get-Re $Name
    $n = 0
    foreach ($l in $Lines) { if ($re.IsMatch($l)) { $n++ } }
    return $n
}
function Test-Src {
    param([string]$Name, [string[]]$Lines)
    $re = Get-Re $Name
    foreach ($l in $Lines) { if ($re.IsMatch($l)) { return $true } }
    return $false
}

function Get-HostInfo {
    $arch = ''
    try { $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if (-not $arch) {
        $arch = $env:PROCESSOR_ARCHITEW6432
        if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    }
    $fam = 'x86'; $bits = 64; $label = 'x64'
    switch -Regex ($arch.ToLower()) {
        '^(x86|i.86)$'       { $fam = 'x86';   $bits = 32; $label = 'x86' }
        '^(x64|amd64|x86_64)$' { $fam = 'x86'; $bits = 64; $label = 'x64' }
        '^arm64|aarch64'     { $fam = 'arm64'; $bits = 64; $label = 'ARM64' }
        '^arm$'              { $fam = 'arm32'; $bits = 32; $label = 'ARM' }
    }
    return @{ Family = $fam; Bits = $bits; Label = $label }
}
$script:HostInfo = Get-HostInfo

# ---------------------------------------------------------------- reading ----
function Read-SourceFile {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc = ''
    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = 'UTF-8 BOM'
        $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = 'UTF-16 LE'
        $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = 'UTF-16 BE'
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        foreach ($b in $bytes) { if ($b -eq 0) { Die "'$Path' contains NUL bytes - it does not look like a text file (UTF-16 without a BOM? a binary?)." } }
        $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
    }
    $lines = [regex]::Split($text, "\r\n|\n|\r")
    return @{ Path = $Path; Bytes = $bytes.Length; Encoding = $enc; Text = $text; Lines = $lines; Crlf = $text.Contains("`r`n") }
}

# ---- comment / string sanitiser: port of sanitize_source() in the engine ----
# Without it, "; compare with rax" in an ARM file would vote for x86.  MODE: generic | x86 | arm64 | arm32 | <other>
function Get-SanitizedLines {
    param([string[]]$Lines, [string]$Mode)
    $semi = 0; $hash = 0; $at = 0; $sl2 = $false
    switch ($Mode) {
        'x86'     { $semi = 1; $hash = 1 }
        'arm64'   { $semi = 1; $hash = 2; $sl2 = $true }
        'arm32'   { $at = 1; $hash = 2; $sl2 = $true }
        'generic' { $semi = 2; $hash = 3; $at = 2; $sl2 = $true }
        default   { $hash = 1 }
    }
    $dirRe = New-Object System.Text.RegularExpressions.Regex('^[ \t]*#(include|define|undef|ifdef|ifndef|if|elif|else|endif|pragma|error|warning|line)([ \t(<"]|$)')
    $out = New-Object System.Collections.ArrayList
    $inblk = $false
    $first = $true
    foreach ($raw in $Lines) {
        $line = $raw.Replace("`r", '')
        if ($first -and $line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) { $line = $line.Substring(1) }
        $first = $false
        if (-not $inblk -and $dirRe.IsMatch($line)) { [void]$out.Add($line); continue }
        $sb = New-Object System.Text.StringBuilder
        $n = $line.Length; $i = 0
        while ($i -lt $n) {
            if ($inblk) {
                $j = $line.IndexOf('*/', $i, [StringComparison]::Ordinal)
                if ($j -lt 0) { $i = $n; break }
                $i = $j + 2; $inblk = $false; [void]$sb.Append(' '); continue
            }
            $c = $line[$i]
            $c2 = [string]$c; if ($i + 1 -lt $n) { $c2 = $line.Substring($i, 2) }
            $prev = [char]' '; if ($i -gt 0) { $prev = $line[$i - 1] }
            $ws = ($prev -eq ' ' -or $prev -eq "`t")
            $wsnx = $true; if ($i + 1 -lt $n) { $nx = $line[$i + 1]; $wsnx = ($nx -eq ' ' -or $nx -eq "`t") }
            if ($c2 -eq '/*') { $inblk = $true; $i += 2; continue }
            if ($sl2 -and $c2 -eq '//') { break }
            if ($c -eq ';' -and $semi -ne 0 -and ($semi -eq 1 -or $ws)) { break }
            if ($c -eq '@' -and $at -ne 0 -and ($at -eq 1 -or ($ws -and $wsnx))) { break }
            if ($c -eq '#' -and $hash -ne 0) {
                if ($hash -eq 1) { break }
                if ($sb.ToString().Trim([char]' ', [char]"`t").Length -eq 0) { break }
                if ($hash -eq 3 -and $ws -and $wsnx) { break }
            }
            if ($c -eq '"' -or $c -eq '`') {
                $j = $i + 1
                while ($j -lt $n) {
                    $d = $line[$j]
                    if ($d -eq '\' -and $c -eq '"') { $j += 2; continue }
                    if ($d -eq $c) { break }
                    $j++
                }
                [void]$sb.Append($c).Append($c)
                if ($j -lt $n) { $i = $j + 1 } else { $i = $n }
                continue
            }
            if ($c -eq "'") {
                $j = $line.IndexOf("'", $i + 1)
                if ($j -ge 0) { [void]$sb.Append("''"); $i = $j + 1; continue }
            }
            [void]$sb.Append($c); $i++
        }
        [void]$out.Add($sb.ToString())
    }
    return ,($out.ToArray())
}

# ------------------------------------------------------------ detection ----
$script:ArchFamilies = @(@('x86', 'ArchX86'), @('arm64', 'ArchArm64'), @('arm32', 'ArchArm32'), @('riscv', 'ArchRiscv'),
                         @('ppc', 'ArchPpc'), @('s390x', 'ArchS390x'), @('mips', 'ArchMips'), @('loong', 'ArchLoong'))

# Port of detect_arch / detect_syntax / detect_bits / detect_entry_libc_cpp of the engine,
# plus MASM / FASM recognition and the Windows-vs-Linux evidence used for routing.
function Get-SourceProfile {
    param([hashtable]$Src, [string]$FileName, [switch]$Lenient)
    $O = $script:Opt
    $Raw = $Src.Lines
    $P = @{ Arch = ''; Syntax = ''; Bits = 0; Votes = ''; WinScore = 0; LinScore = 0; WinWhy = @(); LinWhy = @()
            HasStart = $false; HasPStart = $false; HasMain = $false; HasUMain = $false; HasEntry = $false; EntryName = ''
            HasWinMain = $false; UsesLibc = $false; Cpp = $false; Includes = $false; EndLabel = ''; HasCMain = $false; Fasm = ''
            SyntaxFirm = $false; BitsFirm = $false }
    $hostFam = $script:HostInfo.Family

    # ---- architecture: weighted vote on the generic-sanitised text; ties go to the host ----
    $gen = Get-SanitizedLines $Raw 'generic'
    $best = 0; $srcArch = $hostFam; $voteText = New-Object System.Collections.ArrayList
    foreach ($fam in $script:ArchFamilies) {
        $num = Measure-Src $fam[1] $gen
        [void]$voteText.Add("$($fam[0])=$num")
        if ($num -gt $best) { $best = $num; $srcArch = $fam[0] }
        elseif ($num -eq $best -and $num -gt 0 -and $fam[0] -eq $hostFam) { $srcArch = $fam[0] }
    }
    $P.Votes = ($voteText -join ' ')
    if ($O.Arch) { $srcArch = Get-ArchName $O.Arch }
    $P.Arch = $srcArch

    # ---- from here on look at text sanitised for THIS family ----
    $Lines = Get-SanitizedLines $Raw $srcArch
    $isX86 = ($srcArch -eq 'x86')

    # ---- syntax (x86 only) ----
    if (-not $isX86) {
        if ($O.Syntax -eq 'nasm' -and -not $Lenient) { Die "NASM only supports x86; use GNU as syntax for $srcArch." 2 }
        $P.Syntax = 'gas'
    } else {
        if ($O.Syntax -ne 'auto') { $P.Syntax = $O.Syntax; $P.SyntaxFirm = $true }
        else {
            $gate = Test-Src 'MasmGate' $Lines
            if ($gate -and (Test-Src 'Boot16' $Lines)) {
                if (-not $Lenient) {
                    Fail 'This is 16-bit / boot-sector code. asmrun only runs normal user-space programs.'
                    Say 'Try:  nasm -f bin file.asm -o boot.bin  and run boot.bin in an emulator (QEMU, Bochs, VirtualBox).'
                    $script:ExitCode = 1; throw 'ASMRUN_EXIT'
                }
            }
            if ($gate -and (Test-Src 'MasmLike' $Lines)) { $P.Syntax = 'masm'; $P.SyntaxFirm = $true }
            elseif (Test-Src 'FasmLike' $Lines) { $P.Syntax = 'fasm'; $P.SyntaxFirm = $true }
            else { $P.Syntax = Get-Syntax $Lines $FileName $P }
        }
    }
    if ($P.Syntax -eq 'masm') { $P.EndLabel = ''; $re = Get-Re 'MasmEnd'; foreach ($l2 in $Lines) { $m = $re.Match($l2); if ($m.Success) { $P.EndLabel = $m.Groups[1].Value } } }
    if ($P.Syntax -eq 'fasm') {
        $P.Fasm = 'pe'
        foreach ($l2 in $Lines) { if ($l2 -match '(?i)^\s*format\s+(elf|elf64|mz|binary|coff)\b') { $P.Fasm = $Matches[1].ToLower() } }
    }

    # ---- bitness ----
    if ($isX86) {
        if ($O.Bits -ne 0) { $P.Bits = $O.Bits; $P.BitsFirm = $true }
        elseif ($O.Target) { $P.Bits = 0 }
        elseif (Test-Src 'Bits32Dir' $Lines) { $P.Bits = 32; $P.BitsFirm = $true }
        elseif (Test-Src 'Bits64Dir' $Lines) { $P.Bits = 64; $P.BitsFirm = $true }
        elseif ($P.Syntax -eq 'masm' -and (Test-Src 'MasmFlat' $Lines)) { $P.Bits = 32; $P.BitsFirm = $true }
        else {
            $b32 = 0; $b64 = 0
            if (Test-Src 'BitInt80' $Lines)    { $b32 += 5 }
            if (Test-Src 'BitSyscall' $Lines)  { $b64 += 5 }
            if (Test-Src 'BitSysenter' $Lines) { $b32 += 3 }
            if (Test-Src 'Bit32Ops' $Lines)    { $b32 += 2 }
            if (Test-Src 'Bit64Ops' $Lines)    { $b64 += 2 }
            $b32 += (Measure-Src 'Reg32' $Lines); $b64 += (Measure-Src 'Reg64' $Lines)
            if ($P.Syntax -eq 'masm' -and (Test-Src 'Masm386' $Lines) -and $b64 -eq 0) { $b32 += 5 }
            if ($b64 -gt $b32) { $P.Bits = 64 } elseif ($b32 -gt $b64) { $P.Bits = 32 }
            elseif ($script:HostInfo.Bits -eq 32) { $P.Bits = 32 } else { $P.Bits = 64 }
        }
    } else {
        if ($O.Bits -ne 0 -and -not $Lenient) { Die "--32/--64 only apply to x86; $srcArch is fixed-width." 2 }
        if ($srcArch -eq 'arm32') { $P.Bits = 32 } else { $P.Bits = 64 }
    }

    # ---- entry point, libc, preprocessor ----
    if (Test-Src 'EntryStartLbl' $Lines)  { $P.HasStart = $true }
    if (Test-Src 'EntryPStartLbl' $Lines) { $P.HasPStart = $true }
    if (Test-Src 'EntryStartGlob' $Lines) { $P.HasStart = $true }
    if (Test-Src 'EntryPStartGlob' $Lines){ $P.HasPStart = $true }
    if (Test-Src 'EntryMainLbl' $Lines)   { $P.HasMain = $true }
    if (Test-Src 'EntryMainGlob' $Lines)  { $P.HasMain = $true }
    if (-not $P.HasMain -and (Test-Src 'EntryUMainLbl' $Lines)) { $P.HasUMain = $true }
    $re = Get-Re 'EntryDecl'
    foreach ($rawLine in $Raw) {                                    # ENTRY(name) is read from the RAW file (it usually sits in a comment)
        $m = $re.Match($rawLine)
        if ($m.Success) { $P.EntryName = $m.Groups[1].Value; break }
    }
    if ($P.EntryName) {
        switch -CaseSensitive ($P.EntryName) {
            '_start' { $P.HasStart = $true }
            'start'  { $P.HasPStart = $true }
            { 'main', '_main' -ccontains $_ } { $P.HasMain = $true }
            default  { $P.HasEntry = $true }
        }
    }
    if (Test-Src 'LibcFunc' $Lines) { $P.UsesLibc = $true }
    if (Test-Src 'LibcExtern' $Lines) { $P.UsesLibc = $true }
    if ($FileName -cmatch '\.S$') { $P.Cpp = $true }
    if ($P.Syntax -eq 'gas' -and (Test-Src 'CppDirective' $Lines)) { $P.Cpp = $true }
    if (Test-Src 'IncludeDir' $Lines) { $P.Includes = $true }
    # Windows' own notion of "the C main()": _main in 32-bit code (decorated), main in 64-bit code.
    if ($P.Bits -eq 32) { $P.HasCMain = ($P.HasUMain -or (Test-Src 'EntryUMainGlob' $Lines) -or (Test-Src 'EntryUMainLbl' $Lines)) }
    else { $P.HasCMain = $P.HasMain }
    if ($P.Syntax -eq 'masm' -and (Test-Src 'MasmMainProc' $Lines)) { $P.HasCMain = $true }

    # ---- Windows or Linux?  (new: asmrun v5/v6 only ever ran on Linux/macOS) ----
    $code = $Lines
    $win = 0; $lin = 0; $ww = New-Object System.Collections.ArrayList; $lw = New-Object System.Collections.ArrayList
    $n = Measure-Src 'WinApi' $code;  if ($n -gt 0) { $win += 3 * [Math]::Min($n, 4); [void]$ww.Add("Win32 API calls x$n") }
    $n = Measure-Src 'WinDll' $code;  if ($n -gt 0) { $win += 2 * [Math]::Min($n, 2); [void]$ww.Add('Windows DLL names') }
    if (Test-Src 'WinEntry' $code)    { $win += 5; $P.HasWinMain = $true; [void]$ww.Add('WinMain/CRT-startup entry') }
    $n = Measure-Src 'WinDir' $code;  if ($n -gt 0) { $win += 2 * [Math]::Min($n, 2); [void]$ww.Add('PE/COFF directives') }
    if (Test-Src 'WinDecor' $code)    { $win += 2; [void]$ww.Add('stdcall names (_Name@N)') }
    if (Test-Src 'WinShadow' $code)   { $win += 2; [void]$ww.Add('Win64 shadow space') }
    if ($P.Syntax -eq 'masm')         { $win += 10; [void]$ww.Add('MASM syntax') }
    if ($P.Syntax -eq 'fasm' -and $P.Fasm -eq 'pe') { $win += 10; [void]$ww.Add('FASM format PE') }
    if (Test-Src 'BitInt80' $code)    { $lin += 5; [void]$lw.Add('int 0x80') }
    if (Test-Src 'BitSyscall' $code)  { $lin += 4; [void]$lw.Add('syscall') }
    if (Test-Src 'BitSysenter' $code) { $lin += 3; [void]$lw.Add('sysenter') }
    if (Test-Src 'LinElf' $code)      { $lin += 3; [void]$lw.Add('ELF/PLT/.rodata markers') }
    if (Test-Src 'LinNR' $code)       { $lin += 2; [void]$lw.Add('Linux syscall names') }
    if ($P.HasStart)                  { $lin += 1; [void]$lw.Add('_start') }
    if ($P.UsesLibc) {   # which C calling convention does the code use for its first argument?
        $aw = Measure-Src 'AbiWin' $code; $as = Measure-Src 'AbiSysV' $code
        if ($aw -gt 0 -and $as -eq 0)     { $win += 3; [void]$ww.Add('Win64 calling convention (rcx first)') }
        elseif ($as -gt 0 -and $aw -eq 0) { $lin += 3; [void]$lw.Add('SysV calling convention (rdi first)') }
    }
    if ($P.Bits -eq 32 -and (Test-Src 'WinUnder' $code)) { $win += 3; [void]$ww.Add('_-prefixed C imports (MinGW/MSVC 32-bit)') }
    if ($P.Syntax -eq 'fasm' -and $P.Fasm -like 'elf*') { $lin += 10; [void]$lw.Add('FASM format ELF') }
    if ($srcArch -ne 'x86')           { $lin += 10; [void]$lw.Add("$srcArch source") }
    $P.WinScore = $win; $P.LinScore = $lin
    $P.WinWhy = $ww.ToArray(); $P.LinWhy = $lw.ToArray()
    return $P
}

# x86 only: NASM (Intel) vs GNU as - same rules as detect_syntax() of the engine
function Get-Syntax {
    param([string[]]$Lines, [string]$FileName, [hashtable]$P)
    if ($FileName -cmatch '\.S$') { $P.SyntaxFirm = $true; return 'gas' }
    if ($FileName -cmatch '\.nasm$') { $P.SyntaxFirm = $true; return 'nasm' }
    if (Test-Src 'SynMarker' $Lines) { $P.SyntaxFirm = $true; return 'gas' }
    if (Test-Src 'SynCpp' $Lines)    { $P.SyntaxFirm = $true; return 'gas' }
    $nasm = Measure-Src 'SynNasm' $Lines
    $gas  = Measure-Src 'SynGas' $Lines
    VInfo "syntax votes: nasm=$nasm gas=$gas"
    if ($gas -gt $nasm) { return 'gas' }
    if ($nasm -gt $gas) { return 'nasm' }
    if ($FileName -cmatch '\.(s|sx)$') { return 'gas' }
    return 'nasm'
}

# Name of the entry point as the engine reports it (--detect).
function Get-EntryReport {
    param([hashtable]$P)
    if ($P.HasStart) { return '_start' }
    if ($P.HasEntry) { return $P.EntryName }
    if ($P.HasPStart) { return 'start' }
    return 'none'
}

# --detect: the engine's key=value report, from the Windows-side analysis.
function Show-DetectReport {
    param([hashtable]$P, [string]$File, [hashtable]$Route)
    $o = New-Object System.Collections.ArrayList
    [void]$o.Add("file=$File"); [void]$o.Add("arch=$($P.Arch)"); [void]$o.Add("bits=$($P.Bits)")
    [void]$o.Add("syntax=$($P.Syntax)"); [void]$o.Add("entry=$(Get-EntryReport $P)")
    [void]$o.Add("c_main=$(if ($P.HasMain) { 'yes' } else { 'no' })")
    [void]$o.Add("libc=$(if ($P.UsesLibc -or $P.HasMain) { 'yes' } else { 'no' })")
    [void]$o.Add("cpp=$(if ($P.Cpp) { 'yes' } else { 'no' })")
    [void]$o.Add("arch_votes=$($P.Votes)")
    [void]$o.Add("windows_score=$($P.WinScore)"); [void]$o.Add("linux_score=$($P.LinScore)")
    if ($Route) { [void]$o.Add("route=$($Route.Route)"); [void]$o.Add("route_reason=$($Route.Why)") }
    Write-Stdout (($o -join "`n") + "`n")
}

# Decide the route.  Returns 'native' or 'wsl' plus a reason string.
function Select-Route {
    param([hashtable]$P)
    $O = $script:Opt
    if ($O.Mode -eq 'wsl') {
        if ($P.Syntax -eq 'masm') { Die 'MASM syntax builds Windows programs and cannot run through WSL. Use --native (or drop --wsl).' }
        return @{ Route = 'wsl'; Why = 'forced by --wsl' }
    }
    if ($O.Mode -eq 'native') { return @{ Route = 'native'; Why = 'forced by --native' } }
    if ($O.Target)            { return @{ Route = 'wsl';    Why = "--target $($O.Target) builds a Linux program" } }
    if ($P.Arch -ne 'x86')    { return @{ Route = 'wsl';    Why = "$($P.Arch) code cannot run natively on this PC; WSL provides the cross tools" } }
    if ($P.Syntax -eq 'masm') { return @{ Route = 'native'; Why = 'MASM syntax (a Windows assembler dialect)' } }
    if ($P.Syntax -eq 'fasm') {
        if ($P.Fasm -like 'elf*') { return @{ Route = 'wsl'; Why = 'FASM format ELF is a Linux program' } }
        return @{ Route = 'native'; Why = "FASM format $($P.Fasm)" }
    }
    if ($P.WinScore -ge 3 -and $P.WinScore -gt $P.LinScore) {
        return @{ Route = 'native'; Why = "Windows program ($($P.WinWhy -join ', '))" }
    }
    if ($P.LinScore -gt $P.WinScore) {
        return @{ Route = 'wsl'; Why = "Linux program ($($P.LinWhy -join ', '))" }
    }
    # No clear evidence either way.
    $wslState = Get-WslState          # (slow the first time: starts WSL) - only needed for this tie-break
    if ($wslState.Usable) { return @{ Route = 'wsl';    Why = 'no Windows-API calls found, so it is treated as a Linux program (use --native for a Windows one)' } }
    return @{ Route = 'native'; Why = 'no Windows-API or Linux evidence and WSL is not available; assuming a Windows program' }
}

# ============================================================================
#  4. TOOLS  -  find (and, with permission, install) assemblers and a linker driver
# ============================================================================
# What each syntax needs on the native route:
#   NASM syntax : nasm                         (winget NASM.NASM)
#   GNU as      : a MinGW-w64 gcc (or its as)  (winget BrechtSanders.WinLibs.POSIX.UCRT)
#   MASM        : ml64/ml (Visual Studio, MASM32), UASM or JWasm   (UASM is downloaded, hash-checked)
#   FASM        : fasm
# Linking needs NOTHING extra: asmrun has its own PE linker (see section 5b); gcc is used only when it can.
# winget package ids / downloads.  If a package is renamed or a new release is pinned, change it HERE only.
$script:WingetIds = @{
    nasm = 'NASM.NASM'
    cc   = 'BrechtSanders.WinLibs.POSIX.UCRT'
}
$script:Downloads = @{
    uasm = @{
        Name = 'UASM'; Version = '2.57r'; Home = 'https://github.com/Terraspace/UASM'; License = 'Sybase Open Watcom Public License'
        Url64 = 'https://github.com/Terraspace/UASM/releases/download/v2.57r/uasm257_x64.zip'
        Sha64 = 'a083bf0f7bd45dead8a90f1fe1a25a83d6942d50c6d3def6e442188f15fce991'
        Url86 = 'https://github.com/Terraspace/UASM/releases/download/v2.57r/uasm257_x86.zip'
        Sha86 = 'f40f5b62357efd7e716e691ce3279d1abbaafffd9eee1358208fb5b3252ade71'
        Exe64 = 'uasm64.exe'; Exe86 = 'uasm32.exe'
    }
}
$script:ToolLabels = @{
    nasm = 'NASM assembler'
    cc   = 'MinGW-w64 GCC (GNU as + compiler driver)'
    uasm = 'UASM, a free MASM-compatible assembler'
    fasm = 'FASM (flat assembler)'
}

function Get-ToolsHome {
    if ($env:ASMRUN_HOME) { return (Join-Path $env:ASMRUN_HOME 'tools') }
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'asmrun') 'tools')
}

# Folders where these tools are commonly installed but NOT always on PATH.
# (NASM's installer never edits PATH; winget "portable" packages live under WinGet\Packages.)
function Get-ExtraToolDirs {
    $cands = New-Object System.Collections.ArrayList
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
    $lad = $env:LOCALAPPDATA; $usr = $env:USERPROFILE; $pd = $env:ProgramData
    $add = { param($p) if ($p) { [void]$cands.Add($p) } }
    & $add (Join-Path (Get-ToolsHome) 'uasm*')
    if ($pf)   { & $add (Join-Path $pf 'NASM'); & $add (Join-Path $pf 'mingw-w64\*\mingw64\bin'); & $add (Join-Path $pf 'mingw64\bin'); & $add (Join-Path $pf 'WinGet\Links'); & $add (Join-Path $pf 'JWasm*'); & $add (Join-Path $pf 'UASM*'); & $add (Join-Path $pf 'FASM*') }
    if ($pf86) { & $add (Join-Path $pf86 'NASM'); & $add (Join-Path $pf86 'FASM*') }
    if ($lad)  {
        & $add (Join-Path $lad 'bin\NASM'); & $add (Join-Path $lad 'Programs\NASM')
        & $add (Join-Path $lad 'Microsoft\WinGet\Links')
        & $add (Join-Path $lad 'Microsoft\WinGet\Packages\BrechtSanders.WinLibs*\mingw64\bin')
        & $add (Join-Path $lad 'Microsoft\WinGet\Packages\BrechtSanders.WinLibs*\mingw32\bin')
        & $add (Join-Path $lad 'Microsoft\WinGet\Packages\*NASM*')
    }
    if ($usr)  {
        & $add (Join-Path $usr 'scoop\shims'); & $add (Join-Path $usr 'scoop\apps\nasm\current')
        & $add (Join-Path $usr 'scoop\apps\gcc\current\bin'); & $add (Join-Path $usr 'scoop\apps\mingw\current\bin')
        & $add (Join-Path $usr 'scoop\apps\uasm\current'); & $add (Join-Path $usr 'scoop\apps\fasm\current')
    }
    if ($pd)   { & $add (Join-Path $pd 'chocolatey\bin'); & $add (Join-Path $pd 'mingw64\mingw64\bin'); & $add (Join-Path $pd 'Msys\mingw64\bin'); & $add (Join-Path $pd 'Msys\mingw32\bin') }
    foreach ($d in @('C:\msys64\ucrt64\bin', 'C:\msys64\mingw64\bin', 'C:\msys64\clang64\bin', 'C:\msys64\mingw32\bin',
                     'C:\mingw64\bin', 'C:\mingw32\bin', 'C:\MinGW\bin', 'C:\winlibs\mingw64\bin', 'C:\tools\mingw64\bin',
                     'C:\masm32\bin', 'C:\fasm', 'C:\jwasm', 'C:\uasm')) { & $add $d }
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        if ($c.Contains('*')) {
            foreach ($r in @(Resolve-Path -Path $c -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $r.ProviderPath -PathType Container) { [void]$out.Add($r.ProviderPath) }
            }
        } elseif (Test-Path -LiteralPath $c -PathType Container) { [void]$out.Add($c) }
    }
    return ,($out.ToArray())
}

# Returns the full path of the first tool found (PATH first, then the folders above), or $null.
function Find-Tool {
    param([string[]]$Names)
    foreach ($n in $Names) {
        $c = @(Get-Command $n -CommandType Application -ErrorAction SilentlyContinue)
        if ($c.Count -gt 0) { return $c[0].Source }
    }
    foreach ($d in (Get-ExtraToolDirs)) {
        foreach ($n in $Names) {
            $suffixes = @('.exe')
            if (-not $script:OnWindows) { $suffixes = @('', '.exe') }
            foreach ($s in $suffixes) {
                $p = Join-Path $d ($n + $s)
                if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
            }
        }
    }
    return $null
}
function Add-ToSessionPath {
    param([string]$Dir)
    if (-not $Dir) { return }
    $sep = [IO.Path]::PathSeparator
    foreach ($e in ($env:PATH -split [regex]::Escape([string]$sep))) { if ($e -ieq $Dir) { return } }
    $env:PATH = $Dir + $sep + $env:PATH
}
# After an install, this process still has the OLD PATH; re-read it from the registry.
function Update-SessionPath {
    if (-not $script:OnWindows) { return }
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $seen = @{}; $parts = New-Object System.Collections.ArrayList
    foreach ($src in @($env:PATH, $m, $u)) {
        foreach ($e in ($src -split ';')) {
            if ($e -and -not $seen.ContainsKey($e.ToLower())) { $seen[$e.ToLower()] = $true; [void]$parts.Add($e) }
        }
    }
    $env:PATH = ($parts -join ';')
}

# ---- MASM-compatible assemblers: ml64 / ml (Visual Studio, MASM32), UASM, JWasm ----
function Find-VsMasm {
    param([int]$Bits)
    if (-not $script:OnWindows) { return $null }
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { return $null }
    $vsw = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vsw -PathType Leaf)) { return $null }
    $r = Invoke-Native -File $vsw -Arguments @('-latest', '-products', '*', '-property', 'installationPath') -Capture
    if (-not $r.Started -or $r.ExitCode -ne 0) { return $null }
    foreach ($root in ($r.Out -split "`r?`n")) {
        if (-not $root.Trim()) { continue }
        $pats = @('VC\Tools\MSVC\*\bin\Hostx64\x64\ml64.exe', 'VC\Tools\MSVC\*\bin\Hostx86\x64\ml64.exe')
        if ($Bits -eq 32) { $pats = @('VC\Tools\MSVC\*\bin\Hostx64\x86\ml.exe', 'VC\Tools\MSVC\*\bin\Hostx86\x86\ml.exe') }
        foreach ($pat in $pats) {
            $hit = @(Get-ChildItem -Path (Join-Path $root.Trim() $pat) -File -ErrorAction SilentlyContinue | Sort-Object FullName)
            if ($hit.Count -gt 0) { return $hit[$hit.Count - 1].FullName }
        }
    }
    return $null
}
# Returns @{ Kind = 'ml64'|'ml'|'uasm'|'jwasm'; Exe = path } or $null.
function Find-Masm {
    param([int]$Bits)
    if ($env:ASMRUN_MASM -and (Test-Path -LiteralPath $env:ASMRUN_MASM -PathType Leaf)) {
        $n = [IO.Path]::GetFileNameWithoutExtension($env:ASMRUN_MASM).ToLower()
        $k = 'uasm'; if ($n -like 'ml64*') { $k = 'ml64' } elseif ($n -eq 'ml') { $k = 'ml' } elseif ($n -like 'jwasm*') { $k = 'jwasm' }
        return @{ Kind = $k; Exe = $env:ASMRUN_MASM }
    }
    $vs = Find-VsMasm $Bits
    if ($vs) { $k = 'ml'; if ($Bits -ne 32) { $k = 'ml64' }; return @{ Kind = $k; Exe = $vs } }
    if ($Bits -eq 32) { $ml = Find-Tool @('ml'); if ($ml -and $ml -notlike '*\System32\*') { return @{ Kind = 'ml'; Exe = $ml } } }
    else { $ml = Find-Tool @('ml64'); if ($ml) { return @{ Kind = 'ml64'; Exe = $ml } } }
    $u = Find-Tool @('uasm64', 'uasm32', 'uasm')
    if ($u) { return @{ Kind = 'uasm'; Exe = $u } }
    $j = Find-Tool @('jwasm', 'jwasm64', 'jwasmr')
    if ($j) { return @{ Kind = 'jwasm'; Exe = $j } }
    return $null
}

# Can this C driver LINK programs of this size?  (MSYS2's mingw64 gcc cannot do -m32: no 32-bit libraries.)
function Get-CcMode {
    param([string]$Cc, [int]$Bits)
    $leaf = [IO.Path]::GetFileName($Cc).ToLower()
    return @{ M32 = ($Bits -eq 32 -and -not $leaf.StartsWith('i686') -and -not $leaf.StartsWith('i386')) }
}
# Machine type of the first object inside an import library (.a): 0x14C = 32-bit, 0x8664 = 64-bit, 0 = unknown.
function Get-LibMachine {
    param([string]$Path)
    try {
        $b = [IO.File]::ReadAllBytes($Path)
        if ($b.Length -lt 100 -or [Text.Encoding]::ASCII.GetString($b, 0, 8) -ne "!<arch>`n") { return 0 }
        $pos = 8
        while ($pos + 60 -lt $b.Length) {
            $name = [Text.Encoding]::ASCII.GetString($b, $pos, 16).Trim()
            $size = [int][Text.Encoding]::ASCII.GetString($b, $pos + 48, 10).Trim()
            if ($name -ne '/' -and $name -ne '//' ) { return [int][BitConverter]::ToUInt16($b, $pos + 60) }
            $pos += 60 + $size + ($size % 2)
        }
    } catch { }
    return 0
}
# A gcc that was built without 32-bit libraries still ACCEPTS -m32 and then finds only 64-bit libraries
# (that is what "skipping incompatible libmingw32.a" means).  So look at the library it would really use.
function Test-CcLinks {
    param([string]$Cc, [int]$Bits)
    if (-not $Cc) { return $false }
    $a = @('-print-file-name=libkernel32.a')
    if ((Get-CcMode $Cc $Bits).M32) { $a = @('-m32') + $a }
    $r = Invoke-Native -File $Cc -Arguments $a -Capture
    if (-not $r.Started -or $r.ExitCode -ne 0) { return $false }
    $p = $r.Out.Trim()
    if (-not ($p -match '[\\/]' -and (Test-Path -LiteralPath $p -PathType Leaf))) { return $false }
    $want = 0x8664; if ($Bits -eq 32) { $want = 0x14C }
    return ((Get-LibMachine $p) -eq $want)
}

# Locate every tool the native route may use.  Missing ones are $null.
function Get-NativeTools {
    param([int]$Bits)
    $O = $script:Opt
    $t = @{ Nasm = $null; Cc = $null; CcForced = $false; As = $null; Masm = $null; Fasm = $null }
    if ($env:ASMRUN_NASM -and (Test-Path -LiteralPath $env:ASMRUN_NASM -PathType Leaf)) { $t.Nasm = $env:ASMRUN_NASM }
    else { $t.Nasm = Find-Tool @('nasm') }

    $want = $O.Cc
    if (-not $want) { $want = $env:ASMRUN_CC }
    if ($want) {
        $t.CcForced = $true
        if (Test-Path -LiteralPath $want -PathType Leaf) { $t.Cc = (Resolve-FullPath $want) }
        else { $t.Cc = Find-Tool @($want) }
    } else {
        if ($Bits -eq 32) { $names = @('i686-w64-mingw32-gcc', 'gcc', 'cc', 'i686-w64-mingw32-clang', 'clang') }
        else              { $names = @('gcc', 'x86_64-w64-mingw32-gcc', 'cc', 'x86_64-w64-mingw32-clang', 'clang') }
        $t.Cc = Find-Tool $names
    }
    $asNames = @('as'); if ($Bits -eq 32) { $asNames = @('i686-w64-mingw32-as', 'as') } else { $asNames = @('x86_64-w64-mingw32-as', 'as') }
    $t.As = Find-Tool $asNames
    $t.Masm = Find-Masm $Bits
    $t.Fasm = Find-Tool @('fasm')
    # Make sure the compiler's own folder is on PATH (it needs its sibling as.exe / DLLs).
    if ($t.Cc) { Add-ToSessionPath (Split-Path -Parent $t.Cc) }
    if ($t.Nasm) { Add-ToSessionPath (Split-Path -Parent $t.Nasm) }
    return $t
}

function Get-WindowsLabel {
    $label = ''
    if ($script:OnWindows) {
        try { $label = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
        if (-not $label) {
            $v = [Environment]::OSVersion.Version
            $label = "Windows (build $($v.Build))"
        }
    } else { $label = [Environment]::OSVersion.VersionString }
    return ($label.Trim() + ' ' + $script:HostInfo.Label)
}

# ---- hash-verified download (used for UASM) ----
function Save-VerifiedDownload {
    param([string]$Url, [string]$Sha256, [string]$Dest)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing } finally { $ProgressPreference = $old }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $Dest).Hash.ToLower()
    if ($got -ne $Sha256.ToLower()) {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for $Url (expected $Sha256, got $got). Nothing was installed."
    }
}
function Install-Uasm {
    $d = $script:Downloads['uasm']
    $is86 = ($script:HostInfo.Bits -eq 32)
    $url = $d.Url64; $sha = $d.Sha64; $exe = $d.Exe64
    if ($is86) { $url = $d.Url86; $sha = $d.Sha86; $exe = $d.Exe86 }
    $dir = Join-Path (Get-ToolsHome) ('uasm-' + $d.Version)
    [void][IO.Directory]::CreateDirectory($dir)
    $zip = Join-Path $dir 'uasm.zip'
    Show-Cmd "download $url"
    Save-VerifiedDownload $url $sha $zip
    Good "SHA-256 verified ($($sha.Substring(0, 12))...)"
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    $found = Join-Path $dir $exe
    if (-not (Test-Path -LiteralPath $found -PathType Leaf)) { throw "$exe was not found inside the downloaded archive" }
    if (-not $env:ASMRUN_NO_VERIFY_RUN) {       # prove it runs: assemble a 2-line file
        $probe = Join-Path $dir 'probe.asm'; [IO.File]::WriteAllText($probe, ".code`r`nend`r`n")
        $r = Invoke-Native -File $found -Arguments @('-nologo', '-win64', ('-Fo' + (Join-Path $dir 'probe.obj')), $probe) -Capture
        if (-not $r.Started -or $r.ExitCode -ne 0) { throw "the downloaded $exe does not run on this PC ($($r.Error) $($r.Out))" }
        Remove-Item -LiteralPath $probe, (Join-Path $dir 'probe.obj') -Force -ErrorAction SilentlyContinue
    }
    return $found
}

# Offer to install the missing tools.  $Missing is a list of keys: nasm, cc (winget), uasm (download), fasm (manual).
# Returns $true when everything is available afterwards.
function Install-MissingTools {
    param([string[]]$Missing, [int]$Bits)
    $O = $script:Opt
    if ($env:ASMRUN_NO_INSTALL) { Warn ('Missing tools: ' + ($Missing -join ', ') + ' (installs are disabled by ASMRUN_NO_INSTALL)'); return $false }
    $names = @(); foreach ($m in $Missing) { $names += "$m ($($script:ToolLabels[$m]))" }
    Warn ("Missing tools for this file: " + ($names -join ', '))
    $winget = $null
    if ($script:OnWindows) { $winget = Find-Tool @('winget') }
    Say ("System detected: " + (Get-WindowsLabel) + $(if ($winget) { ', winget found' } else { ', winget NOT found' }))

    $manual = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    foreach ($m in $Missing) {
        if ($m -eq 'uasm') { [void]$plan.Add(@{ Key = $m; How = 'download'; Text = "UASM $($script:Downloads['uasm'].Version) (free MASM-compatible assembler, $($script:Downloads['uasm'].License)) from $($script:Downloads['uasm'].Home), SHA-256 checked, unpacked into $(Get-ToolsHome)" }) }
        elseif ($m -eq 'fasm') { [void]$manual.Add('FASM: download "fasmw" from https://flatassembler.net/download.php , unzip it, and put fasm.exe on PATH (or in C:\fasm).') }
        elseif ($winget) { [void]$plan.Add(@{ Key = $m; How = 'winget'; Text = "winget install --id $($script:WingetIds[$m])   ($($script:ToolLabels[$m]))" }) }
        else {
            if ($m -eq 'nasm') { [void]$manual.Add('NASM: https://www.nasm.us/  (or from MSYS2: pacman -S mingw-w64-ucrt-x86_64-nasm)') }
            if ($m -eq 'cc')   { [void]$manual.Add('MinGW-w64: https://winlibs.com/ (unzip, add its "bin" folder to PATH) or MSYS2 https://www.msys2.org/ : pacman -S mingw-w64-ucrt-x86_64-gcc') }
        }
    }
    if ($plan.Count -eq 0) {
        Say ''; Say 'Please install these yourself, then run asmrun again:'
        foreach ($x in $manual) { Say "  $x" }
        if (-not $winget -and $script:OnWindows) { Say '  (winget would automate NASM/MinGW: Microsoft Store -> "App Installer")' }
        return $false
    }
    Say 'asmrun can install these for you:'
    foreach ($x in $plan) { Say "  - $($x.Text)" }
    foreach ($x in $manual) { Say "  (manual) $x" }
    $ans = Confirm-Yes 'Install them now?' $true
    if ($null -eq $ans) {
        Say 'No terminal to ask on. Install them yourself, then try again.'
        return $false
    }
    if (-not $ans) { Say 'Skipped.'; return $false }

    foreach ($x in $plan) {
        try {
            if ($x.How -eq 'winget') {
                $id = $script:WingetIds[$x.Key]
                Show-Cmd ("winget install --id $id -e --silent")
                $r = Invoke-Native -File $winget -Arguments @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
                if (-not $r.Started) { Fail "Could not start winget: $($r.Error)" }
            } else { [void](Install-Uasm) }
        } catch { Fail ("Installing " + $x.Key + " failed: " + $_.Exception.Message) }
    }
    Update-SessionPath
    $t = Get-NativeTools $Bits
    $ok = @(); $failed = @()
    foreach ($m in $Missing) {
        $have = $false
        if ($m -eq 'nasm' -and $t.Nasm) { $have = $true }
        if ($m -eq 'cc' -and ($t.Cc -or $t.As)) { $have = $true }
        if ($m -eq 'uasm' -and $t.Masm) { $have = $true }
        if ($m -eq 'fasm' -and $t.Fasm) { $have = $true }
        if ($have) { $ok += $m } else { $failed += $m }
    }
    if ($ok.Count -gt 0)     { Good ("Installed and found: " + ($ok -join ', ')) }
    if ($failed.Count -gt 0) {
        Fail ("Still missing after the install: " + ($failed -join ', '))
        Say 'The installer may need a new terminal window (PATH changes) or administrator rights.'
        Say 'Close this window, open a new one and run asmrun again. Or use --doctor to see what was found.'
        return $false
    }
    return $true
}

# ============================================================================
#  5. NATIVE  -  build and run a Windows program
#     assemble (NASM | GNU as | MASM | FASM)  ->  link (gcc if capable | built-in PE linker)  ->  run
# ============================================================================
# Windows reports crashes as NTSTATUS exit codes (like 139 = SIGSEGV on Linux).
$script:NtStatus = @{
    3221225477 = 'access violation (the Windows "segmentation fault"): the program touched an invalid address. Check pointers, and keep RSP 16-byte aligned at every call on x64 (reserve 32 bytes of shadow space).'
    3221225501 = 'illegal instruction: the CPU cannot execute an instruction in the program.'
    3221225620 = 'integer divide by zero.'
    3221225725 = 'stack overflow.'
    3221226505 = 'stack buffer overrun / fast-fail (often a corrupted stack or a bad return address).'
    3221225781 = 'a required DLL was not found.'
    3221225794 = 'a required DLL failed to initialise.'
    3221225622 = 'privileged instruction (cannot be used in a normal program).'
    3221225786 = 'the program was interrupted (Ctrl+C).'
    3221225595 = 'bad image: Windows could not load the program (wrong machine type or damaged file).'
    3221225785 = 'an imported function was not found in a DLL (entry point not found).'
}
# exit codes that mean "Windows could not even start the program" (used to retry with another linker)
$script:LoaderFailures = @(3221225781, 3221225794, 3221225595, 3221225785)

function Invoke-Stage {
    param([string]$Label, [string]$File, [string[]]$Arguments, [switch]$Quiet)
    $line = Format-Command $File $Arguments
    [void]$script:Commands.Add($line)
    $res = @{ Ok = $true; Text = ''; Code = 0 }
    if ($script:Opt.DryRun) { Write-Tag '[PLAN]' 'Magenta' $line; return $res }
    Show-Cmd $line
    $r = Invoke-Native -File $File -Arguments $Arguments -Capture
    if (-not $r.Started) { $res.Ok = $false; $res.Text = "Could not start $Label ($File): $($r.Error)"; $res.Code = -1; if (-not $Quiet) { Fail $res.Text }; return $res }
    $res.Text = (($r.Out + "`n" + $r.Err)).Trim(); $res.Code = $r.ExitCode
    if ($r.ExitCode -ne 0) {
        $res.Ok = $false
        if (-not $Quiet) { Fail "$Label failed (exit code $($r.ExitCode))."; if ($res.Text) { Say (Format-ToolOutput $res.Text) } }
        return $res
    }
    # warnings from a successful step are shown; the routine "N lines, 2 passes ... 0 errors" banner of UASM/JWasm is not
    $plain = $res.Text -replace "\x1b\[[0-9;]*m", ''
    $banner = ($plain -match ': \d+ lines, \d+ passes' -and $plain -match '\b0 errors')
    if ($res.Text -and -not $Quiet -and (-not $banner -or $plain -match '[1-9]\d* warnings' -or $script:Verbose)) { Say $plain }
    return $res
}

# Linkers print the same complaint hundreds of times (gcc: "skipping incompatible ... when searching for -lX").
function Get-LinkFailReason {
    param([string]$Text, [int]$Bits)
    if ($Text -match 'skipping incompatible' -or $Text -match 'cannot find -l') { return "this gcc has no $Bits-bit Windows libraries" }
    foreach ($l in ($Text -split "`r?`n")) { if ($l.Trim() -and $l -notmatch "^\(\d+ 'skipping") { return $l.Trim() } }
    return 'unknown error'
}
function Format-ToolOutput {
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    $seen = @{}; $keep = New-Object System.Collections.ArrayList; $skipped = 0
    foreach ($l in $lines) {
        if ($l -match 'skipping incompatible') { $skipped++; continue }
        $k = ($l -replace '[A-Za-z]:[\\/][^\s:]*', '<path>').Trim()
        if ($k -and $seen.ContainsKey($k)) { continue }
        $seen[$k] = $true; [void]$keep.Add($l)
    }
    if ($skipped -gt 0) { [void]$keep.Insert(0, "($skipped 'skipping incompatible library' lines hidden)") }
    if ($keep.Count -gt 14) { $more = $keep.Count - 14; $keep = $keep.GetRange(0, 14); [void]$keep.Add("... ($more more lines)") }
    return ($keep -join "`n")
}

# Describe a PE/COFF file the way file(1) would: "PE32+ executable (console) x86-64".
function Get-PeSummary {
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $len = [int][Math]::Min(4096, $fs.Length)
            $b = New-Object byte[] $len
            [void]$fs.Read($b, 0, $len)
        } finally { $fs.Dispose() }
        $machineName = { param($m) switch ($m) { 0x14c { 'Intel 80386' } 0x8664 { 'x86-64' } 0xAA64 { 'ARM64' } 0x1c4 { 'ARM' } default { ('machine 0x{0:X}' -f $m) } } }
        if ($len -ge 64 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A) {
            $pe = [BitConverter]::ToInt32($b, 0x3C)
            if ($pe -gt 0 -and $pe + 120 -lt $len -and $b[$pe] -eq 0x50 -and $b[$pe + 1] -eq 0x45) {
                $mach = [BitConverter]::ToUInt16($b, $pe + 4)
                $magic = [BitConverter]::ToUInt16($b, $pe + 24)
                $sub = [BitConverter]::ToUInt16($b, $pe + 24 + 68)
                $kind = 'PE32'; if ($magic -eq 0x20B) { $kind = 'PE32+' }
                $ss = 'console'; if ($sub -eq 2) { $ss = 'GUI' } elseif ($sub -ne 3) { $ss = "subsystem $sub" }
                return ("$kind executable ($ss) " + (& $machineName $mach) + ', for MS Windows')
            }
        }
        if ($len -ge 20) {
            $mach = [BitConverter]::ToUInt16($b, 0)
            if ($mach -eq 0x14c -or $mach -eq 0x8664 -or $mach -eq 0xAA64) { return ('COFF object file ' + (& $machineName $mach)) }
        }
    } catch { }
    return ''
}

function Get-StartLabel {
    param([string[]]$Lines)
    $re1 = New-Object System.Text.RegularExpressions.Regex('^\s*(_start|start)\s*(:|\s+proc\b)', 'IgnoreCase')
    $re2 = New-Object System.Text.RegularExpressions.Regex('^\s*(global|[.]globl|[.]global|public)\s+(_start|start)(\s|$)', 'IgnoreCase')
    foreach ($line in $Lines) { $m = $re1.Match($line); if ($m.Success) { return $m.Groups[1].Value } }
    foreach ($line in $Lines) { $m = $re2.Match($line); if ($m.Success) { return $m.Groups[2].Value } }
    return ''
}

function Write-Report {
    param([hashtable]$R)
    $O = $script:Opt
    if (-not $O.Report) { return }
    $rep = Resolve-FullPath $O.Report
    try {
        $json = [ordered]@{
            tool = 'asmrun'; version = $script:Version; file = $R.File; os = 'windows'; wsl = $false
            host = $script:HostInfo.Family; host_bits = $script:HostInfo.Bits
            source_arch = $R.Arch; syntax = $R.Syntax; bits = $R.Bits; target = $R.Target
            native = $true; link = $R.Link; assembler = $R.Assembler; cpp = $R.Cpp
            tools_required = @($R.Required); build_commands = @($script:Commands.ToArray())
            output = $R.Output; output_kind = $R.OutputKind; exit_code = $R.ExitCode; kept_build_dir = $R.Kept
        }
        $text = ($json | ConvertTo-Json -Depth 5)
        [IO.File]::WriteAllText($rep, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { Warn "Could not write report to '$rep': $($_.Exception.Message)" }
}

function Format-ExitStatus {
    param([int]$Code)
    $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)
    if ($u -ge 2147483648) {      # decimal on purpose: 0x80000000 is a NEGATIVE Int32 in PowerShell
        $hex = ('0x{0:X8}' -f $u)
        if ($script:NtStatus.ContainsKey([int64]$u)) { return @("[exit $hex]", $script:NtStatus[[int64]$u]) }
        return @("[exit $hex]", '')
    }
    return @("[exit $Code]", '')
}

# ---- assemble ---------------------------------------------------------------------------------
# Returns @{ Ok; Tool }.  $ObjFile is the object to write.
function Invoke-NativeAssemble {
    param([hashtable]$P, [hashtable]$T, [string]$AsmPath, [string]$ObjFile, [int]$Bits)
    $res = @{ Ok = $false; Tool = '' }
    switch ($P.Syntax) {
        'nasm' {
            $fmt = 'win64'; if ($Bits -eq 32) { $fmt = 'win32' }
            $res.Tool = 'nasm'
            $s = Invoke-Stage 'assembler' $T.Nasm @('-f', $fmt, '-o', $ObjFile, $AsmPath)
            $res.Ok = $s.Ok
        }
        'masm' {
            $mk = $T.Masm.Kind; $res.Tool = $mk
            $fo = "$ObjFile"
            if ($mk -eq 'ml64')      { $a = @('/nologo', '/c', "/Fo$fo", $AsmPath) }
            elseif ($mk -eq 'ml')    { $a = @('/nologo', '/c', '/coff', "/Fo$fo", $AsmPath) }
            else {                   # uasm / jwasm
                $fmt = '-win64'; if ($Bits -eq 32) { $fmt = '-coff' }
                $a = @('-nologo', $fmt, "-Fo$fo", $AsmPath)
            }
            $s = Invoke-Stage 'MASM assembler' $T.Masm.Exe $a
            $res.Ok = $s.Ok
        }
        default {   # gas
            $xlang = 'assembler'; if ($P.Cpp) { $xlang = 'assembler-with-cpp' }
            if ($T.Cc) {
                $m = Get-CcMode $T.Cc $Bits; $a = @(); if ($m.M32) { $a += '-m32' }
                $a += @('-c', '-x', $xlang, $AsmPath, '-o', $ObjFile)
                $s = Invoke-Stage 'assembler (gcc -c)' $T.Cc $a -Quiet:($T.As -ne $null)
                if ($s.Ok) { $res.Ok = $true; $res.Tool = 'gcc -c'; return $res }
                if (-not $T.As) { return $res }
                Say "[AUTO] gcc could not assemble it; trying GNU as directly"
            }
            if (-not $T.Cc -and -not $T.As) { Fail 'No GNU as / MinGW gcc found for Windows (install MinGW-w64: winget install BrechtSanders.WinLibs.POSIX.UCRT).'; return $res }
            if ($T.As) {
                $flag = '--64'; if ($Bits -eq 32) { $flag = '--32' }
                $s = Invoke-Stage 'assembler (as)' $T.As @($flag, '-o', $ObjFile, $AsmPath)
                $res.Ok = $s.Ok; $res.Tool = 'as'
            }
        }
    }
    return $res
}

# ---- link -------------------------------------------------------------------------------------
function Invoke-GccLink {
    param([hashtable]$T, [string]$Obj, [string]$Exe, [int]$Bits, [string]$Entry, [bool]$Gui, [bool]$Quiet)
    $a = @(); if ((Get-CcMode $T.Cc $Bits).M32) { $a += '-m32' }
    if ($Entry) { $a += '-nostartfiles'; $a += "-Wl,-e,$Entry" }
    if ($Gui)   { $a += '-mwindows' }
    $a += @('-o', $Exe, $Obj)
    return (Invoke-Stage 'linker (gcc)' $T.Cc $a -Quiet:$Quiet)
}
function Invoke-BuiltinLink {
    param([string]$Obj, [string]$Exe, [string]$Entry, [bool]$Gui, [bool]$Quiet)
    $line = 'asmrun-pelink -o ' + (Format-Arg $Exe) + ' ' + (Format-Arg $Obj) + $(if ($Entry) { " -e $Entry" } else { '' })
    [void]$script:Commands.Add($line)
    $res = @{ Ok = $true; Text = ''; Code = 0 }
    if ($script:Opt.DryRun) { Write-Tag '[PLAN]' 'Magenta' $line; return $res }
    Show-Cmd $line
    $r = Invoke-PeLink -Objects @($Obj) -Out $Exe -Entry $Entry -Gui $Gui
    if (-not $r.Ok) {
        $res.Ok = $false; $res.Text = $r.Error; $res.Code = 1
        if (-not $Quiet) { Fail "linker (built-in) failed: $($r.Error)" }
    }
    return $res
}

# ---- FASM: assembles straight to a PE file --------------------------------------------------------
function Invoke-FasmBuild {
    param([hashtable]$T, [string]$AsmPath, [string]$Exe)
    $s = Invoke-Stage 'FASM' $T.Fasm @($AsmPath, $Exe)
    return $s
}

# What does the native route need that is missing?  (keys for Install-MissingTools)
function Get-MissingNative {
    param([hashtable]$P, [hashtable]$T)
    $m = @()
    switch ($P.Syntax) {
        'nasm' { if (-not $T.Nasm) { $m += 'nasm' } }
        'masm' { if (-not $T.Masm) { $m += 'uasm' } }
        'fasm' { if (-not $T.Fasm) { $m += 'fasm' } }
        default { if (-not $T.Cc -and -not $T.As) { $m += 'cc' } }
    }
    return $m
}

# Builds (and normally runs) the program natively.  Returns the exit code.
function Invoke-NativeRoute {
    param([hashtable]$P, [string]$SourcePath, [string]$AsmPath, [string[]]$ProgArgs, [hashtable]$Src)
    $O = $script:Opt
    if ($P.Arch -ne 'x86') { Die "The native Windows route only builds x86 / x64 code (this file is $($P.Arch)). Use --wsl." }
    if ($O.UnknownFwd.Count -gt 0) { Die "Unknown option: $($O.UnknownFwd[0])  (try --help)" 2 }
    $bits = $P.Bits
    if ($bits -ne 32 -and $bits -ne 64) { Die 'Could not decide between 32-bit and 64-bit; use --32 or --64.' }
    $syntax = $P.Syntax
    $isAsmOnly = $O.AsmOnly
    if ($syntax -eq 'fasm' -and $P.Fasm -ne 'pe') { Die "FASM 'format $($P.Fasm)' does not produce a Windows program; asmrun can only run 'format PE' files here." }

    # ---- tools ----
    $t = Get-NativeTools $bits
    if ($t.CcForced -and -not $t.Cc) { Die "C compiler '$(if ($O.Cc) { $O.Cc } else { $env:ASMRUN_CC })' was not found." }
    $missing = @(Get-MissingNative $P $t)
    if ($missing.Count -gt 0) {
        if ($O.DryRun) {
            Write-Tag '[PLAN]' 'Magenta' ('would offer to install: ' + ($missing -join ', '))
            foreach ($m in $missing) { if ($m -eq 'nasm') { $t.Nasm = 'nasm.exe' } elseif ($m -eq 'uasm') { $t.Masm = @{ Kind = 'uasm'; Exe = 'uasm64.exe' } } elseif ($m -eq 'fasm') { $t.Fasm = 'fasm.exe' } else { $t.Cc = 'gcc.exe' } }
        } else {
            if (-not (Install-MissingTools $missing $bits)) { Stop-Run 1 }
            $t = Get-NativeTools $bits
            $still = @(Get-MissingNative $P $t)
            if ($still.Count -gt 0) { Die ('Still missing: ' + ($still -join ', ')) }
        }
    }
    VInfo ("tools: nasm=$($t.Nasm)  cc=$($t.Cc)  as=$($t.As)  masm=$(if ($t.Masm) { $t.Masm.Kind + ' ' + $t.Masm.Exe })  fasm=$($t.Fasm)")

    # Is the compiler really a Windows one?  (a Linux gcc would silently build the wrong thing)
    $gccLinks = $false
    if ($t.Cc -and -not $O.DryRun) {
        $dm = Invoke-Native -File $t.Cc -Arguments @('-dumpmachine') -Capture
        $triple = ''; if ($dm.Started -and $dm.ExitCode -eq 0) { $triple = $dm.Out.Trim() }
        VInfo "compiler target: $triple"
        if ($triple -and $triple -notmatch 'mingw|windows|cygwin|msys') { Warn "The compiler targets '$triple', which is not Windows; asmrun will not use it for linking." ; $t.Cc = $null }
        else { $gccLinks = Test-CcLinks $t.Cc $bits }
    } elseif ($t.Cc -and $O.DryRun) { $gccLinks = $true }

    # ---- paths ----
    $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $work = ''
    if ($O.Workdir) {
        if (-not (Test-Path -LiteralPath $O.Workdir -PathType Container)) { Die "Work directory '$($O.Workdir)' does not exist." }
        $work = New-TempDir (Resolve-FullPath $O.Workdir)
    } else { $work = New-TempDir '' }
    $script:KeepWork = $O.Keep
    $objFile = Join-Path $work 'prog.obj'
    $exe = ''; $outKind = ''
    if ($isAsmOnly) {
        if ($O.Output) { $objFile = Resolve-FullPath $O.Output } else { $objFile = Join-Path $PWD.ProviderPath ($stem + '.obj') }
        $outKind = 'object'
    } else {
        if ($O.Output) {
            $exe = Resolve-FullPath $O.Output
            if ([IO.Path]::GetExtension($exe) -eq '') { $exe += '.exe' }
            $outKind = 'executable'
        } elseif ($O.LinkOnly) { $exe = Join-Path $PWD.ProviderPath ($stem + '.exe'); $outKind = 'executable' }
        else { $exe = Join-Path $work 'prog.exe'; $outKind = 'temp'; if ($O.Keep) { $outKind = 'executable' } }
    }
    foreach ($o2 in @($objFile, $exe)) {
        if ($o2 -and ((Resolve-FullPath $o2) -ieq (Resolve-FullPath $SourcePath))) { Die 'Refusing to overwrite the source file with -o.' }
    }
    if ($O.Report) {
        $repFull = Resolve-FullPath $O.Report
        if ($repFull -ieq (Resolve-FullPath $SourcePath)) { Die 'Refusing to overwrite the source file with --report.' }
        foreach ($o2 in @($objFile, $exe)) { if ($o2 -and $repFull -ieq (Resolve-FullPath $o2)) { Die '-o and --report must not name the same file.' } }
    }

    # ---- entry point (needed by gcc; the built-in linker finds main / _start / "end label" by itself) ----
    $entry = ''; $gui = $false
    if (-not $P.HasCMain) {
        $startLabel = Get-StartLabel $Src.Lines
        if ($P.HasWinMain) { $gui = $true }
        elseif ($P.EntryName -and @('_start', 'start', 'main', '_main') -notcontains $P.EntryName) { $entry = $P.EntryName }
        elseif ($startLabel) { $entry = $startLabel }
        elseif ($P.EndLabel) { $entry = $P.EndLabel }
        elseif ($syntax -ne 'masm' -and -not ($P.HasStart -or $P.HasPStart)) { Warn 'No entry point (main, _start or start) was found; the linker may reject this file.' }
    }
    $gccEntry = $entry
    if ($entry -and $bits -eq 32 -and $syntax -eq 'masm' -and -not $entry.StartsWith('_')) { $gccEntry = '_' + $entry }
    $targetId = 'x86_64-windows'; if ($bits -eq 32) { $targetId = 'i386-windows' }
    $asmTool = ''; $linkUsed = ''
    VInfo ("route: native Windows, $bits-bit, $syntax" + $(if ($entry) { ", custom entry '$entry'" } elseif ($P.HasCMain) { ', C-style main()' } else { '' }))

    # ---- FASM: one step ----
    $rc = 0
    $required = @($syntax)
    if ($syntax -eq 'fasm') {
        $exeOut = $exe; if ($isAsmOnly) { $exeOut = [IO.Path]::ChangeExtension($objFile, '.exe'); Warn 'FASM has no separate object step; building the .exe.' }
        $s = Invoke-FasmBuild $t $AsmPath $exeOut
        if (-not $s.Ok) { $script:ExitCode = 1; return 1 }
        $exe = $exeOut; $asmTool = 'fasm'; $linkUsed = 'fasm'
    } else {
        # ---- assemble ----
        $a = Invoke-NativeAssemble $P $t $AsmPath $objFile $bits
        $asmTool = $a.Tool
        if (-not $a.Ok) {
            Say ''
            $syn = @{ nasm = 'NASM'; gas = 'GNU as'; masm = 'MASM' }[$syntax]
            if (-not $P.SyntaxFirm) { Say "Hint: the syntax was auto-detected as $syn. If that is wrong, force it with --nasm, --gas or --masm." }
            $script:ExitCode = 1
            Write-Report @{ File = $SourcePath; Arch = $P.Arch; Syntax = $syntax; Bits = $bits; Target = $targetId; Link = ''; Assembler = $asmTool; Cpp = $P.Cpp; Required = $required; Output = ''; OutputKind = ''; ExitCode = 1; Kept = $(if ($O.Keep) { $work } else { '' }) }
            return 1
        }
        if (-not $O.DryRun -and -not (Test-Path -LiteralPath $objFile -PathType Leaf)) { Die "The assembler reported success but '$objFile' was not created." }
        if (-not $isAsmOnly) {
            # ---- link: choose the order ----
            $order = @('builtin')
            $linkerOpt = $O.Linker
            if ($linkerOpt -eq 'gcc') { $order = @('gcc') }
            elseif ($linkerOpt -eq 'builtin') { $order = @('builtin') }
            else {
                if ($gccLinks -and $syntax -ne 'masm' -and -not $P.HasWinMain) { $order = @('gcc', 'builtin') }
                elseif ($gccLinks) { $order = @('builtin', 'gcc') }
                else {
                    if ($t.Cc -and -not $O.DryRun) { Info "gcc ($($t.Cc)) has no $bits-bit Windows libraries, so the built-in linker is used." }
                    $order = @('builtin')
                }
            }
            $linked = $false
            for ($k = 0; $k -lt $order.Count; $k++) {
                $which = $order[$k]
                $quiet = ($k -lt $order.Count - 1)          # a fallback is available: keep this attempt quiet
                if ($which -eq 'gcc') { if (-not $t.Cc) { Fail 'gcc was requested but none was found.'; break }; $s = Invoke-GccLink $t $objFile $exe $bits $gccEntry $gui $quiet }
                else { $s = Invoke-BuiltinLink $objFile $exe $entry $gui $quiet }
                if ($s.Ok) { $linked = $true; $linkUsed = $which; break }
                if ($quiet) { Say "[AUTO] $which could not link it ($(Get-LinkFailReason $s.Text $bits)); trying $($order[$k + 1])" }
            }
            if (-not $linked) {
                Say ''
                if ($bits -eq 32) { Say 'Hint: 32-bit Windows programs link with the built-in linker (no MinGW needed). If it complains about unknown symbols, they come from a static C library: install a 32-bit MinGW and use --linker gcc.' }
                else { Say 'Hint: the built-in linker imports from the system DLLs (kernel32, user32, msvcrt, ...). Symbols from static libraries need gcc (--linker gcc).' }
                $script:ExitCode = 1
                Write-Report @{ File = $SourcePath; Arch = $P.Arch; Syntax = $syntax; Bits = $bits; Target = $targetId; Link = ''; Assembler = $asmTool; Cpp = $P.Cpp; Required = $required; Output = ''; OutputKind = ''; ExitCode = 1; Kept = $(if ($O.Keep) { $work } else { '' }) }
                return 1
            }
        }
    }

    $final = $exe; if ($isAsmOnly -and $syntax -ne 'fasm') { $final = $objFile }
    if (-not $O.DryRun) {
        if (-not (Test-Path -LiteralPath $final -PathType Leaf)) { Die "The build reported success but '$final' was not created." }
        $desc = Get-PeSummary $final
        if ($desc) { Write-Tag '[FILE]' 'DarkGray' $desc }
    }
    if ($O.Keep) { Write-Tag '[WORK]' 'DarkGray' "kept build directory: $work" }

    if ($isAsmOnly -or $O.LinkOnly) {
        if (-not $O.DryRun) { Good "Built: $final" }
    } elseif ($O.DryRun) {
        Write-Tag '[PLAN]' 'Magenta' ((Format-Command $exe $ProgArgs) + '   (the program would run here)')
    } else {
        $rc = Start-NativeProgram $exe $ProgArgs
        # Safety net: the built-in linker's output was rejected by Windows' loader -> retry with gcc.
        $rcU = [int64][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$rc), 0)
        $loaderFail = ($script:LastRunNotStarted -or ($script:LoaderFailures -contains $rcU))
        if ($loaderFail -and $linkUsed -eq 'builtin' -and $gccLinks -and $syntax -ne 'fasm' -and $O.Linker -ne 'builtin') {
            Say '[AUTO] Windows rejected the program made by the built-in linker; retrying with gcc'
            $s = Invoke-GccLink $t $objFile $exe $bits $gccEntry $gui $false
            if ($s.Ok) { $linkUsed = 'gcc'; $rc = Start-NativeProgram $exe $ProgArgs }
        }
        if (-not $script:LastRunNotStarted -and $rc -gt 0 -and $rc -lt 256 -and $P.HasCMain) {
            Info "main() returned $rc - that is simply the value left in eax at 'ret' (e.g. printf's character count). Put  xor eax, eax  before 'ret' to return 0."
        }
    }
    Write-Report @{ File = $SourcePath; Arch = $P.Arch; Syntax = $syntax; Bits = $bits; Target = $targetId; Link = $linkUsed; Assembler = $asmTool; Cpp = $P.Cpp
                    Required = $required; Output = $final; OutputKind = $outKind; ExitCode = $rc; Kept = $(if ($O.Keep) { $work } else { '' }) }
    $script:ExitCode = $rc
    return $rc
}

$script:LastRunNotStarted = $false
# Runs the built program with the console inherited and explains a failing exit status.
function Start-NativeProgram {
    param([string]$Exe, [string[]]$ProgArgs)
    $script:LastRunNotStarted = $false
    # ASMRUN_RUNNER: optional launcher for the built program (test hook, e.g. "wine"; leave unset normally).
    $tmo = $script:Opt.Timeout
    if ($env:ASMRUN_RUNNER) { $r = Invoke-Native -File $env:ASMRUN_RUNNER -Arguments (@($Exe) + @($ProgArgs)) -TimeoutSec $tmo }
    else                    { $r = Invoke-Native -File $Exe -Arguments $ProgArgs -TimeoutSec $tmo }
    if ($r.TimedOut) { Fail "the program was stopped after $tmo seconds (--timeout)."; return 124 }
    if (-not $r.Started) {
        $script:LastRunNotStarted = $true
        Fail "Could not start the program: $($r.Error)"
        Say 'If your antivirus or AppLocker blocked it, build into a trusted folder:  asmrun -o C:\path\prog.exe file.asm'
        return 126
    }
    $rc = $r.ExitCode
    if ($rc -ne 0) {
        $st = Format-ExitStatus $rc
        Write-Tag $st[0] 'Yellow' ''
        if ($st[1]) { Say ('        ' + $st[1]) }
    }
    return $rc
}

# ============================================================================
#  5b. PELINK  -  built-in COFF -> PE linker (no MinGW / MSVC / import libraries needed)
# ============================================================================
# Takes the COFF object(s) written by NASM (-f win32/win64), UASM/JWasm/ml (MASM), GNU as ...
# and produces a console/GUI .exe.  External symbols are imported BY NAME from the system DLLs
# (kernel32, user32, msvcrt ...), read straight from their export tables.  Supports i386 and
# amd64, any number of sections, COMMON symbols, __imp_ symbols, and a tiny startup stub that
# calls main() (with argc/argv from msvcrt).  Not supported: static libraries, TLS, SEH tables
# (.pdata/.xdata are dropped), resources.  For those, link with gcc (--linker gcc).

$script:PeStub32 = '5589e583ec18c745f0000000008d45f0506a008d45f4508d45f8508d45fc50ff150000000083c414ff75f4ff75f8ff75fce80000000083c40c50ff1500000000f4'
$script:PeStub64 = '4883ec48488d4c2430488d5424384c8d4424404531c948c744242800000000488d4424284889442420ff15000000008b4c2430488b5424384c8b442440e80000000089c1ff1500000000cc'
# stub fixups: offset of the 32-bit field, kind (dir32 = absolute VA of an IAT slot, rel32 = call/jump displacement), target
$script:PeStubFix32 = @( @(0x21, 'dir32', 'iat:__getmainargs'), @(0x32, 'rel32', 'sym:_main'), @(0x3C, 'dir32', 'iat:exit') )
$script:PeStubFix64 = @( @(0x2B, 'rel32', 'iat:__getmainargs'), @(0x3E, 'rel32', 'sym:main'), @(0x46, 'rel32', 'iat:exit') )
$script:PeDllOrder = @('kernel32', 'user32', 'gdi32', 'advapi32', 'shell32', 'msvcrt', 'ws2_32', 'ole32', 'oleaut32', 'comdlg32', 'comctl32', 'winmm', 'shlwapi', 'version', 'ntdll', 'ucrtbase')

function ConvertFrom-HexString {
    param([string]$Hex)
    $b = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$b
}
function Set-U16 { param([byte[]]$Buf, [int]$Off, [int64]$V) $Buf[$Off] = [byte]($V -band 255); $Buf[$Off + 1] = [byte](($V -shr 8) -band 255) }
function Set-U32 { param([byte[]]$Buf, [int]$Off, [int64]$V) for ($k = 0; $k -lt 4; $k++) { $Buf[$Off + $k] = [byte](($V -shr (8 * $k)) -band 255) } }
function Set-U64 { param([byte[]]$Buf, [int]$Off, [int64]$V) for ($k = 0; $k -lt 8; $k++) { $Buf[$Off + $k] = [byte](($V -shr (8 * $k)) -band 255) } }
function Get-U32 { param([byte[]]$Buf, [int]$Off) return [int64][BitConverter]::ToUInt32($Buf, $Off) }
function Get-AlignedUp { param([int64]$V, [int64]$A) if ($A -le 1) { return $V }; return [int64]([Math]::Ceiling($V / $A) * $A) }

# ---- reading a COFF object ----
function Read-CoffObject {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 20) { throw "'$Path' is too small to be a COFF object" }
    $machine = [BitConverter]::ToUInt16($b, 0)
    if ($machine -ne 0x14c -and $machine -ne 0x8664) { throw ("'{0}' is not an x86/x64 COFF object (machine 0x{1:X})" -f $Path, $machine) }
    $nsec = [BitConverter]::ToUInt16($b, 2)
    $symPtr = [int][BitConverter]::ToUInt32($b, 8)
    $nsym = [int][BitConverter]::ToUInt32($b, 12)
    $optSize = [BitConverter]::ToUInt16($b, 16)
    $strBase = $symPtr + 18 * $nsym
    $readName = {
        param([int]$off)      # 8-byte name field at $off
        if ([BitConverter]::ToUInt32($b, $off) -eq 0) {
            $so = $strBase + [int][BitConverter]::ToUInt32($b, $off + 4)
            $e = $so; while ($b[$e] -ne 0) { $e++ }
            return [Text.Encoding]::ASCII.GetString($b, $so, $e - $so)
        }
        $e = 0; while ($e -lt 8 -and $b[$off + $e] -ne 0) { $e++ }
        return [Text.Encoding]::ASCII.GetString($b, $off, $e)
    }
    $secs = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = 20 + $optSize + 40 * $i
        $nm = & $readName $o
        if ($nm.StartsWith('/')) {     # long name: "/offset" into the string table
            $so = $strBase + [int]$nm.Substring(1); $e = $so; while ($b[$e] -ne 0) { $e++ }
            $nm = [Text.Encoding]::ASCII.GetString($b, $so, $e - $so)
        }
        $raw = [int][BitConverter]::ToUInt32($b, $o + 16); $rawPtr = [int][BitConverter]::ToUInt32($b, $o + 20)
        $relPtr = [int][BitConverter]::ToUInt32($b, $o + 24); $nrel = [int][BitConverter]::ToUInt16($b, $o + 32)
        $flags = [int64][BitConverter]::ToUInt32($b, $o + 36)
        $data = $null
        if (($flags -band 0x80) -eq 0 -or ($flags -band 0x40) -ne 0) {
            if ($raw -gt 0 -and $rawPtr -gt 0) { $data = New-Object byte[] $raw; [Array]::Copy($b, $rawPtr, $data, 0, $raw) }
        }
        $rels = New-Object System.Collections.ArrayList
        for ($r = 0; $r -lt $nrel; $r++) {
            $ro = $relPtr + 10 * $r
            [void]$rels.Add(@{ Off = [int][BitConverter]::ToUInt32($b, $ro); Sym = [int][BitConverter]::ToUInt32($b, $ro + 4); Type = [int][BitConverter]::ToUInt16($b, $ro + 8) })
        }
        [void]$secs.Add(@{ Name = $nm; Index = $i + 1; VSize = [int][BitConverter]::ToUInt32($b, $o + 8); RawSize = $raw; Flags = $flags; Data = $data; Relocs = $rels })
    }
    $syms = New-Object object[] $nsym
    $i = 0
    while ($i -lt $nsym) {
        $so = $symPtr + 18 * $i
        $naux = [int]$b[$so + 17]
        $syms[$i] = @{ Name = (& $readName $so); Value = [int64][BitConverter]::ToUInt32($b, $so + 8); Sect = [int][BitConverter]::ToInt16($b, $so + 12)
                       Class = [int]$b[$so + 16]; Aux = $naux; Tag = $(if ($naux -gt 0) { [int][BitConverter]::ToUInt32($b, $so + 18) } else { -1 }) }
        $i += 1 + $naux
    }
    $drect = ''
    foreach ($s in $secs) { if ($s.Name -eq '.drectve' -and $s.Data) { $drect = [Text.Encoding]::ASCII.GetString($s.Data) } }
    return @{ Path = $Path; Machine = $machine; Sections = $secs; Symbols = $syms; Drectve = $drect }
}

# ---- DLL export tables (binary search; names are sorted in a PE export table) ----
$script:DllCache = @{}
function Open-Dll {
    param([string]$Path)
    if ($script:DllCache.ContainsKey($Path)) { return $script:DllCache[$Path] }
    $d = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $b = [IO.File]::ReadAllBytes($Path)
        if ($b.Length -gt 0x100 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A) {
            $pe = [int][BitConverter]::ToUInt32($b, 0x3C)
            $nsec = [BitConverter]::ToUInt16($b, $pe + 6); $optSz = [BitConverter]::ToUInt16($b, $pe + 20)
            $opt = $pe + 24; $magic = [BitConverter]::ToUInt16($b, $opt)
            $ddOff = $opt + $(if ($magic -eq 0x20B) { 112 } else { 96 })
            $expRva = [int64][BitConverter]::ToUInt32($b, $ddOff)
            $secT = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $nsec; $i++) {
                $so = $opt + $optSz + 40 * $i
                [void]$secT.Add(@{ VA = [int64][BitConverter]::ToUInt32($b, $so + 12); VS = [int64][BitConverter]::ToUInt32($b, $so + 8); RP = [int64][BitConverter]::ToUInt32($b, $so + 20); RS = [int64][BitConverter]::ToUInt32($b, $so + 16) })
            }
            $d = @{ Bytes = $b; Secs = $secT; NNames = 0; NamesOff = 0; Valid = $false }
            if ($expRva -gt 0) {
                $eo = Convert-RvaToOffset $d $expRva
                if ($eo -gt 0) { $d.NNames = [int][BitConverter]::ToUInt32($b, $eo + 24); $d.NamesOff = Convert-RvaToOffset $d ([int64][BitConverter]::ToUInt32($b, $eo + 32)); $d.Valid = ($d.NamesOff -gt 0) }
            }
        }
    }
    $script:DllCache[$Path] = $d
    return $d
}
function Convert-RvaToOffset {
    param([hashtable]$Dll, [int64]$Rva)
    foreach ($s in $Dll.Secs) { if ($Rva -ge $s.VA -and $Rva -lt $s.VA + [Math]::Max($s.VS, $s.RS)) { return [int]($Rva - $s.VA + $s.RP) } }
    return -1
}
function Test-DllExports {
    param([hashtable]$Dll, [string]$Name)
    if (-not $Dll -or -not $Dll.Valid) { return $false }
    $b = $Dll.Bytes; $lo = 0; $hi = $Dll.NNames - 1
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        $nameOff = Convert-RvaToOffset $Dll ([int64][BitConverter]::ToUInt32($b, $Dll.NamesOff + 4 * $mid))
        if ($nameOff -lt 0) { return $false }
        $e = $nameOff; while ($b[$e] -ne 0) { $e++ }
        $cur = [Text.Encoding]::ASCII.GetString($b, $nameOff, $e - $nameOff)
        $c = [string]::CompareOrdinal($Name, $cur)
        if ($c -eq 0) { return $true } elseif ($c -lt 0) { $hi = $mid - 1 } else { $lo = $mid + 1 }
    }
    return $false
}
function Get-DllDirectory {
    param([bool]$Is64)
    $ov = $env:ASMRUN_DLLDIR32; if ($Is64) { $ov = $env:ASMRUN_DLLDIR64 }
    if ($ov) { return $ov }
    $sr = $env:SystemRoot; if (-not $sr) { $sr = 'C:\Windows' }
    if ($Is64) {
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { return (Join-Path $sr 'Sysnative') }
        return (Join-Path $sr 'System32')
    }
    $w = Join-Path $sr 'SysWOW64'
    if (Test-Path -LiteralPath $w -PathType Container) { return $w }
    return (Join-Path $sr 'System32')
}
# i386 C names carry a leading underscore and stdcall names a trailing @N.
function ConvertTo-ExportName {
    param([string]$Sym, [bool]$Is64)
    $n = $Sym
    if (-not $Is64) {
        if ($n.StartsWith('_')) { $n = $n.Substring(1) }
        $n = $n -replace '@[0-9]+$', ''
    }
    return $n
}

# ---- the linker ----
# Returns @{ Ok; Error; Warnings; Entry }.  $Entry: '' = auto.  $Gui: GUI subsystem.
function Invoke-PeLink {
    param([string[]]$Objects, [string]$Out, [string]$Entry = '', [bool]$Gui = $false)
    $res = @{ Ok = $false; Error = ''; Warnings = (New-Object System.Collections.ArrayList); Entry = '' }
    try {
        $objs = @(); foreach ($p in $Objects) { $objs += , (Read-CoffObject $p) }
        $mach = $objs[0].Machine; $is64 = ($mach -eq 0x8664)
        foreach ($o in $objs) { if ($o.Machine -ne $mach) { throw 'objects of different machine types cannot be linked together' } }
        $imageBase = 0x400000
        $ptrSize = 4; if ($is64) { $ptrSize = 8 }

        # --- 1. choose and classify input sections ---
        $cls = @{ text = (New-Object System.Collections.ArrayList); rdata = (New-Object System.Collections.ArrayList); data = (New-Object System.Collections.ArrayList); bss = (New-Object System.Collections.ArrayList) }
        $clsSize = @{ text = 0; rdata = 0; data = 0; bss = 0 }
        $clsAlign = @{ text = 16; rdata = 16; data = 16; bss = 16 }
        foreach ($o in $objs) {
            foreach ($s in $o.Sections) {
                $nm = $s.Name; $fl = $s.Flags
                if (($fl -band 0xE0) -eq 0) { continue }                                  # no code/data
                if (($fl -band 0x02000800) -ne 0) { continue }                            # discardable / LNK_REMOVE
                if ($nm -like '.debug*' -or $nm -like '.pdata*' -or $nm -like '.xdata*' -or $nm -like '.rsrc*' -or $nm -eq '.drectve') { continue }
                $c = 'rdata'
                if (($fl -band 0x20) -ne 0) { $c = 'text' }
                elseif (($fl -band 0x40) -eq 0 -and ($fl -band 0x80) -ne 0) { $c = 'bss' }
                elseif (($fl -band 2147483648) -ne 0) { $c = 'data' }
                $an = [int](($fl -shr 20) -band 15); $al = 16; if ($an -gt 0) { $al = [int][Math]::Pow(2, $an - 1) }
                $size = [Math]::Max($s.RawSize, $s.VSize)
                $off = Get-AlignedUp $clsSize[$c] $al
                $s.Class = $c; $s.ClsOff = $off
                $clsSize[$c] = $off + $size
                if ($al -gt $clsAlign[$c]) { $clsAlign[$c] = $al }
                $s.Obj = $o; [void]$cls[$c].Add($s)
            }
        }

        # --- 2. symbols: defined externals, undefined (imports / COMMON) ---
        $defs = @{}          # name -> @{Sec=<section>; Val=<value>} or @{Abs=<value>}
        foreach ($o in $objs) {
            foreach ($sy in $o.Symbols) {
                if ($null -eq $sy) { continue }
                if ($sy.Class -eq 2 -and $sy.Sect -gt 0) {
                    $secObj = $null; foreach ($s in $o.Sections) { if ($s.Index -eq $sy.Sect) { $secObj = $s } }
                    if ($secObj -and $secObj.ContainsKey('Class')) { $defs[$sy.Name] = @{ Sec = $secObj; Val = $sy.Value } }
                } elseif ($sy.Class -eq 2 -and $sy.Sect -eq -1) { $defs[$sy.Name] = @{ Abs = $sy.Value } }
            }
        }
        # COMMON symbols (undefined external with a size) live in .bss
        $commons = @{}
        foreach ($o in $objs) {
            foreach ($sy in $o.Symbols) {
                if ($null -eq $sy) { continue }
                if ($sy.Class -eq 2 -and $sy.Sect -eq 0 -and $sy.Value -gt 0 -and -not $defs.ContainsKey($sy.Name) -and -not $commons.ContainsKey($sy.Name)) {
                    $off = Get-AlignedUp $clsSize['bss'] 16; $commons[$sy.Name] = $off; $clsSize['bss'] = $off + $sy.Value
                }
            }
        }
        # which undefined symbols are really referenced by kept sections?
        $need = New-Object System.Collections.ArrayList; $needSet = @{}
        foreach ($c in @('text', 'rdata', 'data')) {
            foreach ($s in $cls[$c]) {
                foreach ($r in $s.Relocs) {
                    $sy = $s.Obj.Symbols[$r.Sym]
                    if ($null -eq $sy) { continue }
                    if ($sy.Sect -eq 0 -and $sy.Class -ne 3 -and -not $defs.ContainsKey($sy.Name) -and -not $commons.ContainsKey($sy.Name) -and -not $needSet.ContainsKey($sy.Name)) {
                        $needSet[$sy.Name] = $true; [void]$need.Add($sy.Name)
                    }
                }
            }
        }

        # --- 3. entry point ---
        $mainName = 'main'; if (-not $is64) { $mainName = '_main' }
        $entrySym = $Entry
        if (-not $entrySym) {
            foreach ($o in $objs) { foreach ($m in [regex]::Matches($o.Drectve, '(?i)[-/]entry:([^\s"]+)')) { $entrySym = $m.Groups[1].Value } }
            foreach ($o in $objs) { if ($o.Drectve -match '(?i)[-/]subsystem:windows') { $Gui = $true } }
        }
        $useStub = $false
        if (-not $entrySym) {
            if ($defs.ContainsKey($mainName)) { $useStub = $true; $res.Entry = $mainName }
            else {
                foreach ($cand in @('_start', 'start', 'Start', '_Start', 'START', 'entry', '_entry', 'mainCRTStartup', '_mainCRTStartup', 'WinMainCRTStartup', '_WinMainCRTStartup')) {
                    if ($defs.ContainsKey($cand)) { $entrySym = $cand; break }
                }
            }
        }
        if (-not $useStub) {
            if (-not $entrySym) {
                foreach ($wm in @('WinMain', '_WinMain@16', 'wWinMain', '_wWinMain@16')) { if ($defs.ContainsKey($wm)) { throw "this program defines $wm, which needs the C runtime's startup code: link it with gcc (--linker gcc, needs MinGW-w64), or give it a plain start label (_start / start / Start) that calls ExitProcess" } }
                throw 'no entry point: define main, or a start label (_start / start / Start) and export it (global / public)'
            }
            if (-not $defs.ContainsKey($entrySym)) {
                $alt = $null; if ($entrySym.StartsWith('_')) { $alt = $entrySym.Substring(1) } else { $alt = '_' + $entrySym }
                if ($defs.ContainsKey($alt)) { $entrySym = $alt } else { throw "entry point '$entrySym' is not defined (is it exported with global / public?)" }
            }
            $res.Entry = $entrySym
        }

        # --- 4. imports ---
        $imports = New-Object System.Collections.ArrayList          # @{Sym; Name; Dll; Thunk(bool)}
        $impByName = @{}
        $addImp = {
            param([string]$sym, [bool]$thunk)
            $isImpSym = $sym.StartsWith('__imp_'); $core = $sym; if ($isImpSym) { $core = $sym.Substring(6) }
            $nm = ConvertTo-ExportName $core $is64
            $key = $nm
            if (-not $impByName.ContainsKey($key)) { $e = @{ Name = $nm; Dll = ''; Thunk = $false; IatRva = 0 }; $impByName[$key] = $e; [void]$imports.Add($e) }
            if ($thunk -and -not $isImpSym) { $impByName[$key].Thunk = $true }
            return $impByName[$key]
        }
        $symImp = @{}                                              # symbol name -> import entry
        foreach ($n in $need) {
            $isImpSym = $n.StartsWith('__imp_')
            $symImp[$n] = & $addImp $n (-not $isImpSym)
        }
        if ($useStub) {      # the stub's symbols are written in the object's own (decorated) naming
            if ($is64) { $null = & $addImp '__imp___getmainargs' $false; $null = & $addImp '__imp_exit' $false }
            else       { $null = & $addImp '__imp____getmainargs' $false; $null = & $addImp '__imp__exit' $false }
        }
        # drectve libs give the search order a head start
        $order = New-Object System.Collections.ArrayList
        foreach ($o in $objs) { foreach ($m in [regex]::Matches($o.Drectve, '(?i)[-/]defaultlib:"?([^\s"]+?)(?:\.lib)?"?(?=\s|$)')) {
            $ln = $m.Groups[1].Value.ToLower(); if ($ln -eq 'ucrt' -or $ln -eq 'libcmt' -or $ln -eq 'msvcrt' -or $ln -eq 'legacy_stdio_definitions') { $ln = 'msvcrt' }
            if (-not ($order -contains $ln)) { [void]$order.Add($ln) } } }
        foreach ($d in $script:PeDllOrder) { if (-not ($order -contains $d)) { [void]$order.Add($d) } }
        $dllDir = Get-DllDirectory $is64
        $missing = New-Object System.Collections.ArrayList
        foreach ($imp in $imports) {
            $try = @($order)
            if ($imp.Name -cmatch '^[a-z_]' -and ($try -contains 'msvcrt')) { $try = @('msvcrt') + @($order | Where-Object { $_ -ne 'msvcrt' }) }   # C-runtime style names: look in msvcrt first (fewer DLLs to read)
            foreach ($dn in $try) {
                $dll = Open-Dll (Join-Path $dllDir ($dn + '.dll'))
                if (Test-DllExports $dll $imp.Name) { $imp.Dll = $dn + '.dll'; break }
            }
            if (-not $imp.Dll) { [void]$missing.Add($imp.Name) }
        }
        if ($missing.Count -gt 0) {
            throw ("these symbols were not found in the system DLLs ($dllDir): " + (($missing | Select-Object -First 12) -join ', ') + $(if ($missing.Count -gt 12) { ' ...' } else { '' }))
        }

        # --- 5. layout ---
        $stub = $null; $stubFix = $null
        if ($useStub) { if ($is64) { $stub = ConvertFrom-HexString $script:PeStub64; $stubFix = $script:PeStubFix64 } else { $stub = ConvertFrom-HexString $script:PeStub32; $stubFix = $script:PeStubFix32 } }
        $thunkImps = @($imports | Where-Object { $_.Thunk })
        $textUser = $clsSize['text']
        $stubOff = Get-AlignedUp $textUser 16; $stubLen = 0; if ($stub) { $stubLen = $stub.Length }
        $thunkOff = Get-AlignedUp ($stubOff + $stubLen) 16
        $textSize = $thunkOff + 8 * $thunkImps.Count
        $sizes = @{ text = $textSize; rdata = $clsSize['rdata']; data = $clsSize['data']; bss = $clsSize['bss'] }
        # idata: IDT, then per DLL ILT+IAT, hint/name table, dll names
        $dllNames = New-Object System.Collections.ArrayList
        foreach ($imp in $imports) { if (-not ($dllNames -contains $imp.Dll)) { [void]$dllNames.Add($imp.Dll) } }
        $idtSize = 20 * ($dllNames.Count + 1)
        $iltTotal = 0; foreach ($dn in $dllNames) { $cnt = @($imports | Where-Object { $_.Dll -eq $dn }).Count; $iltTotal += ($cnt + 1) * $ptrSize }
        $hintSize = 0; foreach ($imp in $imports) { $hintSize += Get-AlignedUp (2 + $imp.Name.Length + 1) 2 }
        $nameSize = 0; foreach ($dn in $dllNames) { $nameSize += $dn.Length + 1 }
        $idataSize = $idtSize + 2 * $iltTotal + $hintSize + $nameSize

        $nsecs = 0; $order2 = @('text', 'rdata', 'data', 'bss')
        foreach ($c in $order2) { if ($sizes[$c] -gt 0) { $nsecs++ } }
        $nsecs++                                                    # .idata
        $optSize = 224; if ($is64) { $optSize = 240 }
        $hdrSize = [int](Get-AlignedUp (0x80 + 4 + 20 + $optSize + 40 * $nsecs) 0x200)
        $secAlign = 0x1000; $fileAlign = 0x200
        $rva = @{}; $cur = $secAlign
        foreach ($c in $order2) { if ($sizes[$c] -gt 0) { $rva[$c] = $cur; $cur = [int](Get-AlignedUp ($cur + $sizes[$c]) $secAlign) } }
        $rva['idata'] = $cur; $imageSize = [int](Get-AlignedUp ($cur + $idataSize) $secAlign)

        # idata layout (offsets inside .idata)
        $idata = New-Object byte[] $idataSize
        $pos = $idtSize; $iltPos = @{}; $iatPos = @{}
        foreach ($dn in $dllNames) { $cnt = @($imports | Where-Object { $_.Dll -eq $dn }).Count; $iltPos[$dn] = $pos; $pos += ($cnt + 1) * $ptrSize }
        foreach ($dn in $dllNames) { $cnt = @($imports | Where-Object { $_.Dll -eq $dn }).Count; $iatPos[$dn] = $pos; $pos += ($cnt + 1) * $ptrSize }
        $hintPos = $pos; $pos += $hintSize
        $namePos = @{}; foreach ($dn in $dllNames) { $namePos[$dn] = $pos; $pos += $dn.Length + 1 }
        $dI = 0; $hp = $hintPos
        foreach ($dn in $dllNames) {
            $slot = 0
            foreach ($imp in ($imports | Where-Object { $_.Dll -eq $dn })) {
                $hnRva = $rva['idata'] + $hp
                $ent = $hnRva
                $so = $iltPos[$dn] + $slot * $ptrSize; $ao = $iatPos[$dn] + $slot * $ptrSize
                if ($is64) { Set-U64 $idata $so $ent; Set-U64 $idata $ao $ent } else { Set-U32 $idata $so $ent; Set-U32 $idata $ao $ent }
                $imp.IatRva = $rva['idata'] + $ao
                $nb = [Text.Encoding]::ASCII.GetBytes($imp.Name)
                [Array]::Copy($nb, 0, $idata, $hp + 2, $nb.Length)
                $hp += [int](Get-AlignedUp (2 + $nb.Length + 1) 2)
                $slot++
            }
            $io = 20 * $dI
            Set-U32 $idata $io ($rva['idata'] + $iltPos[$dn]); Set-U32 $idata ($io + 12) ($rva['idata'] + $namePos[$dn]); Set-U32 $idata ($io + 16) ($rva['idata'] + $iatPos[$dn])
            $nb = [Text.Encoding]::ASCII.GetBytes($dn); [Array]::Copy($nb, 0, $idata, $namePos[$dn], $nb.Length)
            $dI++
        }

        # --- 6. section images and symbol addresses ---
        $img = @{}
        foreach ($c in @('text', 'rdata', 'data')) { $img[$c] = New-Object byte[] ([Math]::Max($sizes[$c], 1)) }
        foreach ($c in @('text', 'rdata', 'data')) {
            foreach ($s in $cls[$c]) { if ($s.Data) { [Array]::Copy($s.Data, 0, $img[$c], $s.ClsOff, [Math]::Min($s.Data.Length, $sizes[$c] - $s.ClsOff)) } }
        }
        $secBase = { param($s) return [int64]($rva[$s.Class] + $s.ClsOff) }
        $thunkAddr = @{}; $ti = 0
        foreach ($imp in $thunkImps) { $thunkAddr[$imp.Name] = $rva['text'] + $thunkOff + 8 * $ti; $ti++ }
        $symAddr = {
            param($obj, $sy)
            if ($sy.Sect -gt 0) {
                foreach ($s in $obj.Sections) { if ($s.Index -eq $sy.Sect) { if ($s.ContainsKey('Class')) { return [int64]((& $secBase $s) + $sy.Value) } else { return $null } } }
                return $null
            }
            if ($sy.Sect -eq -1) { return [int64]$sy.Value }
            if ($defs.ContainsKey($sy.Name)) {
                $d = $defs[$sy.Name]
                if ($d.ContainsKey('Abs')) { return [int64]$d.Abs }
                return [int64]((& $secBase $d.Sec) + $d.Val)
            }
            if ($commons.ContainsKey($sy.Name)) { return [int64]($rva['bss'] + $commons[$sy.Name]) }
            $imp = $symImp[$sy.Name]
            if ($null -ne $imp) {
                if ($sy.Name.StartsWith('__imp_')) { return [int64]$imp.IatRva }
                return [int64]$thunkAddr[$imp.Name]
            }
            return $null
        }

        # --- 7. relocations ---
        foreach ($c in @('text', 'rdata', 'data')) {
            $buf = $img[$c]
            foreach ($s in $cls[$c]) {
                foreach ($r in $s.Relocs) {
                    $sy = $s.Obj.Symbols[$r.Sym]
                    if ($null -eq $sy) { continue }
                    $t = & $symAddr $s.Obj $sy
                    if ($null -eq $t) { if ($sy.Class -eq 3 -or $sy.Name -like '.debug*') { continue }; throw "unresolved symbol '$($sy.Name)'" }
                    $loc = $s.ClsOff + $r.Off; $locRva = $rva[$c] + $loc
                    if ($is64) {
                        switch ($r.Type) {
                            1 { $v = [BitConverter]::ToInt64($buf, $loc) + $imageBase + $t; Set-U64 $buf $loc $v }
                            2 { $v = [int64][BitConverter]::ToUInt32($buf, $loc) + $imageBase + $t; Set-U32 $buf $loc $v }
                            3 { $v = [int64][BitConverter]::ToInt32($buf, $loc) + $t; Set-U32 $buf $loc $v }
                            { $_ -ge 4 -and $_ -le 9 } { $v = [int64][BitConverter]::ToInt32($buf, $loc) + $t - ($locRva + 4 + ($_ - 4)); Set-U32 $buf $loc $v }
                            { $_ -eq 0 -or $_ -eq 10 -or $_ -eq 11 } { }
                            default { throw "unsupported amd64 relocation type $($r.Type)" }
                        }
                    } else {
                        switch ($r.Type) {
                            6 { $v = [int64][BitConverter]::ToUInt32($buf, $loc) + $imageBase + $t; Set-U32 $buf $loc $v }
                            7 { $v = [int64][BitConverter]::ToInt32($buf, $loc) + $t; Set-U32 $buf $loc $v }
                            20 { $v = [int64][BitConverter]::ToInt32($buf, $loc) + $t - ($locRva + 4); Set-U32 $buf $loc $v }
                            { $_ -eq 10 -or $_ -eq 11 -or $_ -eq 0 } { }
                            default { throw "unsupported i386 relocation type $($r.Type)" }
                        }
                    }
                }
            }
        }
        # stub + thunks
        $tb = $img['text']
        if ($stub) {
            [Array]::Copy($stub, 0, $tb, $stubOff, $stub.Length)
            foreach ($f in $stubFix) {
                $fo = $stubOff + $f[0]; $kind = $f[1]; $tg = $f[2]
                $addr = 0
                if ($tg.StartsWith('iat:')) { $addr = $impByName[$tg.Substring(4)].IatRva }
                else { $nm = $tg.Substring(4); $addr = & $symAddr $null @{ Sect = 0; Name = $nm; Class = 2; Value = 0 } }
                if ($kind -eq 'dir32') { Set-U32 $tb $fo ($imageBase + $addr) } else { Set-U32 $tb $fo ($addr - ($rva['text'] + $fo + 4)) }
            }
        }
        $ti = 0
        foreach ($imp in $thunkImps) {
            $to = $thunkOff + 8 * $ti; $tb[$to] = 0xFF; $tb[$to + 1] = 0x25
            if ($is64) { Set-U32 $tb ($to + 2) ($imp.IatRva - ($rva['text'] + $to + 6)) } else { Set-U32 $tb ($to + 2) ($imageBase + $imp.IatRva) }
            $tb[$to + 6] = 0xCC; $tb[$to + 7] = 0xCC; $ti++
        }
        # entry
        $entryRva = 0
        if ($useStub) { $entryRva = $rva['text'] + $stubOff }
        else { $entryRva = [int64](& $symAddr $null @{ Sect = 0; Name = $res.Entry; Class = 2; Value = 0 }) }

        # --- 8. write the PE file ---
        $secList = New-Object System.Collections.ArrayList
        foreach ($c in @('text', 'rdata', 'data')) { if ($sizes[$c] -gt 0) { $fl = @{ text = 1610612768; rdata = 1073741888; data = 3221225536 }[$c]; [void]$secList.Add(@{ Name = ".$c"; Buf = $img[$c]; VSize = $sizes[$c]; Rva = $rva[$c]; Flags = $fl }) } }
        if ($sizes['bss'] -gt 0) { [void]$secList.Add(@{ Name = '.bss'; Buf = $null; VSize = $sizes['bss']; Rva = $rva['bss']; Flags = 3221225600 }) }
        [void]$secList.Add(@{ Name = '.idata'; Buf = $idata; VSize = $idataSize; Rva = $rva['idata']; Flags = 3221225536 })
        $fileOff = $hdrSize; $fileSize = $hdrSize
        foreach ($s in $secList) { if ($s.Buf) { $s.RawPtr = $fileOff; $s.RawSize = [int](Get-AlignedUp $s.Buf.Length $fileAlign); if ($s.Name -ne '.idata' -and $s.VSize -lt $s.Buf.Length) { $s.RawSize = [int](Get-AlignedUp $s.VSize $fileAlign) }; $fileOff += $s.RawSize } else { $s.RawPtr = 0; $s.RawSize = 0 } }
        $fileSize = $fileOff
        $pe = New-Object byte[] $fileSize
        $pe[0] = 0x4D; $pe[1] = 0x5A; Set-U32 $pe 0x3C 0x80
        $dosStub = ConvertFrom-HexString '0e1fba0e00b409cd21b8014ccd21'
        [Array]::Copy($dosStub, 0, $pe, 0x40, $dosStub.Length)
        $msg = [Text.Encoding]::ASCII.GetBytes("This program cannot be run in DOS mode.`r`r`n`$"); [Array]::Copy($msg, 0, $pe, 0x4E, $msg.Length)
        $pe[0x80] = 0x50; $pe[0x81] = 0x45
        $co = 0x84
        $machOut = 0x14c; if ($is64) { $machOut = 0x8664 }
        Set-U16 $pe $co $machOut; Set-U16 $pe ($co + 2) $secList.Count; Set-U16 $pe ($co + 16) $optSize
        $chars = 0x0103; if ($is64) { $chars = 0x0023 }                 # EXE, no relocs, (32-bit machine | large address aware)
        Set-U16 $pe ($co + 18) $chars
        $oo = 0x98
        $codeSize = 0; $initSize = 0; $uninit = 0
        foreach ($s in $secList) { if ($s.Name -eq '.text') { $codeSize = $s.VSize } elseif ($s.Name -eq '.bss') { $uninit = $s.VSize } else { $initSize += $s.VSize } }
        if ($is64) { Set-U16 $pe $oo 0x20B } else { Set-U16 $pe $oo 0x10B }
        $pe[$oo + 2] = 2; $pe[$oo + 3] = 30
        Set-U32 $pe ($oo + 4) $codeSize; Set-U32 $pe ($oo + 8) $initSize; Set-U32 $pe ($oo + 12) $uninit
        Set-U32 $pe ($oo + 16) $entryRva; Set-U32 $pe ($oo + 20) $rva['text']
        # optional header, spec offsets relative to $oo (PE32 and PE32+ share everything up to ImageBase)
        if ($is64) { Set-U64 $pe ($oo + 24) $imageBase } else { Set-U32 $pe ($oo + 24) $rva['rdata']; Set-U32 $pe ($oo + 28) $imageBase }
        Set-U32 $pe ($oo + 32) $secAlign; Set-U32 $pe ($oo + 36) $fileAlign
        Set-U16 $pe ($oo + 40) 6                    # MajorOperatingSystemVersion
        Set-U16 $pe ($oo + 48) 6                    # MajorSubsystemVersion
        Set-U32 $pe ($oo + 56) $imageSize; Set-U32 $pe ($oo + 60) $hdrSize
        $sub = 3; if ($Gui) { $sub = 2 }
        Set-U16 $pe ($oo + 68) $sub; Set-U16 $pe ($oo + 70) 0x8000      # subsystem, DllCharacteristics = terminal-server aware (no ASLR, no NX opt-in)
        if ($is64) {
            Set-U64 $pe ($oo + 72) 0x100000; Set-U64 $pe ($oo + 80) 0x1000; Set-U64 $pe ($oo + 88) 0x100000; Set-U64 $pe ($oo + 96) 0x1000
            Set-U32 $pe ($oo + 108) 16; $dd = $oo + 112
        } else {
            Set-U32 $pe ($oo + 72) 0x100000; Set-U32 $pe ($oo + 76) 0x1000; Set-U32 $pe ($oo + 80) 0x100000; Set-U32 $pe ($oo + 84) 0x1000
            Set-U32 $pe ($oo + 92) 16; $dd = $oo + 96
        }
        Set-U32 $pe ($dd + 8) $rva['idata']; Set-U32 $pe ($dd + 12) $idtSize                 # data directory 1 = imports
        $iatStart = $rva['idata'] + $iatPos[$dllNames[0]]; $iatLen = 0
        foreach ($dn in $dllNames) { $cnt = @($imports | Where-Object { $_.Dll -eq $dn }).Count; $iatLen += ($cnt + 1) * $ptrSize }
        Set-U32 $pe ($dd + 96) $iatStart; Set-U32 $pe ($dd + 100) $iatLen                    # data directory 12 = IAT
        $sh = $oo + $optSize
        foreach ($s in $secList) {
            $nb = [Text.Encoding]::ASCII.GetBytes($s.Name); [Array]::Copy($nb, 0, $pe, $sh, $nb.Length)
            Set-U32 $pe ($sh + 8) $s.VSize; Set-U32 $pe ($sh + 12) $s.Rva; Set-U32 $pe ($sh + 16) $s.RawSize; Set-U32 $pe ($sh + 20) $s.RawPtr; Set-U32 $pe ($sh + 36) $s.Flags
            if ($s.Buf) { [Array]::Copy($s.Buf, 0, $pe, $s.RawPtr, [Math]::Min($s.Buf.Length, $s.RawSize)) }
            $sh += 40
        }
        [IO.File]::WriteAllBytes($Out, $pe)
        $res.Ok = $true
    } catch {
        $res.Error = $_.Exception.Message
    }
    return $res
}

# ============================================================================
#  6. WSL  -  run Linux / ARM / RISC-V sources through the embedded asmrun v5 engine
# ============================================================================
$script:WslCache = $null

function Get-WslArgsBase {
    if ($script:Opt.Distro) { return @('-d', $script:Opt.Distro) }
    return @()
}

# Is WSL installed, and does it have a distribution that can run a shell?
function Get-WslState {
    if ($null -ne $script:WslCache) { return $script:WslCache }
    $s = @{ Exe = $null; Usable = $false; Reason = '' }
    $s.Exe = Find-Tool @('wsl.exe')
    # A 32-bit process on 64-bit Windows cannot see System32\wsl.exe (file-system redirection);
    # the "Sysnative" alias reaches the real System32.
    if (-not $s.Exe -and $script:OnWindows -and [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $alt = Join-Path $env:SystemRoot 'Sysnative\wsl.exe'
        if (Test-Path -LiteralPath $alt -PathType Leaf) { $s.Exe = $alt }
    }
    if (-not $s.Exe) {
        $s.Reason = 'wsl.exe was not found (WSL is not installed on this PC)'
    } else {
        $r = Invoke-Native -File $s.Exe -Arguments ((Get-WslArgsBase) + @('-e', 'sh', '-c', 'true')) -Capture
        if (-not $r.Started) { $s.Reason = "wsl.exe could not be started: $($r.Error)" }
        elseif ($r.ExitCode -eq 0) { $s.Usable = $true }
        else {
            $msg = Repair-WslText ($r.Out + ' ' + $r.Err)
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
            $s.Reason = "WSL has no usable Linux distribution (wsl.exe exit code $($r.ExitCode)). $msg"
        }
    }
    $script:WslCache = $s
    return $s
}

# Offer to start "wsl --install" (needs administrator permission and a restart).  Never answered by -y.
function Offer-WslInstall {
    param([hashtable]$St)
    if (-not $script:OnWindows -or -not $St.Exe -or -not (Test-Interactive)) { return }
    if ($St.Reason -notlike 'WSL has no usable*') { return }        # wsl.exe exists but no distribution: "wsl --install" is the right fix
    $a = Read-Line 'Start the WSL installation now?  (asks for administrator permission; you must restart afterwards)  [y/N] '
    if ($null -eq $a -or $a.Trim().ToLower() -notin @('y', 'yes')) { return }
    try {
        Start-Process -FilePath $St.Exe -ArgumentList '--install' -Verb RunAs
        Say 'The installer was started in a new window. When it finishes: restart the PC, open "Ubuntu" from the Start menu once, then run asmrun again.'
    } catch { Fail "Could not start the installer: $($_.Exception.Message)" }
}

function Show-WslHelp {
    param([string]$Reason)
    Say ''
    Say 'This file needs Linux (WSL) to run, but WSL is not ready:'
    Say "  $Reason"
    Say ''
    Say 'Set it up once (Windows 10 version 2004+ or Windows 11):'
    Say '  1. Open PowerShell as Administrator and run:   wsl --install'
    Say '  2. Restart the PC if it asks. Open "Ubuntu" from the Start menu once and create a user name + password.'
    Say '  3. Run asmrun again.  (asmrun installs nasm/gcc/... inside Linux for you, after asking.)'
    Say 'Already have WSL?  Check with   wsl -l -v   . A distro named docker-desktop alone has no shell;'
    Say 'install a real one with   wsl --install -d Ubuntu   or choose it with   --distro NAME .'
    Say 'If this is really a Windows program, force the Windows route with   --native .'
}

# Windows path -> Linux path as seen from inside WSL.
function ConvertTo-WslPath {
    param([string]$WinPath)
    $st = Get-WslState
    if ($st.Usable) {
        $r = Invoke-Native -File $st.Exe -Arguments ((Get-WslArgsBase) + @('-e', 'wslpath', '-a', '-u', $WinPath)) -Capture -OutEncoding (New-Object System.Text.UTF8Encoding($false))
        if ($r.Started -and $r.ExitCode -eq 0) {
            $p = $r.Out.Trim()
            if ($p) { return $p }
        }
    }
    # Fallback for the default mount layout:  C:\dir\file  ->  /mnt/c/dir/file
    if ($WinPath -match '^([A-Za-z]):[\\/](.*)$') { return '/mnt/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/') }
    return ($WinPath -replace '\\', '/')
}

# Writes the POSIX engine to a temp file (LF line endings, no BOM) and returns its Windows path.
function Write-EngineFile {
    param([string]$Dir)
    $O = $script:Opt
    $ext = $O.Engine
    if (-not $ext) { $ext = $env:ASMRUN_ENGINE }
    $text = $null
    if ($ext) {
        if (-not (Test-Path -LiteralPath $ext -PathType Leaf)) { Die "Engine file '$ext' does not exist." }
        $text = [IO.File]::ReadAllText((Resolve-FullPath $ext))
        VInfo "using external engine: $ext"
    } else {
        $text = Get-EngineText
    }
    $path = Join-Path $Dir 'asmrun-engine.sh'
    Write-Utf8Lf $path $text
    return $path
}

function Get-EngineSha256 {
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((Get-EngineText).Replace("`r`n", "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    $sha.Dispose()
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Runs the engine inside WSL.  Returns the program's / engine's exit code.
function Invoke-WslRoute {
    param([string]$SourcePath, [string]$AsmPath, [string[]]$ProgArgs, [string[]]$EngineOnly = $null)
    $O = $script:Opt
    $st = Get-WslState
    if (-not $st.Usable) {
        if ($O.DryRun) { Write-Tag '[PLAN]' 'Magenta' "WSL is not ready ($($st.Reason)); the real run would stop here with setup instructions."; return 0 }
        else {
            Show-WslHelp $st.Reason
            Offer-WslInstall $st
            Stop-Run 1
        }
    }
    $dir = New-TempDir ''
    $engineWin = Write-EngineFile $dir
    $engineLx = ConvertTo-WslPath $engineWin
    $args2 = New-Object System.Collections.ArrayList
    foreach ($a in (Get-WslArgsBase)) { [void]$args2.Add($a) }
    foreach ($a in @('-e', 'sh', $engineLx)) { [void]$args2.Add($a) }
    if ($null -ne $EngineOnly) {                 # e.g. --help or --selftest: no source file involved
        foreach ($a in $EngineOnly) { [void]$args2.Add($a) }
    } else {
        foreach ($f in $O.Fwd) { [void]$args2.Add($f) }
        if ($O.DryRun) { [void]$args2.Add('--dry-run') }               # the engine prints its real build plan and builds nothing
        if ($O.Output) { [void]$args2.Add('-o'); [void]$args2.Add((ConvertTo-WslPath (Resolve-FullPath $O.Output))) }
        if ($O.Report) { [void]$args2.Add('--report'); [void]$args2.Add((ConvertTo-WslPath (Resolve-FullPath $O.Report))) }
        [void]$args2.Add('--')                                   # end of options: the file may not start with '-'
        [void]$args2.Add((ConvertTo-WslPath (Resolve-FullPath $AsmPath)))
        foreach ($a in @($ProgArgs)) { [void]$args2.Add($a) }
    }

    # Let a few settings cross into WSL (WSLENV lists variable names to share).
    $share = @()
    foreach ($v in @('NO_COLOR', 'ASMRUN_NO_RC')) { if ([Environment]::GetEnvironmentVariable($v)) { $share += $v } }
    if ($share.Count -gt 0) {
        $cur = $env:WSLENV
        $env:WSLENV = (($share -join ':') + $(if ($cur) { ':' + $cur } else { '' }))
    }

    $line = Format-Command $st.Exe $args2.ToArray()
    [void]$script:Commands.Add($line)
    VInfo "running the engine in WSL: $line"
    $exeToRun = $st.Exe
    $r = Invoke-Native -File $exeToRun -Arguments $args2.ToArray()      # inherits this console (prompts, sudo, colours work)
    if (-not $r.Started) { Die "Could not start wsl.exe: $($r.Error)" }
    $rc = $r.ExitCode
    if ($rc -eq -1) {
        Say ''
        Say 'wsl.exe itself returned -1. If no asmrun message appeared above, WSL failed to start the command.'
        Say 'Check:  wsl --status   and   wsl -l -v   (and that your distribution has been opened once).'
    }
    $script:ExitCode = $rc
    return $rc
}

# Source files saved with a BOM (Notepad, Visual Studio, PowerShell "> file") or as UTF-16
# are rejected by NASM and GNU as.  Returns the path to assemble (a clean copy if needed).
function Get-AssemblerInput {
    param([hashtable]$Src, [string]$OriginalPath, [string]$FileName, [string]$WorkParent)
    if (-not $Src.Encoding) { return $OriginalPath }
    if (Test-Src 'IncludeDir' $Src.Lines) {
        Warn ("The file is saved as $($Src.Encoding), which assemblers reject, and it uses include directives, so asmrun cannot use a cleaned copy.")
        Say  '      Re-save it as "UTF-8 without BOM" (VS Code: bottom-right encoding -> Save with Encoding -> UTF-8).'
        return $OriginalPath
    }
    $dir = New-TempDir $WorkParent
    $copy = Join-Path $dir $FileName
    Write-Utf8Lf $copy $Src.Text
    Warn ("The file is saved as $($Src.Encoding), which NASM / GNU as reject. Using a clean UTF-8 copy for this run (your file is unchanged).")
    return $copy
}

# ============================================================================
#  7. EXTRAS  -  --doctor and --selftest
# ============================================================================
function Get-ToolVersionLine {
    param([string]$Exe, [string[]]$VArgs)
    $r = Invoke-Native -File $Exe -Arguments $VArgs -Capture
    if (-not $r.Started) { return '' }
    $t = ($r.Out + "`n" + $r.Err).Trim()
    if (-not $t) { return '' }
    return ($t -split "`r?`n")[0]
}

function Invoke-Doctor {
    Say ("asmrun for Windows $($script:Version)   (embedded engine: asmrun v$($script:EngineVersion), sha256 " + (Get-EngineSha256).Substring(0, 12) + '...)')
    Say 'Checking this PC...'
    Good ('Windows : ' + (Get-WindowsLabel))
    $psv = $PSVersionTable.PSVersion.ToString()
    $psed = ''; if ($PSVersionTable.ContainsKey('PSEdition')) { $psed = $PSVersionTable.PSEdition }
    $hostExe = ''; try { $hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    Good ("PowerShell : $psv ($psed)  $hostExe")
    Say  ("          launcher: " + $script:SelfPath)

    # --- native route ---
    Say ''
    Say '--- Windows route (x86 / x64: NASM, GNU as, MASM, FASM) ---'
    $t = Get-NativeTools 64
    if ($t.Nasm) { Good ("NASM    : $($t.Nasm)   " + (Get-ToolVersionLine $t.Nasm @('-v'))) }
    else { Warn ('NASM    : not found  (asmrun can install it:  winget install ' + $script:WingetIds['nasm'] + ')') }
    if ($t.Masm) { Good ("MASM    : $($t.Masm.Kind)  $($t.Masm.Exe)") }
    else { Warn ('MASM    : no ml64 / UASM / JWasm found  (asmrun can download UASM, SHA-256 checked, when a MASM file needs it)') }
    if ($t.Cc) {
        $tri = Get-ToolVersionLine $t.Cc @('-dumpmachine')
        Good ("gcc     : $($t.Cc)   target=$tri")
        if ($tri -and $tri -notmatch 'mingw|windows|cygwin|msys') { Warn '          this compiler does not target Windows - asmrun ignores it for linking' }
        else {
            $l64 = Test-CcLinks $t.Cc 64; $c32 = Find-Tool @('i686-w64-mingw32-gcc')
            $l32 = $false; if ($c32) { $l32 = Test-CcLinks $c32 32 } else { $l32 = Test-CcLinks $t.Cc 32 }
            if ($l64) { Say '          can link 64-bit programs: yes' } else { Warn '          can link 64-bit programs: NO (asmrun uses its built-in linker)' }
            if ($l32) { Say '          can link 32-bit programs: yes' } else { Say '          can link 32-bit programs: no  -> asmrun uses its built-in linker for --32 (nothing to install)' }
        }
    } else { Say 'gcc     : none (only needed for GNU as syntax and as an alternative linker; asmrun can install WinLibs: winget install ' + $script:WingetIds['cc'] + ')' }
    if ($t.As -and -not $t.Cc) { Say "as      : $($t.As)" }
    if ($t.Fasm) { Good ("FASM    : $($t.Fasm)") } else { Say 'FASM    : not found (optional; only for FASM-syntax files)' }
    # built-in linker: can it see the system DLLs?
    foreach ($b in @(64, 32)) {
        $dir = Get-DllDirectory ($b -eq 64)
        $k = Open-Dll (Join-Path $dir 'kernel32.dll'); $m = Open-Dll (Join-Path $dir 'msvcrt.dll')
        if ((Test-DllExports $k 'ExitProcess') -and (Test-DllExports $m 'printf')) { Good ("linker  : built-in PE linker ready for $b-bit (system DLLs in $dir)") }
        elseif ($b -eq 64 -or $script:HostInfo.Bits -eq 64) { Warn ("linker  : built-in PE linker cannot read the $b-bit system DLLs in $dir - use gcc") }
    }
    $wg = $null; if ($script:OnWindows) { $wg = Find-Tool @('winget') }
    if ($wg) { Good ("winget  : $wg   " + (Get-ToolVersionLine $wg @('--version'))) }
    elseif ($script:OnWindows) { Warn 'winget  : not found (Microsoft Store -> "App Installer"); automatic tool install is unavailable (UASM download still works)' }

    # --- WSL ---
    Say ''
    Say '--- Linux route (WSL: NASM, GNU as, every CPU of the engine) ---'
    $w = Get-WslState
    if ($w.Usable) {
        Good ("WSL     : ready (" + $w.Exe + ')')
        $r = Invoke-Native -File $w.Exe -Arguments @('-l', '-v') -Capture
        $txt = Repair-WslText $r.Out
        if ($txt) { foreach ($l in ($txt -split "`r?`n")) { Say ('          ' + $l) } }
        Say '          ---- the engine''s own check (inside Linux) ----'
        [void](Invoke-WslRoute -SourcePath '' -AsmPath '' -ProgArgs @() -EngineOnly @('--doctor'))
    } else {
        Warn ("WSL     : not ready - " + $w.Reason)
        Say  '          Linux/ARM/RISC-V/... sources need it:  wsl --install   (in an Administrator PowerShell)'
    }

    # --- config ---
    Say ''
    foreach ($f in @((Join-Path $(if ($env:USERPROFILE) { $env:USERPROFILE } else { '.' }) '.asmrunrc.win'), (Join-Path $PWD.ProviderPath '.asmrunrc.win'))) {
        if (Test-Path -LiteralPath $f -PathType Leaf) { Say "config  : $f" }
    }
    if ($env:ASMRUN_FLAGS) { Say "config  : ASMRUN_FLAGS=$($env:ASMRUN_FLAGS)" }
    $tmp = [IO.Path]::GetTempPath()
    $okTmp = $false
    try { $probe = Join-Path $tmp ('asmrun-probe-' + [Guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force; $okTmp = $true } catch { }
    if ($okTmp) { Good "temp dir: $tmp (writable)" } else { Warn "temp dir: $tmp is NOT writable - use --workdir" }
    Stop-Run 0
}

# ---- self test -------------------------------------------------------------
# Need: tools that must exist for the case to run (else SKIP).  Args: extra asmrun options.
$script:SelfTestSamples = @(
    @{ Name = 'nasm64-crt';  Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = 'selftest-win-nasm64'; Code = 0; Text = @'
default rel
global main
extern puts
section .text
main:
    sub rsp, 40
    lea rcx, [msg]
    call puts
    xor eax, eax
    add rsp, 40
    ret
section .data
msg: db "selftest-win-nasm64", 0
'@ },
    @{ Name = 'nasm64-builtin-link'; Ext = '.asm'; Need = 'nasm'; Args = @('--linker', 'builtin'); Expect = 'selftest-win-nasm64'; Code = 0; Text = $null; Like = 'nasm64-crt' },
    @{ Name = 'nasm64-winapi'; Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = 'selftest-win-api'; Code = 0; Text = @'
default rel
bits 64
global start
extern GetStdHandle, WriteFile, ExitProcess
section .text
start:
    sub rsp, 40
    mov ecx, -11
    call GetStdHandle
    mov rcx, rax
    lea rdx, [msg]
    mov r8d, msglen
    lea r9, [written]
    mov qword [rsp+32], 0
    call WriteFile
    xor ecx, ecx
    call ExitProcess
section .data
msg: db "selftest-win-api", 13, 10
msglen equ $ - msg
section .bss
written: resd 1
'@ },
    @{ Name = 'nasm32-printf'; Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = 'selftest-win32-crt'; Code = 0; Text = @'
global _main
extern _printf
section .text
_main:
    push message
    call _printf
    add esp, 4
    xor eax, eax
    ret
message: db 'selftest-win32-crt', 10, 0
'@ },
    @{ Name = 'nasm32-winapi'; Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = 'selftest-win32-api'; Code = 0; Text = @'
global _main
extern _GetStdHandle@4
extern _WriteFile@20
extern _ExitProcess@4
section .text
_main:
    mov ebp, esp
    sub esp, 4
    push -11
    call _GetStdHandle@4
    mov ebx, eax
    push 0
    lea eax, [ebp-4]
    push eax
    push (message_end - message)
    push message
    push ebx
    call _WriteFile@20
    push 0
    call _ExitProcess@4
message: db 'selftest-win32-api', 10
message_end:
'@ },
    @{ Name = 'masm64';      Ext = '.asm'; Need = 'masm'; Args = @(); Expect = 'selftest-win-masm64'; Code = -1; Text = @'
extrn printf : proc
.data
msg db "selftest-win-masm64", 10, 0
.code
main proc
    sub rsp, 40
    lea rcx, msg
    call printf
    xor eax, eax
    add rsp, 40
    ret
main endp
end
'@ },
    @{ Name = 'gas64-crt';   Ext = '.s';   Need = 'gas'; Args = @(); Expect = 'selftest-win-gas64'; Code = 0; Text = @'
.globl main
.text
main:
    subq $40, %rsp
    leaq msg(%rip), %rcx
    call puts
    xorl %eax, %eax
    addq $40, %rsp
    ret
.data
msg: .asciz "selftest-win-gas64"
'@ },
    @{ Name = 'exit-code';   Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = ''; Code = 7; Text = @'
default rel
global main
extern ExitProcess
section .text
main:
    sub rsp, 40
    mov ecx, 7
    call ExitProcess
'@ }
)

function Invoke-SelfTest {
    $O = $script:Opt
    Say "asmrun for Windows $($script:Version) self test"
    $pass = 0; $fail = 0; $skip = 0
    $hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $self = $PSCommandPath
    $t = Get-NativeTools 64
    $dir = New-TempDir ''
    $cases = New-Object System.Collections.ArrayList
    foreach ($s in $script:SelfTestSamples) { [void]$cases.Add($s) }
    # BOM case: the CRT sample saved the way Notepad would save it
    [void]$cases.Add(@{ Name = 'bom-file'; Ext = '.asm'; Need = 'nasm'; Args = @(); Expect = 'selftest-win-nasm64'; Code = 0; Text = $script:SelfTestSamples[0].Text; Bom = $true })

    foreach ($c in $cases) {
        $missingTool = ''
        if ($c.Need -eq 'nasm' -and -not $t.Nasm) { $missingTool = 'nasm' }
        if ($c.Need -eq 'masm' -and -not $t.Masm) { $missingTool = 'a MASM assembler (ml64 / UASM / JWasm)' }
        if ($c.Need -eq 'gas' -and -not ($t.Cc -or $t.As)) { $missingTool = 'gcc / GNU as (MinGW-w64)' }
        if ($missingTool) { Say ("  SKIP  {0,-20} ({1} not installed)" -f $c.Name, $missingTool); $skip++; continue }
        $text = $c.Text; if ($c.ContainsKey('Like')) { foreach ($smp in $script:SelfTestSamples) { if ($smp.Name -eq $c.Like) { $text = $smp.Text } } }
        $f = Join-Path $dir ($c.Name + $c.Ext)
        $enc = New-Object System.Text.UTF8Encoding([bool]$c.ContainsKey('Bom'))   # $true => writes a BOM
        [IO.File]::WriteAllText($f, $text.Replace("`r`n", "`n") + "`n", $enc)
        $savedNoInstall = $env:ASMRUN_NO_INSTALL
        $env:ASMRUN_NO_INSTALL = '1'
        $argv = @('-NoProfile', '-File', $self, '--native', '--no-pause') + @($c.Args) + @($f)
        $r = Invoke-Native -File $hostExe -Arguments $argv -Capture
        $env:ASMRUN_NO_INSTALL = $savedNoInstall
        $okOut = ($c.Expect -eq '') -or ($r.Out -match [regex]::Escape($c.Expect))
        $okCode = ($c.Code -eq -1) -or ($r.ExitCode -eq $c.Code)       # -1 = any exit code (a main() that forgets xor eax,eax)
        if ($okOut -and $okCode) { Say ("  PASS  {0}" -f $c.Name); $pass++ }
        else {
            Say ("  FAIL  {0}  (exit {1}, expected {2}; output: {3})" -f $c.Name, $r.ExitCode, $c.Code, ($r.Out.Trim() -replace '\s+', ' '))
            if ($r.Err.Trim()) { Say ('        ' + ($r.Err.Trim() -replace '\s+', ' ')) }
            $fail++
        }
    }
    # --- engine self test inside WSL ---
    $w = Get-WslState
    if ($w.Usable) {
        Say '  ---- asmrun engine self test inside WSL ----'
        $rc = Invoke-WslRoute -SourcePath '' -AsmPath '' -ProgArgs @() -EngineOnly @('--selftest')
        if ($rc -eq 0) { $pass++ } else { $fail++ }
    } else {
        Say ("  SKIP  wsl-engine           ({0})" -f $w.Reason); $skip++
    }
    Say ''
    Say ("{0} passed, {1} failed, {2} skipped" -f $pass, $fail, $skip)
    if ($fail -gt 0) { Stop-Run 1 }
    Stop-Run 0
}

# ============================================================================
#  8. MAIN  -  resolve the file, choose the route, interactive prompt, pause
# ============================================================================
function Write-Stdout { param([string]$T) [Console]::Out.Write($T) }

# Find the source file: as given, then next to asmrun.bat; try common extensions
# when none was typed.  Returns the full path or $null.
function Resolve-SourceFile {
    param([string]$Name)
    $variants = New-Object System.Collections.ArrayList
    [void]$variants.Add($Name)
    if ([IO.Path]::GetExtension($Name) -eq '') { foreach ($e in @('.s', '.S', '.asm', '.nasm', '.sx')) { [void]$variants.Add($Name + $e) } }
    $bases = @('')
    if (-not [IO.Path]::IsPathRooted($Name)) { $bases = @($PWD.ProviderPath, $script:SelfDir) }
    foreach ($b in $bases) {
        foreach ($v in $variants) {
            try {
                $p = $v; if ($b) { $p = Join-Path $b $v }
                if (Test-Path -LiteralPath $p -PathType Leaf) {
                    $full = (Resolve-Path -LiteralPath $p).ProviderPath
                    if ($b -and $b -eq $script:SelfDir -and $b -ne $PWD.ProviderPath) { VInfo "found next to asmrun.bat: $full" }
                    return $full
                }
                if ($v -eq $Name -and (Test-Path -LiteralPath $p -PathType Container)) { Die "'$Name' is a directory, not an assembly file." }
            } catch [System.Management.Automation.RuntimeException] { if ($_.Exception.Message -eq 'ASMRUN_EXIT') { throw } }
        }
    }
    return $null
}

# One complete run of asmrun for one command line.  Exit code is left in $script:ExitCode.
function Invoke-Once {
    param([string[]]$Tokens)
    $script:Opt = New-Opt
    [void]$script:Commands.Clear()
    $script:ExitCode = 0
    $script:KeepWork = $false
    Read-ConfigFlags
    Read-EnvFlags
    $rest = Read-Options $Tokens
    $rest = @($rest)
    $O = $script:Opt
    $script:Verbose = $O.Verbose

    if ($O.Help)       { Write-Stdout ((Show-Usage) -join "`n"); Write-Stdout "`n"; Stop-Run 0 }
    if ($O.Version)    { Write-Stdout ("asmrun for Windows $($script:Version) (engine: asmrun $($script:EngineVersion))`n"); Stop-Run 0 }
    if ($O.EngineInfo) { $et = Get-EngineText; Write-Stdout ("engine: asmrun v$($script:EngineVersion), $(($et.Split("`n").Count - 1)) lines, $($et.Length) bytes, sha256 $(Get-EngineSha256)`n"); Stop-Run 0 }
    if ($O.DumpEngine) { Write-Stdout ((Get-EngineText).Replace("`r`n", "`n")); Stop-Run 0 }
    if ($O.Doctor)     { Invoke-Doctor }
    if ($O.EngineHelp) { [void](Invoke-WslRoute -SourcePath '' -AsmPath '' -ProgArgs @() -EngineOnly @('--help')); Stop-Run $script:ExitCode }
    if ($O.SelfTest)   { Invoke-SelfTest }
    if ($O.ListTargets) { [void](Invoke-WslRoute -SourcePath '' -AsmPath '' -ProgArgs @() -EngineOnly @('--list-targets')); Stop-Run $script:ExitCode }

    if ($rest.Count -lt 1) { Write-Stdout ''; [Console]::Error.WriteLine(((Show-Usage) -join "`n")); Stop-Run 2 }
    $fileArg = $rest[0]
    $progArgs = @(); if ($rest.Count -gt 1) { $progArgs = @($rest[1..($rest.Count - 1)]) }

    if ($O.AsmOnly -and $O.LinkOnly) { Die '--asm-only and --link-only cannot be used together.' 2 }
    if ($O.Arch)   { [void](Get-ArchName $O.Arch) }
    if ($O.Target) { [void](Get-TargetName $O.Target) }

    $full = Resolve-SourceFile $fileArg
    if (-not $full) { Die "File '$fileArg' does not exist." }
    $fname = [IO.Path]::GetFileName($full)
    $fi = Get-Item -LiteralPath $full
    if ($fi.Length -eq 0) { Die "File '$fileArg' is empty." }

    foreach ($pair in @(@('-o', $O.Output), @('--report', $O.Report))) {
        if ($pair[1]) {
            $pf = Resolve-FullPath $pair[1]
            if ($pf -ieq $full) { Die "Refusing to overwrite the source file with $($pair[0])." }
            if (Test-Path -LiteralPath $pf -PathType Container) { Die "Output '$($pair[1])' is a directory." }
            $pd = Split-Path -Parent $pf
            if ($pd -and -not (Test-Path -LiteralPath $pd -PathType Container)) { Die "Output directory '$pd' does not exist." }
        }
    }
    if ($O.Output -and $O.Report -and ((Resolve-FullPath $O.Output) -ieq (Resolve-FullPath $O.Report))) { Die '-o and --report must not name the same file.' }

    $src = Read-SourceFile $full
    $lenient = ($O.Mode -eq 'wsl' -or $O.Target -ne '')
    $P = Get-SourceProfile -Src $src -FileName $fname -Lenient:$lenient
    if ($script:Verbose) {
        VInfo ("arch votes: $($P.Votes) -> $($P.Arch)")
        VInfo ("syntax: $($P.Syntax)   bits: $($P.Bits)   entry: main=$($P.HasMain) _start=$($P.HasStart) start=$($P.HasPStart)   libc=$($P.UsesLibc)   cpp=$($P.Cpp)")
        VInfo ("route score: windows=$($P.WinScore) [$($P.WinWhy -join '; ')]   linux=$($P.LinScore) [$($P.LinWhy -join '; ')]")
    }
    if ($O.Detect) { Show-DetectReport $P $full $null; Stop-Run 0 }
    $route = Select-Route $P
    $label = 'natively on Windows'; if ($route.Route -eq 'wsl') { $label = 'through WSL (Linux)' }
    Info "$fname -> $label  [$($route.Why)]"

    $asmPath = Get-AssemblerInput -Src $src -OriginalPath $full -FileName $fname -WorkParent ''
    if ($route.Route -eq 'wsl') {
        [void](Invoke-WslRoute -SourcePath $full -AsmPath $asmPath -ProgArgs $progArgs)
    } else {
        [void](Invoke-NativeRoute -P $P -SourcePath $full -AsmPath $asmPath -ProgArgs $progArgs -Src $src)
    }
}

# Runs Invoke-Once and turns every way of ending into an exit code.
function Invoke-Guarded {
    param([string[]]$Tokens)
    try { Invoke-Once $Tokens }
    catch {
        if ($_.Exception.Message -ne 'ASMRUN_EXIT') {
            Fail ('Unexpected problem: ' + $_.Exception.Message)
            if ($script:Verbose) { Say $_.ScriptStackTrace }
            else { Say '(run with -v for technical details)' }
            $script:ExitCode = 1
        }
    }
    Invoke-Cleanup
    [void]$script:Cleanup.Clear()
}

# ---- "launched by double-click / drag-and-drop?" -> keep the window open ----
function Test-LaunchedFromExplorer {
    if (-not $script:OnWindows) { return $false }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    try {
        $me  = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $par = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" -ErrorAction Stop
        if ($par.Name -ine 'cmd.exe') { return $false }
        if ($par.CommandLine -notmatch '(?i)\s/c\s') { return $false }        # cmd /c "asmrun.bat" ... = started by Explorer / Run box
        $gp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($par.ParentProcessId)" -ErrorAction Stop
        return ($gp.Name -ieq 'explorer.exe')
    } catch { return $false }
}
function Wait-Close {
    if ($env:ASMRUN_NOPAUSE) { return }
    Say ''
    Say 'Press any key to close this window...'
    try { [void][Console]::ReadKey($true) } catch { [void][Console]::In.ReadLine() }
}

# ---- text typed / dropped at the "File>" prompt -> command-line tokens ----
function ConvertFrom-PromptLine {
    param([string]$Line)
    $t = $Line.Trim()
    if ($t.StartsWith('& ')) { $t = $t.Substring(2).Trim() }        # PowerShell drag-and-drop adds "& "
    # The whole line may be one path with spaces and no quotes.
    $whole = $t
    if ($whole.Length -ge 2 -and (($whole[0] -eq '"' -and $whole[$whole.Length - 1] -eq '"') -or ($whole[0] -eq "'" -and $whole[$whole.Length - 1] -eq "'"))) {
        $whole = $whole.Substring(1, $whole.Length - 2)
    }
    if ($whole -and -not $whole.StartsWith('-')) {
        try { if (Resolve-SourceFile $whole) { return ,@($whole) } } catch { }
    }
    return ,(Split-Tokens $t)
}

function Show-Banner {
    Say '=============================================================='
    Say ("  asmrun for Windows $($script:Version)     (Linux engine: asmrun v$($script:EngineVersion))")
    Say '  Assembles, links and runs an assembly file for you.'
    Say '=============================================================='
    Say '  Drag & drop an assembly file into this window, or type its'
    Say '  path, then press Enter.  A file next to asmrun.bat only needs'
    Say '  its name (hello.s).  Options work too:  -v --32 hello.s'
    Say '  Commands:  ?  help     --doctor  check this PC     q  quit'
    Say ''
}

function Invoke-PromptLoop {
    Show-Banner
    $first = $true
    while ($true) {
        $line = Read-Line 'File> '
        if ($null -eq $line) { break }
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if (@('q', 'quit', 'exit') -contains $t.ToLower()) { break }
        if ($t -eq '?' -or $t.ToLower() -eq 'help') { Say ((Show-Usage) -join "`n"); continue }
        Invoke-Guarded (ConvertFrom-PromptLine $t)
        Say ''
        Say ("---- finished (exit code $($script:ExitCode)).  Drop another file, or type q to quit. ----")
    }
}

function Main {
    param([string[]]$CmdArgs)
    $CmdArgs = @($CmdArgs)
    if ($CmdArgs.Count -eq 0) {
        if (Test-Interactive) { Invoke-PromptLoop; return }
        # No file and no terminal to ask on: same as v5 - show usage, exit 2.
        [Console]::Error.WriteLine(((Show-Usage) -join "`n"))
        $script:ExitCode = 2
        return
    }
    Invoke-Guarded $CmdArgs
    # Started from Explorer (double-click / drag a file onto asmrun.bat)?  Keep the window readable.
    $pause = $script:Opt.Pause
    if ($pause -eq 'yes' -or ($pause -eq 'auto' -and (Test-Interactive) -and (Test-LaunchedFromExplorer))) { Wait-Close }
}

# ============================================================================
#  9. ENGINE  -  the POSIX engine, embedded VERBATIM
#  Source file : asmrun-v6.sh   (asmrun v6.0.0)
#  SHA-256     : 9dc55f6dfcc7064b12000c75ebe9a67ba50989ecf94f518b015a0bd956b1ef88
#  Do not edit the text between the here-string markers by hand. To upgrade:
#  replace it with the new engine file (see asmrunForWindows.md, section "Updating the engine").
#  Check it:  asmrun --dump-engine | sha256 must equal the SHA-256 above.
# ============================================================================
function Get-EngineText {
    $t = @'
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
'@
    return ($t.Replace("`r`n", "`n") + "`n")
}

# ============================================================================
#  10. PROGRAM ENTRY POINT  (must stay LAST: everything above is only definitions)
# ============================================================================
try { Main @($args) }
catch {
    if ($_.Exception.Message -ne 'ASMRUN_EXIT') { [Console]::Error.WriteLine('asmrun: unexpected problem: ' + $_.Exception.Message); $script:ExitCode = 1 }
}
finally { Invoke-Cleanup }
exit $script:ExitCode
