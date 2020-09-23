# Example: tag_batch myrg Microsoft.Network/vpnSites mytag myvalue
function tag_type {
    rg=$1
    resource_type=$2
    tag_key=$3
    tag_value=$4
    echo "Getting $resource_type resources in resource group $rg..."
    resource_id_list=$(az resource list -g $rg --resource-type "$resource_type" --query '[].id' -o tsv)
    if [[ -n "$resource_id_list" ]]; then
        while IFS= read -r resource_id; do
            echo "Tagging resource $resource_id with $tag_key:$tag_value..."
            az resource tag -i --ids $resource_id --tags $tag_key=$tag_value >/dev/null
        done <<< "$resource_id_list"
    else
        echo "No $resource_type resources found in resource group $rg"
    fi
}

tag_rg=vwanlab2
mytag_key=test
tag_type $rg 'Microsoft.Network/vpnSites' $mytag_key 'vpnsite'
tag_type $rg 'Microsoft.Network/virtualHubs' $mytag_key 'hub'
tag_type $rg 'Microsoft.Network/vpnGateways' $mytag_key 'vpngw'
tag_type $rg 'Microsoft.Network/azureFirewalls' $mytag_key 'fw'
tag_type $rg 'Microsoft.Network/virtualWans' $mytag_key 'vwan'
tag_type $rg 'Microsoft.Network/firewallPolicies' $mytag_key 'fwpolicy'
tag_type $rg 'Microsoft.OperationalInsights/workspaces' $mytag_key 'log'