# A microphone for the voice tests on a Windows runner, which has no audio
# device and its audio service stopped: the audio service started, VB-CABLE
# as the only input and the only output, desktop apps allowed to use the
# microphone, and a tone played into the cable for as long as the job runs,
# so a recording has sound in it.
#
#   pwsh tool/ci/windows_microphone.ps1
#
# Like mac_microphone.sh it refuses to run anywhere but CI.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:CI -ne 'true') {
  Write-Error 'windows_microphone.ps1 is for CI runners: it installs an audio driver.'
  exit 2
}

function Show-Inputs([string] $when) {
  Write-Host "Inputs $($when):"
  Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
    Where-Object InstanceId -like 'SWD\MMDEVAPI\{0.0.1.*' |
    Format-Table -AutoSize FriendlyName, Status | Out-Host
}

foreach ($service in 'AudioEndpointBuilder', 'Audiosrv') {
  Set-Service -Name $service -StartupType Automatic
  Start-Service -Name $service
}
Show-Inputs 'before VB-CABLE'

$pack = Join-Path $env:RUNNER_TEMP 'VBCABLE_Driver_Pack45.zip'
$driver = Join-Path $env:RUNNER_TEMP 'vbcable'
Invoke-WebRequest 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip' `
  -OutFile $pack -UserAgent 'Mozilla/5.0' -MaximumRetryCount 3 -RetryIntervalSec 5
$expected = 'b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb'
if ((Get-FileHash $pack -Algorithm SHA256).Hash -ne $expected) {
  throw "$pack is not the VB-CABLE pack this was written against"
}
Expand-Archive $pack -DestinationPath $driver -Force

# Trusting the driver's publisher first is what keeps the silent install from
# stopping at Windows's "install this device software?" prompt.
$signer = (Get-AuthenticodeSignature (Join-Path $driver 'vbaudio_cable64_win10.cat')).SignerCertificate
$store = [System.Security.Cryptography.X509Certificates.X509Store]::new('TrustedPublisher', 'LocalMachine')
$store.Open('ReadWrite')
$store.Add($signer)
$store.Close()
Start-Process (Join-Path $driver 'VBCABLE_Setup_x64.exe') -ArgumentList '-i', '-h' -Wait
Restart-Service Audiosrv -Force

$cable = $null
foreach ($attempt in 1..30) {
  $cable = Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.1.*' -and $_.FriendlyName -like '*CABLE Output*' }
  if ($cable) { break }
  Start-Sleep -Seconds 1
}
Show-Inputs 'after VB-CABLE'
if (-not $cable) { throw 'VB-CABLE installed no input' }

foreach ($key in
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged') {
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name Value -Value 'Allow'
}

# One second of a 440 Hz tone at half scale, as 16-bit mono PCM, looped into
# the cable's playback side, which is now the only output and so the default.
$rate = 16000
$samples = [byte[]]::new($rate * 2)
for ($i = 0; $i -lt $rate; $i++) {
  $value = [int16](16383 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate))
  [BitConverter]::GetBytes($value).CopyTo($samples, 2 * $i)
}
$tone = Join-Path $env:RUNNER_TEMP 'tone.wav'
$wav = [System.IO.BinaryWriter]::new([System.IO.File]::Create($tone))
$wav.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
$wav.Write([int](36 + $samples.Length))
$wav.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
$wav.Write([int]16); $wav.Write([int16]1); $wav.Write([int16]1)
$wav.Write([int]$rate); $wav.Write([int]($rate * 2))
$wav.Write([int16]2); $wav.Write([int16]16)
$wav.Write([Text.Encoding]::ASCII.GetBytes('data'))
$wav.Write([int]$samples.Length)
$wav.Write($samples)
$wav.Close()

Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
  "(New-Object Media.SoundPlayer '$tone').PlayLooping(); Start-Sleep -Seconds 86400"
