#ifndef MyAppVersion
  #define MyAppVersion "1.2.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\..\publish\win-x64\WinPaste.exe"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\publish\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "WinPaste-Setup"
#endif

[Setup]
AppId={{7B6E3A4D-4B54-4B9E-8E8B-8D6E7F120A11}
AppName=WinPaste
AppVersion={#MyAppVersion}
AppPublisher=HunterLzap
AppPublisherURL=https://github.com/HunterLzap/Mac-paste
AppSupportURL=https://github.com/HunterLzap/Mac-paste/issues
DefaultDirName={localappdata}\Programs\WinPaste
DefaultGroupName=WinPaste
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\WinPaste.exe
UninstallDisplayName=WinPaste {#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "WinPaste.exe"; Flags: ignoreversion

[Icons]
Name: "{group}\WinPaste"; Filename: "{app}\WinPaste.exe"
Name: "{group}\卸载 WinPaste"; Filename: "{uninstallexe}"
Name: "{autodesktop}\WinPaste"; Filename: "{app}\WinPaste.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\WinPaste.exe"; Description: "立即启动 WinPaste"; Flags: nowait postinstall skipifsilent
