#ifndef MyAppVersion
  #define MyAppVersion "1.2.0"
#endif

[Setup]
AppId={{8F4C2A19-7B6E-4D33-9A10-2C5E7B81D4F0}
AppName=ClipBridge
AppVersion={#MyAppVersion}
AppPublisher=ClipBridge
DefaultDirName={autopf}\ClipBridge
DefaultGroupName=ClipBridge
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=ClipBridge-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern
UninstallDisplayIcon={app}\clipbridge.exe

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ClipBridge"; Filename: "{app}\clipbridge.exe"
Name: "{group}\卸载 ClipBridge"; Filename: "{uninstallexe}"
Name: "{autodesktop}\ClipBridge"; Filename: "{app}\clipbridge.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"

[Run]
Filename: "{app}\clipbridge.exe"; Description: "启动 ClipBridge"; Flags: nowait postinstall skipifsilent
