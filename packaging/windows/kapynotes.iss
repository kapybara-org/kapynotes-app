; Inno Setup script for the Windows build — the counterpart to the macOS DMG.
;
; Built by .github/workflows/windows-build.yml, which cannot run on macOS.
; To build by hand on a Windows box, from the app/ directory:
;
;   flutter build windows --release
;   iscc packaging\windows\kapynotes.iss
;
; Output: build\release\KapyNotes-<version>-setup.exe, matching the DMG's
; KapyNotes-<version>.dmg. The version comes from pubspec.yaml via /DAppVersion;
; the fallback below only applies when building by hand without that flag.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; `flutter build windows --release` writes here. The exe alone is not runnable:
; flutter_windows.dll, the plugin DLLs and data\ all have to travel with it.
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

#define AppName "Kapy Notes"
#define AppPublisher "Kapybara LLC"
#define AppUrl "https://kapynotes.com"
#define AppExe "kapy_notes.exe"

[Setup]
; Identifies the app to Windows across upgrades and uninstalls. Never change
; it — a new GUID makes 1.0.1 install alongside 1.0.0 instead of replacing it.
AppId={{F6B274FD-6C52-4DEB-90BF-ED8551F7AE61}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/support
AppUpdatesURL={#AppUrl}

; Per-user install under %LOCALAPPDATA%\Programs. This is what keeps the
; installer from raising a UAC prompt: a notes app has no business asking for
; administrator rights, and a machine-wide install would need them.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes

; Flutter only produces a 64-bit Windows binary.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir=..\..\build\release
OutputBaseFilename=KapyNotes-{#AppVersion}-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Offers to close a running copy on upgrade rather than failing on locked DLLs.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Notes live in %APPDATA% (path_provider) and are deliberately left behind on
; uninstall. Only the app's own installed files go.
Type: dirifempty; Name: "{app}"
