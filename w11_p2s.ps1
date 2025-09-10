################################################################
# This script will import CA certs and create P2S tunnel.
# The certs need to be in the Downloads folder.
# See the script strongswan_p2s.azcli for details on how to 
#     create the certs in a strongswan server.
#
# This script needs admin privileges to run.
#
# Jose Moreno, August 2025
################################################################

# Variables for StrongSwan P2S VPN
$rg = "strongswan"
$vm_name = "strongswan"
$org = "cloudtrooper.net"
$vm_fqdn = "$vm_name.$org"
$username = "jose"
$akv_name = "cloudtrooper-vault"
$secret_name = "psk"
$full_username = "$username@$vm_fqdn"
$connection_name = "StrongSwanPWSH"

# Get public IP of the VM
$nic_id = $(az vm show -g $rg -n $vm_name --query 'networkProfile.networkInterfaces[0].id' -o tsv)
$vm_public_ip_id = $(az network nic show --ids $nic_id --query 'ipConfigurations[0].publicIPAddress.id' -o tsv)
$vm_public_ip = $(az network public-ip show --ids $vm_public_ip_id --query 'ipAddress' -o tsv)
Write-Host "Public IP of the VM ($vm_fqdn): $vm_public_ip"

# Get the pre-shared key from Azure Key Vault
$psk = $(az keyvault secret show --name $secret_name --vault-name $akv_name --query 'value' -o tsv)
if (-not $psk) {
    Write-Host "Pre-shared key not found in Key Vault. Please ensure the secret '$secret_name' exists in Key Vault '$akv_name'."
} else {
    Write-Host "Pre-shared key retrieved successfully."
}

# Update hosts file
$hostsFilePath = "C:\Windows\System32\drivers\etc\hosts"
$newentry = "$vm_public_ip`t$vm_fqdn"
$hostsContent = Get-Content -Path $hostsFilePath
$updatedContent = $hostsContent | Where-Object { $_ -notmatch [regex]::Escape($vm_fqdn) }
$updatedContent += "$newentry"
$updatedContent | Set-Content -Path $hostsFilePath -Force

# Add cert
Import-Certificate -FilePath "$env:USERPROFILE/Downloads/caCert.pem" -CertStoreLocation "Cert:\LocalMachine\Root"

# Remove existing VPN connection if it exists
$existingVpn = Get-VpnConnection -Name "StrongSwan" -ErrorAction SilentlyContinue
if ($existingVpn) {
    Write-Host "Removing existing VPN connection 'StrongSwan'..."
    Remove-VpnConnection -Name "StrongSwan" -Force
} else {
    Write-Host "No existing VPN connection 'StrongSwan' found."
}

# Add VPN connection
Write-Host "Adding VPN connection 'StrongSwan'..."
$credential = New-Object System.Management.Automation.PSCredential ("$full_username", (ConvertTo-SecureString "$psk" -AsPlainText -Force))
Add-VpnConnection -Name $connection_name -ServerAddress "${vm_fqdn}" -TunnelType "Ikev2" -EncryptionLevel "Required" -AuthenticationMethod "Eap" -RememberCredential

# Connect (NOT WORKING YET!!!)
$psk_secure = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $psk -AsPlainText -Force)))
$code = (Start-Process rasdial -NoNewWindow -ArgumentList "$connection_name $full_username $psk_secure" -PassThru -Wait).ExitCode   
if ("$code" -eq "0") {
    Write-Host "Create and connect to VPN server success" -ForegroundColor DarkGreen

    return $true
} else {
    # Error codes: https://support.microsoft.com/en-us/help/824864/list-of-error-codes-for-dial-up-connections-or-vpn-connections
    if ("$code" -eq "691") {
        Write-Host "Create and connect to VPN server failed with wrong username or password" -ForegroundColor DarkRed

        return $false # return and try againg
    } else {
        Write-Host "Create and connect to VPN server failed with error code: $($code)" -ForegroundColor DarkRed
        
        throw "$code"
    }

}