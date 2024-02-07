# Environment generic variables
$location = "eastus2"
$rg = "josetest-appgwv1"
$vnet_name = "josetest-vnet"
$vnet_prefix = "192.168.0.0/16"

# Create environment
az group create -n $rg -l $location -o none
az network vnet create -n $vnet_name -g $rg --address-prefix $vnet_prefix -o none

# AppGW-specific variables
$appgw_name = "appgwv1-Standard-v2"
$appgw_sku = "Standard_v2"      # Allowed values: Standard_Large, Standard_Medium, Standard_Small, Standard_v2, WAF_Large, WAF_Medium, WAF_v2.  Default: Standard_Medium.
$subnet_name = $appgw_name
$subnet_prefix = "192.168.3.0/24"
$pip_name = $appgw_name + "-pip"

# Create AppGW v1
az network vnet subnet create --vnet-name $vnet_name -n $subnet_name --address-prefixes $subnet_prefix -g $rg -o none
az network public-ip create -n $pip_name -g $rg --sku Basic -o none
az network application-gateway create -n $appgw_name -g $rg --sku $appgw_sku --public-ip-address $pip_name --vnet-name $vnet_name --subnet $subnet_name --frontend-port 80 --http-settings-port 80 --http-settings-protocol "Http" --routing-rule-type "Basic" --servers "1.2.3.4" -o none
az network application-gateway stop -n $appgw_name -g $rg -o none

# Create AppGW v2
az network vnet subnet create --vnet-name $vnet_name -n $subnet_name --address-prefixes $subnet_prefix -g $rg -o none
az network public-ip create -n $pip_name -g $rg --sku Standard -o none
az network application-gateway create -n $appgw_name -g $rg --sku $appgw_sku --public-ip-address $pip_name --vnet-name $vnet_name --subnet $subnet_name --frontend-port 80 --http-settings-port 80 --http-settings-protocol "Http" --routing-rule-type "Basic" --servers "1.2.3.4" --priority 1000 -o none
az network application-gateway stop -n $appgw_name -g $rg -o none
