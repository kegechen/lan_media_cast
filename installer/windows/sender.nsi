Unicode true
ManifestDPIAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!ifndef APP_VERSION
!define APP_VERSION "1.0.0"
!endif

!define APP_NAME "LAN Media Cast"
!define APP_PUBLISHER "iFLYTEK"
!define APP_EXE "lan_media_cast_sender.exe"
!define APP_ID "LANMediaCastSender"
!define APP_DIR "$INSTDIR\app"
!define BUILD_DIR "..\..\sender_flutter\build\windows\x64\runner\Release"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"

!ifndef OUTPUT_FILE
!define OUTPUT_FILE "..\..\dist\LANMediaCast-Sender-${APP_VERSION}-Setup.exe"
!endif

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\LAN Media Cast"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "FileDescription" "LAN Media Cast Windows Installer"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright (C) 2026 iFLYTEK"

!define MUI_ICON "..\..\sender_flutter\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "..\..\sender_flutter\windows\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_PRE UseExistingInstallDirectory
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE VerifyInstallDirectory
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext all
  SetRegView 64
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "LAN Media Cast requires 64-bit Windows."
    Abort
  ${EndIf}
  ReadRegStr $0 HKLM "${UNINSTALL_KEY}" "InstallLocation"
  StrCmp $0 "" existing_install_location_done
  StrCpy $INSTDIR $0
existing_install_location_done:
FunctionEnd

Function un.onInit
  SetShellVarContext all
FunctionEnd

Function UseExistingInstallDirectory
  SetRegView 64
  ReadRegStr $0 HKLM "${UNINSTALL_KEY}" "InstallLocation"
  StrCmp $0 "" show_install_directory
  StrCpy $INSTDIR $0
  Abort
show_install_directory:
FunctionEnd

Function VerifyInstallDirectory
  SetRegView 64
  ReadRegStr $0 HKLM "${UNINSTALL_KEY}" "InstallLocation"
  StrCmp $0 "" verify_install_directory_done
  StrCmp $0 "$INSTDIR" verify_install_directory_done
  MessageBox MB_ICONEXCLAMATION|MB_OK "LAN Media Cast is already installed in:$\r$\n$0$\r$\n$\r$\nUninstall it before choosing a different directory."
  Abort
verify_install_directory_done:
FunctionEnd

Section "Application" SecMain
  SectionIn RO
  SetRegView 64
  ReadRegStr $0 HKLM "${UNINSTALL_KEY}" "InstallLocation"
  StrCmp $0 "" install_location_ok
  StrCmp $0 "$INSTDIR" install_location_ok
  IfSilent install_location_mismatch_silent
  MessageBox MB_ICONSTOP|MB_OK "LAN Media Cast is already installed in:$\r$\n$0$\r$\n$\r$\nUninstall it before choosing a different directory."
  SetErrorLevel 2
  Quit
install_location_mismatch_silent:
  SetErrorLevel 2
  Quit
install_location_ok:
  nsExec::ExecToLog 'taskkill /IM ${APP_EXE}'
  Sleep 1000
  nsExec::ExecToLog 'taskkill /F /IM ${APP_EXE}'
  ; Only remove recursive payload directories when the registry confirms that this
  ; exact location belongs to an existing LAN Media Cast installation.
  ReadRegStr $0 HKLM "${UNINSTALL_KEY}" "InstallLocation"
  StrCmp $0 "$INSTDIR" 0 install_payload
  IfFileExists "${APP_DIR}\${APP_EXE}" 0 check_legacy_payload
  RMDir /r "${APP_DIR}"

check_legacy_payload:
  ; Remove the complete payload used by the pre-app-directory 0.1.0 installer.
  IfFileExists "$INSTDIR\${APP_EXE}" 0 install_payload
  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\dartjni.dll"
  Delete "$INSTDIR\flutter_secure_storage_windows_plugin.dll"
  Delete "$INSTDIR\flutter_windows.dll"
  Delete "$INSTDIR\native_assets.json"
  Delete "$INSTDIR\yt-dlp.exe"
  RMDir /r "$INSTDIR\data"
  RMDir /r "$INSTDIR\licenses"

install_payload:
  SetOutPath "${APP_DIR}"
  File /r "${BUILD_DIR}\*.*"

  SetOutPath "${APP_DIR}\licenses"
  File "THIRD_PARTY_NOTICES.txt"
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayIcon" "${APP_DIR}\${APP_EXE}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "EstimatedSize" $0

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "${APP_DIR}\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "${APP_DIR}\${APP_EXE}"

  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${APP_NAME} Sender"'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="${APP_NAME} Sender" dir=in action=allow program="${APP_DIR}\${APP_EXE}" enable=yes profile=any'
SectionEnd

Section "Uninstall"
  SetRegView 64
  nsExec::ExecToLog 'taskkill /IM ${APP_EXE}'
  Sleep 1000
  nsExec::ExecToLog 'taskkill /F /IM ${APP_EXE}'
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${APP_NAME} Sender"'
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
  RMDir /r "${APP_DIR}"
  Delete /REBOOTOK "$INSTDIR\uninstall.exe"
  RMDir /REBOOTOK "$INSTDIR"
  IfFileExists "$INSTDIR\*.*" 0 un_done
  IfSilent un_done
  MessageBox MB_ICONEXCLAMATION|MB_OK "LAN Media Cast was removed, but unexpected files remain in:$\r$\n$INSTDIR$\r$\n$\r$\nThey were not deleted."
un_done:
SectionEnd
