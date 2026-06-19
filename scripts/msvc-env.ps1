function Set-MsvcEnvironment {
    param(
        [string] $Architecture = "x64",
        [string] $HostArchitecture = "x64"
    )

    if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
        return
    }

    $vswhereCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    $vswhere = $vswhereCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $vswhere) {
        throw "vswhere.exe was not found. Install Visual Studio Build Tools with the Desktop development with C++ workload."
    }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
        throw "Visual Studio C++ build tools were not found. Install the Desktop development with C++ workload."
    }

    $vsDevCmd = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path -LiteralPath $vsDevCmd)) {
        throw "VsDevCmd.bat was not found under Visual Studio installation: $installationPath"
    }

    $command = "`"$vsDevCmd`" -arch=$Architecture -host_arch=$HostArchitecture >nul && set"
    $environment = & cmd.exe /s /c $command
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize the MSVC developer environment."
    }

    foreach ($line in $environment) {
        $index = $line.IndexOf("=")
        if ($index -le 0) {
            continue
        }

        $name = $line.Substring(0, $index)
        $value = $line.Substring($index + 1)
        Set-Item -Path "Env:$name" -Value $value
    }
}
