# These PS commands and functions are my notes to help manage a VMWare environment using PowerShell
# Please do not have the expectation that they will work in your environment without modification.
# Do not run this as a script!! 

# When running PowerShell ISE, run this command to initiate all the PowerCLI commandlets 
. "C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1"

# Setup credentials and connect to vCenter server
$cred1 = Get-Credential
$Server1 = "vcenter1"
Connect-VIServer -Server $Server1 -Credential $cred1

# Setup credentials and connect to a second vCenter server
# If connected to multiple vCenter servers you will likely need the -server options in most PowerCLI commands
$cred2 = Get-Credential
$Server2 = "vcenter2"
Connect-VIServer -Server $Server2 -Credential $cred2



## Create a new VM from a template in content library
$cLibItem = Get-ContentLibraryItem -Name linux-vyos-1.1.7-template
new-vm -Name $VMName -Location $Location -Datastore $DataStore -ResourcePool $ResPool -ContentLibraryItem $cLibItem

# List all VMs on esxi-1
Get-VM -Location esxi-1
# That are powered on
Get-VM -Location esxi-1 | Where-Object { $_.PowerState -eq "poweredon"}
# That match a VM Name
Get-VM -Location esxi-1 | Where-Object { $_.PowerState -eq "poweredon" -and $_.Name -match $VMName}


# Move all powered on VMs from esxi-1 to esxi-2
Get-VM -Location esxi-1 | Where-Object { $_.PowerState -eq "poweredon"} | ForEach-Object {Move-VM -VM $_ -Destination esxi-2}

# Get all port groups on a server
get-vdportgroup -server $Server2 

# Get DSwitches on a server
Get-VDSwitch -server $Server2
$Switch = Get-VDSwitch -server $Server2

# Get all port groups on a VDSwitch 
Get-VDPortgroup -server $Server2 -vdswitch $Switch | Select-Object Name,VlanConfiguration

# Get all VLAN IDs used on a VDSwitch - unique
$vlanList = Get-VirtualPortGroup -Server $Server1,$Server2 | Select-Object @{N="VLANId";E={$_.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId}} -Unique | Where-Object {$_.VLANId -match '^\d*$'}

# Function to product list of 10 vlans that are open
# This is useful when creating multiple port groups and you need to find open VLANs
function Get-Vlans ([int]$num = 10) {
   $vlanList = Get-VDPortGroup -Server $Server1,$Server2 | Select-Object @{N="VLANId";E={$_.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId}} -Unique | Where-Object {$_.VLANId -match '^\d*$'}
   [System.Collections.ArrayList]$vlans = 500..700
   ForEach ($v in $vlanList) {
      if ($vlans -contains $v.VLANId) {
      $vlans.remove($v.VLANId)
      }
   }
   $retVlans = $vlans | select -First $num
   return $retVlans
}

# Function to List VM's connected to a VDPortGroup
function Get-VM-by-VDPortGroup($VDPG) {
get-vm | Get-NetworkAdapter | ForEach-Object {
  if ($_.NetworkName -eq $VDPG) {
      Write-Host $_.parent.name
  }
}
}


# When moving esx-i servers from one vCenter server to another sometimes a lot of the configuration is lost.
# This happens when, for example, a vCenter server is being decommissioned yet the esx-i server, with associated VMs,
# needs to be kept. VNICs, VM Folders, Resource Groups will not be transfered over. The following commands are used
# to configure vCenter server (server1) the same as the old vCenter server (server2)

# Template for moving VMs on server1 into the destination structure found on server2
# Used for folders, resource groups and vApps
get-vm -server $server2 | ForEach-Object {
    if ($_.folder) {
        $vm = get-vm -server $server1 -name $_.name
        $dest = get-folder -server $server1 -name $_.folder.name
        move-vm -server $server1 -vm $vm -Destination $dest
        }
}


# Get a list of folders from server2 and create the same list of folders on server1
get-folder -server $server2 -type vm | foreach-object {
if ($_.name -ne "vm") {new-folder -server $server1 -location "vm" -name $_.name}
}

# Rebuild the parent/child folder structure
get-folder -server $server2 -type VM | foreach-object {
$Parent = $_.Parent.name
if ($Parent -eq "ENV1") { $Parent = "ENV2" }
$Folder = $_.name
if ($Folder -ne "vm") {move-folder -server $server1 -folder $Folder -Destination $Parent}
}

# Move all VMs on server1 into the folder they used to be in on server2
get-vm -server $server2 | foreach-object {
$Folder = $_.Folder
$VM = $_.name
#move-vm -server $server1 -vm $VM -Destination $Folder
write-host $VM,":",$Folder
}


# Reset VM NIC's to old vCenter Server
get-vm -server $Server2 | foreach-object {
     $VM_old = $_
     $VNICS_old = $VM_old | get-networkadapter 
     $VM_new = get-vm -server $Server1 -name $VM_old.name
     $VNICS_old |foreach-object {
          $VNIC_new = get-networkadapter -VM $VM_new -Server $Server1 -name $_.Name
          write-host $VM_new.name,$_.name,$VNIC_new.networkname,"->",$_.networkname
          get-networkadapter -VM $VM_new -Server $Server1 -name $_.Name | Set-NetworkAdapter -portgroup $_.networkname -server $server1 -confirm:$False -RunAsync 
          }
} 


# Rebuild resource pool structure
get-vm -server $server2 | foreach-object {
$rp = $_.ResourcePool.name
$name = $_.name

write-host $name," -> " , $rp
if ($rp) {  $dest = get-resourcepool -server $server1 -name $rp
            move-vm -server $server1 -vm $name -location $dest 
          }
}


# Rebuid vApp structure
get-vm -server $server2 | foreach-object {
    if ($_.vapp) {
         $dest = get-vapp -server $server1 -name $_.vapp.name
         move-vm -server $server1 -vm $_.name -Destination $dest
         #write-host $_.name, $dest
    }
}




# Clone a VM
new-vm -Name $NewVM -VM $TemplateVM -Location $Location -Datastore $DS -ResourcePool $ResPool -RunAsync

# Clone a VM several times; need to define $Location, $ResPool, and names for datastores
$TemplateVM = "vm_Template"
for ($i=1; $i -le 5; $i++) {
$NewVM = "vm_" + $i
# Alternate between datastores DS1 and DS2
$DS = "DS" + (($i % 2) + 1)
new-vm -Name $NewVM -VM $TemplateVM -Location $Location -Datastore $DS -ResourcePool $ResPool -RunAsync
}


# Set Network adapter on several VMs
for ($i=1; $i -le 5; $i++) {
$VM = "vm_" + $i
get-vm $VM | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $PGroup -Confirm:$False -RunAsync
}

# Start several VMs 
for ($i=1; $i -le 5; $i++) {
$VM = "vm_" + $i
Start-vm $VM
}

# Sysprep several Windows VMs (not fully tested)          
for ($i=4; $i -le 5; $i++) {
$VM = "vm_" + $i
Invoke-VMScript -VM $VM -ScriptText "C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /reboot /quiet" -GuestUser "administrator" -GuestPassword "PASSWORD"
}

# Set network adapter across multiple Debian Linux VMs by using VMWare tools and Invoke-VMScript
for ($i=2; $i -le 10; $i++) {

$VM = "vm_Debian_" + $i 
#$ip_cmd = "/bin/echo address 172.16.1." + $i >> /etc/network/interfaces"
#$route_cmd = "/bin/echo gateway 172.16.1.1" >> /etc/network/interfaces"
#$ifcfg = "/sbin/ifconfig eth0 172.16." + $i + "/24"
#$route_cfg = "/sbin/ip route add default via 172.16.1.1"
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo "" >> /etc/network/interfaces'
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo auto eth0 >> /etc/network/interfaces'
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo iface eth0 inet static >> /etc/network/interfaces' 
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText $ip_cmd 
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo netmask 255.255.255.0 >> /etc/network/interfaces'
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText $route_cmd
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo dns-nameservers 172.16.1.1 >> /etc/network/interfaces'
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/bin/echo nameserver 172.16.1.1 > /etc/resolv.conf'
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText $ifcfg
#Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText $route_cfg
# Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText '/usr/bin/apt install resolvconf'
# Invoke-VMScript -VM $VM -GuestUser "root" -GuestPassword "PASSWORD" -ScriptText 'init 6'
}


# Create X DSwitch Port Groups
for ($i=2 ; $i -le 5 ; $i++) {
$VlanName = "net_Access" + $i + "Core_07"
$VlanID = 570 + $i
New-VDPortgroup -vdswitch DSwitch -Name $VlanName -VlanID $VlanID -RunAsync -Confirm:$false
}




# vCenter/vSphere License Management through PS
$servInst = Get-View ServiceInstance
$licMgr = Get-View $servInst.Content.licenseManager
$licAssignMgr = Get-View $licMgr.licenseAssignmentManager
 
function Get-LicenseKey($LicName)
{
    $licenses = $licMgr.Licenses | where {$_.Name -eq $LicName}
    foreach ($license in $licenses) {
            if ( (($license.Total - $license.Used) -ne "0") -or (($license.Total - $license.Used) -lt "0") )  {
                return $license.LicenseKey
                break
            }
    }
}
 
function Get-VMHostId($Name)
{
    $vmhost = Get-VMHost $Name | Get-View
    return $vmhost.Config.Host.Value
}
 
function Set-LicenseKey($VMHostId, $LicKey, $Name)
{
    $license = New-Object VMware.Vim.LicenseManagerLicenseInfo
    $license.LicenseKey = $LicKey
    $licAssignMgr.UpdateAssignedLicense($VMHostId, $license.LicenseKey, $Name)
}
 
function Get-License($VMHostId)
{
    $details = @()
    $detail = "" |select LicenseKey,LicenseType,Host
    $license = $licAssignMgr.QueryAssignedLicenses($VMHostId)
    $license = $license.GetValue(0)
    $detail.LicenseKey = $license.AssignedLicense.LicenseKey
    $detail.LicenseType = $license.AssignedLicense.Name
    $detail.Host = $license.EntityDisplayName
    $details += $detail
    return $details
}