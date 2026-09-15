[CmdletBinding()]
param(
  [string] $Destination = 'build\windows\x64\runner\Release',
  [string] $VisualStudioDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredRuntimeDlls = @(
  'msvcp140.dll'
  'vcruntime140.dll'
  'vcruntime140_1.dll'
)

if ([string]::IsNullOrWhiteSpace($VisualStudioDirectory)) {
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
    throw 'Could not resolve the 32-bit Program Files directory needed to find Visual Studio'
  }

  $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Could not find vswhere.exe at $vswhere"
  }

  $installations = @(
    & $vswhere `
      -latest `
      -products '*' `
      -requires `
      Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
      Microsoft.VisualStudio.Component.VC.CMake.Project `
      -property installationPath
  )
  if ($LASTEXITCODE -ne 0) {
    throw "vswhere.exe failed with exit code $LASTEXITCODE"
  }

  $installations = @($installations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($installations.Count -eq 0) {
    throw 'Could not find a usable Visual Studio C++ installation'
  }
  $VisualStudioDirectory = $installations[0].Trim()
}

if (-not (Test-Path -LiteralPath $VisualStudioDirectory -PathType Container)) {
  throw "Visual Studio directory does not exist: $VisualStudioDirectory"
}

$redistRoot = Join-Path $VisualStudioDirectory 'VC\Redist\MSVC'
if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
  throw "Visual Studio's MSVC redistributables are missing: $redistRoot"
}

$runtimeDirectory = $null
$redistVersions = @(
  Get-ChildItem -LiteralPath $redistRoot -Directory |
    # Visual Studio 2026 adds aliases such as `v145` beside numeric version
    # directories. Try every directory instead of assuming every name can be
    # parsed as System.Version; the completeness check below chooses a CRT.
    Sort-Object Name -Descending
)
foreach ($redistVersion in $redistVersions) {
  $x64Directory = Join-Path $redistVersion.FullName 'x64'
  if (-not (Test-Path -LiteralPath $x64Directory -PathType Container)) {
    continue
  }

  $crtDirectories = @(
    Get-ChildItem -LiteralPath $x64Directory -Directory -Filter 'Microsoft.VC*.CRT' |
      Sort-Object Name -Descending
  )
  foreach ($crtDirectory in $crtDirectories) {
    $missingRuntimeDlls = @(
      $requiredRuntimeDlls |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $crtDirectory.FullName $_) -PathType Leaf) }
    )
    if ($missingRuntimeDlls.Count -eq 0) {
      $runtimeDirectory = $crtDirectory.FullName
      break
    }
  }

  if ($null -ne $runtimeDirectory) {
    break
  }
}

if ($null -eq $runtimeDirectory) {
  throw "Could not find a complete x64 Visual C++ runtime under $redistRoot"
}

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
  throw "Windows release directory does not exist: $Destination"
}
foreach ($bundleFile in @('kapy_notes.exe', 'flutter_windows.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $Destination $bundleFile) -PathType Leaf)) {
    throw "Windows release directory is incomplete: missing $bundleFile"
  }
}

$runtimeDlls = @(Get-ChildItem -LiteralPath $runtimeDirectory -File -Filter '*.dll')
foreach ($runtimeDll in $runtimeDlls) {
  Copy-Item -LiteralPath $runtimeDll.FullName -Destination $Destination -Force
}

foreach ($requiredRuntimeDll in $requiredRuntimeDlls) {
  if (-not (Test-Path -LiteralPath (Join-Path $Destination $requiredRuntimeDll) -PathType Leaf)) {
    throw "Failed to stage required Visual C++ runtime: $requiredRuntimeDll"
  }
}

$totalBytes = ($runtimeDlls | Measure-Object -Property Length -Sum).Sum
$totalMiB = [math]::Round($totalBytes / 1MB, 2)
Write-Host "Staged $($runtimeDlls.Count) x64 Visual C++ runtime DLLs ($totalMiB MiB) from $runtimeDirectory"
