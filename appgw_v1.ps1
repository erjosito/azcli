# Environment generic variables
$location = "eastus2"
$rg = "josetest-appgwv1"
$vnet_name = "josetest-vnet"
$vnet_prefix = "192.168.0.0/16"
# AppGW variables
$appgw_name = "appgwv1-WAFMedium"
$appgw_sku = "WAF_Medium"      # Allowed values: Standard_Large, Standard_Medium, Standard_Small, Standard_v2, WAF_Large, WAF_Medium, WAF_v2.  Default: Standard_Medium.
$subnet_name = $appgw_name
$subnet_prefix = "192.168.3.0/24"
$pip_name = $appgw_name + "-pip"
# Migrated AppGwv2 variables
$appgwv2_name = "appgwv2"
$subnetv2_name = $appgwv2_name
$subnetv2_prefix = "192.168.5.0/24"

# Create environment
echo "Creating RG and VNet..."
az group create -n $rg -l $location -o none
az network vnet create -n $vnet_name -g $rg --address-prefix $vnet_prefix -o none

# Create AppGW v1
echo "Application Gateway v1..."
az network vnet subnet create --vnet-name $vnet_name -n $subnet_name --address-prefixes $subnet_prefix -g $rg -o none
az network public-ip create -n $pip_name -g $rg --sku Basic -o none
az network application-gateway create -n $appgw_name -g $rg --sku $appgw_sku --public-ip-address $pip_name --vnet-name $vnet_name --subnet $subnet_name --frontend-port 80 --http-settings-port 80 --http-settings-protocol "Http" --routing-rule-type "Basic" --servers "1.2.3.4" -o none
az network application-gateway stop -n $appgw_name -g $rg -o none

# Create AppGW v2 (the rule priority argument is required)
# az network vnet subnet create --vnet-name $vnet_name -n $subnet_name --address-prefixes $subnet_prefix -g $rg -o none
# az network public-ip create -n $pip_name -g $rg --sku Standard -o none
# az network application-gateway create -n $appgw_name -g $rg --sku $appgw_sku --public-ip-address $pip_name --vnet-name $vnet_name --subnet $subnet_name --frontend-port 80 --http-settings-port 80 --http-settings-protocol "Http" --routing-rule-type "Basic" --servers "1.2.3.4" --priority 1000 -o none
# az network application-gateway stop -n $appgw_name -g $rg -o none

####################
# Migrate v1 to v2 #
####################

# Script installation errors out if Az modules installed?? (works for me!)
if (Get-InstalledScript -Name "AzureAppGWMigration") {
    echo "Updating migration script..."
    Update-Script -Name AzureAppGWMigration
} else {
    echo "Installing migration script..."
    Install-Script -Name AzureAppGWMigration
}

# Manual installation
# $nupkg_url = "https://www.powershellgallery.com/api/v2/package/AzureAppGWMigration/1.0.11"
# $nupkg_path = "C:\Users\jomore\Downloads\azureappgw-migration.1.0.11.nupkg"
# $script_folder = "C:\Users\jomore\Downloads"
# $script_name = "AzureAppGWMigration.ps1"
# $script_path = $script_folder + "\" + $script_name
# Invoke-WebRequest -Uri $nupkg_url -OutFile $nupkg_path
# Unblock-File -Path $nupkg_path
# Expand-Archive -Path $nupkg_path -Destination $script_folder
# cd $script_folder

#

# Get some values first
az network vnet subnet create --vnet-name $vnet_name -n $subnetv2_name --address-prefixes $subnetv2_prefix -g $rg -o none
$appgw = Get-AzApplicationGateway -Name $appgw_name -ResourceGroupName $rg

# Create PIP
$appgw2_pip_name = "appgw2-pip"
$ip = @{
    Name = $appgw2_pip_name
    ResourceGroupName = $rg
    Location = $location
    Sku = 'Standard'
    AllocationMethod = 'Static'
    IpAddressVersion = 'IPv4'
    Zone = 1,2,3
}
$appgw2_pip = New-AzPublicIpAddress @ip


# https://learn.microsoft.com/en-us/azure/application-gateway/migrate-v1-v2
AzureAppGWMigration -resourceId $appgw.Id `
                    -subnetAddressRange $subnetv2_prefix `
                    -PublicIpResourceId $appgw2_pip.Id `
                    -appgwName $appgwv2_name `
                    -AppGwResourceGroupName $rg `
                    -validateMigration -enableAutoScale

# Errors:
# 1. Az.Resources missing