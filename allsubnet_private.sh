#!/bin/zsh
# Get the vnet list
vnet_list=$(az network vnet list --query "[].id" -o tsv)
echo "$(echo $vnet_list | wc -l) vnets found"
# Process line by line
echo "$vnet_list" | while IFS= read -r vnet; do
    echo "Processing VNet $vnet..."
    # Get the vnet name
    vnet_name=$(az network vnet show --id $vnet --query "name" -o tsv)
    # Get the resource group name
    rg_name=$(az network vnet show --id $vnet --query "resourceGroup" -o tsv)
    # Get the subnet list
    subnet_list=$(az network vnet subnet list --vnet-name $vnet_name -g $rg_name --query "[].name" -o tsv)
    echo "$(echo $subnet_list | wc -l) subnets found"
    # Process line by line
    echo "$subnet_list" | while IFS= read -r subnet; do
        echo " - Processing subnet $subnet in VNet $vnet_name..."
        # Disable outbound access
        echo "   * Disabling outbound access in subnet $subnet..."
        az network vnet subnet update -n $subnet --vnet-name $vnet_name -g $rg_name --default-outbound false -o none
        # Get current status
        featureStatus=$(az network vnet subnet show -n $subnet --vnet-name $vnet_name -g $rg_name --query defaultOutboundAccess -o tsv)
        echo "   * Outbound access status in subnet $subnet is now $featureStatus"
        # if [[ "$featureStatus" -eq "false" ]]; then
        #     echo " - Outbound access already disabled in subnet $subnet, status is $featureStatus"
        # else
        #     echo " - Disabling outbound access in subnet $subnet..."
        #     az network vnet subnet update -n $subnet --vnet-name $vnet_name -g $rg_name --default-outbound false -o none
        # fi
    done
done