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

function ConvertTo-RcString {
    param([Parameter(Mandatory = $true)][string] $Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Export-CBundleBytes {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

    $reader = [System.IO.StreamReader]::new($Source, [System.Text.Encoding]::ASCII)
    $writer = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $buffer = [byte[]]::new(65536)
    $count = 0
    $total = 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $matches = [regex]::Matches($line, "\\x([0-9a-fA-F]{1,2})")
            foreach ($match in $matches) {
                $buffer[$count] = [Convert]::ToByte($match.Groups[1].Value, 16)
                $count += 1
                $total += 1
                if ($count -eq $buffer.Length) {
                    $writer.Write($buffer, 0, $count)
                    $count = 0
                }
            }
        }

        if ($count -gt 0) {
            $writer.Write($buffer, 0, $count)
        }
    } finally {
        $writer.Dispose()
        $reader.Dispose()
    }

    if ($total -eq 0) {
        throw "failed to extract bundle bytes from $Source"
    }
}

function Get-KernelBundleMetadata {
    param([Parameter(Mandatory = $true)][string] $Source)

    $loadAddr = $null
    $entryAddr = $null
    foreach ($line in [System.IO.File]::ReadLines($Source, [System.Text.Encoding]::ASCII)) {
        if ($null -eq $loadAddr -and $line -match "\*load_addr\s*=\s*([^;]+);") {
            $loadAddr = $Matches[1].Trim()
        } elseif ($null -eq $entryAddr -and $line -match "\*entry_addr\s*=\s*([^;]+);") {
            $entryAddr = $Matches[1].Trim()
        }

        if ($null -ne $loadAddr -and $null -ne $entryAddr) {
            break
        }
    }

    if ($null -eq $loadAddr -or $null -eq $entryAddr) {
        throw "failed to read libkrunfw kernel load metadata from $Source"
    }

    return @{
        LoadAddr = $loadAddr
        EntryAddr = $entryAddr
    }
}

function New-ResourceBackedSources {
    param(
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][bool] $IsTee,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter(Mandatory = $true)][string] $HostArchitecture
    )

    $workDir = Join-Path $SourceRoot "build\windows"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null

    $kernelSource = Join-Path $SourceRoot "kernel.c"
    $kernelBinary = Join-Path $workDir "kernel.bin"
    $metadata = Get-KernelBundleMetadata -Source $kernelSource
    Export-CBundleBytes -Source $kernelSource -Destination $kernelBinary

    $resourceIds = @{
        Kernel = 101
        Qboot = 102
        Initrd = 103
    }

    $resourceLines = @(
        "#define IDR_KRUNFW_KERNEL $($resourceIds.Kernel)",
        "IDR_KRUNFW_KERNEL RCDATA $(ConvertTo-RcString -Value $kernelBinary)"
    )

    $teeExports = ""
    if ($IsTee) {
        $qbootSource = Join-Path $SourceRoot "qboot.c"
        $qbootBinary = Join-Path $workDir "qboot.bin"
        $initrdSource = Join-Path $SourceRoot "initrd.c"
        $initrdBinary = Join-Path $workDir "initrd.bin"
        Export-CBundleBytes -Source $qbootSource -Destination $qbootBinary
        Export-CBundleBytes -Source $initrdSource -Destination $initrdBinary

        $resourceLines += @(
            "#define IDR_KRUNFW_QBOOT $($resourceIds.Qboot)",
            "#define IDR_KRUNFW_INITRD $($resourceIds.Initrd)",
            "IDR_KRUNFW_QBOOT RCDATA $(ConvertTo-RcString -Value $qbootBinary)",
            "IDR_KRUNFW_INITRD RCDATA $(ConvertTo-RcString -Value $initrdBinary)"
        )

        $teeExports = @"

__declspec(dllexport) char * krunfw_get_qboot(size_t *size)
{
    if (size != NULL) {
        *size = 0;
    }

    char *bundle = krunfw_load_resource_bundle(IDR_KRUNFW_QBOOT, &QBOOT_BUNDLE, &QBOOT_BUNDLE_SIZE);
    if (bundle == NULL) {
        return NULL;
    }

    if (size != NULL) {
        *size = QBOOT_BUNDLE_SIZE;
    }
    return bundle;
}

__declspec(dllexport) char * krunfw_get_initrd(size_t *size)
{
    if (size != NULL) {
        *size = 0;
    }

    char *bundle = krunfw_load_resource_bundle(IDR_KRUNFW_INITRD, &INITRD_BUNDLE, &INITRD_BUNDLE_SIZE);
    if (bundle == NULL) {
        return NULL;
    }

    if (size != NULL) {
        *size = INITRD_BUNDLE_SIZE;
    }
    return bundle;
}
"@
    }

    $resourceRc = Join-Path $workDir "libkrunfw-bundles.rc"
    $resourceRes = Join-Path $workDir "libkrunfw-bundles.res"
    $wrapper = Join-Path $workDir "libkrunfw-windows.c"
    Set-Content -LiteralPath $resourceRc -Encoding ASCII -Value $resourceLines

    $wrapperSource = @"
#define WIN32_LEAN_AND_MEAN
#include <stddef.h>
#include <windows.h>

#define IDR_KRUNFW_KERNEL $($resourceIds.Kernel)
#define IDR_KRUNFW_QBOOT $($resourceIds.Qboot)
#define IDR_KRUNFW_INITRD $($resourceIds.Initrd)

#pragma section(".krunfw", read)
__declspec(allocate(".krunfw")) static const unsigned char KRUNFW_SECTION_MARKER[1] = {0};

static char *KERNEL_BUNDLE = NULL;
static size_t KERNEL_BUNDLE_SIZE = 0;
static char *QBOOT_BUNDLE = NULL;
static size_t QBOOT_BUNDLE_SIZE = 0;
static char *INITRD_BUNDLE = NULL;
static size_t INITRD_BUNDLE_SIZE = 0;

static char *krunfw_load_resource_bundle(int resource_id, char **bundle, size_t *bundle_size)
{
    HMODULE module = NULL;
    HRSRC resource = NULL;
    HGLOBAL loaded = NULL;
    DWORD resource_size = 0;
    void *resource_data = NULL;

    if (*bundle != NULL) {
        return *bundle;
    }

    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)&krunfw_load_resource_bundle,
            &module)) {
        return NULL;
    }

    resource = FindResourceA(module, MAKEINTRESOURCEA(resource_id), RT_RCDATA);
    if (resource == NULL) {
        return NULL;
    }

    resource_size = SizeofResource(module, resource);
    loaded = LoadResource(module, resource);
    resource_data = LockResource(loaded);
    if (resource_size == 0 || loaded == NULL || resource_data == NULL) {
        return NULL;
    }

    *bundle = (char *)VirtualAlloc(NULL, resource_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (*bundle == NULL) {
        return NULL;
    }

    CopyMemory(*bundle, resource_data, resource_size);
    *bundle_size = (size_t)resource_size;
    return *bundle;
}

__declspec(dllexport) char * krunfw_get_kernel(size_t *load_addr, size_t *entry_addr, size_t *size)
{
    if (load_addr != NULL) {
        *load_addr = $($metadata.LoadAddr);
    }
    if (entry_addr != NULL) {
        *entry_addr = $($metadata.EntryAddr);
    }
    if (size != NULL) {
        *size = 0;
    }

    char *bundle = krunfw_load_resource_bundle(IDR_KRUNFW_KERNEL, &KERNEL_BUNDLE, &KERNEL_BUNDLE_SIZE);
    if (bundle == NULL) {
        return NULL;
    }

    if (size != NULL) {
        *size = KERNEL_BUNDLE_SIZE;
    }
    return bundle;
}

__declspec(dllexport) int krunfw_get_version()
{
    return ABI_VERSION;
}
$teeExports
"@
    Set-Content -LiteralPath $wrapper -Encoding ASCII -Value $wrapperSource

    Set-MsvcEnvironment -Architecture $Architecture -HostArchitecture $HostArchitecture
    if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) {
        throw "rc.exe was not found. Run this from an MSVC developer shell or configure the Visual Studio Build Tools environment first."
    }

    & rc.exe /nologo /fo $resourceRes $resourceRc
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    return @($wrapper, $resourceRes)
}

if (-not $SkipKernelBundle) {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        throw "docker.exe was not found. Install Docker Desktop or pass -SkipKernelBundle when kernel.c already exists."
    }

    $targets = $makeTargets -join " "
    $makeJobs = [Math]::Max(1, [Environment]::ProcessorCount)
    $dockerCommand = @"
set -euo pipefail
dnf install -y 'dnf-command(builddep)' python3-pyelftools curl
dnf builddep -y kernel
build_dir=/tmp/libkrunfw-build
rm -rf "`$build_dir"
mkdir -p "`$build_dir"
cleanup() {
    rm -rf "`$build_dir"
}
trap cleanup EXIT

cd /work
tar --exclude='.git' \
    --exclude='./.git' \
    --exclude='kernel.c' \
    --exclude='./kernel.c' \
    --exclude='qboot.c' \
    --exclude='./qboot.c' \
    --exclude='initrd.c' \
    --exclude='./initrd.c' \
    --exclude='linux-*' \
    --exclude='./linux-*' \
    --exclude='*.dll' \
    --exclude='./*.dll' \
    --exclude='*.lib' \
    --exclude='./*.lib' \
    --exclude='*.exp' \
    --exclude='./*.exp' \
    --exclude='*.pdb' \
    --exclude='./*.pdb' \
    --exclude='*.obj' \
    --exclude='./*.obj' \
    -cf - . | tar -xf - -C "`$build_dir"

cd "`$build_dir"
make $makeVariant $makeArch clean
make -j$makeJobs $makeVariant $makeArch $targets
for target in $targets; do
    cp "`$target" "/work/`$target"
done
if [ -d tarballs ]; then
    mkdir -p /work/tarballs
    cp -a tarballs/. /work/tarballs/
fi
"@
    # PowerShell here-strings use CRLF on Windows, but Bash treats the CR as
    # part of tokens such as pipefail. Normalize before passing to bash -lc.
    $dockerCommand = $dockerCommand.Replace("`r`n", "`n").Replace("`r", "`n")

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

& "$PSScriptRoot\check-kernel-bundle.ps1" -Source $kernelBundle

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
    $sources = New-ResourceBackedSources `
        -SourceRoot $repoRoot `
        -IsTee $isTee `
        -Architecture $Architecture `
        -HostArchitecture $HostArchitecture

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
