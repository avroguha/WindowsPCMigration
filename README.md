# Windows PC Migration kit (non-admin, OneDrive only)

Moves **your** side of a Windows PC - installed-software inventory, application settings, Windows
personalisation, dev-tool configs - from an old company machine to a new one, when:

- you are **not an administrator** on either machine,
- **USB is blocked** and there is no network share, and
- **OneDrive is the only thing that travels** (Desktop/Documents already go with it; this kit carries the rest).

It does not install software (that is the company portal's job) - it tells you **what** to install and then
puts your **settings** back.

## The simple way: `PCMigration.exe` (or `Start Migration.cmd`)

Share **`dist\PCMigration-<version>.exe`**: one file, about 500 KB, nothing to install, no administrator rights.
It is a proper Windows desktop application (C# / WPF on the .NET Framework that is part of every Windows 10 and 11),
designed after the Windows 11 Settings app: a step rail on the left, a content page on the right, light or dark
following Windows, your accent colour, Mica backdrop on Windows 11. The migration engine (the PowerShell scripts and
`catalog.json`) travels inside the exe and is unpacked to `%LOCALAPPDATA%\PCMigration\kit-<version>` at start, so an
updated exe always runs its own engine. Put the exe in OneDrive so the same copy is on both computers. If the company
blocks unsigned programs, the zip has the same files plus `Export.cmd` / `Import.cmd` for the command line; if it blocks
PowerShell scripts, IT has to allow the kit folder. Rebuild with `Build-Exe.ps1` (needs the .NET SDK on the build
machine only - the script installs it per user when missing); it also runs `Build-Package.ps1` for the zip.

**With or without admin.** The exe asks for nothing (`asInvoker` manifest) and works the same as a standard user or
an administrator; everything it touches is inside the signed-in profile. When it does run elevated it says so on the
first page and names the account whose settings it will pack or restore - the only thing elevation changes.

**Versions.** The version lives in the `VERSION` file, is baked into the exe name and properties, shown bottom-left in
the app, printed on the first log line of every script, written into each backup's `manifest.json` and `report.md`,
and checked on restore: a backup made with a newer kit than the one restoring is flagged on the Backup page.
Bump `VERSION` before running the build scripts.

Double-click it. The steps are listed on the left and you can go back to any finished one:

**Old computer** - 1 Start, 2 Scan, 3 Choose, 4 Review, 5 Pack, 6 Done.

1. **Start.** Which computer is this? The app guesses from what is already in the backup location. The pane at the
   bottom left shows the signed-in user, the backup location (with *Change*), network and OneDrive state.
2. **Scan.** The catalog is checked against this PC, then AppData is searched for programs the catalog does not
   know. Result tiles: settings found, programs, other data folders, keys and passwords. Programs still open that hold
   unsaved work are listed with *Close them for me*.
3. **Choose.** Everything found, grouped (Windows look and feel, Office and Outlook, browsers, developer tools,
   utilities, data tools, other programs found, folders you added), each with a one-line description and its size
   (measured in the background). Search box, Select all / none, *Add a folder…*. Keys and passwords are a separate,
   optional group with the password for the encrypted bundle.
4. **Review.** Items, estimated size, destination folder, what is still open, OneDrive state - the last look before
   anything is written.
5. **Pack.** Progress, phase, elapsed time, a network/pause strip, and the engine log under *Details*.
6. **Done.** What was packed, what was in use or too large, what to do next, and the list of things only you can do.

**New computer** - 1 Start, 2 Backup, 3 Install, 4 Choose, 5 Review, 6 Restore, 7 Done.

2. **Backup.** Every backup in the backup location as a card: computer, user, date, items, size, version, whether its
   files are downloaded (*Download everything now*), whether a restore is already in progress on this PC.
3. **Install.** One checklist built by comparing the old computer with this one: programs, Store apps, developer
   tools, VS Code and browser extensions, npm / pip / .NET / PowerShell packages. Each row has Open (store or package
   page), Install now (where a command exists), Copy name, Installed and Skip; whatever is detected on the machine is
   ticked off automatically on every visit, and the status is saved in the backup folder, so closing the app and
   reopening it continues exactly there (the first page offers *Continue where you left off*). Skipped programs keep
   their settings out of the restore; programs you mark installed by hand are restored even if they cannot be detected.
4. **Choose.** The same tick list, built from the backup: ready now, waiting for a program, restored earlier.
   Open programs that would block the restore are listed with *Close them for me*.
5. **Review.** Items, size, source, the *also restore settings whose program is not installed yet* option.
6. **Restore.** Progress as above; anything replaced is backed up first under `AppData\Local\PCMigration-backup`.
7. **Done.** Restored / problems / waiting, *Sign out now*, the report, and the things only you can do.

Run it again any time: a second pack merges into the same backup, a second restore only touches what you tick.

**Programs that are not installed yet.** Each catalog entry knows how to tell whether its program exists on
the new PC (`appCheck`: an entry in Apps & Features, an exe on PATH, a Store package, a registry key or a
path). A restore skips entries whose program is missing, records them in `restore-state-<computer>.json` next
to the backup, and the app shows them as *Waiting for Notepad++ to be installed*. Install the program,
run the app again: those entries are pre-ticked as *installed now - ready*, entries restored earlier are
unticked with the date. The command line does the same (`Import.cmd` repeatedly; `-RestoreEvenIfMissing`
overrides the check).

**Unsaved work.** Only what a program has already written to disk can travel. The kit carries: Windows 11
Notepad's open and unsaved tabs (`win-notepad-tabs`), Notepad++'s unsaved tabs and session (`dev-notepadpp`),
VS Code's hot-exit backups (`dev-vscode`), Office AutoRecover copies and the Unsaved Files folder
(`office-unsaved`), Sticky Notes, browser open tabs, and pinned clipboard items. Outlook drafts live in the
mailbox. Notepad and Notepad++ write their recovery files while running; VS Code and Office mostly on close
or every few minutes, so the app lists the editors that are still open and offers to close them (each one
asks you to save). On the new PC those programs must be closed during the restore, or they overwrite the
restored tabs with their own empty state.

**Network.** Packing into a local OneDrive folder needs no network; the upload happens afterwards. The first
page shows the network and OneDrive status. Where the network does matter - a share as the backup location,
or the new PC reading files that are still cloud-only - every package is preceded by a reachability check:
if the location is gone, the script logs PAUSE, the app shows "Paused - waiting", and it resumes by itself
when the location is back (up to 60 minutes, then it stops cleanly; re-running continues where it left off).

**Paths longer than 260 characters** (typically caches of editor extensions) cannot be zipped by Windows'
own libraries. They are detected before copying, left out, and listed in `report.md`.

**Programs the kit does not know (data folders).** The "what to take" page lists every AppData folder that no
catalog entry covers, with its size and the program it seems to belong to, caches excluded; small ones with a
known program are ticked, big or unknown ones are not. *Add a folder...* carries anything else (collections,
scripts, projects outside OneDrive) to the same path on the new PC. These choices are stored with the backup
(`extra-entries.json`), so the restore knows them and the next export of the same PC offers them again.

**Programs the kit does not know (registry).** Besides the catalog, two entries are computed at export time:
`apps-registry-other` takes every vendor key under `HKCU\Software` that no catalog entry covers (minus Windows,
hardware vendors, browsers and corporate agents), one `.reg` per vendor, and restores each key only once a program
matching that vendor is installed on the new PC. `dev-bruno-collections` reads Bruno's own config for the folders
that hold your collections and carries them. AppData folders of unknown programs are listed in `discovery\*.csv`
for you to add to the catalog. `inventory\vscode-extensions.md` and `inventory\browser-extensions.md` list
extensions with install links; the VS Code extension *files* can be carried too (`dev-vscode-extensions-folder`,
unticked by default, for when the Marketplace is blocked).

**No OneDrive?** The first page has *Change folder...*: pick any folder both computers can reach (a network
share, for example). The scripts honour the same choice through the `PCMIG_ROOT` environment variable.

## The command-line way (same engine)

| Where | Run | What it does |
|---|---|---|
| OLD PC | `Export.cmd` | Inventories software, packages settings into `OneDrive\PCMigration\<pc>-<user>-<date>\`, writes `report.md` |
| NEW PC | `Compare-Software.cmd` | Diffs the old inventory against the new PC -> `install-list.md` (what to get from the portal) |
| NEW PC | `Import.cmd -WhatIf`, then `Import.cmd` | Restores settings (files + HKCU registry), env vars, drives, printers, VS Code extensions |

Copy this folder into OneDrive first (it is already there if you are reading it from OneDrive), so the same
files are on both machines. Each `.cmd` just runs its `.ps1` with `-ExecutionPolicy Bypass`; pass the same
parameters to either (`Import.cmd -Include office,browser -WhatIf`).

### On the OLD machine

1. Close Outlook, browsers, VS Code, Notepad++ - open apps lock their settings files (locked files are listed
   in `report.md` under *Copy failures*; close the app and re-run `Export.cmd -Include <id>` - re-runs into the
   same folder merge into it).
2. `Export.cmd`. Takes a few minutes; browser profiles are the slow part.
3. Read `report.md`: it lists what was captured, files over the size cap, and the **manual steps** list.
4. Look at `discovery\*.csv`. Rows marked **NOT COVERED - review** are AppData folders of apps the catalog
   does not know. Add an entry to `catalog.json` (see below) and re-run with `-Include <new id>`, or copy them by hand.
5. Secrets (SSH keys, `.git-credentials`, `.npmrc`, cloud CLI creds, Firefox logins, DBeaver passwords) are
   **not exported unless** you run `Export.cmd -IncludeSecrets`. You are asked for a password and the bundle is
   AES-256 encrypted in OneDrive. Leaving the password empty stores them in clear - do not do that on a corporate
   OneDrive. Often simpler: create new keys on the new PC.
6. Wait for OneDrive to show the green tick on the whole folder.

### On the NEW machine

1. Sign in, let OneDrive sync. In OneDrive, right-click `PCMigration` -> **Always keep on this device**
   (placeholders are fetched on read otherwise, which is slow).
2. `Compare-Software.cmd` -> open `install-list.md`. Section 1 is what to install from the portal, section 2
   what you installed yourself without admin, sections 5-7 what NOT to install (corporate agents, drivers,
   runtimes). Install the software **before** importing settings, so settings land where the apps look.
3. Close all apps. `Import.cmd -WhatIf` shows every file and registry key it would touch.
4. `Import.cmd`. Existing targets are zipped to `%LOCALAPPDATA%\PCMigration-backup\<timestamp>\` first.
   `-Include` / `-Exclude` take ids or categories (`windows`, `office`, `browser`, `dev`, `tools`, `data`, `comms`).
   `-IncludeSecrets` restores the secrets bundle (asks for the password).
5. Sign out and back in (wallpaper, Explorer, taskbar, fonts). Then work through *Manual steps* in `report.md`.
6. Re-run `Compare-Software.cmd` after installing to confirm nothing is missing, and `Import.cmd` again once
   late-installed apps exist (it skips what is already identical and only appends PATH entries whose folder exists).

If the username differs between the machines, paths inside configs and `.reg` files are rewritten
automatically; registry values stored as `REG_EXPAND_SZ`/binary are counted and reported instead.

## What moves and what cannot

**Moves (catalog, ~120 entries):** Windows personalisation and input, Explorer options, taskbar and Start pins,
Startup/SendTo, user fonts, console colours, RDP history, Sticky Notes, Windows Terminal, PowerShell profiles
and history; Office options (Word/Excel/PowerPoint/Outlook view settings, recent lists), templates
(Normal.dotm), signatures, custom dictionaries and AutoCorrect, Quick Access Toolbar, XLSTART/PERSONAL.XLSB,
Word STARTUP, Outlook macros and PSTs; Edge/Chrome/Firefox/Opera/Brave/Vivaldi profiles (bookmarks, extensions,
history, open tabs - found wherever the browser keeps them, see below); Git, VS Code (+ extension list), JetBrains, Notepad++, Sublime, Python/pip/conda, npm, Maven/Gradle,
NuGet, Visual Studio, Claude Code/Desktop, Docker Desktop, Arduino; PuTTY (sessions, host keys and the .ppk files the
sessions point at), SuperPuTTY, WinSCP, 7-Zip, Greenshot, ShareX,
Snagit, PowerToys, KeePass, Adobe Reader, SAP GUI, Citrix; MobaXterm (ini, home folder, stored credentials), KiTTY,
mRemoteNG, Royal TS, Tabby, SecureCRT, Xshell, Remote Desktop Manager, Beyond Compare, WinMerge, TortoiseGit/SVN,
Sourcetree, GitHub Desktop, Fiddler, Wireshark, Insomnia, Obsidian; DBeaver, SSMS, Azure Data Studio, SQL Developer,
Postman (local collections, settings, working directory), Power BI, Tableau, RStudio, ODBC user DSNs; user environment variables and PATH, mapped drives,
network printers and the default printer.

**Cannot move, by design of Windows (the report lists them so you can redo them):**

| Item | Why | What to do |
|---|---|---|
| Credential Manager (Windows/Git/RDP/Office saved passwords) | DPAPI - encrypted to the old machine + user | `inventory\credential-targets.txt` names each one; re-enter |
| Edge/Chrome saved passwords, cookies, cards | DPAPI | Sign in to the browser; sync restores them |
| Browser extensions a browser refuses from the copied profile | Chromium validates copied profiles | `inventory\browser-extensions.md`: every extension with a store link |
| Outlook mail profile / OST | machine-bound; autodiscover recreates it | Start Outlook once; re-pick default signature, re-attach PSTs |
| Default apps / file associations | Windows requires the user to click, hashes block scripts | `inventory\default-apps.csv`; Settings > Default apps |
| User certificates with private keys | export right usually denied | re-enroll |
| Wi-Fi keys, VPN, machine-wide software, drivers, ODBC drivers | admin / IT-managed | portal / service desk |
| WSL distributions, VMs, Docker images, SDKs, model weights | GB-sized content | `wsl --export`, copy by hand; listed in discovery |

### Where the app looks for browser data (bookmarks are wherever the profile is)

A browser's bookmarks, history and extensions live inside its profile folder, and that folder is not always in the
default place: a company policy (`UserDataDir`), a shortcut started with `--user-data-dir=...`, or a Firefox profile
created somewhere else (`profiles.ini` with `IsRelative=0`, `firefox -profile <dir>`) all move it. For every browser
entry the app therefore resolves the real folders in this order and packs **all** of them: the policy value (HKCU
then HKLM, `${local_app_data}`-style variables expanded), the command line of a running copy of the browser, shortcuts
on the Desktop, Start menu and taskbar, and finally the default folder. The selection page shows "Also found outside the
default location" when that happens, and `export.log` names the folder. On restore a folder goes back to the same path
(username adjusted); if that path cannot exist on the new PC (another drive letter), it is restored into the folder the
browser uses there instead.

## Output layout

```
PCMigration\<pc>-<user>-<date>\
  manifest.json        what was packaged, read by Import-Profile and the app
  catalog.json         copy of the catalog used
  report.md            summary + manual to-do list        <- read this
  install-list.md/.csv written by Compare-Software on the new PC
  import-<pc>-<date>.md  written by Import-Profile
  inventory\           software.csv, store-apps.csv, portable-apps.csv, env-user.json, mapped-drives.csv,
                       printers.csv, startup.csv, scheduled-tasks.csv (+ task-*.xml), credential-targets.txt,
                       default-apps.csv, browser-extensions.csv, vscode-extensions.txt, ps-modules.csv,
                       office.json, tool-versions.txt (npm -g, dotnet tools, pip --user, WSL), user-certificates.csv
  discovery\           appdata-roaming/local/locallow.csv, profile-root.csv - size + coverage of every folder
  packages\<id>.zip    one zip per catalog entry
  secrets\<id>.zip.enc encrypted secret entries (only with -IncludeSecrets)
  logs\
```

## Extending the catalog

Every entry has a `summary` (the one-liner the app shows) and `notes` (the technical detail in report.md).


`catalog.json` is the whole definition of "what a setting is". An entry is a set of files or HKCU keys:

```json
{ "id": "tools-myapp", "app": "My App", "category": "tools", "kind": "files",
  "paths": [ "%APPDATA%\\MyApp", "%USERPROFILE%\\.myapprc" ],
  "excludeDirs": [ "Cache", "logs" ], "excludeFiles": [ "*.log" ],
  "notes": "shown in report.md" }

{ "id": "tools-myapp-reg", "app": "My App", "category": "tools", "kind": "registry",
  "keys": [ "HKCU\\Software\\MyApp" ], "excludeKeys": [ "HKCU\\Software\\MyApp\\Cache" ],
  "needsRestart": "explorer" }
```

Tokens: `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%`, `%DOCUMENTS%`, `%DESKTOP%` (the last two follow
OneDrive folder redirection). `"dynamic"` adds paths found at run time: `browser-dirs` (with `"browser"`: chrome,
edge, brave, vivaldi, opera, firefox - the real profile folders), `bruno-collections`, `putty-keyfiles` (the .ppk files
PuTTY/KiTTY sessions reference), `hkcu-vendors` (registry entries only). `"secret": true` moves the entry to the encrypted bundle. `includeFiles` restricts
a folder to named files. Entries whose paths do not exist on the source are skipped silently, so the catalog can
be generous. Use `discovery\*.csv` from a real export to decide what to add.

## The app's source (`src\PCMigration`)

| File | What it is |
|---|---|
| `PCMigration.csproj` | SDK-style project, `net48`, `UseWPF`; reads `VERSION`; embeds the engine files as resources |
| `app.manifest` | `asInvoker` (never asks for admin), per-monitor DPI v2, long paths |
| `App.xaml(.cs)` | start-up: `--kit <dir>`, `--root <backup root>`, `--theme light|dark|system`; unpacks the kit; global error dialog |
| `Themes\Controls.xaml` | the control styles in the Windows 11 (WinUI 3) idiom: buttons, check boxes, inputs, combo, scroll bars, progress, expander, cards, nav items |
| `Themes\Light.xaml`, `Dark.xaml` | the colour tokens (same keys); `Theme.cs` swaps them and derives the accent set from Windows' `AccentPalette` |
| `Native.cs` | the few Win32 calls: Mica backdrop and dark title bar (DWM), Snap Layouts hit-testing for the custom maximize button, the modern folder picker |
| `MainWindow.xaml(.cs)` | custom title bar, the step rail, page host, command bar, the content dialog layer |
| `Pages\*` | one page per step: Start, Scan, Select, Review, Run, Done; Backup, Install, RestoreSelect |
| `Controls\InfoBar`, `SelectionList` | the WinUI-style info strip and the grouped tick list both selection pages use |
| `Engine.cs`, `Kit.cs`, `Json.cs`, `Models.cs`, `Session.cs`, `Apps.cs` | runs the scripts, unpacks the kit, parses JSON with the in-box serializer, holds the models and the per-run state, knows which running programs matter |

Design references: the Windows 11 design principles and Fluent 2 tokens (type ramp, 4 px corners, 32 px controls,
layer and card fills, accent usage in light and dark), the Settings app's navigation layout, and the step-based flow
that PC migration products share (choose the computer, analyse, select with totals, review, transfer with a log,
report). Every control the UI tests touch has an `AutomationProperties.Name` (buttons by their text, tick boxes by
catalog id), so `lab\ui-test.ps1` drives the real app through UI Automation.

## Screenshots (`sample-output\app-*.png`)

Captured by `lab\ui-test.ps1` from the real app on 2026-11-07: the old-computer flow in the light theme
(`app-1-start` to `app-6-done`) and the new-computer flow in the dark theme (`app-7-backup` to `app-11-done`).
`powershell -File lab\ui-test.ps1 -Mode export -ShotDir <dir> -MigRoot <backup root> -Exe dist\PCMigration-<ver>.exe
[-Theme light|dark] [-Ids a,b,c]` runs the whole flow against a scratch backup root and leaves a PNG per page.
On the lab VMs: `bash lab/push-kit.sh` puts the kit and exe on the share, then on `pve`
`bash run-on-vm.sh 9311 elevated 'lab\vm-ui-test.ps1' -Mode export` (and `9312 ... -Mode import`). It must be the
`elevated` (interactive, `/it`) mode: the `user` mode runs the task in session 0, where the app starts but UI
Automation cannot see its window ("window not found"). The run on 2026-11-07 passed on both VMs with the 2.0.0 exe
(no .NET SDK there, .NET Framework 4.8 only).

## The lab test (`lab\`)

Result of the run on 2026-10-21 (`sample-output\lab-run\`): the first restore on the bare new VM restored 13
Windows settings and deferred the 6 program-bound entries; after installing Notepad++ and VS Code the second run
restored those two (and reinstalled the VS Code extension); after Git, PuTTY and 7-Zip the third run restored the
rest. 22 of 23 fingerprint checks matched; the one difference is a user PATH entry pointing at a profile folder
that does not exist on the new machine, which the restore skips until the folder exists.

`lab\build-lab.sh` builds two disposable Windows 11 VMs on the Proxmox host (`mig-old`, `mig-new`, IDs 9311/9312,
unattended install from the host's Win11 ISO) and a Samba container (9313) whose share stands in for OneDrive.
`lab\run-on-vm.sh` runs a kit script inside a VM as the lab user through the QEMU guest agent (a scheduled task
wrapped by `lab\run-task.cmd`); `lab\run-all.sh old|new` chains the phases and prints the transcripts via
`lab\showlog.py`. `lab\old-pc.ps1`
installs Notepad++, 7-Zip, VS Code, Git and PuTTY on the old VM, creates recognisable settings in each plus
Windows/PATH/SendTo/Terminal settings, exports, and writes a fingerprint. `lab\new-pc.ps1` runs the restore
three times on the new VM - with nothing installed (everything app-related must defer), after installing two
programs, after installing the rest - and compares the fingerprint. `bash build-lab.sh destroy` removes it all.

## Requirements and limits

- Windows 10 or 11 with the .NET Framework 4.8 (part of Windows) and Windows PowerShell 5.1 (built in); standard
  user. Nothing is installed. The app (`src\PCMigration`, C# / WPF) never reads AppData or the registry itself: it
  runs the engine scripts in hidden child processes - `UI-Probe.ps1` answers its questions as JSON, the three
  worker scripts stream their log back - so the command line and the app always agree on what a setting is.
- If the company blocks scripts (AppLocker/WDAC "this script is blocked"), the fallback is
  `powershell -NoProfile -Command "Get-Content .\Export-Profile.ps1 -Raw | Invoke-Expression"`
  from inside the kit folder; in Constrained Language Mode the zip step falls back to `Compress-Archive` (2 GB
  per archive).
- Per-file cap 500 MB by default (`-MaxFileMB`); larger files are listed in `report.md`. OneDrive's own limit is
  250 GB per file and about 400 characters per path - packages are zipped so deep AppData paths never hit it.
- `reg import` of a key under a path the policy locks (HKCU\Software\Policies) fails and is reported, not fatal.
- Everything is per user. Nothing here touches HKLM, Program Files, services, drivers or other users.
