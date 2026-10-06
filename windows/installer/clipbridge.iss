#ifndef MyAppVersion
  #define MyAppVersion "1.3.0"
#endif

[Setup]
AppId={{8F4C2A19-7B6E-4D33-9A10-2C5E7B81D4F0}
AppName=ClipDock
AppVersion={#MyAppVersion}
AppPublisher=ClipDock
DefaultDirName={autopf}\ClipDock
DefaultGroupName=ClipDock
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=ClipDock-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern
UninstallDisplayIcon={app}\clipbridge.exe

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{group}\ClipBridge.lnk"
Type: files; Name: "{group}\卸载 ClipBridge.lnk"
Type: files; Name: "{autodesktop}\ClipBridge.lnk"
Type: files; Name: "{autoprograms}\ClipBridge\ClipBridge.lnk"
Type: files; Name: "{autoprograms}\ClipBridge\卸载 ClipBridge.lnk"

[Icons]
Name: "{group}\ClipDock"; Filename: "{app}\clipbridge.exe"
Name: "{group}\卸载 ClipDock"; Filename: "{uninstallexe}"
Name: "{autodesktop}\ClipDock"; Filename: "{app}\clipbridge.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"

[Run]
Filename: "{app}\clipbridge.exe"; Description: "启动 ClipDock"; Flags: nowait postinstall skipifsilent
