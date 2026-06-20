param(
    [string] $AbiVersion = "5",
    [string] $DockerImage = "fedora:latest",
    [string] $DockerPlatform = "",
    [string] $Output = "libkrunfw.dll",
    [string] $ImportLibrary = "libkrunfw.lib",
    [string] $Definition = "libkrunfw.def",
    [string] $Architecture = "",
    [string] $HostArchitecture = "",
    [string] $GuestArchitecture = "",
    [ValidateSet("generic", "sev", "tdx")]
    [string] $Variant = "generic",
    [switch] $SkipKernelBundle,
    [switch] $SkipVerify
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$kernelBundle = Join-Path $repoRoot "kernel.c"
$qbootBundle = Join-Path $repoRoot "qboot.c"
$initrdBundle = Join-Path $repoRoot "initrd.c"
$isTee = $Variant -ne "generic"

. "$PSScriptRoot\msvc-env.ps1"

if (-not $Architecture) {
    $Architecture = Get-NativeMsvcArchitecture
}

if (-not $HostArchitecture) {
    $HostArchitecture = Get-NativeMsvcArchitecture
}

if (-not $GuestArchitecture) {
    if ($Architecture -eq "arm64") {
        $GuestArchitecture = "arm64"
    } else {
        $GuestArchitecture = "x86_64"
    }
}

if (-not $DockerPlatform) {
    if ($GuestArchitecture -eq "arm64" -or $GuestArchitecture -eq "aarch64") {
        $DockerPlatform = "linux/arm64"
    } else {
        $DockerPlatform = "linux/amd64"
    }
}

if ($isTee -and $Definition -eq "libkrunfw.def") {
    $Definition = "libkrunfw-tee.def"
}

if ($isTee -and $Output -eq "libkrunfw.dll") {
    $Output = "libkrunfw-$Variant.dll"
}

if ($isTee -and $ImportLibrary -eq "libkrunfw.lib") {
    $ImportLibrary = "libkrunfw-$Variant.lib"
}

$makeVariant = switch ($Variant) {
    "sev" { "SEV=1" }
    "tdx" { "TDX=1" }
    default { "" }
}
$makeArch = if ($GuestArchitecture) { "ARCH=$GuestArchitecture" } else { "" }

$makeTargets = @("kernel.c")
if ($isTee) {
    $makeTargets += @("qboot.c", "initrd.c")
}

if (-not $SkipKernelBundle) {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        throw "docker.exe was not found. Install Docker Desktop or pass -SkipKernelBundle when kernel.c already exists."
    }

    $targets = $makeTargets -join " "
    $dockerCommand = @"
set -euo pipefail
dnf install -y 'dnf-command(builddep)' python3-pyelftools curl
dnf builddep -y kernel
make $makeVariant $makeArch clean
make -j"`$(nproc)" $makeVariant $makeArch $targets
"@

    $dockerArgs = @("run", "--rm")
    if ($DockerPlatform) {
        $dockerArgs += @("--platform", $DockerPlatform)
    }
    $dockerArgs += @(
        "-v", "${repoRoot}:/work",
        "-w", "/work",
        $DockerImage,
        "bash", "-lc", $dockerCommand
    )

    & docker.exe @dockerArgs

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if (-not (Test-Path -LiteralPath $kernelBundle)) {
    throw "kernel.c was not found. Build it with Docker first or provide an existing kernel.c."
}

if ($isTee) {
    if (-not (Test-Path -LiteralPath $qbootBundle)) {
        throw "qboot.c was not found. Build it with Docker first or omit -SkipKernelBundle."
    }

    if (-not (Test-Path -LiteralPath $initrdBundle)) {
        throw "initrd.c was not found. Build it with Docker first or omit -SkipKernelBundle."
    }
}

Push-Location $repoRoot
try {
    $sources = @("kernel.c")
    if ($isTee) {
        $sources += @("qboot.c", "initrd.c")
    }

    & "$PSScriptRoot\build-windows-dll.ps1" `
        -AbiVersion $AbiVersion `
        -Output $Output `
        -ImportLibrary $ImportLibrary `
        -Definition $Definition `
        -Sources $sources `
        -Architecture $Architecture `
        -HostArchitecture $HostArchitecture

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if (-not $SkipVerify) {
        $expectedExports = @("krunfw_get_kernel", "krunfw_get_version")
        if ($isTee) {
            $expectedExports += @("krunfw_get_qboot", "krunfw_get_initrd")
        }

        & "$PSScriptRoot\verify-windows-dll.ps1" `
            -Dll $Output `
            -ImportLibrary $ImportLibrary `
            -ExpectedExports $expectedExports `
            -Architecture $Architecture `
            -HostArchitecture $HostArchitecture

        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
} finally {
    Pop-Location
}
