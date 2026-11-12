@@rem ======================================================================
@@rem  asmrun.bat - asmrun for Windows. Documentation: asmrunForWindows.md
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

$script:Version       = '1.0.0'
$script:EngineVersion = '5.0.0'     # version of the embedded POSIX engine
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
    param([string]$File, [string[]]$Arguments = @(), [switch]$Capture, [System.Text.Encoding]$OutEncoding)
    $r = @{ Started = $false; ExitCode = -1; Out = ''; Err = ''; Error = '' }
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

$script:ValueOpts = @('-o', '--output', '--arch', '--target', '--cc', '--report', '--distro', '--engine', '--workdir')

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
        default { Die "Unknown --arch '$A' (x86 | arm64 | arm32 | riscv)." 2 }
    }
}
function Get-TargetName {
    param([string]$T)
    switch -CaseSensitive ($T) {
        { 'x86_64', 'amd64', 'x86-64' -ccontains $_ }                 { return 'x86_64' }
        { 'i386', 'i486', 'i586', 'i686', 'x86' -ccontains $_ }       { return 'i386' }
        { 'aarch64', 'arm64' -ccontains $_ }                          { return 'aarch64' }
        { 'arm', 'arm32', 'armv7', 'armhf' -ccontains $_ }            { return 'armv7' }
        { 'riscv', 'riscv64' -ccontains $_ }                          { return 'riscv64' }
        default { Die "Unknown --target '$T' (x86_64 | i386 | aarch64 | armv7 | riscv64)." 2 }
    }
}

function Show-Usage {
@"
asmrun for Windows $($script:Version)   (embedded POSIX engine: asmrun v$($script:EngineVersion))

Usage: asmrun [options] <file> [program arguments...]
       asmrun                      (no file: asks for one - you can drag & drop it)

Assembles, links and runs a hand-written assembly file.  asmrun looks at the file
and chooses the right route by itself:
  * Windows programs (Win32 API / MinGW C runtime, x86/x64)  -> built natively
    with NASM or GNU as + MinGW-w64, and run as a normal .exe.
  * Linux programs (int 0x80 / syscall / ARM / RISC-V / --target ...) -> built and
    run inside WSL with the full asmrun v$($script:EngineVersion) engine.
If asmrun.bat and your file are in the same folder, the file name alone is enough.

Options (put them BEFORE the file name):
  -v, --verbose         show detection details and every command
  -y, --yes             install missing tools without asking
  -o, --output FILE     keep the output at FILE
      --asm-only        assemble only; write the object file and stop
      --link-only       assemble+link, but do not run (alias: --no-run)
      --keep-build-dir  keep the temporary build directory
      --nasm            force NASM syntax
      --gas, --as       force GNU as syntax
      --32 | --64       force 32-bit / 64-bit (x86 only)
      --arch ARCH       force source arch: x86 | arm64 | arm32 | riscv
      --target TARGET   cross-build a LINUX program: x86_64 | i386 | aarch64 | armv7 | riscv64
      --cc CMD          use CMD as the C compiler/linker driver
      --report FILE     write a JSON build/run report to FILE
      --selftest        run the built-in self test and exit
      --version         print the version and exit
  -h, --help            this help

Windows-only options:
      --wsl             force the Linux route (WSL)
      --native          force the Windows route (alias: --windows)
      --distro NAME     WSL distribution to use (default: your default distro)
      --engine FILE     use FILE (a POSIX asmrun script) instead of the embedded one
      --engine-help     show the help text of the embedded POSIX engine
      --dump-engine     print the embedded POSIX engine to stdout and exit
      --engine-info     print the embedded engine's version, size and SHA-256, then exit
      --dry-run         show what would be done; build and run nothing (alias: --plan)
      --doctor          check this PC (PowerShell, WSL, NASM, MinGW, winget) and exit
      --workdir DIR     build in DIR instead of %TEMP%
      --pause           always wait for a key at the end
      --no-pause        never wait for a key at the end

Anything after the file name is passed to your program as arguments.

Examples:
  asmrun hello.s                      (Linux asm -> WSL;  Windows asm -> native)
  asmrun C:\code\prog.asm
  asmrun --native --64 win.asm
  asmrun --wsl --32 boot.s
  asmrun --asm-only -o hello.o hello.s
  asmrun --target aarch64 --link-only hello.s

Environment:
  NO_COLOR=1          disable colours
  ASMRUN_NO_RC=1      do not read .asmrunrc.win files
  ASMRUN_FLAGS=...    extra options, parsed before the command line
  ASMRUN_CC=...       default C compiler/linker driver (native route)
  ASMRUN_NASM=...     full path of nasm.exe (native route)
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
    ArchX86          = '(^|[^A-Za-z0-9_])(r(ax|bx|cx|dx|si|di|bp|sp|ip)|e(ax|bx|cx|dx|si|di|bp|sp|ip)|r(8|9|1[0-5])[dwb]?|[xy]mm[0-9]+)([^A-Za-z0-9_]|$)|(^|[\s])syscall([\s]|$)|(^|[\s])sysenter([\s]|$)|int[\s]+[$]?(0x80|80h|0x2e|2eh)|[.]intel_syntax|[.]code(16|32|64)|(^|[\s])bits[\s]+(16|32|64)|(^|[\s])(pushad|popad|pushfd|popfd)([\s]|$)|^[\s]*(global|extern|section|segment)[\s]'
    ArchArm64        = '(^|[^A-Za-z0-9_])([xw]([0-9]|[12][0-9]|30)|xzr|wzr)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.])(stp|ldp|adrp|adr|cbz|cbnz|tbz|tbnz|csel|cset|svc|hvc|smc|br|blr|eret|mrs|msr)([\s]|$)|[.]arch[\s]+armv8|aarch64|(^|[\s])[.]xword[\s]'
    ArchArm32        = '(^|[^A-Za-z0-9_])r([0-9]|1[0-2])[\s]*(,|[}]|-|$)|(push|pop|stmfd|ldmfd|stmdb|ldmia|stmia)[\s]*[{]|[.]syntax[\s]+unified|(^|[\s])(bx|blx)[\s]+(lr|r[0-9]+)|[.](thumb|thumb_func|arm|cpu)([\s]|$)|(^|[\s])swi[\s]|(^|[\s])(movs|adds|subs|ldrs?|strs?|ldrb|strb|ldrh|strh|bics?|ands?|orrs?|eors?|lsls?|lsrs?|asrs?|adcs?|sbcs?|rsbs?|muls?)[\s]+(r[0-9]|lr|pc|sp|#)|(^|[\s])(ite|itt|itee|it)[\s]'
    ArchRiscv        = '(^|[^A-Za-z0-9_.])(ecall|ebreak)([^A-Za-z0-9_]|$)|(^|[\s])(li|la|lla|mv|not|neg|seqz|snez|sltz|sgtz|addi|add|sub|and|or|xor|slli|srli|srai|slti|sltiu|slt|sltu|lui|auipc|jal|jalr|j|jr|beq|bne|blt|bge|bltu|bgeu|beqz|bnez|blez|bgez|bltz|bgtz|lw|sw|ld|sd|lh|sh|lb|sb|lbu|lhu|csrr?[a-z]*)[\s]+(a[0-7]|t[0-6]|s([0-9]|1[01])|sp|ra|zero|gp|tp)[\s]*,|[.]option[\s]+(rvc|norvc|push|pop)|(^|[\s])c[.](addi|mv|li|add|sub|lw|sw|ld|sd|j|jal|beqz|bnez|nop)([\s]|$)'
    SynMarker        = '[.]intel_syntax|[.]att_syntax'
    SynCpp           = '^[\s]*#[\s]*(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)'
    SynNasm          = '^[\s]*(section|segment)[\s]+[.]|^[\s]*(global|extern)[\s]+[A-Za-z_.$]|(^|[\s]|:)(db|dw|dd|dq|dt|resb|resw|resd|resq|equ|times)[\s]|^[\s]*%[\s]*(define|macro|endmacro|include|assign|if|ifdef|ifndef|else|endif|rep|endrep|xdefine|undef|imacro|strlen|ifidn|ifnum)|(^|[\s])bits[\s]+(16|32|64)|^[\s]*default[\s]+rel|(byte|word|dword|qword)[\s]+[[]'
    SynGas           = '^[\s]*[.](globl|global|section|text|data|bss|ascii|asciz|string|quad|long|byte|word|short|int|skip|space|zero|equ|set|align|balign|p2align|type|size|macro|endm|code32|code64|file|ident|rodata|comm|lcomm|fill|rept|endr)([\s]|$)|%[re]?(ax|bx|cx|dx|si|di|bp|sp)([^A-Za-z0-9_]|$)|%r(8|9|1[0-5])[dwb]?([^A-Za-z0-9_]|$)|%[abcd][lh]([^A-Za-z0-9_]|$)|%[xy]?mm[0-9]+|(^|[\s])(mov|add|sub|push|pop|lea|cmp|xor|and|or|test|inc|dec|imul|idiv|shl|shr|call|ret|jmp)[bwlq][\s]|[$][-]?(0x[0-9a-f]+|[0-9]+)'
    Bits32Dir        = '(^|[^A-Za-z0-9_])bits[\s]+32|[.]code32'
    Bits64Dir        = '(^|[^A-Za-z0-9_])bits[\s]+64|[.]code64'
    BitInt80         = 'int[\s]+[$]?(0x80|80h|0x2e|2eh)([^A-Za-z0-9_]|$)'
    BitSyscall       = '(^|[^A-Za-z0-9_])syscall([^A-Za-z0-9_]|$)'
    BitSysenter      = '(^|[^A-Za-z0-9_])sysenter([^A-Za-z0-9_]|$)'
    Bit32Ops         = '(^|[^A-Za-z0-9_])(pushad|popad|pushfd|popfd)([^A-Za-z0-9_]|$)'
    Bit64Ops         = '(^|[^A-Za-z0-9_])(pushfq|popfq)([^A-Za-z0-9_]|$)'
    Reg32            = '(^|[^A-Za-z0-9_])e(ax|bx|cx|dx|si|di|sp|bp|ip)([^A-Za-z0-9_]|$)'
    Reg64            = '(^|[^A-Za-z0-9_])(r(ax|bx|cx|dx|si|di|sp|bp|ip)|r([8-9]|1[0-5])[dwb]?)([^A-Za-z0-9_]|$)'
    Boot16           = '(^|[^A-Za-z0-9_])bits[\s]+16|[.]code16|(^|[\s])org[\s]+(0x)?7c00h?([\s]|$)'
    MasmForced       = '[.]model[\s]|(^|[\s])endp([\s]|$)|^[\s]*(invoke|includelib)[\s]'
    MasmAuto         = '[.]model[\s]|(^|[\s])endp([\s]|$)|^[\s]*(invoke|includelib)[\s]|(^|[\s])proc([\s]|$)|[.]286|[.]386|[.]486'
    FasmLike         = '^[\s]*format[\s]+(elf|elf64|pe|pe64|ms|mz|binary)|segment[\s]+readable|^[\s]*entry[\s]+[A-Za-z_.]'
    EntryStartLbl    = '^[\s]*_start[\s]*:'
    EntryPStartLbl   = '^[\s]*start[\s]*:'
    EntryMainLbl     = '^[\s]*_?main[\s]*:'
    EntryStartGlob   = '^[\s]*(global|\.globl|\.global)[\s]+_start([\s]|$)'
    EntryPStartGlob  = '^[\s]*(global|\.globl|\.global)[\s]+start([\s]|$)'
    EntryMainGlob    = '^[\s]*(global|\.globl|\.global)[\s]+_?main([\s]|$)'
    Libc             = '^[\s]*[.]?extern[\s]+_?(printf|fprintf|sprintf|snprintf|puts|putchar|scanf|sscanf|fscanf|getchar|fgets|fputs|fopen|fclose|fread|fwrite|malloc|calloc|realloc|free|strlen|strcmp|strncmp|strcpy|strncpy|strcat|memcpy|memmove|memset|atoi|atol|strtol|exit|abort|perror|getenv|time|rand|srand|write)(@PLT)?([\s]|$)|@plt([^A-Za-z0-9_]|$)|wrt[\s]+[.][.]plt|(call[qwl]?|bl|jmp)[\s]+_?(printf|fprintf|sprintf|snprintf|puts|putchar|scanf|sscanf|fscanf|getchar|fgets|fputs|fopen|fclose|fread|fwrite|malloc|calloc|realloc|free|strlen|strcmp|strncmp|strcpy|strncpy|strcat|memcpy|memmove|memset|atoi|atol|strtol|exit|abort|perror|getenv|time|rand|srand|write)(@PLT)?([^A-Za-z0-9_]|$)'
    CppDirective     = '^[\s]*#[\s]*include[\s]*[<"]|^[\s]*#[\s]*(define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)[\s]'
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

function Get-Re {
    param([string]$Name)
    if (-not $script:PatCache.ContainsKey($Name)) {
        $script:PatCache[$Name] = New-Object System.Text.RegularExpressions.Regex($script:SrcPat[$Name], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $script:PatCache[$Name]
}
# has / cnt as in asmrun-v5.sh: number of LINES matching.
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

# Remove comments so words in comments do not count as Windows/Linux evidence.
function Get-CodeLines {
    param([string[]]$Lines)
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) {
        $c = $l -replace ';.*$', ''
        $c = $c -replace '^\s*#(?!\s*(include|define|ifdef|ifndef|if|elif|else|endif|undef|pragma|error)\b).*$', ''
        $c = $c -replace '(^|\s)//.*$', ''
        [void]$out.Add($c)
    }
    return ,($out.ToArray())
}

# ------------------------------------------------------------ detection ----
function Get-SourceProfile {
    param([hashtable]$Src, [string]$FileName, [switch]$Lenient)
    $O = $script:Opt
    $Lines = $Src.Lines
    $P = @{ Arch = ''; Syntax = ''; Bits = 0; Votes = ''; WinScore = 0; LinScore = 0; WinWhy = @(); LinWhy = @()
            HasStart = $false; HasPStart = $false; HasMain = $false; HasEntry = $false; EntryName = ''
            HasWinMain = $false; UsesLibc = $false; Cpp = $false; Includes = $false }
    $host_fam = $script:HostInfo.Family

    # ---- architecture (weighted vote, ties go to the host) ----
    $vx = Measure-Src 'ArchX86' $Lines;   $va = Measure-Src 'ArchArm64' $Lines
    $vb = Measure-Src 'ArchArm32' $Lines; $vr = Measure-Src 'ArchRiscv' $Lines
    $src_arch = $host_fam; $best = 0
    foreach ($pair in @(@('x86', $vx), @('arm64', $va), @('arm32', $vb), @('riscv', $vr))) {
        $fam = $pair[0]; $num = [int]$pair[1]
        if ($num -gt $best) { $src_arch = $fam; $best = $num }
        elseif ($num -eq $best -and $num -gt 0 -and $fam -eq $host_fam) { $src_arch = $fam }
    }
    $P.Votes = "x86=$vx arm64=$va arm32=$vb riscv=$vr"
    if ($O.Arch) { $src_arch = Get-ArchName $O.Arch }
    $P.Arch = $src_arch

    # ---- bitness ----
    if ($src_arch -eq 'x86') {
        if ($O.Bits -ne 0) { $P.Bits = $O.Bits }
        elseif ($O.Target) { $P.Bits = 0 }
        else {
            if (-not $Lenient -and (Test-Src 'Boot16' $Lines)) {
                Fail 'This is 16-bit / boot-sector code. asmrun only runs normal user-space programs.'
                Say 'Try:  nasm -f bin file.asm -o boot.bin  and run boot.bin in an emulator (QEMU, Bochs, VirtualBox).'
                $script:ExitCode = 1; throw 'ASMRUN_EXIT'
            }
            if (Test-Src 'Bits32Dir' $Lines) { $P.Bits = 32 }
            elseif (Test-Src 'Bits64Dir' $Lines) { $P.Bits = 64 }
            else {
                $b32 = 0; $b64 = 0
                if (Test-Src 'BitInt80' $Lines)    { $b32 += 5 }
                if (Test-Src 'BitSyscall' $Lines)  { $b64 += 5 }
                if (Test-Src 'BitSysenter' $Lines) { $b32 += 3 }
                if (Test-Src 'Bit32Ops' $Lines)    { $b32 += 2 }
                if (Test-Src 'Bit64Ops' $Lines)    { $b64 += 2 }
                $b32 += (Measure-Src 'Reg32' $Lines); $b64 += (Measure-Src 'Reg64' $Lines)
                if ($b64 -gt $b32) { $P.Bits = 64 } elseif ($b32 -gt $b64) { $P.Bits = 32 }
                elseif ($script:HostInfo.Bits -eq 32) { $P.Bits = 32 } else { $P.Bits = 64 }
            }
        }
    } else {
        if ($O.Bits -ne 0 -and -not $Lenient) { Die "--32/--64 only apply to x86; $src_arch is fixed-width." 2 }
        if ($src_arch -eq 'arm32') { $P.Bits = 32 } else { $P.Bits = 64 }
    }

    # ---- syntax ----
    if ($src_arch -ne 'x86') {
        if ($O.Syntax -eq 'nasm' -and -not $Lenient) { Die "NASM only supports x86; use GNU as syntax for $src_arch." 2 }
        $P.Syntax = 'gas'
    } else {
        if ($O.Syntax -ne 'auto') {
            if (Test-Src 'MasmForced' $Lines) { Die 'This looks like MASM/TASM (Windows) assembly. asmrun supports NASM and GNU as syntax (MASM needs ml64.exe from Visual Studio).' }
            if (Test-Src 'FasmLike' $Lines)   { Die 'This looks like FASM assembly, which asmrun does not support (NASM and GNU as only).' }
            $P.Syntax = $O.Syntax
        } else {
            if (Test-Src 'MasmAuto' $Lines) { Die 'This looks like MASM/TASM (Windows) assembly. asmrun supports NASM and GNU as syntax (MASM needs ml64.exe from Visual Studio).' }
            if (Test-Src 'FasmLike' $Lines) { Die 'This looks like FASM assembly, which asmrun does not support (NASM and GNU as only).' }
            $P.Syntax = Get-Syntax $Src $FileName
        }
    }

    # ---- entry point, libc, preprocessor ----
    if (Test-Src 'EntryStartLbl' $Lines)  { $P.HasStart = $true }
    if (Test-Src 'EntryPStartLbl' $Lines) { $P.HasPStart = $true }
    if (Test-Src 'EntryMainLbl' $Lines)   { $P.HasMain = $true }
    if (Test-Src 'EntryStartGlob' $Lines) { $P.HasStart = $true }
    if (Test-Src 'EntryPStartGlob' $Lines){ $P.HasPStart = $true }
    if (Test-Src 'EntryMainGlob' $Lines)  { $P.HasMain = $true }
    $re = Get-Re 'EntryDecl'
    foreach ($line in $Lines) {
        $m = $re.Match($line)
        if ($m.Success) { $P.EntryName = $m.Groups[1].Value; break }
    }
    if ($P.EntryName) {
        switch ($P.EntryName) {
            '_start' { $P.HasStart = $true }
            'start'  { $P.HasPStart = $true }
            { 'main', '_main' -contains $_ } { $P.HasMain = $true }
            default  { $P.HasEntry = $true }
        }
    }
    if (Test-Src 'Libc' $Lines) { $P.UsesLibc = $true }
    if ($FileName -cmatch '\.S$') { $P.Cpp = $true }
    if ($P.Syntax -eq 'gas' -and (Test-Src 'CppDirective' $Lines)) { $P.Cpp = $true }
    if (Test-Src 'IncludeDir' $Lines) { $P.Includes = $true }

    # ---- Windows or Linux?  (new: asmrun v5 only ever ran on Linux/macOS) ----
    $code = Get-CodeLines $Lines
    $win = 0; $lin = 0; $ww = New-Object System.Collections.ArrayList; $lw = New-Object System.Collections.ArrayList
    $n = Measure-Src 'WinApi' $code;  if ($n -gt 0) { $win += 3 * [Math]::Min($n, 4); [void]$ww.Add("Win32 API calls x$n") }
    $n = Measure-Src 'WinDll' $code;  if ($n -gt 0) { $win += 2 * [Math]::Min($n, 2); [void]$ww.Add('Windows DLL names') }
    if (Test-Src 'WinEntry' $code)    { $win += 5; $P.HasWinMain = $true; [void]$ww.Add('WinMain/CRT-startup entry') }
    $n = Measure-Src 'WinDir' $code;  if ($n -gt 0) { $win += 2 * [Math]::Min($n, 2); [void]$ww.Add('PE/COFF directives') }
    if (Test-Src 'WinDecor' $code)    { $win += 2; [void]$ww.Add('stdcall names (_Name@N)') }
    if (Test-Src 'WinShadow' $code)   { $win += 2; [void]$ww.Add('Win64 shadow space') }
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
    if ($src_arch -ne 'x86')          { $lin += 10; [void]$lw.Add("$src_arch source") }
    $P.WinScore = $win; $P.LinScore = $lin
    $P.WinWhy = $ww.ToArray(); $P.LinWhy = $lw.ToArray()
    return $P
}

# x86 only: NASM (Intel) vs GNU as - same rules as detect_syntax() in asmrun-v5.sh
function Get-Syntax {
    param([hashtable]$Src, [string]$FileName)
    $Lines = $Src.Lines
    if ($FileName -cmatch '\.S$') { return 'gas' }
    if (Test-Src 'SynMarker' $Lines) { return 'gas' }
    if (Test-Src 'SynCpp' $Lines)    { return 'gas' }
    $nasm = Measure-Src 'SynNasm' $Lines
    $gas  = Measure-Src 'SynGas' $Lines
    VInfo "syntax votes: nasm=$nasm gas=$gas"
    if ($gas -gt $nasm) { return 'gas' }
    if ($nasm -gt $gas) { return 'nasm' }
    if ($FileName -cmatch '\.(s|S|sx)$') { return 'gas' }
    return 'nasm'
}

# Decide the route.  Returns 'native' or 'wsl' plus a reason string.
function Select-Route {
    param([hashtable]$P)
    $O = $script:Opt
    if ($O.Mode -eq 'wsl')    { return @{ Route = 'wsl';    Why = 'forced by --wsl' } }
    if ($O.Mode -eq 'native') { return @{ Route = 'native'; Why = 'forced by --native' } }
    if ($O.Target)            { return @{ Route = 'wsl';    Why = "--target $($O.Target) builds a Linux program" } }
    if ($P.Arch -ne 'x86')    { return @{ Route = 'wsl';    Why = "$($P.Arch) code cannot run natively on this PC; WSL provides the cross tools" } }
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
#  4. TOOLS  -  find (and, with permission, install) NASM and a MinGW-w64 compiler
# ============================================================================
# winget package ids.  If a package is ever renamed, change it HERE only.
$script:WingetIds = @{
    nasm = 'NASM.NASM'
    cc   = 'BrechtSanders.WinLibs.POSIX.UCRT'
}
$script:ToolLabels = @{
    nasm = 'NASM assembler'
    cc   = 'MinGW-w64 GCC (compiler / linker driver)'
}

# Folders where these tools are commonly installed but NOT always on PATH.
# (NASM's installer never edits PATH; winget "portable" packages live under WinGet\Packages.)
function Get-ExtraToolDirs {
    $cands = New-Object System.Collections.ArrayList
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
    $lad = $env:LOCALAPPDATA; $usr = $env:USERPROFILE; $pd = $env:ProgramData
    $add = { param($p) if ($p) { [void]$cands.Add($p) } }
    if ($pf)   { & $add (Join-Path $pf 'NASM'); & $add (Join-Path $pf 'mingw-w64\*\mingw64\bin'); & $add (Join-Path $pf 'mingw64\bin'); & $add (Join-Path $pf 'WinGet\Links') }
    if ($pf86) { & $add (Join-Path $pf86 'NASM') }
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
    }
    if ($pd)   { & $add (Join-Path $pd 'chocolatey\bin'); & $add (Join-Path $pd 'mingw64\mingw64\bin') }
    foreach ($d in @('C:\msys64\ucrt64\bin', 'C:\msys64\mingw64\bin', 'C:\msys64\clang64\bin', 'C:\msys64\mingw32\bin',
                     'C:\mingw64\bin', 'C:\mingw32\bin', 'C:\MinGW\bin', 'C:\winlibs\mingw64\bin', 'C:\tools\mingw64\bin')) { & $add $d }
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

# Locate nasm and a compiler driver for the native route.  Missing ones are $null.
function Get-NativeTools {
    param([int]$Bits)
    $O = $script:Opt
    $t = @{ Nasm = $null; Cc = $null; CcForced = $false }
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

# Offer to install the missing tools.  $Missing is a list of keys of $script:WingetIds.
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

    if (-not $winget) {
        Say ''
        Say 'asmrun installs tools with winget (App Installer), but it was not found. Install these yourself,'
        Say 'then run asmrun again:'
        Say '  NASM        https://www.nasm.us/        (or from MSYS2: pacman -S mingw-w64-ucrt-x86_64-nasm)'
        Say '  MinGW-w64   https://winlibs.com/  (unzip it and add its "bin" folder to PATH)'
        Say '              or MSYS2 https://www.msys2.org/ :  pacman -S mingw-w64-ucrt-x86_64-gcc'
        Say '  winget      Microsoft Store -> "App Installer"'
        return $false
    }
    Say 'The following will be installed with winget:'
    $cmds = @()
    foreach ($m in $Missing) { $cmds += "winget install --id $($script:WingetIds[$m]) -e --accept-package-agreements --accept-source-agreements"; Say ("  - " + $script:WingetIds[$m] + "   (" + $script:ToolLabels[$m] + ")") }
    $ans = Confirm-Yes 'Install them now?' $true
    if ($null -eq $ans) {
        Say 'No terminal to ask on. Run these commands yourself, then try again:'
        foreach ($c in $cmds) { Say "  $c" }
        return $false
    }
    if (-not $ans) { Say 'Skipped. You can install them later with:'; foreach ($c in $cmds) { Say "  $c" }; return $false }

    $failed = @()
    foreach ($m in $Missing) {
        $id = $script:WingetIds[$m]
        Show-Cmd ("winget install --id $id -e --silent")
        $r = Invoke-Native -File $winget -Arguments @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if (-not $r.Started) { Fail "Could not start winget: $($r.Error)" }
    }
    Update-SessionPath
    $t = Get-NativeTools $Bits
    $ok = @()
    foreach ($m in $Missing) {
        $have = $false
        if ($m -eq 'nasm' -and $t.Nasm) { $have = $true }
        if ($m -eq 'cc' -and $t.Cc)     { $have = $true }
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
#  5. NATIVE  -  build and run a Windows program (NASM or GNU as + MinGW-w64)
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
}

function Invoke-Stage {
    param([string]$Label, [string]$File, [string[]]$Arguments)
    $line = Format-Command $File $Arguments
    [void]$script:Commands.Add($line)
    if ($script:Opt.DryRun) { Write-Tag '[PLAN]' 'Magenta' $line; return $true }
    Show-Cmd $line
    $r = Invoke-Native -File $File -Arguments $Arguments -Capture
    if (-not $r.Started) { Fail "Could not start $Label ($File): $($r.Error)"; return $false }
    $text = (($r.Out + "`n" + $r.Err)).Trim()
    if ($r.ExitCode -ne 0) {
        Fail "$Label failed (exit code $($r.ExitCode))."
        if ($text) { Say $text }
        return $false
    }
    if ($text) { Say $text }       # warnings from a successful step
    return $true
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
    $re1 = New-Object System.Text.RegularExpressions.Regex('^\s*(_start|start)\s*:', 'IgnoreCase')
    $re2 = New-Object System.Text.RegularExpressions.Regex('^\s*(global|[.]globl|[.]global)\s+(_start|start)(\s|$)', 'IgnoreCase')
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
            native = $true; link = $R.Link; cpp = $R.Cpp
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

# Builds (and normally runs) the program natively.  Returns the exit code.
function Invoke-NativeRoute {
    param([hashtable]$P, [string]$SourcePath, [string]$AsmPath, [string[]]$ProgArgs, [hashtable]$Src)
    $O = $script:Opt
    if ($P.Arch -ne 'x86') { Die "The native Windows route only builds x86 / x64 code (this file is $($P.Arch)). Use --wsl." }
    if ($O.UnknownFwd.Count -gt 0) { Die "Unknown option: $($O.UnknownFwd[0])  (try --help)" 2 }
    $bits = $P.Bits
    $isNasm = ($P.Syntax -eq 'nasm')
    $needNasm = $isNasm
    $needCc = ((-not $isNasm) -or (-not $O.AsmOnly))
    if ($O.Syntax -eq 'nasm' -and $P.Arch -ne 'x86') { Die 'NASM only supports x86.' }

    # ---- tools ----
    $t = Get-NativeTools $bits
    if ($t.CcForced -and -not $t.Cc) { Die "C compiler '$(if ($O.Cc) { $O.Cc } else { $env:ASMRUN_CC })' was not found." }
    $missing = @()
    if ($needNasm -and -not $t.Nasm) { $missing += 'nasm' }
    if ($needCc -and -not $t.Cc)     { $missing += 'cc' }
    if ($missing.Count -gt 0) {
        if ($O.DryRun) {
            Write-Tag '[PLAN]' 'Magenta' ('would offer to install with winget: ' + (($missing | ForEach-Object { $script:WingetIds[$_] }) -join ', '))
            foreach ($m in $missing) { if ($m -eq 'nasm') { $t.Nasm = 'nasm.exe' } else { $t.Cc = 'gcc.exe' } }
        } else {
            if (-not (Install-MissingTools $missing $bits)) { Stop-Run 1 }
            $t = Get-NativeTools $bits
        }
    }
    $required = @(); if ($needNasm) { $required += 'nasm' }; if ($needCc) { $required += 'cc' }
    VInfo ("tools: nasm=" + $t.Nasm + "  cc=" + $t.Cc)

    # Is the compiler really a Windows one?  (a Linux gcc would silently build the wrong thing)
    $m32 = $false
    if ($t.Cc -and -not $O.DryRun) {
        $dm = Invoke-Native -File $t.Cc -Arguments @('-dumpmachine') -Capture
        $triple = ''; if ($dm.Started -and $dm.ExitCode -eq 0) { $triple = $dm.Out.Trim() }
        VInfo "compiler target: $triple"
        if ($triple -and $triple -notmatch 'mingw|windows|cygwin|msys') {
            Warn "The compiler targets '$triple', which is not Windows. Install MinGW-w64 (winget install $($script:WingetIds['cc'])) or pass --cc."
        }
        if ($bits -eq 32 -and $triple -match '^x86_64') { $m32 = $true }
    }

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
    if ($O.AsmOnly) {
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

    # ---- entry point ----
    $entry = ''; $gui = $false
    if (-not $P.HasMain) {
        $startLabel = Get-StartLabel $Src.Lines
        if ($P.HasWinMain) { $gui = $true }
        elseif ($P.EntryName -and @('_start', 'start', 'main', '_main') -notcontains $P.EntryName) { $entry = $P.EntryName }
        elseif ($startLabel) { $entry = $startLabel }
        elseif (-not ($P.HasStart -or $P.HasPStart)) {
            Warn 'No entry point (main, _start or start) was found; the linker may reject this file.'
        }
    }
    $fmt = 'win64'; if ($bits -eq 32) { $fmt = 'win32' }
    $xlang = 'assembler'; if ($P.Cpp) { $xlang = 'assembler-with-cpp' }
    $targetId = 'x86_64-windows'; if ($bits -eq 32) { $targetId = 'i386-windows' }
    VInfo ("route: native Windows, $bits-bit, " + $(if ($isNasm) { "NASM -f $fmt" } else { "GNU as via $xlang" }) + $(if ($entry) { ", custom entry '$entry'" } elseif ($P.HasMain) { ', C runtime main()' } else { '' }))

    # ---- build ----
    $rc = 0
    $ok = $true
    $linkArgs = @()
    if ($m32) { $linkArgs += '-m32' }
    if ($entry) { $linkArgs += '-nostartfiles'; $linkArgs += "-Wl,-e,$entry" }
    if ($gui)   { $linkArgs += '-mwindows' }

    if ($isNasm) {
        $ok = Invoke-Stage 'assembler' $t.Nasm @('-f', $fmt, '-o', $objFile, $AsmPath)
        if ($ok -and -not $O.AsmOnly) {
            $ok = Invoke-Stage 'linker' $t.Cc ($linkArgs + @('-o', $exe, $objFile))
        }
    } else {
        if ($O.AsmOnly) {
            $gargs = @(); if ($m32) { $gargs += '-m32' }
            $ok = Invoke-Stage 'assembler' $t.Cc ($gargs + @('-c', '-x', $xlang, $AsmPath, '-o', $objFile))
        } else {
            $gargs = @(); if ($m32) { $gargs += '-m32' }
            $ok = Invoke-Stage 'assembler+linker' $t.Cc ($gargs + @('-x', $xlang, $AsmPath) + @($linkArgs | Where-Object { $_ -ne '-m32' }) + @('-o', $exe))
        }
    }
    if (-not $ok) {
        Say ''
        Say "Hint: the syntax was auto-detected as $(if ($isNasm) { 'NASM' } else { 'GNU as' }). If that is wrong, force it with --nasm or --gas."
        if ($bits -eq 32) { Say 'Hint: 32-bit Windows programs need a 32-bit MinGW toolchain (i686). WinLibs offers one at https://winlibs.com/ .' }
        $rc = 1
        Write-Report @{ File = $SourcePath; Arch = $P.Arch; Syntax = $P.Syntax; Bits = $bits; Target = $targetId; Link = 'cc'; Cpp = $P.Cpp
                        Required = $required; Output = ''; OutputKind = ''; ExitCode = $rc; Kept = $(if ($O.Keep) { $work } else { '' }) }
        $script:ExitCode = $rc
        return $rc
    }

    $final = $exe; if ($O.AsmOnly) { $final = $objFile }
    if (-not $O.DryRun) {
        if (-not (Test-Path -LiteralPath $final -PathType Leaf)) { Die "The build reported success but '$final' was not created." }
        $desc = Get-PeSummary $final
        if ($desc) { Write-Tag '[FILE]' 'DarkGray' $desc }
    }
    if ($O.Keep) { Write-Tag '[WORK]' 'DarkGray' "kept build directory: $work" }

    if ($O.AsmOnly -or $O.LinkOnly) {
        if (-not $O.DryRun) { Good "Built: $final" }
    } elseif ($O.DryRun) {
        Write-Tag '[PLAN]' 'Magenta' ((Format-Command $exe $ProgArgs) + '   (the program would run here)')
    } else {
        # ASMRUN_RUNNER: optional launcher for the built program (test hook, e.g. "wine"; leave unset normally).
        if ($env:ASMRUN_RUNNER) { $r = Invoke-Native -File $env:ASMRUN_RUNNER -Arguments (@($exe) + @($ProgArgs)) }
        else                    { $r = Invoke-Native -File $exe -Arguments $ProgArgs }
        if (-not $r.Started) {
            Fail "Could not start the program: $($r.Error)"
            Say 'If your antivirus or AppLocker blocked it, build into a trusted folder:  asmrun -o C:\path\prog.exe file.asm'
            $rc = 126
        } else {
            $rc = $r.ExitCode
            if ($rc -ne 0) {
                $st = Format-ExitStatus $rc
                Write-Tag $st[0] 'Yellow' ''
                if ($st[1]) { Say ('        ' + $st[1]) }
            }
        }
    }
    Write-Report @{ File = $SourcePath; Arch = $P.Arch; Syntax = $P.Syntax; Bits = $bits; Target = $targetId; Link = 'cc'; Cpp = $P.Cpp
                    Required = $required; Output = $final; OutputKind = $outKind; ExitCode = $rc; Kept = $(if ($O.Keep) { $work } else { '' }) }
    $script:ExitCode = $rc
    return $rc
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
        if ($O.DryRun) { Write-Tag '[PLAN]' 'Magenta' "WSL is not ready ($($st.Reason)); the real run would stop here with setup instructions." }
        else { Show-WslHelp $st.Reason; Stop-Run 1 }
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
    if ($O.DryRun) { Write-Tag '[PLAN]' 'Magenta' $line; return 0 }
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

    # --- WSL ---
    $w = Get-WslState
    if ($w.Usable) {
        Good ("WSL     : ready (" + $w.Exe + ')')
        $r = Invoke-Native -File $w.Exe -Arguments @('-l', '-v') -Capture
        $txt = Repair-WslText $r.Out
        if ($txt) { foreach ($l in ($txt -split "`r?`n")) { Say ('          ' + $l) } }
        $probeText = @'
printf "          Linux: "; uname -sm
for t in nasm as ld gcc qemu-x86_64 qemu-aarch64; do
  if command -v $t >/dev/null 2>&1; then printf "          %-14s found\n" $t
  else printf "          %-14s missing (asmrun installs it when needed)\n" $t; fi
done
'@
        $pdir = New-TempDir ''
        $pfile = Join-Path $pdir 'probe.sh'
        Write-Utf8Lf $pfile $probeText
        $r2 = Invoke-Native -File $w.Exe -Arguments ((Get-WslArgsBase) + @('-e', 'sh', (ConvertTo-WslPath $pfile))) -Capture
        if ($r2.Started) { Say ($r2.Out.TrimEnd()) }
    } else {
        Warn ("WSL     : not ready - " + $w.Reason)
        Say  '          Linux/ARM/RISC-V sources need it:  wsl --install   (in an Administrator PowerShell)'
    }

    # --- native tools ---
    $t = Get-NativeTools 64
    if ($t.Nasm) { Good ("NASM    : $($t.Nasm)   " + (Get-ToolVersionLine $t.Nasm @('-v'))) }
    else { Warn ('NASM    : not found  (asmrun can install it:  winget install ' + $script:WingetIds['nasm'] + ')') }
    if ($t.Cc) {
        $tri = Get-ToolVersionLine $t.Cc @('-dumpmachine')
        Good ("C driver : $($t.Cc)   target=$tri")
        if ($tri -and $tri -notmatch 'mingw|windows|cygwin|msys') { Warn '          this compiler does not target Windows - use MinGW-w64 or pass --cc' }
    } else { Warn ('C driver : no MinGW-w64 gcc found  (asmrun can install it:  winget install ' + $script:WingetIds['cc'] + ')') }
    $c32 = Find-Tool @('i686-w64-mingw32-gcc')
    if ($c32) { Good "32-bit  : $c32" } else { Say '32-bit  : no i686 MinGW compiler (only needed for 32-bit Windows programs)' }
    $wg = $null; if ($script:OnWindows) { $wg = Find-Tool @('winget') }
    if ($wg) { Good ("winget  : $wg   " + (Get-ToolVersionLine $wg @('--version'))) }
    elseif ($script:OnWindows) { Warn 'winget  : not found (Microsoft Store -> "App Installer"); automatic tool install is unavailable' }

    # --- config ---
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
$script:SelfTestSamples = @(
    @{ Name = 'nasm64-crt';  Ext = '.asm'; Need = 'nasm,cc'; Expect = 'selftest-win-nasm64'; Code = 0; Text = @'
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
    @{ Name = 'nasm64-winapi'; Ext = '.asm'; Need = 'nasm,cc'; Expect = 'selftest-win-api'; Code = 0; Text = @'
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
    @{ Name = 'gas64-crt';   Ext = '.s';   Need = 'cc'; Expect = 'selftest-win-gas64'; Code = 0; Text = @'
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
    @{ Name = 'exit-code';   Ext = '.asm'; Need = 'nasm,cc'; Expect = ''; Code = 7; Text = @'
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
    # BOM case: same CRT sample, saved the way Notepad would save it
    $bomSample = @{ Name = 'bom-file'; Ext = '.asm'; Need = 'nasm,cc'; Expect = 'selftest-win-nasm64'; Code = 0; Text = $script:SelfTestSamples[0].Text; Bom = $true }
    [void]$cases.Add($bomSample)

    foreach ($c in $cases) {
        $need = $c.Need -split ','
        $missingTool = ''
        if ($need -contains 'nasm' -and -not $t.Nasm) { $missingTool = 'nasm' }
        if ($need -contains 'cc' -and -not $t.Cc)     { $missingTool = 'gcc (MinGW-w64)' }
        if ($missingTool) { Say ("  SKIP  {0,-14} ({1} not installed)" -f $c.Name, $missingTool); $skip++; continue }
        $f = Join-Path $dir ($c.Name + $c.Ext)
        $enc = New-Object System.Text.UTF8Encoding([bool]$c.ContainsKey('Bom'))   # $true => writes a BOM
        [IO.File]::WriteAllText($f, $c.Text.Replace("`r`n", "`n") + "`n", $enc)
        $savedNoInstall = $env:ASMRUN_NO_INSTALL
        $env:ASMRUN_NO_INSTALL = '1'
        $r = Invoke-Native -File $hostExe -Arguments @('-NoProfile', '-File', $self, '--native', '--no-pause', $f) -Capture
        $env:ASMRUN_NO_INSTALL = $savedNoInstall
        $okOut = ($c.Expect -eq '') -or ($r.Out -match [regex]::Escape($c.Expect))
        $okCode = ($r.ExitCode -eq $c.Code)
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
        Say '  ---- asmrun v5 engine self test inside WSL ----'
        $rc = Invoke-WslRoute -SourcePath '' -AsmPath '' -ProgArgs @() -EngineOnly @('--selftest')
        if ($rc -eq 0) { $pass++ } else { $fail++ }
    } else {
        Say ("  SKIP  wsl-engine     ({0})" -f $w.Reason); $skip++
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
#  Source file : asmrun-v5.sh   (asmrun v5.0.0)
#  SHA-256     : 187eaf48f106713f5211d933a462b780b240c87bbcaf0639dab18475676f2fe5
#  Do not edit the text between the here-string markers by hand. To upgrade:
#  replace it with the new engine file (see asmrunForWindows.md, section "Updating the engine").
#  Check it:  asmrun --dump-engine | sha256 must equal the SHA-256 above.
# ============================================================================
function Get-EngineText {
    $t = @'
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
