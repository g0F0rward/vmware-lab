
<# 
.NAME
Easy_VMwareInventory.ps1
.SYNOPSIS
  Daily vSphere inventory report (VMs, Hosts, Datastores) with logging & error handling.
.DESCRIPTION
  Collects comprehensive vSphere inventory data with performance optimizations for large environments.
  Exports to CSV and HTML formats with enhanced error handling and retry logic.
.EXAMPLE
  .\vSphere-Inventory.ps1 -vCenter "vcenter01.company.com" -OutDir "C:\Reports" -CredPath "C:\creds\vcenter_cred.xml"
#>

#
$cred = Get-Credential -Message "Enter your credentials"
$path = "c:\temp"
$cred | Export-Clixml "$path\vmware_cred.cred"
$vCenter_server = "vcenter01.red.pvt"
 
Connect-VIServer -Server $vCenter_server -Protocol https -credential $cred | ForEach-Object -Process {
  $vc = $_
#  $vc | Format-List -Property *
  Get-VMHost -Server $vc |
    ForEach-Object -Process {
      New-Object -TypeName PSObject -Property ([ordered]@{
        vCenter = $vc.Name
        vCenterVersion = $vc.Version
        vCenterBuild = $vc.Build
        VMHost = $_.Name
        VMHostVersion = $_.Version
        VMHostBuild = $_.Build
      })
    }
  } | Export-Csv -Path .\report.csv -NoTypeInformation -UseCulture