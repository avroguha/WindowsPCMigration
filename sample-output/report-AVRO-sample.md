# PC migration export - AVRO (AVRO\avrog)

Created 2026-10-21 13:13, took 2 min. Folder: `C:\Users\avrog\AppData\Local\Temp\claude\C--Users-avrog-OneDrive-Documents-Claude-WindowsPCMigration\c4882492-1e2e-493d-ae73-f0dfeead51e3\scratchpad\export-final`

## What to do on the NEW machine

1. Sign in, let OneDrive finish syncing (this folder must show the green tick, not the cloud icon).
2. Run `Compare-Software.cmd` -> `install-list.md` tells you what to install from the company portal. Install those FIRST.
3. Close Outlook/Office, browsers, VS Code, Notepad++ etc., then run `Import-Profile.cmd` (add `-WhatIf` first to preview).
4. Sign out and back in. Then work through the manual list below.

## Packaged settings

| id | app | files | MB | notes |
|---|---|---:|---:|---|
| `tools-kitty-mobaxterm` | KiTTY / MobaXterm / mRemoteNG / Royal TS configs | 2 | 0.0 |  |
| `tools-7zip` | 7-Zip settings | 1 | 0.0 |  |
| `dev-claude-code` | Claude Code (CLI) settings, memory, project notes | 2368 | 116.8 |  |
| `dev-windows-tools-cfg` | Shell config files in the profile root (.wslconfig, .vimrc, .tmux.conf, .curlrc, .wgetrc, .editorconfig, .terraformrc, .gnupg config) | 1 | 0.0 |  |
| `browser-chrome` | Google Chrome profile | 1557 | 95.8 | **1 large file(s) skipped** |
| `dev-git` | Git configuration | 3 | 0.0 |  |
| `dev-vscode` | Visual Studio Code user settings | 50 | 1.3 |  |
| `dev-claude-desktop` | Claude Desktop app config (MCP servers, preferences) | 3 | 0.0 |  |
| `dev-virtualbox-cfg` | VirtualBox global config | 1 | 0.0 |  |
| `dev-arduino` | Arduino IDE preferences and board manager config | 20 | 0.2 |  |
| `tools-lmstudio-ollama` | LM Studio / Ollama settings (models excluded) | 20 | 0.3 |  |
| `dev-docker-desktop` | Docker Desktop settings | 1 | 0.0 |  |
| `browser-opera` | Opera / Opera GX profile | 751 | 43.8 |  |
| `tools-joplin` | Joplin settings | 1 | 0.0 |  |
| `dev-bruno` | Bruno API client preferences | 1 | 0.0 |  |
| `win-taskbar-order` | Taskbar pin order | 1 | 0.1 |  |
| `win-start-menu` | Start menu user shortcuts and layout | 64 | 0.1 |  |
| `win-startup-folder` | Startup folder | 1 | 0.0 |  |
| `win-taskbar-pins` | Taskbar pinned apps | 4 | 0.0 |  |
| `win-desktop-input` | Windows personalisation and input | 10 | 0.0 |  |
| `win-wallpaper` | Current wallpaper file | 2 | 1.2 |  |
| `win-explorer` | File Explorer options | 6 | 0.0 |  |
| `win-sendto` | Send To menu | 6 | 0.0 |  |
| `dev-windows-terminal` | Windows Terminal | 1 | 0.0 |  |
| `ps-history` | PowerShell command history | 1 | 0.0 |  |
| `office-common` | Microsoft Office options (Word, Excel, PowerPoint, Outlook, OneNote...) | 1 | 0.0 |  |
| `win-snip-sketch` | Snipping Tool settings | 1 | 0.0 |  |
| `win-user-fonts-reg` | User-installed fonts registration | 1 | 0.0 |  |
| `win-console` | Console (cmd/PowerShell window) settings | 1 | 0.0 |  |
| `win-rdp-client` | Remote Desktop client history | 1 | 0.1 |  |

## Skipped

- `browser-firefox-logins`: secret (use -IncludeSecrets)
- `dev-git-credentials`: secret (use -IncludeSecrets)
- `dev-ssh`: secret (use -IncludeSecrets)
- `dev-npmrc`: secret (use -IncludeSecrets)
- `dev-gradle-props`: secret (use -IncludeSecrets)
- `dev-docker-config`: secret (use -IncludeSecrets)
- `dev-cloud-cli`: secret (use -IncludeSecrets)
- `dev-gnupg`: secret (use -IncludeSecrets)
- `tools-filezilla`: secret (use -IncludeSecrets)
- `data-dbeaver-credentials`: secret (use -IncludeSecrets)
- `dev-claude-code-credentials`: secret (use -IncludeSecrets)

## Files over the 500 MB cap (copy by hand into OneDrive, or re-run with -MaxFileMB)

- `C:\Users\avrog\AppData\Local\Google\Chrome\User Data\OptGuideOnDeviceModel\2025.8.8.1141\weights.bin`

## Copy failures (usually a file locked by a running app - close it and re-run with -Include <id>)

- C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings (robocopy 9): ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat.LOG1 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat.LOG1 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat.LOG2 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat.LOG2 - The process cannot access the file because it is being used by another process.
- C:\Users\avrog\AppData\Local\Google\Chrome\User Data (robocopy 9): ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Google\Chrome\User Data\Default\Sessions\Session_13437007021649859 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Google\Chrome\User Data\Default\Sessions\Session_13437007021649859 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Google\Chrome\User Data\Default\Sessions\Tabs_13437006494563342 - The process cannot access the file because it is being used by another process. | ERROR 32 (0x00000020) Copying File C:\Users\avrog\AppData\Local\Google\Chrome\User Data\Default\Sessions\Tabs_13437006494563342 - The process cannot access the file because it is being used by another process.

## Manual steps after import (things no script can carry)

- **Credential Manager**: Windows, Git, RDP, mapped-drive and Office saved passwords are encrypted to the old PC and the list in `inventory\credential-targets.txt` tells you which ones to re-enter.
- **Browsers**: saved passwords/cookies/payment methods do not travel in Edge/Chrome - sign in to the browser with your work account and let sync restore them. Extensions from the inventory may need re-enabling.
- **Outlook**: the mail profile is recreated by autodiscover on first start. Afterwards re-select the default signature per account, re-attach any PST, re-tick COM add-ins that show as inactive.
- **Default apps**: Windows does not let a script set them. `inventory\default-apps.csv` lists yours; set them in Settings > Apps > Default apps.
- **Certificates**: user certificates (`inventory\user-certificates.csv`) must be re-enrolled; private keys cannot be exported.
- **Network printers / mapped drives**: Import-Profile re-adds them from the inventory; drivers for a network printer come from the print server.
- **Wi-Fi / VPN**: corporate profiles are pushed by Intune/GPO; personal Wi-Fi keys need admin to export - re-type them.
- **Taskbar / Start pins**: restored, but a pin to a program that is not installed yet shows broken until the program is installed from the portal.
- **VS Code extensions**: Import-Profile reinstalls them when `code` is on PATH; otherwise `inventory\vscode-extensions.txt` is the list.
- **WSL**: distributions are not copied. `wsl --export <name> <OneDrive>\<name>.tar` on this PC, `wsl --import` on the new one (needs WSL installed there).
- **SSH keys**: only exported with `-IncludeSecrets`. Alternatively generate a new key on the new PC and register its public half wherever the old one was used.
- **Windows personalisation and input** (`win-desktop-input`): Wallpaper, colours, dark/light mode, mouse speed, pointer scheme, keyboard repeat, region/date formats, accessibility. The wallpaper file itself must exist on the new machine (see win-wallpaper).
- **File Explorer options** (`win-explorer`): Show extensions / hidden files, compact view, open to This PC, taskbar position/auto-hide, search settings, desktop icon visibility, default folder view.
- **Taskbar pinned apps** (`win-taskbar-pins`): Pinned shortcuts. Pins to apps that are not yet installed on the new PC show as broken until the app is installed; the Taskband registry key (win-taskbar-order) holds the order.
- **Taskbar pin order** (`win-taskbar-order`): Import after win-taskbar-pins, then restart Explorer.
- **Start menu user shortcuts and layout** (`win-start-menu`): Per-user Start menu shortcuts (installers of per-user apps put them here) and the Windows 11 pinned layout (start2.bin). Layout applies after sign-out/in; pins to missing apps are dropped.
- **User-installed fonts registration** (`win-user-fonts-reg`): Absolute paths into the profile - rewritten automatically when the username differs.
- **Microsoft Office options (Word, Excel, PowerPoint, Outlook, OneNote...)** (`office-common`): Options dialogs, recent files lists, Excel/Word preferences, Outlook view preferences, COM add-in load behaviour (HKCU add-ins). Outlook mail profiles are deliberately excluded - the company's autodiscover recreates them. Office must be CLOSED during import.
- **Google Chrome profile** (`browser-chrome`): Same caveats as Edge. Chrome must be CLOSED on both machines. Site data (IndexedDB/WebStorage - web-app caches like YouTube/Teams) is excluded; sites rebuild it.
- **Git configuration** (`dev-git`): Identity, aliases, credential helper setting, Git Bash shell config. Stored credentials are in Credential Manager (Git Credential Manager) and must be re-entered on first push.
- **Visual Studio Code user settings** (`dev-vscode`): settings.json, keybindings.json, snippets, profiles, extension state. The extension LIST is captured in the inventory and reinstalled by Import-Profile when 'code' is on PATH. VS Code must be CLOSED during import.
- **Opera / Opera GX profile** (`browser-opera`): Chromium-based: same DPAPI caveat as Chrome/Edge (no passwords/cookies). Opera must be closed.
- **Docker Desktop settings** (`dev-docker-desktop`): Resource limits, file sharing, proxies. Images/volumes are not copied (docker save / volume backup by hand). Docker Desktop itself needs admin to install - portal.
- **VirtualBox global config** (`dev-virtualbox-cfg`): The VM list with absolute paths. The VM folders (VirtualBox VMs, GB-sized) must be moved by hand and re-registered.
- **Arduino IDE preferences and board manager config** (`dev-arduino`): Boards/libraries re-download from the manager (lists in the yaml). Sketchbook is user content.
- **LM Studio / Ollama settings (models excluded)** (`tools-lmstudio-ollama`): Model weights (GB) are not copied; re-download them.

## Inventory files

- `inventory\browser-extensions.csv` (1 KB)
- `inventory\credential-targets.txt` (4 KB)
- `inventory\default-apps.csv` (1 KB)
- `inventory\env-user.json` (1 KB)
- `inventory\mapped-drives.csv` (0 KB)
- `inventory\office.json` (1 KB)
- `inventory\portable-apps.csv` (1 KB)
- `inventory\printers.csv` (0 KB)
- `inventory\ps-modules.csv` (0 KB)
- `inventory\scheduled-tasks.csv` (0 KB)
- `inventory\software.csv` (19 KB)
- `inventory\startup.csv` (2 KB)
- `inventory\store-apps.csv` (20 KB)
- `inventory\system.json` (1 KB)
- `inventory\tool-versions.txt` (3 KB)
- `inventory\user-certificates.csv` (0 KB)
- `inventory\vscode-extensions.txt` (1 KB)
- `inventory\winget-list.txt` (28 KB)

`discovery\*.csv` list every profile folder with its size and whether a catalog entry covers it. Rows marked **NOT COVERED - review** are settings of apps this kit does not know - add an entry to `catalog.json` or copy them by hand.
