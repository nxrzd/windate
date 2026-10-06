# windate

An interactive PowerShell utility for searching, downloading, and installing Windows updates through the Windows Update Agent.

windate displays available updates in three categories: required software updates, optional software updates, and drivers. Required updates are selected by default; optional updates and drivers require an explicit switch.

## Features

- Automatic administrator elevation through Windows UAC.
- Online search for updates that are neither installed nor hidden.
- Update titles, KB identifiers, and estimated download sizes.
- Confirmation before downloading and installing selected updates.
- Per-update installation results and a completion summary.
- Pending reboot detection and optional automatic restart.

## Requirements

- Windows with the Windows Update Agent available.
- Windows PowerShell; the elevation process launches `powershell.exe`.
- Administrator credentials or permission to approve UAC elevation.
- Access to the computer's configured update service.

## Usage

Download `windate.ps1` and open Windows PowerShell in its directory.

### Required updates

```powershell
.\windate.ps1
```

### Include optional updates and drivers

```powershell
.\windate.ps1 -Include_Optional
```

### Include optional updates, drivers, and automatic restart

```powershell
.\windate.ps1 -Include_Optional -Auto_Reboot
```

If administrator privileges are needed, windate requests UAC elevation and launches an elevated copy with both switches preserved. The original process exits after launching that copy.

Review the displayed updates and answer the installation prompt to continue. Declining cancels the Windows Update operation.

## Options

| Switch | Default | Effect |
| --- | --- | --- |
| `-Include_Optional` | Off | Selects optional software updates and drivers in addition to required updates. |
| `-Auto_Reboot` | Off | Allows a forced restart after installation when a reboot is detected, following a 15-second countdown. |

Drivers are classified separately first. Other updates are considered optional when their Windows Update Agent `BrowseOnly` property is true; remaining software updates are labeled required.

## Restart behavior

An existing pending reboot produces a warning at startup and does not immediately restart the computer. Without `-Auto_Reboot`, windate reports the restart requirement and leaves the restart to the administrator.

After installation, windate checks both the installation result and pending reboot registry indicators. A pre-existing reboot requirement can therefore still cause a restart at this stage when `-Auto_Reboot` is enabled. Automatic restart can also occur after partial update failures.

## Results and exit codes

The console summary reports installation duration, successful updates, updates completed with errors, failed or unknown results, download failures, and reboot status.

| Code | Meaning |
| --- | --- |
| `0` | Success, or successful launch of the elevated process. |
| `1` | Administrator elevation cancelled or failed, or startup failure. |
| `2` | Windows Update initialization failed. |
| `3` | Update search failed. |
| `10` | User cancelled installation. |
| `20` | Download operation failed. |
| `21` | No selected updates downloaded successfully. |
| `30` | Installation operation failed. |
| `40` | Updates failed, downloads failed, results were unknown, or installation reported errors without a reboot requirement. |
| `3010` | A restart is required; review individual results because updates may also have reported errors. |

The original process does not wait for the elevated copy, so its exit code does not represent the completed update operation. For automation that needs the final result, start the script in an already elevated session.
