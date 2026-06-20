param(
    [string] $AbiVersion = "5",
    [string] $Output = "libkrunfw.dll",
    [string] $ImportLibrary = "libkrunfw.lib",
    [string] $Definition = "libkrunfw.def",
    [string[]] $Sources = @("kernel.c"),
    [int] $SectionAlignment = 65536,
    [string] $Architecture = "",
    [string] $HostArchitecture = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\msvc-env.ps1"
if (-not $Architecture) {
    $Architecture = Get-NativeMsvcArchitecture
}
if (-not $HostArchitecture) {
    $HostArchitecture = Get-NativeMsvcArchitecture
}
Set-MsvcEnvironment -Architecture $Architecture -HostArchitecture $HostArchitecture

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "cl.exe was not found. Run this from an MSVC developer shell or configure the Visual Studio Build Tools environment first."
}

foreach ($source in $Sources) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source file not found: $source"
    }
}

if (-not (Test-Path -LiteralPath $Definition)) {
    throw "Module definition file not found: $Definition"
}

$compileArgs = @(
    "/nologo",
    "/LD",
    "/DABI_VERSION=$AbiVersion",
    "/Fe:$Output"
) + $Sources + @(
    "/link",
    "/DEF:$Definition",
    "/IMPLIB:$ImportLibrary",
    "/ALIGN:$SectionAlignment",
    "/SECTION:.krunfw,R,ALIGN=$SectionAlignment"
)

& cl.exe @compileArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
