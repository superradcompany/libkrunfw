param(
    [string] $Source = (Join-Path $PSScriptRoot "../kernel.c"),
    [string] $Makefile = (Join-Path $PSScriptRoot "../Makefile")
)

$ErrorActionPreference = "Stop"

$versionLine = Select-String -LiteralPath $Makefile -Pattern '^KERNEL_VERSION = linux-([0-9]+\.[0-9]+\.[0-9]+)$'
if ($null -eq $versionLine) {
    throw "Could not read the kernel version from $Makefile"
}

$version = $versionLine.Matches[0].Groups[1].Value
$expectedHeader = "/* libkrunfw kernel version: $version */"
if (-not (Test-Path -LiteralPath $Source) -or
    (Get-Content -LiteralPath $Source -TotalCount 1) -cne $expectedHeader) {
    throw "Kernel bundle is missing, unversioned, or not Linux $version. Rebuild it without -SkipKernelBundle before linking."
}
