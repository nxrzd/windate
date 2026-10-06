#Requires -Version 5.1
<#
.SYNOPSIS
    windate: interactive Windows and Lenovo update menu.
.DESCRIPTION
    One readable script for local execution or irm <hosted HTTPS URL> | iex.
    Optional Windows updates, hidden updates, Lenovo drivers, BIOS/firmware,
    hardware driver installation, and automatic Windows restart are configured before scanning starts.
    Lenovo requires Commercial Vantage and SU Helper. Firmware is opt-in.
    Internal worker modes isolate Windows Update exit codes from the menu.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Run','Windows')][string]$Mode = 'Menu',
    [switch]$Optional, [switch]$Hidden, [switch]$Lenovo,
    [switch]$Firmware, [switch]$Hardware, [switch]$Reboot
)

function Invoke-Windate {
    [CmdletBinding()]
    param(
        [ValidateSet('Menu','Run','Windows')][string]$Mode = 'Menu',
        [switch]$Optional,
        [switch]$Hidden,
        [switch]$Lenovo,
        [switch]$Firmware,
        [switch]$Hardware,
        [switch]$Reboot
    )

    function Invoke-WindowsUpdate {
        <#
        .SYNOPSIS
            Verbose, interactive Windows Update installer with automatic UAC elevation.

        .DESCRIPTION
            Searches Windows Update and displays:

                Required Updates
                Optional Updates
                Drivers

            Required updates are selected by default.

            Use -Include_Optional to also select optional updates
            and drivers.

            Use -Auto_Reboot to automatically restart Windows when
            a reboot is required by this update operation.

            If the script is started without Administrator privileges,
            it automatically requests elevation through UAC.

            The original non-administrator PowerShell process exits
            immediately after launching the elevated copy.

            Existing pending reboots do NOT automatically trigger a
            reboot before searching for updates.

        .PARAMETER Include_Optional
            Includes optional updates and driver updates.

        .PARAMETER Auto_Reboot
            Automatically restarts Windows when the update operation
            requires a reboot.

        .EXAMPLES

            Required updates only:
                .\windate.ps1

            Required + optional + drivers:
                .\windate.ps1 -Include_Optional

            Required + optional + drivers + automatic reboot:
                .\windate.ps1 -Include_Optional -Auto_Reboot

        .EXIT CODES

            0     Success
            1     Not Administrator / UAC cancelled / startup failure
            2     Windows Update initialization failure
            3     Windows Update search failure
            10    User cancelled
            20    Download operation failure
            21    No selected updates downloaded successfully
            30    Installation operation failure
            40    One or more updates failed or could not be downloaded
            3010  Success, reboot required
        #>

        [CmdletBinding()]
        param(
            [switch]$Include_Optional,

            [switch]$Include_Hidden,
            [switch]$Hardware_Drivers,
            [switch]$Auto_Reboot
        )

        $ErrorActionPreference = "Stop"

        # ============================================================
        # SELF-ELEVATION
        # ============================================================
        #
        # The script intentionally does NOT use:
        #
        #     #requires -RunAsAdministrator
        #
        # because #requires would terminate the script before it could
        # request UAC elevation itself.
        #
        # Instead, the script checks the current process and relaunches
        # itself with "RunAs" when necessary.
        # ============================================================

        function Test-IsAdministrator {

            try {

                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

                $principal = New-Object Security.Principal.WindowsPrincipal(
                    $identity
                )

                return $principal.IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator
                )
            }
            catch {

                return $false
            }
        }

        # SCRIPT IS NOW ELEVATED
        # ============================================================
        #
        # Nothing below this point executes in the original
        # non-administrator process.
        # ============================================================

        # ============================================================
        # DISPLAY FUNCTIONS
        # ============================================================

        function Write-Step {
            param(
                [Parameter(Mandatory)]
                [string]$Message
            )

            Write-Host ""
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] " `
                -NoNewline `
                -ForegroundColor DarkGray

            Write-Host $Message -ForegroundColor Cyan
        }

        function Write-Info {
            param(
                [Parameter(Mandatory)]
                [string]$Message
            )

            Write-Host "    $Message" -ForegroundColor Gray
        }

        function Write-Success {
            param(
                [Parameter(Mandatory)]
                [string]$Message
            )

            Write-Host "    $Message" -ForegroundColor Green
        }

        function Write-WarningMessage {
            param(
                [Parameter(Mandatory)]
                [string]$Message
            )

            Write-Host "    $Message" -ForegroundColor Yellow
        }

        function Write-Failure {
            param(
                [Parameter(Mandatory)]
                [string]$Message
            )

            Write-Host "    $Message" -ForegroundColor Red
        }

        function Write-UpdateEntry {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            $kb = Get-KB $Update
            $size = Get-SizeMB $Update

            Write-Host "  ● " `
                -NoNewline `
                -ForegroundColor Yellow

            if ($kb) {

                Write-Host "$kb " `
                    -NoNewline `
                    -ForegroundColor Yellow
            }

            Write-Host $Update.Title -ForegroundColor White

            if ($size -gt 0) {

                Write-Host "      Size: $size MB" `
                    -ForegroundColor DarkGray
            }
        }

        # ============================================================
        # UPDATE HELPERS
        # ============================================================

        function Get-KB {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            try {

                if ($null -ne $Update.KBArticleIDs -and
                    $Update.KBArticleIDs.Count -gt 0) {

                    return "KB$($Update.KBArticleIDs.Item(0))"
                }
            }
            catch {
                # Some updates do not expose KBArticleIDs.
            }

            return ""
        }

        function Get-SizeMB {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            try {

                if ($Update.MaxDownloadSize -gt 0) {

                    return [math]::Round(
                        $Update.MaxDownloadSize / 1MB,
                        1
                    )
                }
            }
            catch {
                # Some updates do not expose download size.
            }

            return 0
        }

        function Test-DriverUpdate {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            try {

                # Windows Update Agent:
                #
                # 1 = Software
                # 2 = Driver

                return ([int]$Update.Type -eq 2)
            }
            catch {

                return $false
            }
        }

        function Test-OptionalUpdate {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            # BrowseOnly is the primary WUA indication that an update
            # is not normally offered as an automatic/required update.

            try {

                if ([bool]$Update.BrowseOnly) {

                    return $true
                }
            }
            catch {
            }

            return $false
        }

        function Get-UpdateType {
            param(
                [Parameter(Mandatory)]
                $Update
            )

            # Drivers are classified separately before optional status.

            if (Test-DriverUpdate $Update) {

                return "Driver"
            }

            if (Test-OptionalUpdate $Update) {

                return "Optional"
            }

            return "Required"
        }

        # ============================================================
        # REBOOT DETECTION
        # ============================================================

        function Test-PendingReboot {

            $paths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            )

            foreach ($path in $paths) {

                if (Test-Path $path) {

                    return $true
                }
            }

            return $false
        }

        # ============================================================
        # AUTOMATIC REBOOT
        # ============================================================

        function Start-UpdateReboot {

            Write-Host ""

            Write-WarningMessage `
                "Windows needs to restart to finish applying updates."

            if (-not $Auto_Reboot) {

                Write-WarningMessage `
                    "Automatic reboot is disabled."

                Write-WarningMessage `
                    "Restart Windows manually when convenient."

                return $false
            }

            Write-Host ""

            for ($seconds = 15; $seconds -gt 0; $seconds--) {

                Write-Host `
                    "`r    Restarting in $seconds seconds... " `
                    -NoNewline `
                    -ForegroundColor Yellow

                Start-Sleep -Seconds 1
            }

            Write-Host ""
            Write-Host ""

            Write-WarningMessage `
                "Restarting computer..."

            Restart-Computer -Force

            return $true
        }

        # ============================================================
        # HEADER
        # ============================================================

        Clear-Host

        Write-Host ""
        Write-Host "============================================================" `
            -ForegroundColor Cyan

        Write-Host "                  WINDOWS UPDATE" `
            -ForegroundColor Cyan

        Write-Host "============================================================" `
            -ForegroundColor Cyan

        Write-Host ""

        Write-Info "Computer : $env:COMPUTERNAME"
        Write-Info "Started  : $(Get-Date)"

        if ($Include_Optional) {

            Write-Info "Optional : Included"
        }
        else {

            Write-Info "Optional : Not selected"
        }

        if ($Auto_Reboot) {

            Write-Info "Reboot   : Automatic when required"
        }
        else {

            Write-Info "Reboot   : Manual"
        }

        Write-Info "Elevated : Administrator"

        # ============================================================
        # ADMIN CHECK
        # ============================================================
        #
        # This is a safety check only.
        #
        # The actual elevation occurred at the beginning of the script.
        # If this check fails, something unexpected happened.
        # ============================================================

        Write-Step "Verifying administrator privileges..."

        if (-not (Test-IsAdministrator)) {

            Write-Failure `
                "Administrator privileges were not detected."

            Write-Failure `
                "Windows Update cannot continue."

            exit 1
        }

        Write-Success `
            "Administrator privileges confirmed."

        # ============================================================
        # EXISTING REBOOT CHECK
        # ============================================================

        Write-Step "Checking for a pending reboot..."

        $existingPendingReboot = Test-PendingReboot

        if ($existingPendingReboot) {

            Write-WarningMessage `
                "Windows currently reports a pending reboot."

            Write-WarningMessage `
                "The script will not automatically reboot at this stage."

            if ($Auto_Reboot) {

                Write-Info `
                    "Automatic reboot will only occur if the current update operation requires it."
            }
        }
        else {

            Write-Success `
                "No pending reboot detected."
        }

        # ============================================================
        # WINDOWS UPDATE SESSION
        # ============================================================

        Write-Step "Connecting to Windows Update..."

        try {

            $session = New-Object -ComObject Microsoft.Update.Session

            $session.ClientApplicationID = `
                "PowerShell Windows Updater"

            $searcher = $session.CreateUpdateSearcher()

            $searcher.Online = $true
        }
        catch {

            Write-Failure `
                "Could not initialize Windows Update."

            Write-Failure `
                $_.Exception.Message

            exit 2
        }

        Write-Success `
            "Windows Update Agent initialized."

        # ============================================================
        # SEARCH
        # ============================================================

        Write-Step "Searching Windows Update..."

        Write-Info "Online search: enabled"
        Write-Info "Hidden updates included: $Include_Hidden"
        Write-Info "Installed updates: excluded"

        Write-Host ""

        $searchStart = Get-Date

        try {

            $searchResult = $searcher.Search(
                $(if ($Include_Hidden) { "(IsInstalled=0 and IsHidden=0) or (IsInstalled=0 and IsHidden=1)" } else { "IsInstalled=0 and IsHidden=0" })
            )
        }
        catch {

            Write-Failure `
                "Windows Update search failed."

            Write-Failure `
                $_.Exception.Message

            exit 3
        }

        $searchSeconds = [math]::Round(
            ((Get-Date) - $searchStart).TotalSeconds,
            1
        )

        $allUpdates = $searchResult.Updates
        # Record exactly what the API offered for feature-update troubleshooting.
        try {
            $reportDir = Join-Path $env:ProgramData 'windate'
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $offerReport = @($allUpdates | ForEach-Object {
                [pscustomobject]@{
                    Title = $_.Title
                    UpdateID = $_.Identity.UpdateID
                    Hidden = $_.IsHidden
                    Optional = $_.BrowseOnly
                    Type = $_.Type
                }
            })
            ConvertTo-Json -InputObject $offerReport -Depth 4 | Set-Content -LiteralPath (Join-Path $reportDir 'last-update-scan.json') -Encoding UTF8
            Write-Info "Scan report: $reportDir\last-update-scan.json"
        } catch { Write-WarningMessage "Could not save scan report: $($_.Exception.Message)" }
        Write-Info 'All offered software updates are selected when option 1 is enabled, including feature updates returned by this API.'
        Write-WarningMessage 'A feature upgrade shown only in Settings may not be returned by this API. This scan does not prove Settings has no additional upgrade.'


        Write-Success `
            "Search completed."

        Write-Info `
            "Search time: $searchSeconds seconds"

        Write-Info `
            "Updates found: $($allUpdates.Count)"

        # ============================================================
        # CATEGORIZE UPDATES
        # ============================================================

        Write-Step "Categorizing updates..."

        $requiredUpdates = `
            New-Object -ComObject Microsoft.Update.UpdateColl

        $optionalUpdates = `
            New-Object -ComObject Microsoft.Update.UpdateColl

        $driverUpdates = `
            New-Object -ComObject Microsoft.Update.UpdateColl

        foreach ($update in $allUpdates) {

            $type = Get-UpdateType $update

            switch ($type) {

                "Driver" {

                    [void]$driverUpdates.Add($update)
                }

                "Optional" {

                    [void]$optionalUpdates.Add($update)
                }

                default {

                    [void]$requiredUpdates.Add($update)
                }
            }
        }

        Write-Success `
            "Categorization complete."

        # ============================================================
        # DISPLAY REQUIRED
        # ============================================================

        Write-Host ""
        Write-Host "WINDOWS UPDATE" -ForegroundColor White

        Write-Host "------------------------------------------------------------" `
            -ForegroundColor DarkGray

        Write-Host ""
        Write-Host "Required Updates" -ForegroundColor Cyan

        if ($requiredUpdates.Count -eq 0) {

            Write-Host "  None" -ForegroundColor DarkGray
        }
        else {

            for (
                $i = 0;
                $i -lt $requiredUpdates.Count;
                $i++
            ) {

                $update = $requiredUpdates.Item($i)

                Write-UpdateEntry $update
            }
        }

        # ============================================================
        # DISPLAY OPTIONAL
        # ============================================================

        Write-Host ""
        Write-Host "Optional Updates" -ForegroundColor Cyan

        if ($optionalUpdates.Count -eq 0) {

            Write-Host "  None" -ForegroundColor DarkGray
        }
        else {

            for (
                $i = 0;
                $i -lt $optionalUpdates.Count;
                $i++
            ) {

                $update = $optionalUpdates.Item($i)

                Write-UpdateEntry $update
            }
        }

        # ============================================================
        # DISPLAY DRIVERS
        # ============================================================

        Write-Host ""
        Write-Host "Drivers" -ForegroundColor Cyan

        if ($driverUpdates.Count -eq 0) {

            Write-Host "  None" -ForegroundColor DarkGray
        }
        else {

            for (
                $i = 0;
                $i -lt $driverUpdates.Count;
                $i++
            ) {

                $update = $driverUpdates.Item($i)

                Write-UpdateEntry $update
            }
        }

        # ============================================================
        # SUMMARY
        # ============================================================

        Write-Host ""
        Write-Host "Available Updates:" -ForegroundColor Cyan

        Write-Host "  Required:         $($requiredUpdates.Count)"
        Write-Host "  Optional:         $($optionalUpdates.Count)"
        Write-Host "  Drivers:          $($driverUpdates.Count)"

        # ============================================================
        # NOTHING FOUND
        # ============================================================

        if (
            $requiredUpdates.Count -eq 0 -and
            $optionalUpdates.Count -eq 0 -and
            $driverUpdates.Count -eq 0
        ) {

            Write-Host ""

            Write-Host `
                "============================================================" `
                -ForegroundColor Green

            Write-Host `
                "                WINDOWS IS UP TO DATE" `
                -ForegroundColor Green

            Write-Host `
                "============================================================" `
                -ForegroundColor Green

            Write-Host ""

            exit 0
        }

        # ============================================================
        # BUILD INSTALLATION LIST
        # ============================================================

        $updatesToInstall = `
            New-Object -ComObject Microsoft.Update.UpdateColl

        # Required updates are always selected.

        foreach ($update in $requiredUpdates) {

            if ($update.IsHidden) {
                if ((Read-Host "Include hidden update '$($update.Title)'? [y/N]") -notmatch '^[Yy]$') { continue }
            }
            [void]$updatesToInstall.Add($update)
        }

        # Optional software and applicable device drivers can be selected independently.
        if ($Include_Optional) {
            foreach ($update in $optionalUpdates) {
                if ($update.IsHidden -and (Read-Host "Include hidden update '$($update.Title)'? [y/N]") -notmatch '^[Yy]$') { continue }
                [void]$updatesToInstall.Add($update)
            }
        }
        if ($Include_Optional -or $Hardware_Drivers) {
            foreach ($update in $driverUpdates) {
                if ($update.IsHidden -and (Read-Host "Include hidden driver '$($update.Title)'? [y/N]") -notmatch '^[Yy]$') { continue }
                [void]$updatesToInstall.Add($update)
            }
        }

        Write-Host ""

        Write-Host `
            "Selected for installation: $($updatesToInstall.Count)" `
            -ForegroundColor Cyan

        if (-not $Include_Optional) {

            Write-Info `
                "Optional software is not selected. Hardware driver selection: $Hardware_Drivers"

            Write-Info `
                "Use -Include_Optional to install them."
        }

        # ============================================================
        # NOTHING SELECTED
        # ============================================================

        if ($updatesToInstall.Count -eq 0) {

            Write-Host ""

            Write-WarningMessage `
                "No updates are selected for installation."

            Write-Info `
                "Use -Include_Optional if you want to install optional updates and drivers."

            exit 0
        }

        # ============================================================
        # CONFIRMATION
        # ============================================================

        Write-Host ""

        Write-Host `
            "Install selected updates? [Y/N] " `
            -NoNewline `
            -ForegroundColor Yellow

        $answer = Read-Host

        if ($answer -notmatch "^[Yy]$") {

            Write-Host ""

            Write-WarningMessage `
                "Installation cancelled by user."

            exit 10
        }

        # ============================================================
        # DOWNLOAD PREPARATION
        # ============================================================

        Write-Step "Preparing updates..."

        # Unhide only confirmed, selected updates immediately before downloading.
        foreach ($update in $updatesToInstall) {
            if ($update.IsHidden) { $update.IsHidden = $false }
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
        }

        $updatesNeedingEula = 0

        foreach ($update in $updatesToInstall) {

            try {

                if (-not $update.EulaAccepted) {

                    Write-WarningMessage `
                        "EULA not yet accepted:"

                    Write-Info `
                        $update.Title

                    Write-Info `
                        "Windows Update will handle EULA requirements during installation."

                    $updatesNeedingEula++
                }
            }
            catch {
                # Some updates may not expose EulaAccepted.
            }
        }

        if ($updatesNeedingEula -gt 0) {

            Write-Info `
                "$updatesNeedingEula update(s) report an unaccepted EULA."
        }

        Write-Success `
            "Updates prepared."

        # ============================================================
        # DOWNLOAD
        # ============================================================

        Write-Step "Downloading updates..."

        Write-Info `
            "Updates selected: $($updatesToInstall.Count)"

        Write-Info `
            "Windows Update is downloading the required files."

        $downloader = $session.CreateUpdateDownloader()

        $downloader.Updates = $updatesToInstall

        $downloadStart = Get-Date

        try {

            $downloadResult = $downloader.Download()
        }
        catch {

            Write-Failure `
                "Download operation failed."

            Write-Failure `
                $_.Exception.Message

            exit 20
        }

        $downloadSeconds = [math]::Round(
            ((Get-Date) - $downloadStart).TotalSeconds,
            1
        )

        Write-Success `
            "Download operation completed."

        Write-Info `
            "Download time: $downloadSeconds seconds"

        Write-Info `
            "Result code: $($downloadResult.ResultCode)"

        # ============================================================
        # CHECK DOWNLOADS
        # ============================================================

        Write-Step "Checking downloaded updates..."

        $installCollection = `
            New-Object -ComObject Microsoft.Update.UpdateColl

        $downloadFailures = 0

        foreach ($update in $updatesToInstall) {

            if ($update.IsDownloaded) {

                [void]$installCollection.Add($update)

                Write-Success `
                    "Ready: $($update.Title)"
            }
            else {

                Write-Failure `
                    "Download failed: $($update.Title)"

                $downloadFailures++
            }
        }

        Write-Host ""

        Write-Info `
            "Ready to install: $($installCollection.Count)"

        Write-Info `
            "Download failures: $downloadFailures"

        if ($installCollection.Count -eq 0) {

            Write-Failure `
                "No selected updates were successfully downloaded."

            exit 21
        }

        # ============================================================
        # INSTALLATION SETUP
        # ============================================================

        Write-Step `
            "Checking installation requirements..."

        $installer = $session.CreateUpdateInstaller()

        $installer.Updates = $installCollection

        try {

            if ($installer.RebootRequiredBeforeInstallation) {

                Write-WarningMessage `
                    "Windows requires a reboot before installation."

                if ($Auto_Reboot) {

                    Write-WarningMessage `
                        "Automatic reboot is enabled."

                    Write-WarningMessage `
                        "Restarting now..."

                    Restart-Computer -Force

                    exit 3010
                }

                Write-Failure `
                    "Installation cannot continue until Windows is restarted."

                Write-WarningMessage `
                    "Restart Windows and run this script again."

                exit 3010
            }
        }
        catch {

            Write-WarningMessage `
                "Could not determine pre-install reboot state."

            Write-WarningMessage `
                "Continuing with installation."
        }

        # ============================================================
        # INSTALL
        # ============================================================

        Write-Step "Installing Windows Updates..."

        Write-Info `
            "Updates to install: $($installCollection.Count)"

        Write-Info `
            "This may take several minutes."

        $installStart = Get-Date

        try {

            $installResult = $installer.Install()
        }
        catch {

            Write-Failure `
                "Windows Update installation failed."

            Write-Failure `
                $_.Exception.Message

            exit 30
        }

        $installSeconds = [math]::Round(
            ((Get-Date) - $installStart).TotalSeconds,
            1
        )

        # ============================================================
        # INDIVIDUAL RESULTS
        # ============================================================

        Write-Step "Installation Results"

        $installedSuccessfully = 0
        $installedWithErrors = 0
        $failed = 0
        $unknown = 0

        for (
            $i = 0;
            $i -lt $installCollection.Count;
            $i++
        ) {

            $update = $installCollection.Item($i)

            $result = $installResult.GetUpdateResult($i)

            Write-Host ""

            Write-Host `
                "  [$($i + 1)/$($installCollection.Count)]" `
                -ForegroundColor Yellow

            Write-Host `
                "  $($update.Title)" `
                -ForegroundColor White

            Write-Info `
                "Result code: $($result.ResultCode)"

            Write-Info `
                "HRESULT:     $($result.HResult)"

            switch ([int]$result.ResultCode) {

                # 2 = Succeeded
                2 {

                    Write-Success `
                        "Installed successfully."

                    $installedSuccessfully++
                }

                # 3 = Succeeded with errors
                3 {

                    Write-WarningMessage `
                        "Installed with errors."

                    $installedWithErrors++
                }

                # 4 = Failed
                4 {

                    Write-Failure `
                        "Installation failed."

                    $failed++
                }

                # 5 = Aborted
                5 {

                    Write-Failure `
                        "Installation aborted."

                    $failed++
                }

                default {

                    Write-WarningMessage `
                        "Unknown installation result."

                    $unknown++
                }
            }
        }

        # ============================================================
        # REBOOT STATUS
        # ============================================================

        Write-Step "Checking final reboot status..."

        $rebootRequired = $false

        try {

            $rebootRequired = `
                [bool]$installResult.RebootRequired
        }
        catch {

            $rebootRequired = Test-PendingReboot
        }

        # Check system state as a fallback.

        if (-not $rebootRequired) {

            $rebootRequired = Test-PendingReboot
        }

        # ============================================================
        # FINAL SUMMARY
        # ============================================================

        Write-Host ""

        Write-Host `
            "============================================================" `
            -ForegroundColor Cyan

        Write-Host `
            "                    UPDATE SUMMARY" `
            -ForegroundColor Cyan

        Write-Host `
            "============================================================" `
            -ForegroundColor Cyan

        Write-Host ""

        Write-Info `
            "Installation time     : $installSeconds seconds"

        Write-Info `
            "Installed successfully: $installedSuccessfully"

        Write-Info `
            "Installed with errors : $installedWithErrors"

        Write-Info `
            "Failed                : $failed"

        Write-Info `
            "Unknown               : $unknown"

        Write-Info `
            "Download failures     : $downloadFailures"

        if ($existingPendingReboot) {

            Write-Host ""

            Write-WarningMessage `
                "A reboot was already pending before this script ran."
        }

        if ($rebootRequired) {

            Write-Host ""

            Write-Host `
                "    *** REBOOT REQUIRED ***" `
                -ForegroundColor Yellow

            Write-WarningMessage `
                "Windows must restart to finish applying updates."
        }
        else {

            Write-Host ""

            Write-Success `
                "No reboot is required."
        }

        # ============================================================
        # FAILURE HANDLING
        # ============================================================

        if (
            $failed -gt 0 -or
            $downloadFailures -gt 0 -or
            $unknown -gt 0
        ) {

            Write-Host ""

            Write-Failure `
                "Windows Update completed with errors."

            if ($installedWithErrors -gt 0) {

                Write-WarningMessage `
                    "$installedWithErrors update(s) installed with errors."
            }

            if ($rebootRequired -and $Auto_Reboot) {

                Start-UpdateReboot | Out-Null
            }

            exit 40
        }

        # ============================================================
        # INSTALLATION-WITH-ERRORS HANDLING
        # ============================================================

        if ($installedWithErrors -gt 0) {

            Write-Host ""

            Write-WarningMessage `
                "All selected updates completed, but one or more reported errors."

            if ($rebootRequired) {

                if ($Auto_Reboot) {

                    Start-UpdateReboot | Out-Null

                    exit 3010
                }

                Write-WarningMessage `
                    "Automatic reboot is disabled."

                Write-WarningMessage `
                    "Restart Windows manually when convenient."

                exit 3010
            }

            exit 40
        }

        # ============================================================
        # REBOOT HANDLING
        # ============================================================

        if ($rebootRequired) {

            if ($Auto_Reboot) {

                Start-UpdateReboot | Out-Null

                exit 3010
            }

            Write-Host ""

            Write-WarningMessage `
                "Automatic reboot is disabled."

            Write-WarningMessage `
                "Restart Windows manually when convenient."

            exit 3010
        }

        # ============================================================
        # SUCCESS
        # ============================================================

        Write-Host ""

        Write-Host `
            "============================================================" `
            -ForegroundColor Green

        Write-Host `
            "              WINDOWS UPDATE COMPLETE" `
            -ForegroundColor Green

        Write-Host `
            "============================================================" `
            -ForegroundColor Green

        Write-Host ""

        Write-Success `
            "All selected updates completed successfully."

        exit 0
    }

    if ($Mode -eq 'Windows') {
        Invoke-WindowsUpdate -Include_Optional:$Optional -Include_Hidden:$Hidden -Auto_Reboot:$Reboot -Hardware_Drivers:$Hardware
        return
    }
    if ($Mode -eq 'Run') {
        $ErrorActionPreference = 'Stop'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator access is required.' }
        Write-Host 'Detected hardware' -ForegroundColor Cyan
        $computer = Get-CimInstance Win32_ComputerSystem
        $processors = @(Get-CimInstance Win32_Processor)
        $graphics = @(Get-CimInstance Win32_VideoController)
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Host "Computer: $($computer.Manufacturer) $($computer.Model)"
        Write-Host "Windows architecture: $($os.OSArchitecture)"
        foreach ($cpu in $processors) {
            $architecture = switch ([int]$cpu.Architecture) { 0 {'x86'} 9 {'x64'} 12 {'ARM64'} default {"Code $($cpu.Architecture)"} }
            Write-Host "CPU: $($cpu.Name) | $architecture"
        }
        foreach ($gpu in $graphics) {
            $vendor = switch -Regex ($gpu.PNPDeviceID) {
                'VEN_8086' {'Intel'; break}
                'VEN_1002' {'AMD'; break}
                'VEN_10DE' {'NVIDIA'; break}
                default {$gpu.AdapterCompatibility}
            }
            Write-Host "GPU: $($gpu.Name) | $vendor | Driver $($gpu.DriverVersion)"
            Write-Host "  Device ID: $($gpu.PNPDeviceID)"
        }
        if ($Hardware) {
            Write-Host 'Windows Update will select drivers applicable to this hardware and operating system.'
            Write-Host 'Includes available graphics, chipset, network, and other device drivers.'
            Write-Host 'The configured update service may not offer the newest vendor website releases.'
        }
        $argsWU = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath, '-Mode', 'Windows')
            if ($Optional) { $argsWU += '-Optional' }
            if ($Hidden) { $argsWU += '-Hidden' }
            if ($Hardware) { $argsWU += '-Hardware' }
            if ($Reboot -and -not $Lenovo) { $argsWU += '-Reboot' }
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @argsWU
            $windowsExit = $LASTEXITCODE
            Write-Host "Windows Update exit code: $windowsExit"
            $restartRequired = ($windowsExit -eq 3010)
            try {
                $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
                $restartRequired = $restartRequired -or [bool]$systemInfo.RebootRequired
            } catch { Write-Warning 'Could not read Windows Update restart status.' }
            foreach ($key in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            )) { if (Test-Path $key) { $restartRequired = $true } }
            if ($restartRequired) {
                Write-Host 'RESTART REQUIRED: save your work and restart Windows to finish updating.' -ForegroundColor Yellow
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    Add-Type -AssemblyName System.Drawing
                    $notification = New-Object System.Windows.Forms.NotifyIcon
                    try {
                        $notification.Icon = [System.Drawing.SystemIcons]::Information
                        $notification.Visible = $true
                        $notification.BalloonTipTitle = 'windate: restart required'
                        $notification.BalloonTipText = 'Save your work and restart Windows to finish applying updates.'
                        $notification.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                        $notification.ShowBalloonTip(10000)
                        # Keep the notification icon alive while Windows displays the balloon.
                        for ($tick = 0; $tick -lt 100; $tick++) {
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 100
                        }
                    } finally { $notification.Dispose() }
                } catch { Write-Warning 'Desktop notification unavailable; restart requirement is shown above.' }
            }

            if ($Lenovo) {
                if ((Get-CimInstance Win32_ComputerSystem).Manufacturer -notmatch 'Lenovo') {
                    Write-Warning 'Lenovo updates skipped: this computer is not identified as Lenovo.'
                } else {
                    $helper = Join-Path $env:ProgramFiles 'Lenovo\SUHelper\suhelper.exe'
                    if (-not (Test-Path -LiteralPath $helper)) {
                        Write-Warning 'Install Lenovo Commercial Vantage and SU Helper, then rerun this menu.'
                        Write-Host 'https://docs.lenovocdrt.com/guides/lcv/suhelper/'
                    } elseif ((Read-Host 'Start Lenovo update installation now? [y/N]') -match '^[Yy]$') {
                        $types = '2'
                        if ($Firmware) { $types = '2,3,4' }
                        & $helper -autoupdate -packagetype $types -reboottype '0,3,5' -noreboot
                        $helperExit = $LASTEXITCODE
                        if ($helperExit -eq 0) {
                            Write-Host 'Lenovo update session requested. Installation continues through Commercial Vantage.'
                            Write-Host 'Check Vantage for completion and results before restarting.'
                        } else { Write-Warning "Lenovo SU Helper returned $helperExit (1=parameters, 2=busy, 3=error)." }
                    }
                }
            }

        [void](Read-Host 'Press Enter to close')
        return
    }
    $ErrorActionPreference = 'Stop'
    function Read-Choice([string]$Prompt) {
        while ($true) {
            $answer = Read-Host "$Prompt [y/N]"
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[Nn]$') { return $false }
            if ($answer -match '^[Yy]$') { return $true }
            Write-Host 'Enter Y or N.'
        }
    }
    $optional = $true; $hidden = $false; $lenovo = $false; $firmware = $false; $hardware = $true; $reboot = $false
    while ($true) {
        Clear-Host
        Write-Host 'windate - update options' -ForegroundColor Cyan
        Write-Host 'All offered Windows software and hardware updates are selected by default.'
        Write-Host "[1] Optional Windows updates and drivers: $optional"
        Write-Host "[2] Hidden Windows updates (individual review): $hidden"
        Write-Host "[3] Lenovo drivers via Commercial Vantage: $lenovo"
        Write-Host "[4] Lenovo BIOS and firmware: $firmware"
        Write-Host "[5] Automatic Windows restart: $reboot"
        Write-Host "[6] Automatic hardware drivers (Intel / AMD / NVIDIA): $hardware"
        Write-Host '[S] Start    [Q] Quit' 
        $choice = (Read-Host 'Choose an option').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { $optional = -not $optional }
            '2' { $hidden = -not $hidden }
            '3' { $lenovo = -not $lenovo; if (-not $lenovo) { $firmware = $false } }
            '4' {
                if ($firmware) { $firmware = $false }
                elseif (Read-Choice 'Include Lenovo BIOS/firmware updates? Connect AC power first.') { $firmware = $true; $lenovo = $true }
            }
            '5' { $reboot = -not $reboot }
            '6' { $hardware = -not $hardware }
            'Q' { return }
            'S' { break }
            default { continue }
        }
        if ($choice -eq 'S') { break }
    }
    if ($lenovo -and $reboot) {
        Write-Host 'Automatic restart disabled for this run so vendor updates can finish.'
        $reboot = $false
    }

    # Preserve this complete, readable script when invoked through irm | iex.
    $definition = (Get-Command Invoke-Windate -CommandType Function).Definition
    $entry = @'
param(
    [ValidateSet('Menu','Run','Windows')][string]$Mode = 'Menu',
    [switch]$Optional, [switch]$Hidden, [switch]$Lenovo,
    [switch]$Firmware, [switch]$Hardware, [switch]$Reboot
)
'@
    $scriptText = $entry + "`r`nfunction Invoke-Windate {`r`n" + $definition + "`r`n}`r`nInvoke-Windate @PSBoundParameters`r`n"
    $runnerPath = Join-Path $env:TEMP ('windate-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($runnerPath, $scriptText, (New-Object Text.UTF8Encoding($true)))
    $launchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $runnerPath + '"'), '-Mode', 'Run')
    if ($optional) { $launchArgs += '-Optional' }
    if ($hidden) { $launchArgs += '-Hidden' }
    if ($lenovo) { $launchArgs += '-Lenovo' }
    if ($firmware) { $launchArgs += '-Firmware' }
    if ($hardware) { $launchArgs += '-Hardware' }
    if ($reboot) { $launchArgs += '-Reboot' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    try {
        $processOptions = @{
            FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            ArgumentList = $launchArgs
            Wait = $true
            PassThru = $true
        }
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $processOptions.Verb = 'RunAs' }
        $process = Start-Process @processOptions
        Write-Host "windate process finished with exit code $($process.ExitCode)."
    } catch { Write-Warning "windate could not start: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue }
}
Invoke-Windate @PSBoundParameters
