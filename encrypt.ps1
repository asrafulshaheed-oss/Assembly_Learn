<#
.SYNOPSIS
    Military-grade folder encryption using built-in Windows .NET crypto.
.DESCRIPTION
    - AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC, authenticated IV and ciphertext)
    - PBKDF2-SHA256, 100,000 iterations
    - Streaming I/O (supports files > 1 TB with constant memory footprint)
    - Hidden filenames (random GUIDs + encrypted manifest)
    - Directory structure preservation (including empty subdirectories)
    - Multi-folder support
    - Encrypt and Decrypt modes
    - -Force: skip prompt when decrypt destination already exists
.EXAMPLE
    .\encrypt.ps1 "C:\Docs" "D:\Photos"
.EXAMPLE
    .\encrypt.ps1 -Decrypt "C:\Docs.secure"
.EXAMPLE
    .\encrypt.ps1 -Decrypt -Force "C:\Docs.secure"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$FolderPaths,

    [switch]$Decrypt,
    [switch]$Force,
    [System.Security.SecureString]$Password
)

# Set strict mode and error handling
$ErrorActionPreference = "Stop"

# -- Configuration -------------------------------------------------------
$Iterations      = 100000
$SaltSize        = 16
$IVSize          = 16
$HmacSize        = 32
$BufferSize      = 1048576  # 1 MB buffer (multiple of AES 16-byte block)
$ManifestName    = "manifest.enc"
$EncryptedSuffix = ".secure"

# -- Helpers -------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Get-PlainTextFromSecureString {
    param([System.Security.SecureString]$SecureString)
    if ($null -eq $SecureString) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-PasswordComplexity {
    param([string]$Password)
    if ([string]::IsNullOrEmpty($Password) -or $Password.Length -lt 8) { return $false }
    $classes = 0
    if ($Password -cmatch '[A-Z]') { $classes++ }
    if ($Password -cmatch '[a-z]') { $classes++ }
    if ($Password -match  '[0-9]') { $classes++ }
    if ($Password -match  '[^A-Za-z0-9]') { $classes++ }
    return ($classes -ge 3)
}

function New-RandomBytes {
    param([int]$Length)
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try   { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return $bytes
}

function Compare-BytesConstantTime {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length)       { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor ($A[$i] -bxor $B[$i])
    }
    return ($diff -eq 0)
}

function Read-Exact {
    param(
        [System.IO.Stream]$Stream,
        [byte[]]$Buffer,
        [int]$Offset,
        [int]$Count
    )
    $totalRead = 0
    while ($totalRead -lt $Count) {
        $read = $Stream.Read($Buffer, $Offset + $totalRead, $Count - $totalRead)
        if ($read -le 0) { break }
        $totalRead += $read
    }
    return $totalRead
}

function Derive-Keys {
    param([string]$Password, [byte[]]$Salt, [int]$Iterations)
    try {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Password, $Salt, $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    } catch {
        # Fallback for older .NET Framework (< 4.7.2)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            $Password, $Salt, $Iterations)
    }
    try {
        $encKey  = $kdf.GetBytes(32)
        $hmacKey = $kdf.GetBytes(32)
    } finally { $kdf.Dispose() }
    return @{ EncryptionKey = $encKey; HmacKey = $hmacKey }
}

# --- Encrypt-File: streaming I/O, in-pass HMAC-SHA256, block-aligned -----
function Encrypt-File {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [byte[]]$EncryptionKey,
        [byte[]]$HmacKey
    )
    $iv  = New-RandomBytes $IVSize
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $EncryptionKey
    $aes.IV      = $iv
    $encryptor   = $aes.CreateEncryptor()

    $hmac     = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $HmacKey

    $inStream  = [System.IO.File]::OpenRead($SourcePath)
    $outStream = New-Object System.IO.FileStream(
        $DestinationPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
    try {
        # Write IV and HMAC placeholder
        $outStream.Write($iv, 0, $iv.Length)
        $outStream.Write((New-Object byte[] $HmacSize), 0, $HmacSize)

        # Authenticate IV in HMAC (Encrypt-then-MAC covers IV + Ciphertext)
        [void]$hmac.TransformBlock($iv, 0, $iv.Length, $iv, 0)

        $buffer       = New-Object byte[] $BufferSize
        $cipherBuffer = New-Object byte[] ($BufferSize + 16)
        $remaining    = $inStream.Length

        if ($remaining -eq 0) {
            # 0-byte file: transform empty final block with PKCS7 padding (produces 1 AES block)
            $finalBlock = $encryptor.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            if ($finalBlock.Length -gt 0) {
                $outStream.Write($finalBlock, 0, $finalBlock.Length)
                [void]$hmac.TransformBlock($finalBlock, 0, $finalBlock.Length, $finalBlock, 0)
            }
        } else {
            while ($remaining -gt 0) {
                $toRead = [int][Math]::Min($buffer.Length, $remaining)
                $read = Read-Exact -Stream $inStream -Buffer $buffer -Offset 0 -Count $toRead
                if ($read -le 0) { break }
                $remaining -= $read

                if ($remaining -gt 0) {
                    # Non-final chunk: $read is guaranteed to be $buffer.Length (multiple of 16)
                    $cipherLen = $encryptor.TransformBlock($buffer, 0, $read, $cipherBuffer, 0)
                    if ($cipherLen -gt 0) {
                        $outStream.Write($cipherBuffer, 0, $cipherLen)
                        [void]$hmac.TransformBlock($cipherBuffer, 0, $cipherLen, $cipherBuffer, 0)
                    }
                } else {
                    # Final chunk: process remaining data with PKCS7 padding
                    $finalBlock = $encryptor.TransformFinalBlock($buffer, 0, $read)
                    if ($finalBlock.Length -gt 0) {
                        $outStream.Write($finalBlock, 0, $finalBlock.Length)
                        [void]$hmac.TransformBlock($finalBlock, 0, $finalBlock.Length, $finalBlock, 0)
                    }
                }
            }
        }

        # Finalize HMAC computation
        [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $hmacBytes = $hmac.Hash

        # Seek back to write computed HMAC tag into the reserved header slot
        $outStream.Position = $IVSize
        $outStream.Write($hmacBytes, 0, $hmacBytes.Length)
        $outStream.Flush()
    }
    finally {
        $inStream.Dispose()
        $outStream.Dispose()
        $encryptor.Dispose()
        $aes.Dispose()
        $hmac.Dispose()
    }
}

# --- Decrypt-File: verify HMAC first, then decrypt via CryptoStream -----
function Decrypt-File {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [byte[]]$EncryptionKey,
        [byte[]]$HmacKey
    )
    $inStream = [System.IO.File]::OpenRead($SourcePath)
    try {
        $minSize = $IVSize + $HmacSize + 16 # IV + HMAC + at least 1 AES block of ciphertext
        if ($inStream.Length -lt $minSize) {
            throw "Encrypted file is corrupted or too small ($($inStream.Length) bytes)."
        }

        $iv = New-Object byte[] $IVSize
        $readIv = Read-Exact -Stream $inStream -Buffer $iv -Offset 0 -Count $IVSize
        if ($readIv -ne $IVSize) { throw "Truncated IV in encrypted file." }

        $storedHmac = New-Object byte[] $HmacSize
        $readHmac = Read-Exact -Stream $inStream -Buffer $storedHmac -Offset 0 -Count $HmacSize
        if ($readHmac -ne $HmacSize) { throw "Truncated HMAC in encrypted file." }

        # Pass 1: Verify HMAC
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $HmacKey
        try {
            [void]$hmac.TransformBlock($iv, 0, $iv.Length, $iv, 0)
            $buffer  = New-Object byte[] $BufferSize
            $scratch = New-Object byte[] $BufferSize
            while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                [void]$hmac.TransformBlock($buffer, 0, $read, $scratch, 0)
            }
            [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $computedMac = $hmac.Hash
        }
        finally {
            $hmac.Dispose()
        }

        # Check standard authenticated HMAC (IV + Ciphertext)
        $hmacValid = Compare-BytesConstantTime $computedMac $storedHmac

        # Fallback check for legacy HMAC (Ciphertext only) if needed
        if (-not $hmacValid) {
            $inStream.Position = $IVSize + $HmacSize
            $legacyHmac = New-Object System.Security.Cryptography.HMACSHA256
            $legacyHmac.Key = $HmacKey
            try {
                $buf2 = New-Object byte[] $BufferSize
                $scr2 = New-Object byte[] $BufferSize
                while (($read2 = $inStream.Read($buf2, 0, $buf2.Length)) -gt 0) {
                    [void]$legacyHmac.TransformBlock($buf2, 0, $read2, $scr2, 0)
                }
                [void]$legacyHmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                $legacyMac = $legacyHmac.Hash
            } finally {
                $legacyHmac.Dispose()
            }
            $hmacValid = Compare-BytesConstantTime $legacyMac $storedHmac
        }

        if (-not $hmacValid) {
            throw "HMAC verification failed - file tampered or wrong password."
        }

        # Pass 2: Decrypt verified ciphertext using CryptoStream
        $inStream.Position = $IVSize + $HmacSize
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = $EncryptionKey
        $aes.IV      = $iv

        # If destination file already exists and is ReadOnly, clear attribute
        if (Test-Path -LiteralPath $DestinationPath) {
            $destFile = New-Object System.IO.FileInfo($DestinationPath)
            if ($destFile.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                $destFile.Attributes = $destFile.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }
        }

        $decryptor = $aes.CreateDecryptor()
        $cryptoStream = New-Object System.Security.Cryptography.CryptoStream(
            $inStream,
            $decryptor,
            [System.Security.Cryptography.CryptoStreamMode]::Read)
        $outStream = [System.IO.File]::Create($DestinationPath)
        try {
            $plainBuffer = New-Object byte[] $BufferSize
            while (($read = $cryptoStream.Read($plainBuffer, 0, $plainBuffer.Length)) -gt 0) {
                $outStream.Write($plainBuffer, 0, $read)
            }
            $outStream.Flush()
        }
        finally {
            $outStream.Dispose()
            $cryptoStream.Dispose()
            $decryptor.Dispose()
            $aes.Dispose()
        }
    }
    finally {
        $inStream.Dispose()
    }
}

function Encrypt-ManifestBytes {
    param([byte[]]$Plaintext, [byte[]]$EncKey, [byte[]]$HmacKey)
    $iv  = New-RandomBytes $IVSize
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $EncKey
    $aes.IV      = $iv
    $encryptor   = $aes.CreateEncryptor()
    try {
        $cipher = $encryptor.TransformFinalBlock($Plaintext, 0, $Plaintext.Length)
    } finally {
        $encryptor.Dispose()
        $aes.Dispose()
    }

    $hmac     = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $HmacKey
    try {
        [void]$hmac.TransformBlock($iv, 0, $iv.Length, $iv, 0)
        [void]$hmac.TransformFinalBlock($cipher, 0, $cipher.Length)
        $mac = $hmac.Hash
    }
    finally { $hmac.Dispose() }

    return @{ IV = $iv; HMAC = $mac; Cipher = $cipher }
}

function Decrypt-ManifestBytes {
    param([byte[]]$Iv, [byte[]]$Mac, [byte[]]$Cipher, [byte[]]$EncKey, [byte[]]$HmacKey)
    $hmac     = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $HmacKey
    try {
        [void]$hmac.TransformBlock($Iv, 0, $Iv.Length, $Iv, 0)
        [void]$hmac.TransformFinalBlock($Cipher, 0, $Cipher.Length)
        $expected = $hmac.Hash
    }
    finally { $hmac.Dispose() }

    if (-not (Compare-BytesConstantTime $expected $Mac)) {
        # Fallback to legacy HMAC check (Cipher only)
        $legacyHmac = New-Object System.Security.Cryptography.HMACSHA256
        $legacyHmac.Key = $HmacKey
        try {
            $legacyExpected = $legacyHmac.ComputeHash($Cipher)
        } finally { $legacyHmac.Dispose() }

        if (-not (Compare-BytesConstantTime $legacyExpected $Mac)) {
            throw "Manifest HMAC invalid - wrong password or tampered."
        }
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $EncKey
    $aes.IV      = $Iv
    $decryptor = $aes.CreateDecryptor()
    try   { return $decryptor.TransformFinalBlock($Cipher, 0, $Cipher.Length) }
    finally { $decryptor.Dispose(); $aes.Dispose() }
}

function Secure-DeleteFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        # Clear ReadOnly attribute if set
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }

        $length = $item.Length
        if ($length -gt 0) {
            $stream = [System.IO.File]::OpenWrite($Path)
            try {
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                try {
                    $buffer = New-Object byte[] ([int][Math]::Min($BufferSize, $length))
                    $remaining = $length
                    while ($remaining -gt 0) {
                        $toWrite = [int][Math]::Min($buffer.Length, $remaining)
                        $rng.GetBytes($buffer)
                        $stream.Write($buffer, 0, $toWrite)
                        $remaining -= $toWrite
                    }
                } finally { $rng.Dispose() }
                $stream.Flush()
            } finally { $stream.Dispose() }
        }
        Remove-Item -LiteralPath $Path -Force
    } catch {
        Write-Log "  [!] Could not securely delete $Path : $_" Yellow
    }
}

function Encrypt-Folder {
    param([string]$FolderPath, [string]$Password)
    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Folder not found: $FolderPath"
    }
    $source = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $FolderPath).FullName).TrimEnd('\','/')
    $parent = Split-Path $source -Parent
    $leaf   = Split-Path $source -Leaf

    if ([string]::IsNullOrEmpty($parent) -or [string]::IsNullOrEmpty($leaf)) {
        throw "Cannot encrypt root drive directly ($source). Please specify a folder."
    }

    $dest = Join-Path $parent ($leaf + $EncryptedSuffix)

    if (Test-Path -LiteralPath $dest) { throw "Destination exists: $dest" }
    $sourceWithSep = $source + [System.IO.Path]::DirectorySeparatorChar
    if ($dest.StartsWith($sourceWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination inside source: $dest"
    }

    Write-Log "`n-- Encrypting: $source --" Cyan
    Write-Log "   Destination: $dest" Gray
    [void][System.IO.Directory]::CreateDirectory($dest)

    try {
        $salt = New-RandomBytes $SaltSize
        $keys = Derive-Keys -Password $Password -Salt $salt -Iterations $Iterations

        # Record subdirectories to preserve directory structure (including empty dirs)
        $allDirs = @(Get-ChildItem -LiteralPath $source -Recurse -Directory -Force -ErrorAction Stop |
                     Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
        $relDirs = @()
        foreach ($d in $allDirs) {
            $rel = $d.FullName.Substring($source.Length).TrimStart('\', '/')
            if (-not [string]::IsNullOrEmpty($rel)) {
                $relDirs += $rel
            }
        }

        $files = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force -ErrorAction Stop |
                   Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })

        if ($files.Count -eq 0 -and $relDirs.Count -eq 0) {
            Write-Log "   [!] Folder is completely empty." Yellow
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            return
        }

        $manifestFiles = @()
        $i = 0
        foreach ($file in $files) {
            $i++
            $relPath = $file.FullName.Substring($source.Length).TrimStart('\', '/')
            $encName = [Guid]::NewGuid().ToString("N") + ".enc"
            $encPath = Join-Path $dest $encName
            Write-Log ("   [{0}/{1}] {2}" -f $i, $files.Count, $relPath) Gray
            Encrypt-File -SourcePath $file.FullName `
                         -DestinationPath $encPath `
                         -EncryptionKey $keys.EncryptionKey `
                         -HmacKey $keys.HmacKey
            $manifestFiles += [PSCustomObject]@{
                OriginalPath  = $relPath
                EncryptedFile = $encName
            }
        }

        $manifestPayload = [PSCustomObject]@{
            Version     = 1
            Directories = @($relDirs)
            Files       = @($manifestFiles)
        }

        $manifestJson  = $manifestPayload | ConvertTo-Json -Depth 5 -Compress
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
        $enc = Encrypt-ManifestBytes -Plaintext $manifestBytes `
                                     -EncKey $keys.EncryptionKey `
                                     -HmacKey $keys.HmacKey

        $manifestPath = Join-Path $dest $ManifestName
        $outStream = [System.IO.File]::Create($manifestPath)
        try {
            $outStream.Write($salt, 0, $salt.Length)
            $outStream.Write($enc.IV, 0, $enc.IV.Length)
            $outStream.Write($enc.HMAC, 0, $enc.HMAC.Length)
            $outStream.Write($enc.Cipher, 0, $enc.Cipher.Length)
            $outStream.Flush()
        } finally { $outStream.Dispose() }

        Write-Log ("   [OK] Encrypted {0} file(s) -> {1}" -f $files.Count, $dest) Green
    }
    catch {
        Write-Log "   [X] Encryption failed: $_" Red
        Write-Log "       Cleaning up partial output..." Yellow
        try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        throw
    }
}

function Decrypt-Folder {
    param([string]$FolderPath, [string]$Password, [bool]$Force = $false)
    $src = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $FolderPath).FullName).TrimEnd('\','/')
    if ((Split-Path $src -Leaf) -notlike "*$EncryptedSuffix") {
        throw "Folder does not end in '$EncryptedSuffix': $src"
    }
    $parent  = Split-Path $src -Parent
    $leaf    = (Split-Path $src -Leaf)
    $outName = $leaf.Substring(0, $leaf.Length - $EncryptedSuffix.Length)
    $dest    = Join-Path $parent $outName

    $manifestPath = Join-Path $src $ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest missing: $manifestPath"
    }

    Write-Log "`n-- Decrypting: $src --" Cyan

    # Verify password BEFORE touching destination
    $inStream = [System.IO.File]::OpenRead($manifestPath)
    try {
        $minHeader = $SaltSize + $IVSize + $HmacSize
        if ($inStream.Length -lt $minHeader + 16) {
            throw "Manifest file is corrupted or truncated."
        }

        $salt = New-Object byte[] $SaltSize
        $r1 = Read-Exact -Stream $inStream -Buffer $salt -Offset 0 -Count $SaltSize
        if ($r1 -ne $SaltSize) { throw "Truncated salt in manifest." }

        $iv = New-Object byte[] $IVSize
        $r2 = Read-Exact -Stream $inStream -Buffer $iv -Offset 0 -Count $IVSize
        if ($r2 -ne $IVSize) { throw "Truncated IV in manifest." }

        $mac = New-Object byte[] $HmacSize
        $r3 = Read-Exact -Stream $inStream -Buffer $mac -Offset 0 -Count $HmacSize
        if ($r3 -ne $HmacSize) { throw "Truncated HMAC in manifest." }

        $cipherLen = [int]($inStream.Length - $minHeader)
        $cipher = New-Object byte[] $cipherLen
        $r4 = Read-Exact -Stream $inStream -Buffer $cipher -Offset 0 -Count $cipherLen
        if ($r4 -ne $cipherLen) { throw "Truncated ciphertext in manifest." }
    } finally { $inStream.Dispose() }

    $keys = Derive-Keys -Password $Password -Salt $salt -Iterations $Iterations
    try {
        $plain = Decrypt-ManifestBytes -Iv $iv -Mac $mac -Cipher $cipher `
                                       -EncKey $keys.EncryptionKey -HmacKey $keys.HmacKey
    } catch {
        throw "Wrong password (manifest HMAC failed)."
    }

    $manifestRaw = [System.Text.Encoding]::UTF8.GetString($plain)
    $manifestObj = $manifestRaw | ConvertFrom-Json

    # Handle both new structured payload and legacy array format
    $manifestFiles = @()
    $manifestDirs  = @()

    if ($manifestObj -is [System.Management.Automation.PSCustomObject] -and $manifestObj.PSObject.Properties['Files']) {
        $manifestFiles = @($manifestObj.Files)
        if ($manifestObj.PSObject.Properties['Directories']) {
            $manifestDirs = @($manifestObj.Directories)
        }
    } else {
        $manifestFiles = @($manifestObj)
    }

    # Now handle destination folder collision
    $destExisted = Test-Path -LiteralPath $dest
    if ($destExisted) {
        if (-not $Force) {
            Write-Log ("   [!] Destination already exists: {0}" -f $dest) Yellow
            $choice = Read-Host "   Merge (m) / Replace (r) / Abort (a)"
            switch -Regex ($choice) {
                '^[mM]' { }
                '^[rR]' {
                    Write-Log "   Removing existing folder..." Yellow
                    # Clear ReadOnly on all items in destination prior to removal
                    Get-ChildItem -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                                $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                            }
                        }
                    Remove-Item -LiteralPath $dest -Recurse -Force
                    [void][System.IO.Directory]::CreateDirectory($dest)
                    $destExisted = $false
                }
                default {
                    throw "Aborted by user. Destination exists: $dest"
                }
            }
        }
        if ($destExisted) {
            Write-Log "   [i] Merging into existing folder (matching files will be overwritten)." Yellow
        }
    } else {
        [void][System.IO.Directory]::CreateDirectory($dest)
    }

    $destWithSep = $dest.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

    try {
        # Restore empty directory structure first
        foreach ($relDir in $manifestDirs) {
            $targetDir = [System.IO.Path]::GetFullPath((Join-Path $dest $relDir))
            if (-not $targetDir.StartsWith($destWithSep, [System.StringComparison]::OrdinalIgnoreCase) -and
                $targetDir -ne $dest) {
                throw "Security violation: Path traversal detected in directory '$relDir'"
            }
            [void][System.IO.Directory]::CreateDirectory($targetDir)
        }

        # Restore files
        $i = 0
        foreach ($entry in $manifestFiles) {
            $i++
            if ([string]::IsNullOrWhiteSpace($entry.OriginalPath)) {
                throw "Invalid manifest: entry has empty OriginalPath."
            }
            $outPath = [System.IO.Path]::GetFullPath((Join-Path $dest $entry.OriginalPath))
            if (-not $outPath.StartsWith($destWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Security violation: Path traversal detected in '$($entry.OriginalPath)'"
            }

            $encPath = Join-Path $src $entry.EncryptedFile
            if (-not (Test-Path -LiteralPath $encPath)) {
                throw "Encrypted file missing from vault: $($entry.EncryptedFile)"
            }

            $outDir = [System.IO.Path]::GetDirectoryName($outPath)
            if (-not [string]::IsNullOrEmpty($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
                [void][System.IO.Directory]::CreateDirectory($outDir)
            }

            Write-Log ("   [{0}/{1}] {2}" -f $i, $manifestFiles.Count, $entry.OriginalPath) Gray
            Decrypt-File -SourcePath $encPath `
                         -DestinationPath $outPath `
                         -EncryptionKey $keys.EncryptionKey `
                         -HmacKey $keys.HmacKey
        }
        Write-Log ("   [OK] Restored {0} file(s) -> {1}" -f $manifestFiles.Count, $dest) Green
    }
    catch {
        Write-Log "   [X] Decryption failed: $_" Red
        if (-not $destExisted) {
            Write-Log "       Cleaning up partial output..." Yellow
            try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        } else {
            Write-Log "       (Existing destination folder left intact; partial files may remain)" Yellow
        }
        throw
    }
}

# -- Main execution flow -------------------------------------------------
if ($Decrypt) { $mode = "DECRYPT" } else { $mode = "ENCRYPT" }
Write-Log "=== SUPER MILITARY GRADE FOLDER ENCRYPTION ===" Cyan
Write-Log ("Mode:    {0}" -f $mode) Yellow
Write-Log ("Targets: {0}" -f ($FolderPaths -join ', ')) Yellow

# Validate paths early
$validTargets = @()
foreach ($folder in $FolderPaths) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Write-Log ("[X] Folder not found: {0}" -f $folder) Red
    } else {
        $validTargets += $folder
    }
}

if ($validTargets.Count -eq 0) {
    Write-Log "No valid target folders to process. Aborting." Red
    exit 1
}

# Confirmation
if (-not $Force) {
    $confirm = Read-Host ("Type '{0}' to confirm" -f $mode)
    if ($confirm -cne $mode) {
        Write-Log "Cancelled." Red
        exit 0
    }
}

# Resolve password
$resolvedPassword = $null
if ($Password) {
    $resolvedPassword = Get-PlainTextFromSecureString $Password
}

if ([string]::IsNullOrEmpty($resolvedPassword)) {
    if ($Decrypt) {
        # Decryption password prompt (single prompt, no complexity validation)
        do {
            $sec = Read-Host "Enter decryption password" -AsSecureString
            $p = Get-PlainTextFromSecureString $sec
            if ([string]::IsNullOrEmpty($p)) {
                Write-Log "[X] Password cannot be empty." Red
                continue
            }
            $resolvedPassword = $p
        } while ([string]::IsNullOrEmpty($resolvedPassword))
    } else {
        # Encryption password prompt (confirmation + complexity validation)
        do {
            $sec1 = Read-Host "Password (min 8 chars, mix of upper/lower/digit/special)" -AsSecureString
            $p1 = Get-PlainTextFromSecureString $sec1
            if (-not (Test-PasswordComplexity $p1)) {
                Write-Log "[X] Password must be at least 8 characters with at least 3 of: uppercase, lowercase, digit, special character." Red
                continue
            }
            $sec2 = Read-Host "Re-enter password" -AsSecureString
            $p2 = Get-PlainTextFromSecureString $sec2
            if ($p1 -cne $p2) {
                Write-Log "[X] Passwords do not match." Red
                continue
            }
            $resolvedPassword = $p1
        } while ([string]::IsNullOrEmpty($resolvedPassword))
    }
}

$success = @()
foreach ($folder in $validTargets) {
    try {
        if ($Decrypt) {
            Decrypt-Folder -FolderPath $folder -Password $resolvedPassword -Force:($Force.IsPresent)
        } else {
            Encrypt-Folder -FolderPath $folder -Password $resolvedPassword
        }
        $success += $folder
    } catch {
        Write-Log ("[X] Failed for {0}: {1}" -f $folder, $_) Red
    }
}

# Optional secure wipe of originals after successful encryption
if (-not $Decrypt -and $success.Count -gt 0) {
    $wipeChoice = Read-Host ("`nSecurely delete {0} original folder(s)? (y/n)" -f $success.Count)
    if ($wipeChoice -match '^[yY]') {
        foreach ($folder in $success) {
            Write-Log ("  Wiping {0} ..." -f $folder) Yellow
            Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Secure-DeleteFile -Path $_.FullName }
            try {
                # Clear read-only on directories prior to removal
                Get-ChildItem -LiteralPath $folder -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                            $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                        }
                    }
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log ("  [OK] Removed {0}" -f $folder) Green
            } catch {
                Write-Log ("  [!] Could not remove {0}: {1}" -f $folder, $_) Yellow
            }
        }
    } else {
        Write-Log "Originals retained." Cyan
    }
}

$resolvedPassword = $null
[GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Write-Log "`nDone." Cyan
