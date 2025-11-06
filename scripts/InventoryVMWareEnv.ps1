<#
.SYNOPSIS
  Daily vSphere inventory report (VMs, Hosts, Datastores) with logging & error handling.
.DESCRIPTION
  Collects comprehensive vSphere inventory data with performance optimizations for large environments.
  Exports to CSV and HTML formats with enhanced error handling and retry logic.
.PARAMETER vCenter
  vCenter Server FQDN or IP address
.PARAMETER OutDir
  Output directory for reports
.PARAMETER CredPath
  Path to encrypted credential file
.PARAMETER BatchSize
  Number of VMs to process in each batch (default: 200)
.PARAMETER RetryCount
  Number of connection retry attempts (default: 3)
.EXAMPLE
  .\vSphere-Inventory.ps1 -vCenter "vcenter01.company.com" -OutDir "C:\Reports" -CredPath "C:\creds\vcenter_cred.xml"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenter,
    
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    
    [Parameter(Mandatory = $true)]
    [string]$CredPath,
    
    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 200,
    
    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 3
)

# -------------------------
# Setup and Initialization
# -------------------------
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

# Import required modules
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
}
catch {
    Write-Error "Failed to import VMware.PowerCLI module: $($_.Exception.Message)"
    exit 1
}

# Initialize timing and paths
$script:StartTime = Get-Date
$stamp = $script:StartTime.ToString('yyyy-MM-dd_HH-mm-ss')
$RunDir = Join-Path $OutDir $stamp
$LogFile = Join-Path $RunDir "inventory_$stamp.log"

# Validate and create directories
if (!(Test-Path $OutDir)) {
    try {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        Write-Host "Created output directory: $OutDir"
    }
    catch {
        Write-Error "Failed to create output directory: $OutDir"
        exit 1
    }
}

try {
    New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
}
catch {
    Write-Error "Failed to create run directory: $RunDir"
    exit 1
}

# Enhanced logger function
function Write-Log {
    param(
        [string]$Message, 
        [string]$Level = 'INFO',
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1}] {2}' -f $timestamp, $Level.PadRight(5), $Message
    
    if (-not $NoConsole) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'INFO'  { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
    
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

# Retry function for robust operations
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$RetryDelay = 10
    )
    
    $attempt = 0
    do {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -le $MaxRetries) {
                Write-Log "Attempt $attempt failed: $($_.Exception.Message). Retrying in $RetryDelay seconds..." "WARN"
                Start-Sleep -Seconds $RetryDelay
            }
            else {
                Write-Log "All $MaxRetries attempts failed." "ERROR"
                throw
            }
        }
    } while ($attempt -le $MaxRetries)
}

try {
    Write-Log "=== vSphere Inventory: START ==="
    Write-Log "Output folder: $RunDir"
    Write-Log "Batch size: $BatchSize"
    Write-Log "Retry count: $RetryCount"

    # Validate credential file
    if (!(Test-Path $CredPath)) {
        throw "Credential file not found at $CredPath"
    }

    # -------------------------
    # Connect to vCenter with retry logic
    # -------------------------
    Write-Log "Connecting to vCenter: $vCenter"
    $vi = Invoke-WithRetry -ScriptBlock {
        $cred = Import-Clixml $CredPath
        Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop
    } -MaxRetries $RetryCount
    
    Write-Log "Connected as $($vi.User) to $($vi.Name)"

    # -------------------------
    # Collect VM Inventory (with batching for large environments)
    # -------------------------
    Write-Log "Collecting VM inventory..."
    $allVMs = Get-VM
    Write-Log "Found $($allVMs.Count) virtual machines"

    $vmBatches = @()
    for ($i = 0; $i -lt $allVMs.Count; $i += $BatchSize) {
        $batch = $allVMs[$i..[math]::Min($i + $BatchSize - 1, $allVMs.Count - 1)]
        $vmBatches += , $batch
    }

    $vmResults = @()
    $batchNumber = 1
    
    foreach ($batch in $vmBatches) {
        Write-Log "Processing VM batch $batchNumber of $($vmBatches.Count) ($($batch.Count) VMs)"
        
        $batchResults = $batch | Select-Object -Property @(
            'Name'
            @{n = 'PowerState'; e = { $_.PowerState } }
            @{n = 'CPU'; e = { $_.NumCpu } }
            @{n = 'MemoryGB'; e = { [math]::Round($_.MemoryGB, 2) } }
            @{n = 'ProvisionedGB'; e = { [math]::Round(($_.ProvisionedSpaceGB), 2) } }
            @{n = 'UsedGB'; e = { [math]::Round(($_.UsedSpaceGB), 2) } }
            @{n = 'GuestOS'; e = { $_.Guest.OSFullName } }
            @{n = 'VMHost'; e = { $_.VMHost.Name } }
            @{n = 'Cluster'; e = { 
                try { (Get-Cluster -VM $_ -ErrorAction SilentlyContinue).Name } 
                catch { 'N/A' } 
            }}
            @{n = 'Datastore(s)'; e = { 
                try { (($_ | Get-Datastore -ErrorAction SilentlyContinue).Name -join ';') }
                catch { 'N/A' }
            }}
            @{n = 'ToolsStatus'; e = { ($_.ExtensionData.Guest.ToolsStatus | Out-String).Trim() } }
            @{n = 'IPAddress'; e = { 
                try { ($_.Guest.IPAddress | Where-Object { $_ } | ForEach-Object { $_ }) -join ';' }
                catch { 'N/A' }
            }}
            @{n = 'CreationDate'; e = { 
                try { $_.ExtensionData.Config.CreateDate } 
                catch { 'N/A' } 
            }}
            @{n = 'HardwareVersion'; e = { $_.Version } }
            @{n = 'FolderPath'; e = { 
                try { $_.Folder.Name } 
                catch { 'N/A' } 
            }}
            @{n = 'Notes'; e = { $_.Notes } }
        )
        
        $vmResults += $batchResults
        $batchNumber++
    }

    $vms = $vmResults
    Write-Log "VM inventory collection completed"

    # -------------------------
    # Collect Host Inventory
    # -------------------------
    Write-Log "Collecting Host inventory..."
    $hosts = Get-VMHost | Select-Object -Property @(
        'Name'
        @{n = 'ConnectionState'; e = { $_.ConnectionState } }
        @{n = 'Version'; e = { $_.Version } }
        @{n = 'Build'; e = { $_.Build } }
        @{n = 'CPUModel'; e = { $_.ProcessorType } }
        @{n = 'CPUCores'; e = { $_.NumCpu } }
        @{n = 'MemoryGB'; e = { [math]::Round($_.MemoryTotalGB, 2) } }
        @{n = 'NICs'; e = { (Get-VMHostNetworkAdapter -VMHost $_ -Physical | Measure-Object).Count } }
        @{n = 'vSwitches'; e = { (Get-VirtualSwitch -VMHost $_ | Measure-Object).Count } }
        @{n = 'vMotionEnabled'; e = { (Get-VMHostNetworkAdapter -VMHost $_ -VMKernel | Where-Object { $_.VMotionEnabled -eq $true } | Measure-Object).Count -gt 0 } }
        @{n = 'MgmtVMKernel'; e = { (Get-VMHostNetworkAdapter -VMHost $_ -VMKernel | Where-Object { $_.ManagementTrafficEnabled -eq $true } | Select-Object -ExpandProperty IP -ErrorAction SilentlyContinue) } }
        @{n = 'Manufacturer'; e = { 
            try { $_.ExtensionData.Hardware.SystemInfo.Vendor } 
            catch { 'N/A' } 
        }}
        @{n = 'Model'; e = { 
            try { $_.ExtensionData.Hardware.SystemInfo.Model } 
            catch { 'N/A' } 
        }}
        @{n = 'LicenseKey'; e = { 
            try { $_.ExtensionData.Config.Product.LicenseProductKey } 
            catch { 'N/A' } 
        }}
    )
    Write-Log "Host inventory collection completed: $($hosts.Count) hosts"

    # -------------------------
    # Collect Datastore Inventory
    # -------------------------
    Write-Log "Collecting Datastore inventory..."
    $ds = Get-Datastore | Select-Object -Property @(
        'Name', 'Type'
        @{n = 'CapacityGB'; e = { [math]::Round($_.CapacityGB, 2) } }
        @{n = 'FreeGB'; e = { [math]::Round($_.FreeSpaceGB, 2) } }
        @{n = 'UsedGB'; e = { [math]::Round(($_.CapacityGB - $_.FreeSpaceGB), 2) } }
        @{n = 'PctFree'; e = { [math]::Round(($_.FreeSpaceGB / [double]$_.CapacityGB) * 100, 2) } }
        @{n = 'Accessible'; e = { $_.ExtensionData.Summary.Accessible } }
        @{n = 'HostsMounted'; e = { 
            try { (Get-View $_.Id -ErrorAction SilentlyContinue).Host.Count } 
            catch { 'N/A' } 
        }}
    )
    Write-Log "Datastore inventory collection completed: $($ds.Count) datastores"

    # -------------------------
    # Generate Summary Statistics
    # -------------------------
    Write-Log "Generating summary statistics..."
    $totalVMMemory = ($vms | Measure-Object -Property MemoryGB -Sum).Sum
    $totalHostMemory = ($hosts | Measure-Object -Property MemoryGB -Sum).Sum
    $totalDSCapacity = ($ds | Measure-Object -Property CapacityGB -Sum).Sum
    $totalDSFree = ($ds | Measure-Object -Property FreeGB -Sum).Sum
    
    $summaryStats = @{
        TotalVMs = $vms.Count
        PoweredOnVMs = ($vms | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
        TotalHosts = $hosts.Count
        ConnectedHosts = ($hosts | Where-Object { $_.ConnectionState -eq 'Connected' }).Count
        TotalDatastores = $ds.Count
        AccessibleDatastores = ($ds | Where-Object { $_.Accessible -eq $true }).Count
        TotalVMMemoryGB = [math]::Round($totalVMMemory, 2)
        TotalHostMemoryGB = [math]::Round($totalHostMemory, 2)
        TotalDSCapacityGB = [math]::Round($totalDSCapacity, 2)
        TotalDSFreeGB = [math]::Round($totalDSFree, 2)
        DSFreePercentage = [math]::Round(($totalDSFree / $totalDSCapacity) * 100, 2)
    }

    # -------------------------
    # Export CSVs
    # -------------------------
    Write-Log "Exporting CSVs..."
    $vmCsv = Join-Path $RunDir 'VMs.csv'
    $hostCsv = Join-Path $RunDir 'Hosts.csv'
    $dsCsv = Join-Path $RunDir 'Datastores.csv'
    $summaryCsv = Join-Path $RunDir 'Summary.csv'

    $vms | Export-Csv -Path $vmCsv -NoTypeInformation -Encoding UTF8
    $hosts | Export-Csv -Path $hostCsv -NoTypeInformation -Encoding UTF8
    $ds | Export-Csv -Path $dsCsv -NoTypeInformation -Encoding UTF8
    $summaryStats.GetEnumerator() | Select-Object @{n='Metric';e={$_.Key}}, @{n='Value';e={$_.Value}} | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

    # -------------------------
    # Enhanced HTML Report
    # -------------------------
    Write-Log "Generating HTML report..."
    $html = @()
    $html += "<html>"
    $html += "<head>"
    $html += "<title>vSphere Inventory Report</title>"
    $html += "<style>"
    $html += "body { font-family: Arial, sans-serif; margin: 20px; }"
    $html += "h1 { color: #2c3e50; }"
    $html += "h2 { color: #34495e; border-bottom: 1px solid #bdc3c7; padding-bottom: 5px; }"
    $html += "table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }"
    $html += "th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }"
    $html += "th { background-color: #f2f2f2; }"
    $html += "tr:nth-child(even) { background-color: #f9f9f9; }"
    $html += ".summary { background-color: #e8f4f8; padding: 15px; border-radius: 5px; margin-bottom: 20px; }"
    $html += ".stat { font-weight: bold; color: #2c3e50; }"
    $html += "</style>"
    $html += "</head>"
    $html += "<body>"

    $html += "<h1>vSphere Inventory Report</h1>"
    $html += "<div class='summary'>"
    $html += "<h2>Environment Summary</h2>"
    $html += "<p><span class='stat'>vCenter:</span> $vCenter</p>"
    $html += "<p><span class='stat'>Generated:</span> $(Get-Date)</p>"
    $html += "<p><span class='stat'>Total VMs:</span> $($summaryStats.TotalVMs) ($($summaryStats.PoweredOnVMs) powered on)</p>"
    $html += "<p><span class='stat'>Total Hosts:</span> $($summaryStats.TotalHosts) ($($summaryStats.ConnectedHosts) connected)</p>"
    $html += "<p><span class='stat'>Total Datastores:</span> $($summaryStats.TotalDatastores) ($($summaryStats.AccessibleDatastores) accessible)</p>"
    $html += "<p><span class='stat'>Total VM Memory:</span> $($summaryStats.TotalVMMemoryGB) GB</p>"
    $html += "<p><span class='stat'>Total Host Memory:</span> $($summaryStats.TotalHostMemoryGB) GB</p>"
    $html += "<p><span class='stat'>Datastore Capacity:</span> $($summaryStats.TotalDSCapacityGB) GB ($($summaryStats.TotalDSFreeGB) GB free - $($summaryStats.DSFreePercentage)%)</p>"
    $html += "</div>"

    function ConvertTo-HtmlTable {
        param($Data, $Title)
        
        if ($null -eq $Data -or $Data.Count -eq 0) {
            return "<h2>$Title</h2><p><i>No data available</i></p>"
        }
        
        $htmlTable = "<h2>$Title</h2>"
        $htmlTable += $Data | ConvertTo-Html -Fragment
        return $htmlTable
    }

    $html += ConvertTo-HtmlTable -Data $vms -Title "Virtual Machines ($($vms.Count))"
    $html += ConvertTo-HtmlTable -Data $hosts -Title "ESXi Hosts ($($hosts.Count))"
    $html += ConvertTo-HtmlTable -Data $ds -Title "Datastores ($($ds.Count))"

    $html += "</body></html>"

    $htmlFile = Join-Path $RunDir 'Report.html'
    $html -join [Environment]::NewLine | Out-File -FilePath $htmlFile -Encoding UTF8

    # -------------------------
    # Completion
    # -------------------------
    Write-Log "Export completed:"
    Write-Log "  CSV: $vmCsv"
    Write-Log "  CSV: $hostCsv"
    Write-Log "  CSV: $dsCsv"
    Write-Log "  CSV: $summaryCsv"
    Write-Log "  HTML: $htmlFile"

    Disconnect-VIServer -Server $vCenter -Confirm:$false | Out-Null
    Write-Log "Disconnected from vCenter."

    $duration = (Get-Date) - $script:StartTime
    Write-Log "=== vSphere Inventory: SUCCESS in $([math]::Round($duration.TotalMinutes, 1)) minutes ==="
    
    # Display summary
    Write-Host "`n" + "="*50
    Write-Host "INVENTORY SUMMARY" -ForegroundColor Green
    Write-Host "="*50
    Write-Host "Virtual Machines: $($summaryStats.TotalVMs) ($($summaryStats.PoweredOnVMs) powered on)"
    Write-Host "ESXi Hosts: $($summaryStats.TotalHosts) ($($summaryStats.ConnectedHosts) connected)"
    Write-Host "Datastores: $($summaryStats.TotalDatastores) ($($summaryStats.AccessibleDatastores) accessible)"
    Write-Host "Total VM Memory: $($summaryStats.TotalVMMemoryGB) GB"
    Write-Host "Datastore Free Space: $($summaryStats.DSFreePercentage)%"
    Write-Host "Report Location: $RunDir"
    Write-Host "="*50
    
    exit 0
}
catch {
    Write-Log "SCRIPT ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
    
    try { 
        Disconnect-VIServer -Server $vCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null 
        Write-Log "Disconnected from vCenter during error cleanup." "WARN"
    } 
    catch { 
        Write-Log "Failed to disconnect from vCenter: $($_.Exception.Message)" "WARN"
    }
    
    exit 1
}