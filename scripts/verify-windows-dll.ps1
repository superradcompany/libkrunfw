param(
    [Parameter(Mandatory = $true)]
    [string] $Dll,

    [Parameter(Mandatory = $true)]
    [string] $ImportLibrary,

    [Parameter(Mandatory = $true)]
    [string[]] $ExpectedExports,

    [string] $BundleSection = ".krunfw",
    [int] $SectionAlignment = 65536
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\msvc-env.ps1"
Set-MsvcEnvironment

if (-not (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) {
    throw "dumpbin.exe was not found. Run this from an MSVC developer shell or configure the Visual Studio Build Tools environment first."
}

if (-not (Test-Path -LiteralPath $Dll)) {
    throw "DLL not found: $Dll"
}

if (-not (Test-Path -LiteralPath $ImportLibrary)) {
    throw "Import library not found: $ImportLibrary"
}

$expectedExportList = @(
    foreach ($symbol in $ExpectedExports) {
        foreach ($entry in ($symbol -split ",")) {
            $entry.Trim()
        }
    }
) | Where-Object { $_ }

$exports = & dumpbin.exe /nologo /exports $Dll
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$exportsText = $exports -join "`n"

foreach ($symbol in $expectedExportList) {
    if ($exportsText -notmatch "\b$([regex]::Escape($symbol))\b") {
        throw "Missing export: $symbol"
    }
}

$headers = & dumpbin.exe /nologo /headers $Dll
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
$headersText = $headers -join "`n"

$alignmentHex = "{0:x}" -f $SectionAlignment
if ($headersText -notmatch "(?im)^\s*$alignmentHex\s+section alignment\s*$") {
    throw "DLL section alignment is not $SectionAlignment bytes."
}

if ($headersText -notmatch [regex]::Escape($BundleSection)) {
    throw "Bundle section not found: $BundleSection"
}

if (-not ("Krunfw.NativeLibraryCheck" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace Krunfw {
    public static class NativeLibraryCheck {
        [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr LoadLibraryW(string lpFileName);

        [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Ansi)]
        public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

        [DllImport("kernel32", SetLastError=true)]
        public static extern bool FreeLibrary(IntPtr hModule);
    }
}
"@
}

$resolvedDll = (Resolve-Path -LiteralPath $Dll).Path
$handle = [Krunfw.NativeLibraryCheck]::LoadLibraryW($resolvedDll)
if ($handle -eq [IntPtr]::Zero) {
    throw "LoadLibraryW failed for $resolvedDll with error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

try {
    foreach ($symbol in $expectedExportList) {
        $address = [Krunfw.NativeLibraryCheck]::GetProcAddress($handle, $symbol)
        if ($address -eq [IntPtr]::Zero) {
            throw "GetProcAddress failed for $symbol with error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
} finally {
    [void] [Krunfw.NativeLibraryCheck]::FreeLibrary($handle)
}
