; Minecraft 指令台 — Windows 安装包脚本（Inno Setup 6）
;
; 用法：
;   powershell -File packaging\windows\build_installer.ps1
; 或手动：
;   ISCC.exe packaging\windows\installer.iss
;
; 注意：版本号需与 pubspec.yaml 的 version 保持一致。

#define MyAppName "Minecraft"
#define MyAppNameEn "MinecraftCommand"
#define MyAppVersion "2.0.0"
#define MyAppPublisher "minecraftcommand"
#define MyAppExeName "minecraftcommand.exe"
; Release 产物目录（相对本脚本所在目录：packaging/windows → 项目根）
#define MySourceDir "..\..\build\windows\x64\runner\Release"

[Setup]
; AppId 一旦发布请保持不变，否则升级时会被认为是另一个应用
AppId={{9B4F2E7A-3C51-4D8E-A7F0-6E1D2C8B5A34}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppNameEn}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableWelcomePage=no
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=..\..\dist
OutputBaseFilename={#MyAppNameEn}-{#MyAppVersion}-win64-setup
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
MinVersion=10.0
SetupIconFile=..\..\windows\runner\resources\app_icon.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupAppTitle=安装 {#MyAppName}
SetupWindowTitle=安装 - {#MyAppName}
UninstallAppTitle=卸载 {#MyAppName}
UninstallAppFullTitle=卸载 - {#MyAppName}
SelectDirDesc=安装程序将把 {#MyAppName} 安装到以下文件夹。
SelectDirLabel3=点击“下一步”继续。如果选择其他文件夹，请点击“浏览”。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked

[Files]
; Release 目录下的全部内容（exe / flutter_windows.dll / rust_lib_*.dll / data / VC++ 运行库）
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
