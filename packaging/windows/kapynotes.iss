; Inno Setup script for the Windows build — the counterpart to the macOS DMG.
;
; Built by .github/workflows/desktop-ci.yml on every push and by
; desktop-release.yml on a tag, neither of which can run on macOS.
; To build by hand on a Windows box, from the repository root:
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

; The wizard's own artwork, so installing looks like this app rather than like
; Inno. The small mark rides the top right of every page; the tall panel is the
; left of the Setup Completed page — and of the Welcome page, for anyone who
; ever turns that back on with DisableWelcomePage=no. It is off by default in
; Inno 6, and worth leaving off: a page whose only job is to be looked at is
; still a click.
;
; Both are drawn by tool/generate_windows_installer_art.swift at Inno's 250%
; DPI sizes, and Inno scales them down for everything below that. Relative to
; this script, like SetupIconFile above. PNG — rather than the .bmp this used
; to have to be — needs Inno Setup 6.3 or newer.
WizardImageFile=wizard-image.png
WizardSmallImageFile=wizard-small.png
Compression=lzma2/max
SolidCompression=yes
; Closes a running copy before replacing the files it holds open, through
; Windows Restart Manager.
;
; "force" rather than "yes" because of what "yes" leaves behind. Restart
; Manager asks a window to close, and a copy set to keep running in the
; background answers that by hiding to the tray: the window goes, the process
; stays, the DLLs stay locked and the install fails. "force" still asks
; politely first and only terminates after thirty seconds of being ignored —
; which is exactly the grace an older build needs, since the copy being
; replaced is always the one built before the runner learned to answer.
CloseApplications=force
; Restart Manager will not put the app back. It only restarts applications
; that registered themselves with RegisterApplicationRestart, and this one has
; no reason to: the [Run] entry below does the same job for every install,
; silent or not, and one mechanism that always works beats two that half do.
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; "Open at login" is written by the app itself, into the per-user autorun list.
; Setup creates nothing here — ValueType none sees to that — and only claims
; the value so uninstalling takes it away too. Without this, removing the app
; would leave Windows starting a path that no longer exists.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "{#AppName}"; Flags: uninsdeletevalue

[Run]
; The checkbox on the Setup Completed page, for someone who ran this by hand.
; runasoriginaluser so that an installer started elevated — which is a
; tempting way past the SmartScreen warning — does not hand the user an app
; running as administrator.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent runasoriginaluser
; And the same thing for an update. WinSparkle runs this installer with
; /VERYSILENT, so there is no Setup Completed page for that checkbox to live
; on and the entry above is skipped — which used to leave every in-app update
; finishing with the app closed and nothing bringing it back.
;
; Harmless if something else got there first: the runner holds a single
; instance mutex, so a second copy hands over to the one already running and
; exits.
Filename: "{app}\{#AppExe}"; Flags: nowait runasoriginaluser; Check: WizardSilent

[UninstallDelete]
; Notes live in %APPDATA% (path_provider) and are deliberately left behind on
; uninstall. Only the app's own installed files go.
Type: dirifempty; Name: "{app}"
