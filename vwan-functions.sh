############################################################################
# Created by Jose Moreno
# May 2020
#
# Contains functions to manage VWAN using the 2020-05-01 APIs for custom routing
# Support for up to 3 locations.
############################################################################

# Variables
# rg=vwantest         # RG to be defined in the main function
# vwan_name=vwantest  # RG to be defined in the main function
location1=westeurope
location2=westcentralus
location3=uksouth
password=Microsoft123!  # Used as IPsec PSK too
publisher=cisco
offer=cisco-csr-1000v
sku=16_12-byol
version=$(az vm image list -p $publisher -f $offer -s $sku --all --query '[0].version' -o tsv)
nva_size=Standard_B2ms
vm_size=Standard_B1ms
logws_name=log$RANDOM
azfw_policy_name=vwan

#####################
#   JSON snippets   #
#####################

# REST Variables
vwan_api_version=2020-05-01
subscription_id=$(az account show --query id -o tsv)
# JSON
vwan_json='{location: $location, properties: {disableVpnEncryption: false, type: $sku}}'
vhub_json='{location: $location, properties: {virtualWan: {id: $vwan_id}, addressPrefix: $hub_prefix, sku: $sku}}'
vpnsitelink_json='{name: $link_name, properties: {ipAddress: $remote_pip, bgpProperties: {bgpPeeringAddress: $remote_bgp_ip, asn: $remote_asn}, linkProperties: {linkProviderName: "vendor1", linkSpeedInMbps: 100}}}'
vpnsite_json='{location: $location, properties: {virtualWan: {id: $vwan_id}, addressSpace: { addressPrefixes: [ $site_prefix ] }, isSecuritySite: $security, vpnSiteLinks: [ '${vpnsitelink_json}']}}'
cx_json='{name: $cx_name, properties: {connectionBandwidth: 200, vpnConnectionProtocolType: "IKEv2", enableBgp: true, sharedKey: $psk, vpnSiteLink: {id: $site_link_id}}}'
vpncx_json='{properties: {enableInternetSecurity: true, remoteVpnSite: {id: $site_id}, vpnLinkConnections: ['$cx_json']}}'
vpngw_json='{location: $location, properties: {virtualHub: {id: $vhub_id}, connections: [], bgpSettings: {asn: $asn, peerWeight: 0}}}'
vnet_cx_json='{properties: {remoteVirtualNetwork: {id: $vnet_id}, enableInternetSecurity: true}}'
rt_json='{properties: {routes: [], labels: []}}'
route_json='{name: $name, destinationType: "CIDR", destinations: [ $prefixes ], nextHopType: $type, nextHop: $nexthop }'
cxroute_json='{name: $name, addressPrefixes: [ $prefixes ], nextHopIpAddress: $nexthop }'


###############
#   Aliases   #
###############

alias remote="ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no"

####################
#  Wait functions  #
####################

wait_interval=5

function wait_until_finished {
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo "Waiting for resource $resource_name to finish provisioning..."
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
        echo "Something really bad happened..."
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        # echo "Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}

function wait_until_csr_finished {
    branch_id=$1
    wait_interval_csr=30    # longer wait interval, since this is quite verbose
    echo "Waiting until CSR in branch${branch_id} is reachable..."
    # Wait until getting an IP
    branch_ip=$(az network public-ip show -n "branch${branch_id}-pip" -g $rg --query ipAddress -o tsv 2>/dev/null)
    until [[ -n "$branch_ip" ]]
    do
        sleep $wait_interval_csr
        branch_ip=$(az network public-ip show -n "branch${branch_id}-pip" -g $rg --query ipAddress -o tsv 2>/dev/null)
    done
    # Wait until getting SSH output
    command="sho ver | i uptime"
    command_output=$(remote $branch_ip "$command" 2>/dev/null)
    until [[ -n "$command_output" ]]
    do
        sleep $wait_interval_csr
        command_output=$(remote $branch_ip "$command")
    done
    echo "CSR is live, output to the command \"$command\" is $command_output"
}

function wait_until_hub_finished {
    hub_name=$1
    hub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    wait_until_finished $hub_id
    # Check state of connections
    # echo "Hub state is $(get_vhub_state $hub_name), checking connections..."
    connections=$(get_vnetcx_state $hub_name | grep Updating)
    until [[ -z "$connections" ]]
    do
        sleep $wait_interval
        connections=$(get_vnetcx_state $hub_name | grep Updating)
    done
    # Check state of route tables
    # echo "No connections in Updating state in hub $hub_name, checking route tables..."
    rts=$(get_rt_state $hub_name | grep Updating)
    until [[ -z "$rts" ]]
    do
        sleep $wait_interval
        rts=$(get_rt_state $hub_name | grep Updating)
    done
}

function wait_until_gw_finished {
    gw_name=$1
    # It can be that we do not get a valid GW ID at the first try
    echo "Finding out ID for VPN gateway $gw_name..."
    gw_id=$(az network vpn-gateway show -n $gw_name -g $rg --query id -o tsv)
    while [[ -z "$gw_id" ]]
    do
        sleep $wait_interval
        gw_id=$(az network vpn-gateway show -n $gw_name -g $rg --query id -o tsv)
    done
    wait_until_finished $gw_id
}

# Get JSON for a hub or all hubs
function get_vhub {
    hub_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}?api-version=$vwan_api_version"
    if [[ -z "${hub_name}" ]]
    then
        az rest --method get --uri $uri | jq '.value'
    else
        az rest --method get --uri $uri | jq
    fi
}

# Get provisioningState for a hub or all hubs
function get_vhub_state {
    hub_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}?api-version=$vwan_api_version"
    if [[ -z "${hub_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.provisioningState'
    fi
}

# Print a list of virtual hubs to iterate over it
function list_vhub {
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs?api-version=$vwan_api_version"
    az rest --method get --uri $uri | jq -r '.value[].name'
}


# Get JSON for a vnet connection or all vnet connections in a hub
function get_vnetcx {
    hub_name=$1
    cx_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    if [[ -z "${cx_name}" ]]
    then
        az rest --method get --uri $uri | jq '.value'
    else
        az rest --method get --uri $uri | jq
    fi
}

# Get provisioningState for a vnet cx in a hub or all vnet cx in a hub
function get_vnetcx_state {
    hub_name=$1
    cx_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    if [[ -z "${cx_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.provisioningState'
    fi
}

# List vnet connections
function list_vnetcx {
    hub_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/?api-version=$vwan_api_version"
    az rest --method get --uri $uri | jq -r '.value[].name' 2>/dev/null
}

# Get JSON for a hubRT or all hubRTs
function get_rt {
    hub_name=$1
    rt_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    if [[ -z "${rt_name}" ]]
    then
        az rest --method get --uri $uri | jq '.value'
    else
        az rest --method get --uri $uri | jq
    fi
}

# Get provisioningState for a hubRT or all hubRTs
function get_rt_state {
    hub_name=$1
    rt_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    if [[ -z "${rt_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.provisioningState'
    fi
}

# Get provisioningState for a hubRT or all hubRTs
function list_rt {
    hub_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables?api-version=$vwan_api_version"
    az rest --method get --uri $uri | jq -r '.value[].name'
}

# Get JSON for a vpngw or all vpngw
function get_vpngw {
    gw_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [[ -z "${gw_name}" ]]
    then
        az rest --method get --uri $uri | jq '.value'
    else
        az rest --method get --uri $uri | jq
    fi
}

# Get provisioningState for a VPN GW or all VPN GWs
function get_vpngw_state {
    gw_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [[ -z "${gw_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.provisioningState'
    fi
}

# Get VPN gateway ID for a certain hub
function get_vpngw_id {
    hub_id=$1
    az network vhub show -n hub${hub_id} -g $rg --query vpnGateway.id -o tsv
}

# Get VPN gateway ID for a certain hub
function get_azfw_id {
    hub_id=$1
    az network firewall show -n azfw${hub_id} -g $rg --query id -o tsv
}

# Get VPN gateway ID for a certain hub
function get_vnetcx_id {
    hub_id=$1
    spoke_id=$2
    cx_name="spoke${hub_id}${spoke_id}"
    hub_name=hub${hub_id}
    az network vhub connection show -n $cx_name --vhub-name $hub_name -g $rg --query id -o tsv
}


# List all VPN gateways (to iterate over them afterwards)
function list_vpngw {
    gw_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways?api-version=$vwan_api_version"
    az rest --method get --uri $uri | jq -r '.value[].name'
}

# Get BGP info for a VPN GW or all VPN GWs
function get_vpngw_bgp {
    gw_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [[ -z "${gw_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.bgpSettings})'
    else
        az rest --method get --uri $uri | jq -r '.properties.bgpSettings'
    fi
}

# Get VPN connections
function get_vpngw_cx {
    gw_name=$1
    cx_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [[ -z "${cx_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.properties.connections'
    else
        az rest --method get --uri $uri | jq -r '.properties.connections[] | select (.name == "'$cx_name'")'
    fi
}

# Get VPN connections state
function get_vpngw_cx_state {
    gw_name=$1
    cx_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [[ -z "${cx_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.properties.connections | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.connections[] | select (.name == "'$cx_name'") | .properties.provisioningState'
    fi
}

# Get JSON for a VPN site or all VPN sites
function get_vpnsite {
    site_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnSites/${site_name}?api-version=$vwan_api_version"
    if [[ -z "${site_name}" ]]
    then
        az rest --method get --uri $uri | jq '.value'
    else
        az rest --method get --uri $uri | jq
    fi
}

# Get provisioningState for a VPN site or all VPN sites
function get_vpnsite_state {
    site_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnSites/${site_name}?api-version=$vwan_api_version"
    if [[ -z "${site_name}" ]]
    then
        az rest --method get --uri $uri | jq -r '.value | map({name, provisioningState: .properties.provisioningState})'
    else
        az rest --method get --uri $uri | jq -r '.properties.provisioningState'
    fi
}

#################
#       RT      #
#################

# Create Route Table (aka hubRouteTable)
# https://docs.microsoft.com/en-us/rest/api/virtualwan/hubroutetables/createorupdate
function create_rt {
    hub_name=$1
    rt_name=$2
    rt_label=$3
    rt_json_string=$(jq -n \
            $rt_json)
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    if [[ -n "$rt_label" ]]
    then
        rt_json_string=$(echo $rt_json_string | jq '.properties.labels += [ "'$rt_label'" ] | {name, properties}')
    fi
    echo "Creating route in ${hub_name}/${rt_name}..."
    wait_until_hub_finished $hub_name
    az rest --method put --uri $rt_uri --body $rt_json_string >/dev/null
}

# Delete rt
function delete_rt {
    hub_name=$1
    rt_name=$2
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    az rest --method delete --uri $rt_uri
}

# Update vnet connection associated RT
function cx_set_ass_rt {
    hub_name=$1
    cx_name=$2
    new_rt_name=$3
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    new_rt_id="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${new_rt_name}"
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.associatedRouteTable.id = "'$new_rt_id'" | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated >/dev/null
    # az rest --method get --uri $cx_uri | jq '.properties.routingConfiguration.associatedRouteTable.id'
}

# Update vnet connection propagated RT
# Example: cx_set_prop_rt hub1 spoke1 redRT,defaultRouteTable
function cx_set_prop_rt {
    hub_name=$1
    cx_name=$2
    IFS=',' read -r -a new_rt_names <<< "$3"
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    new_rt_ids=""
    for new_rt_name in ${new_rt_names[@]}; do
        new_rt_ids="${new_rt_ids}{\"id\": \"/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${new_rt_name}\"},"
    done
    new_rt_ids="${new_rt_ids: : -1}"   # Remove trailing comma
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.propagatedRouteTables.ids = ['$new_rt_ids'] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated >/dev/null
}

# Modify propagation labels
function cx_set_prop_labels {
    hub_name=$1
    cx_name=$2
    if [[ -n "$3" ]]
    then
        echo "Setting labels from connection ${hub_name}/${cx_name} to $3..."
        if [ -n "$BASH_VERSION" ]; then
            arr_opt=a
        elif [ -n "$ZSH_VERSION" ]; then
            arr_opt=A
        fi
        IFS=',' read -r"$arr_opt" new_labels <<< "$3"
        new_labels_txt=""
        for new_label in ${new_labels[@]}; do
            new_labels_txt="${new_labels_txt}\"${new_label}\","
        done
        new_labels_txt="${new_labels_txt: : -1}"   # Remove trailing comma
    else
        echo "Deleting labels from connection ${hub_name}/${cx_name}..."
        new_labels_txt=" "
    fi
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.propagatedRouteTables.labels = ['${new_labels_txt}'] | {name, properties}')
    wait_until_hub_finished $hub_name
    # Check: if hub is Failed, we can try to reset it
    # We dont do this inside of the wait_until_hub_finished function because we could have infinite recursion
    hub_state=$(get_vhub_state $hub_name)
    if [[ "$hub_state" == "Failed" ]]
    then
        echo "Hub $hub_name is Failed, trying to fix it with a reset"
        reset_vhub "$hub_name"
        wait_until_hub_finished "$hub_name"
    fi
    # Check: if hub is still Failed, do not do anything
    hub_state=$(get_vhub_state "$hub_name")
    if [[ "$hub_state" == "Succeeded" ]]
    then
    az rest --method put --uri "$cx_uri" --body "$cx_json_updated" >/dev/null
    else
        echo "Hub $hub_name is $hub_state and could not fix it"
    fi
}

# Modify propagated RT for VPN connection
# RT can be given as rt_name or hub_name/rt_name
# Example:
# vpncx_set_prop_rt 1 branch1 hub1/defaultRouteTable
function vpncx_set_prop_rt {
    hub_id=$1
    cx_name=$2
    gw_id=$(az network vhub show -n hub${hub_id} -g $rg --query vpnGateway.id -o tsv)
    gw_name=$(echo $gw_id | cut -d/ -f 9)
    echo "Setting routing for VPN connection $cx_name in gateway $gw_name..."
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    if [ -n "$BASH_VERSION" ]; then
        arr_opt=a
    elif [ -n "$ZSH_VERSION" ]; then
        arr_opt=A
    fi
    IFS=',' read -r"$arr_opt" new_rt_names <<< "$3"
    hub_id=$(az network vpn-gateway show -n $gw_name -g $rg --query 'virtualHub.id' -o tsv)
    hub_name=$(echo $hub_id | cut -d/ -f 9)
    new_rt_ids=""
    for new_proprt_name in ${new_rt_names[@]}
    do
        # support both formats: hub/rt and rt (defaults to local hub)
        proprt_hub_name=$(echo $new_proprt_name | cut -d/ -f 1)
        proprt_rt_name=$(echo $new_proprt_name | cut -d/ -f 2)
        if [[ -z "$proprt_rt_name" ]]
        then
            proprt_hub_name=$hub_name
            proprt_rt_name=$new_proprt_name
        fi
        new_rt_ids="${new_rt_ids}{\"id\": \"/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${proprt_hub_name}/hubRouteTables/${proprt_rt_name}\"},"
    done
    new_rt_ids="${new_rt_ids: : -1}"   # Remove trailing comma
    vpn_json=$(az rest --method get --uri $uri)
    connections=$(echo $vpn_json | jq '.properties.connections | map({name, properties})')
    # Remove unneeded attributes
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].resourceGroup)')
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].etag)')
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].type)')
    connections_updated=$(echo $connections | jq 'map(if .name=="'$cx_name'" then .properties.routingConfiguration.propagatedRouteTables.ids=['"$new_rt_ids"'] else . end)')
    # Optionally, set labels
    if [[ -n "$4" ]]
    then
        IFS=',' read -r"$arr_opt" new_labels <<< "$4"
        new_labels_txt=""
        for new_label in "${new_labels[@]}"; do
            new_labels_txt="${new_labels_txt}\"${new_label}\","
        done
        new_labels_txt="${new_labels_txt: : -1}"   # Remove trailing comma
        connections_updated=$(echo $connections_updated | jq 'map(if .name=="'$cx_name'" then .properties.routingConfiguration.propagatedRouteTables.labels=['"$new_labels_txt"'] else . end)')
    fi
    # Send JSON
    vpn_json_updated=$(echo $vpn_json | jq '.properties.connections = '${connections_updated}' | {name, properties, location}')
    wait_until_gw_finished $gw_name
    az rest --method put --uri $uri --body $vpn_json_updated >/dev/null
}

# Set propagation labels
# If prop labels empty, clear the labels
function vpncx_set_prop_labels {
    gw_name=$1
    cx_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    hub_id=$(az network vpn-gateway show -n $gw_name -g $rg --query 'virtualHub.id' -o tsv)
    hub_name=$(echo $hub_id | cut -d/ -f 9)
    if [[ -n "$3" ]]
    then
        if [ -n "$BASH_VERSION" ]; then
            arr_opt=a
        elif [ -n "$ZSH_VERSION" ]; then
            arr_opt=A
        fi
        IFS=',' read -r"$arr_opt" new_labels <<< "$3"
        new_labels_txt=""
        for new_label in ${new_labels[@]}; do
            new_labels_txt="${new_labels_txt}\"${new_label}\","
        done
        new_labels_txt="${new_labels_txt: : -1}"   # Remove trailing comma
    else
        new_labels_txt=""
    fi
    vpn_json=$(az rest --method get --uri $uri)
    connections=$(echo $vpn_json | jq '.properties.connections | map({name, properties})')
    # Remove unneeded attributes
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].resourceGroup)')
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].etag)')
    connections=$(echo $connections | jq 'del(.[].properties.vpnLinkConnections[].type)')
    connections_updated=$(echo $connections | jq 'map(if .name=="'$cx_name'" then .properties.routingConfiguration.propagatedRouteTables.labels=['"$new_labels_txt"'] else . end)')
    vpn_json_updated=$(echo $vpn_json | jq '.properties.connections = '${connections_updated}' | {name, properties, location}')
    wait_until_gw_finished $gw_name
    az rest --method put --uri $uri --body $vpn_json_updated >/dev/null
}

# Update vnet connection associated and propagated RT at the same time
# example: cx_set_rt hub1 spoke1 redRT redRT,defaultRouteTable
function cx_set_rt {
    hub_name=$1
    cx_name=$2
    new_assrt_name=$3
    if [ -n "$BASH_VERSION" ]; then
        arr_opt=a
    elif [ -n "$ZSH_VERSION" ]; then
        arr_opt=A
    fi
    IFS=',' read -r"$arr_opt" new_proprt_names <<< "$4"
    echo "Setting connection $cx_name associated route table to $new_assrt_name, propagated route tables to $new_proprt_names"  # DEBUG
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    new_assrt_id="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${new_assrt_name}"
    new_proprt_ids=""
    for new_proprt_name in ${new_proprt_names[@]}; do
        # support both formats: hub/rt and rt (defaults to local hub)
        proprt_hub_name=$(echo $new_proprt_name | cut -d/ -f 1)
        proprt_rt_name=$(echo $new_proprt_name | cut -d/ -f 2)
        if [[ -z "$proprt_rt_name" ]]
        then
            proprt_hub_name=$hub_name
            proprt_rt_name=$new_proprt_name
        fi
        new_proprt_ids="${new_proprt_ids}{\"id\": \"/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${proprt_hub_name}/hubRouteTables/${proprt_rt_name}\"},"
    done
    new_proprt_ids="${new_proprt_ids: : -1}"   # Remove trailing comma
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.associatedRouteTable.id = "'$new_assrt_id'" | .properties.routingConfiguration.propagatedRouteTables.ids = ['$new_proprt_ids'] | {name, properties}')
    if [[ -n "$5" ]]
    then
        IFS=',' read -r"$arr_opt" new_labels <<< "$5"
        new_labels_txt=""
        for new_label in ${new_labels[@]}; do
            new_labels_txt="${new_labels_txt}\"${new_label}\","
        done
        new_labels_txt="${new_labels_txt: : -1}"   # Remove trailing comma
        cx_json_updated=$(echo $cx_json_updated | jq '.properties.routingConfiguration.propagatedRouteTables.labels = ['${new_labels_txt}'] | {name, properties}')
    fi
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated >/dev/null
}

# Add routes to RT
# https://docs.microsoft.com/en-us/rest/api/virtualwan/hubroutetables/createorupdate#hubroute
function rt_add_route {
    hub_name=hub$1
    rt_name=$2
    prefix=$3
    nexthop=$4
    echo "Adding static route for ${prefix} to route table ${hub_name}/${rt_name}"
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    rt_json_current=$(az rest --method get --uri $rt_uri)
    # type (next hop): CIDR, resourceId, Service
    # prefixes: comma-separated prefix list
    new_route_json_string=$(jq -n \
            --arg name "route$RANDOM" \
            --arg type "ResourceId" \
            --arg prefixes "$prefix" \
            --arg nexthop "$nexthop" \
            $route_json)
    rt_json_updated=$(echo $rt_json_current | jq '.properties.routes += [ '$new_route_json_string' ] | {name, properties}')
    wait_until_hub_finished $hub_name
    # Check: if hub is Failed, we can try to reset it
    # We dont do this inside of the wait_until_hub_finished function because we could have infinite recursion
    hub_state=$(get_vhub_state $hub_name)
    if [[ "$hub_state" == "Failed" ]]
    then
        echo "Hub $hub_name is Failed, trying to fix it with a reset"
        reset_vhub "$hub_name"
        wait_until_hub_finished "$hub_name"
    fi
    # Check: if hub is still Failed, do not do anything
    hub_state=$(get_vhub_state "$hub_name")
    if [[ "$hub_state" == "Succeeded" ]]
    then
        az rest --method put --uri $rt_uri --body $rt_json_updated >/dev/null   # PUT
    else
        echo "Hub $hub_name is $hub_state and could not fix it"
    fi
}

# Delete all routes from RT
function rt_delete_routes {
    hub_name=$1
    rt_name=$2
    echo "Deleting all routes from route table ${hub_name}/${rt_name}"
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    rt_json_current=$(az rest --method get --uri $rt_uri)
    rt_json_updated=$(echo $rt_json_current | jq '.properties.routes = [] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $rt_uri --body $rt_json_updated >/dev/null   # PUT
}

# Add routes to vnet conection
# https://docs.microsoft.com/en-us/rest/api/virtualwan/hubvirtualnetworkconnections/createorupdate#staticroute
# Example: cx_add_routes hub1 spoke1 192.168.0.0/16 172.21.10.68
function cx_add_routes {
    hub_name=hub$1
    cx_name=$2
    prefix=$3
    nexthop=$4
    echo "Adding route for $prefix to $nexthop in connection ${hub_name}/${cx_name}..."
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    # prefixes: comma-separated prefix list
    new_route_json_string=$(jq -n \
            --arg name "route$RANDOM" \
            --arg prefixes "$prefix" \
            --arg nexthop "$nexthop" \
            $cxroute_json)
    existing_routes=$(echo $cx_json | jq '.properties.routingConfiguration.vnetRoutes.staticRoutes[]')
    if [ -z "${existing_routes}" ]
    then
        new_routes=${new_route_json_string}
    else
        new_routes=${existing_routes},${new_route_json_string}
    fi
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.vnetRoutes.staticRoutes = ['$new_routes'] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated >/dev/null # PUT
}

# Delete all routes from vnet cx
function cx_delete_routes {
    hub_name=$1
    cx_name=$2
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.vnetRoutes.staticRoutes = [] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated >/dev/null
    # az rest --method get --uri $cx_uri | jq '.properties.routingConfiguration.vnetRoutes.staticRoutes'  # GET
}

# Delete all labels from vnet cx
function cx_delete_labels {
    hub_name=$1
    cx_name=$2
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json=$(az rest --method get --uri $cx_uri)
    cx_json_updated=$(echo $cx_json | jq '.properties.routingConfiguration.propagatedRouteTables.labels = [] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $cx_uri --body $cx_json_updated    # PUT
    # az rest --method get --uri $cx_uri | jq '.properties.routingConfiguration.propagatedRouteTables.labels'  # GET
}

# Add label to route table
# https://docs.microsoft.com/en-us/rest/api/virtualwan/hubroutetables/createorupdate#hubroute
function rt_add_label {
    hub_name=$1
    rt_name=$2
    new_label=$3
    wait_until_hub_finished $hub_name
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    rt_json_current=$(az rest --method get --uri $rt_uri)
    rt_json_updated=$(echo $rt_json_current | jq '.properties.labels += [ "'$new_label'" ] | {name, properties}')
    az rest --method put --uri $rt_uri --body $rt_json_updated    # PUT
}

# Delete all labels
function rt_delete_labels {
    hub_name=$1
    rt_name=$2
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    rt_json_current=$(az rest --method get --uri $rt_uri)
    rt_json_updated=$(echo $rt_json_current | jq '.properties.labels = [] | {name, properties}')
    wait_until_hub_finished $hub_name
    az rest --method put --uri $rt_uri --body $rt_json_updated    # PUT
}


#################
#  Reset stuff  #
#################

# reset vhub
function reset_vhub {
    hub_name=$1
    hub_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}?api-version=$vwan_api_version"
    hub_json_current=$(az rest --method get --uri $hub_uri)
    hub_json_updated=$(echo $hub_json_current | jq '{name, location, properties}')
    az rest --method put --uri $hub_uri --body $hub_json_updated >/dev/null
}

# reset vhub
function reset_rt {
    hub_name=$1
    rt_name=$2
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    rt_json_current=$(az rest --method get --uri $rt_uri)
    rt_json_updated=$(echo $rt_json_current | jq '{name, location, properties}')
    az rest --method put --uri $rt_uri --body $rt_json_updated >/dev/null
}

# reset vnet cx
function reset_vhub_cx {
    hub_name=$1
    cx_name=$2
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    cx_json_current=$(az rest --method get --uri $cx_uri)       # GET
    cx_json_updated=$(echo $cx_json_current | jq '{name, location, properties}')
    # If you delete, you should wait until the delete operation finishes before sending the PUT, hence commented out
    # az rest --method delete --uri $cx_uri                     # DELETE
    az rest --method put --uri $cx_uri --body $cx_json_updated  >/dev/null
}

# reset vpngw - NOT WORKING!
function reset_vpngw {
    gw_name=$1
    gw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    gw_json_current=$(az rest --method get --uri $gw_uri)
    gw_json_updated=$(echo $gw_json_current | jq '{name, location, properties}')
    az rest --method put --uri $gw_uri --body $gw_json_updated
}


##################
#  Summary info  #
##################

# Get label info
function get_cx_labels {
    hub_name=$1
    cx_name=$2
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    az rest --method get --uri $cx_uri | jq -r '.properties.routingConfiguration.propagatedRouteTables.labels[]' | paste -sd, - 2>/dev/null
}
function get_rt_labels {
    hub_name=$1
    rt_name=$2
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    az rest --method get --uri $rt_uri | jq -r '.properties.labels[]' | paste -sd, - 2>/dev/null
}
function get_rt_routes {
    hub_name=$1
    rt_name=$2
    rt_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    az rest --method get --uri $rt_uri | jq -r '.properties.routes[] | .destinations[],.nextHop' | paste -sd, - 2>/dev/null
}
function get_vpncx_labels {
    gw_name=$1
    cx_name=$2
    gw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    az rest --method get --uri $gw_uri | jq -r '.properties.connections[] | select (.name == "'$cx_name'") | .properties.routingConfiguration.propagatedRouteTables.labels[]' | paste -sd, - 2>/dev/null
}
function get_vpncx {
    gw_name=$1
    cx_name=$2
    gw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    az rest --method get --uri $gw_uri | jq -r '.properties.connections[] | select (.name == "'$cx_name'")' 2>/dev/null
}
function list_vpncx {
    gw_name=$1
    gw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    az rest --method get --uri $gw_uri | jq -r '.properties.connections[].name' 2>/dev/null
}

function labels {
    # Vnet connections
    hubs=$(list_vhub)
    while IFS= read -r hub_name; do
        vnet_cxs=$(list_vnetcx $hub_name)
        if [[ -n "$vnet_cxs" ]]
        then
            while IFS= read -r vnetcx_name; do
                echo "${hub_name}/${vnetcx_name} connection:  $(get_cx_labels $hub_name $vnetcx_name)"
            done <<< "$vnet_cxs"
        else
            echo "No vnet connections in hub $hub_name"
        fi
    done <<< "$hubs"
    # VPN connections
    vpngws=$(list_vpngw)
    while IFS= read -r gw_name; do
        vpn_cxs=$(list_vpncx $gw_name)
        if [[ -n "$vpn_cxs" ]]
        then
            while IFS= read -r vpncx_name; do
                echo "${gw_name}/${vpncx_name} connection:  $(get_vpncx_labels $gw_name $vpncx_name)"
            done <<< "$vpn_cxs"
        else
            echo "No VPN connections in gateway $gw_name"
        fi
    done <<< "$vpngws"
    # Route Tables
    while IFS= read -r hub_name; do
        rts=$(list_rt $hub_name)
        if [[ -n "$rts" ]]
        then
            while IFS= read -r rt_name; do
                echo "${hub_name}/${rt_name}:  $(get_rt_labels $hub_name $rt_name)"
            done <<< "$rts"
        else
            echo "No route tables in hub $hub_name"
        fi
    done <<< "$hubs"
}

function state {
    # Hubs
    hubs=$(list_vhub)
    while IFS= read -r hub_name; do
        echo "${hub_name}: $(get_vhub_state $hub_name)"
        # Vnet connections
        vnet_cxs=$(list_vnetcx $hub_name)
        if [[ -n "$vnet_cxs" ]]
        then
            while IFS= read -r vnetcx_name; do
                echo "${hub_name}/${vnetcx_name} connection:  $(get_vnetcx_state $hub_name $vnetcx_name)"
            done <<< "$vnet_cxs"
        else
            echo "No vnet connections in hub $hub_name"
        fi
        # Route Tables
        rts=$(list_rt $hub_name)
        if [[ -n "$rts" ]]
        then
            while IFS= read -r rt_name; do
                echo "${hub_name}/${rt_name}:  $(get_rt_state $hub_name $rt_name)"
            done <<< "$rts"
        else
            echo "No route tables in hub $hub_name"
        fi
    done <<< "$hubs"
    # VPN connections
    vpngws=$(list_vpngw)
    while IFS= read -r gw_name; do
        echo "${gw_name}: $(get_vpngw_state $gw_name)"
        vpn_cxs=$(list_vpncx $gw_name)
        if [[ -n "$vpn_cxs" ]]
        then
            while IFS= read -r vpncx_name; do
                echo "${gw_name}/${vpncx_name} connection:  $(get_vpngw_cx_state $gw_name $vpncx_name)"
            done <<< "$vpn_cxs"
        else
            echo "No VPN connections in gateway $gw_name"
        fi
    done <<< "$vpngws"
}

# Get associated/propagated routing tables
function print_routing {
    routing=$1
    assrt=$(echo $routing | jq -r '.associatedRouteTable.id')
    assrt_hub=$(echo $assrt | cut -d/ -f 9)
    assrt_name=$(echo $assrt | cut -d/ -f 11)
    proprt=$(echo $routing | jq -r '.propagatedRouteTables.ids[].id')
    proprt_txt=""
    while IFS= read -r proprt_id; do
        proprt_hub=$(echo $proprt_id | cut -d/ -f 9)
        proprt_name=$(echo $proprt_id | cut -d/ -f 11)
        if [[ -n "$proprt_txt" ]]
        then
            proprt_txt+=", "
        fi
        proprt_txt+=${proprt_hub}/${proprt_name}
    done <<< "$proprt"
    proplbls=$(echo $routing | jq -r '.propagatedRouteTables.labels[]')
    proplbl_txt=""
    while IFS= read -r label; do
        if [[ -n "$proplbl_txt" ]]
        then
            proplbl_txt+=", "
        fi
        proplbl_txt+=${label}
    done <<< "$proplbls"
    echo "  * Associated: ${assrt_hub}/${assrt_name}"
    echo "  * Propagated: $proprt_txt - Labels: ${proplbl_txt}"
}
function get_cx_routing {
    hub_name=$1
    cx_name=$2
    cx_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubVirtualNetworkConnections/${cx_name}?api-version=$vwan_api_version"
    routing=$(az rest --method get --uri $cx_uri | jq -r '.properties.routingConfiguration')
    echo "$hub_name / $cx_name"
    print_routing $routing
}
function get_vpncx_routing {
    gw_name=$1
    cx_name=$2
    gw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${gw_name}?api-version=$vwan_api_version"
    routing=$(az rest --method get --uri $gw_uri | jq -r '.properties.connections[] | select (.name == "'$cx_name'") | .properties.routingConfiguration')
    echo "$gw_name / $cx_name"
    print_routing $routing
}

function routing {
    # Vnet connections
    hubs=$(list_vhub)
    while IFS= read -r hub_name; do
        vnet_cxs=$(list_vnetcx $hub_name)
        if [[ -n "$vnet_cxs" ]]
        then
            while IFS= read -r vnetcx_name; do
                get_cx_routing $hub_name $vnetcx_name
            done <<< "$vnet_cxs"
        else
            echo "No vnet connections in hub $hub_name"
        fi
    done <<< "$hubs"
    # VPN connections
    vpngws=$(list_vpngw)
    while IFS= read -r gw_name; do
        vpn_cxs=$(list_vpncx $gw_name)
        if [[ -n "$vpn_cxs" ]]
        then
            while IFS= read -r vpncx_name; do
                get_vpncx_routing $gw_name $vpncx_name
            done <<< "$vpn_cxs"
        else
            echo "No VPN connections in gateway $gw_name"
        fi
    done <<< "$vpngws"
    # Route tables
    get_static
}

# Get static routes in route table
function get_rt_static {
    hub_name=$1
    rt_name=$2
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/hubRouteTables/${rt_name}?api-version=$vwan_api_version"
    routes=$(az rest --method get --uri $uri | jq '.properties.routes')
    srch="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/"
    routes=$(echo $routes | awk -v srch="$srch" '{sub(srch,"",$0); print$0}')
    srch="hubVirtualNetworkConnections/"
    routes=$(echo $routes | awk -v srch="$srch" '{sub(srch,"",$0); print$0}')
    srch="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/azureFirewalls/"
    routes=$(echo $routes | awk -v srch="$srch" '{sub(srch,"",$0); print$0}')
    routes=$(echo $routes | jq -r '.[] | "  * \(.name)\t\(.destinations[])\t\(.nextHop)"')
    if [[ -n $routes ]]
    then
        echo $routes
    else
        echo "  * No static routes"
    fi
}

function get_static {
    # Hubs
    hubs=$(list_vhub)
    while IFS= read -r hub_name; do
        # Route Tables
        rts=$(list_rt $hub_name)
        if [[ -n "$rts" ]]
        then
            while IFS= read -r rt_name; do
                echo "${hub_name}/${rt_name} (labels: $(get_rt_labels $hub_name $rt_name))"
                get_rt_static $hub_name $rt_name
            done <<< "$rts"
        else
            echo "No route tables in hub $hub_name"
        fi
    done <<< "$hubs"
}


################
# Getting logs #
################

function create_logs {
    # Workspace
    echo "Creating log analytics workspace..."
    az monitor log-analytics workspace create -n $logws_name -g $rg >/dev/null
    logws_name=$(az monitor log-analytics workspace list -g $rg --query '[0].name' -o tsv)  # In case the log analytics workspace already exists
    logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
    logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
    # VPN gateways
    echo "Configuring VPN gateways..."
    gw_id_list=$(az network vpn-gateway list -g $rg --query '[].id' -o tsv)
    while IFS= read -r gw_id; do
        az monitor diagnostic-settings create -n mydiag --resource $gw_id --workspace $logws_id \
            --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
            --logs '[{"category": "GatewayDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "TunnelDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
                    {"category": "RouteDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
                    {"category": "IKEDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
    done <<< "$gw_id_list"
    # Azure Firewalls
    echo "Configuring Azure Firewalls..."
    fw_id_list=$(az network firewall list -g $rg --query '[].id' -o tsv)
    while IFS= read -r fw_id; do
        az monitor diagnostic-settings create -n mydiag --resource $fw_id --workspace $logws_id \
            --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
            --logs '[{"category": "AzureFirewallApplicationRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "AzureFirewallNetworkRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
    done <<< "$fw_id_list"
}

function init_log_vars {
    logws_name=$(az monitor log-analytics workspace list -g $rg --query '[0].name' -o tsv)  # In case the log analytics workspace already exists
    logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
    logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
}

function get_fw_logs_net {
    query='AzureDiagnostics
    | where Category == "AzureFirewallNetworkRule"
    | where TimeGenerated >= ago(5m) 
    | parse msg_s with Protocol " request from " SourceIP ":" SourcePortInt:int " to " TargetIP ":" TargetPortInt:int *
    | parse msg_s with * ". Action: " Action1a
    | parse msg_s with * " was " Action1b " to " NatDestination
    | parse msg_s with Protocol2 " request from " SourceIP2 " to " TargetIP2 ". Action: " Action2
    | extend SourcePort = tostring(SourcePortInt),TargetPort = tostring(TargetPortInt)
    | extend Action = case(Action1a == "", case(Action1b == "",Action2,Action1b), Action1a),Protocol = case(Protocol == "", Protocol2, Protocol),SourceIP = case(SourceIP == "", SourceIP2, SourceIP),TargetIP = case(TargetIP == "", TargetIP2, TargetIP),SourcePort = case(SourcePort == "", "N/A", SourcePort),TargetPort = case(TargetPort == "", "N/A", TargetPort),NatDestination = case(NatDestination == "", "N/A", NatDestination)
    //| where Action == "Deny" 
    //| project TimeGenerated, msg_s, Protocol, SourceIP,SourcePort,TargetIP,TargetPort,Action, NatDestination  // with msg_s
    | project TimeGenerated, Protocol, SourceIP,SourcePort,TargetIP,TargetPort,Action, NatDestination, Resource  // without msg_s
    | take 20 '
    az monitor log-analytics query -w $logws_customerid --analytics-query $query -o tsv
}

function get_fw_logs_app {
    query='AzureDiagnostics 
    | where ResourceType == "AZUREFIREWALLS" 
    | where Category == "AzureFirewallApplicationRule" 
    | where TimeGenerated >= ago(5m) 
    | project Protocol=split(msg_s, " ")[0], From=split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",3,4)], To=split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",5,6)], Action=trim_end(".", tostring(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",7,8)])), Rule_Collection=iif(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)]=="traffic.", "AzureInternalTraffic", iif(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)]=="matched.","NoRuleMatched",trim_end(".",tostring(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)])))), Rule=iif(split(msg_s, " ")[11]=="Proceeding" or split(msg_s, " ")[12]=="Proceeding","DefaultAction",split(msg_s, " ")[12]), msg_s 
    | where Rule_Collection != "AzureInternalTraffic" 
    //| where Action == "Deny" 
    | take 20'
    az monitor log-analytics query -w $logws_customerid --analytics-query $query -o tsv
}

##################
# VM Maintenance #
##################
function stop_vms {
    vms=$(az vm list -g $rg --query '[].name' -o tsv)
    while IFS= read -r vm_name; do
        echo "Stopping ${vm_name}..."
        az vm deallocate -n $vm_name -g $rg --no-wait
    done <<< "$vms"
    az vm list -d -g $rg -o table
}
function start_vms {
    vms=$(az vm list -g $rg --query '[].name' -o tsv)
    while IFS= read -r vm_name; do
        echo "Starting ${vm_name}..."
        az vm start -n $vm_name -g $rg --no-wait
    done <<< "$vms"
    az vm list -d -g $rg -o table
}

function add_to_hosts {
    ip=$1
    if [[ -n "$ip" ]]
    then
        ssh-keyscan -H $ip >> ~/.ssh/known_hosts
    fi
}

function get_ips {
    echo "Getting public IP addresses..."
    spoke11_jump_pip=$(az network public-ip show -n spoke11-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke11_jump_pip
    add_to_hosts $spoke11_jump_pip
    spoke12_jump_pip=$(az network public-ip show -n spoke12-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke12_jump_pip
    add_to_hosts $spoke12_jump_pip
    spoke13_jump_pip=$(az network public-ip show -n spoke13-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke13_jump_pip
    add_to_hosts $spoke13_jump_pip
    spoke14_jump_pip=$(az network public-ip show -n spoke14-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke14_jump_pip
    add_to_hosts $spoke14_jump_pip
    spoke15_jump_pip=$(az network public-ip show -n spoke15-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke15_jump_pip
    add_to_hosts $spoke15_jump_pip
    spoke21_jump_pip=$(az network public-ip show -n spoke21-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke21_jump_pip
    add_to_hosts $spoke21_jump_pip
    spoke22_jump_pip=$(az network public-ip show -n spoke22-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke22_jump_pip
    add_to_hosts $spoke22_jump_pip
    spoke23_jump_pip=$(az network public-ip show -n spoke23-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke23_jump_pip
    add_to_hosts $spoke23_jump_pip
    spoke24_jump_pip=$(az network public-ip show -n spoke24-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke24_jump_pip
    add_to_hosts $spoke24_jump_pip
    spoke25_jump_pip=$(az network public-ip show -n spoke25-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $spoke25_jump_pip
    add_to_hosts $spoke25_jump_pip
    branch1_ip=$(az network public-ip show -n branch1-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $branch1_ip
    add_to_hosts $branch1_ip
    branch2_ip=$(az network public-ip show -n branch2-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $branch2_ip
    add_to_hosts $branch2_ip
    branch3_ip=$(az network public-ip show -n branch3-pip -g $rg --query ipAddress -o tsv 2>/dev/null) && echo $branch3_ip
    add_to_hosts $branch3_ip
}

################
# VPN gateways #
################

function get_location {
    hub_id=$1
    case $hub_id in
    1)
        echo $location1
        ;;
    2)
        echo $location2
        ;;
    3)
        echo $location3
        ;;
    esac
}

# Create VPN Gateway in VWAN virtual hub
function create_vpngw {
    hub_id=$1
    hub_name=hub${hub_id}
    vpngw_name=hubvpn${hub_id}
    location=$(get_location $hub_id)
    vpngw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw_name?api-version=$vwan_api_version"
    vhub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    wait_until_finished $vhub_id
    vpngw_json_string=$(jq -n \
            --arg location "$location" \
            --arg vhub_id $vhub_id \
            --arg asn "65515" \
            $vpngw_json)
    az rest --method put --uri $vpngw_uri --body $vpngw_json_string >/dev/null  # PUT
}
function delete_vpngw {
    hub_id=$1
    vpngw_id=$(az network vhub show -n hub${hub_id} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpngw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw_name?api-version=$vwan_api_version"
    az rest --method delete --uri $vpngw_uri                        # DELETE
}

# Connects site to VPNgw
function connect_branch {
    hub_id=$1
    branch_id=$2
    # Create site
    branch_ip=$(az network public-ip show -n branch${branch_id}-pip -g $rg --query ipAddress -o tsv)
    branch_bgp_ip=$(az vm list-ip-addresses -n branch${branch_id}-nva -g $rg --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv)
    create_site $hub_id $branch_id $branch_ip $branch_bgp_ip
    sleep 30
    # Create connection
    site_name=hub${hub_id}branch${branch_id}
    site_id=$(az network vpn-site show -n ${site_name} -g $rg --query id -o tsv)
    vpnsite_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnSites/${site_name}?api-version=$vwan_api_version"
    site_link_id=$(az rest --method get --uri $vpnsite_uri | jq -r '.properties.vpnSiteLinks[0].id')
    vpngw_id=$(az network vhub show -n hub${hub_id} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    wait_until_finished $vpngw_id
    vpncx_json_string=$(jq -n \
            --arg cx_name "branch${branch_id}" \
            --arg site_id "${site_id}" \
            --arg site_link_id ${site_link_id} \
            --arg psk $password \
            $vpncx_json)
    vpngw_base_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/${vpngw_name}"
    vpngw_cx_uri="${vpngw_base_uri}/vpnConnections/branch${branch_id}?api-version=$vwan_api_version"
    # Optional: configure some additional attributes:
    # rt1_id=/subscriptions/$subscription/resourceGroups/vwan/providers/Microsoft.Network/virtualHubs/hub1/hubRouteTables/hub1NvaRouteTable
    # rt2_id=/subscriptions/$subscription/resourceGroups/vwan/providers/Microsoft.Network/virtualHubs/hub2/hubRouteTables/hub2NvaRouteTable
    # rt3_id=/subscriptions/$subscription/resourceGroups/vwan/providers/Microsoft.Network/virtualHubs/$hub_name/hubRouteTables/hub1BlueRT
    # rt4_id=/subscriptions/$subscription/resourceGroups/vwan/providers/Microsoft.Network/virtualHubs/$hub_name/hubRouteTables/commonRouteTable
    # vpncx2_json_string=$(echo $vpncx2_json_string | jq '.properties.routingConfiguration.propagatedRouteTables.ids = [{"id": "'$rt1_id'"}, {"id": "'$rt2_id'"}]')
    # Send PUT
    az rest --method put --uri $vpngw_cx_uri --body $vpncx_json_string >/dev/null # PUT
}

# Configures CSR in branch x to connect to a VPN gateway
function configure_csr {
    hub_id=$1
    branch_id=$2
    # These 2 commands do not work if the GW has not been created yet
    # vpngw_id=$(az network vhub show -n hub${hub_id} -g $rg --query vpnGateway.id -o tsv)
    # vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpngw_name=hubvpn${hub_id}
    wait_until_gw_finished $vpngw_name
    wait_until_csr_finished $branch_id
    echo "Extracting IP information from VPN gateway $vpngw_name..."
    branch_asn=6550${branch_id}
    vpngw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw_name?api-version=$vwan_api_version"
    vpngw=$(az rest --method get --uri $vpngw_uri)
    vpngw_gw0_pip=$(echo $vpngw | jq -r '.properties.ipConfigurations[0].publicIpAddress')
    vpngw_gw1_pip=$(echo $vpngw | jq -r '.properties.ipConfigurations[1].publicIpAddress')
    vpngw_gw0_bgp_ip=$(echo $vpngw | jq -r '.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw_gw1_bgp_ip=$(echo $vpngw | jq -r '.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    echo "Extracted info for vpngw: Gateway0 $vpngw_gw0_pip, $vpngw_gw0_bgp_ip. Gateway1 $vpngw_gw1_pip, $vpngw_gw1_bgp_ip."
    if [[ "$vpngw_gw0_pip" == "null" ]] || [[ "$vpngw_gw0_pip" == "null" ]]
    then
        echo "Could not extract IP information out of gateway $vpngw_name"
    else
        # Create config
        csr_config_url="https://raw.githubusercontent.com/erjosito/azure-wan-lab/master/csr_config_2tunnels_tokenized.txt"
        config_file_csr="branch${branch_id}_csr.cfg"
        config_file_local="/tmp/branch${branch_id}_csr.cfg"
        wget $csr_config_url -O $config_file_local
        sed -i "s|\*\*PSK\*\*|${password}|g" $config_file_local
        sed -i "s|\*\*GW0_Private_IP\*\*|${vpngw_gw0_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW1_Private_IP\*\*|${vpngw_gw1_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW0_Public_IP\*\*|${vpngw_gw0_pip}|g" $config_file_local
        sed -i "s|\*\*GW1_Public_IP\*\*|${vpngw_gw1_pip}|g" $config_file_local
        sed -i "s|\*\*BGP_ID\*\*|${branch_asn}|g" $config_file_local
        # eval "branch_ip=\"\${branch${branch_id}_ip}\""
        branch_ip=$(az network public-ip show -n branch${branch_id}-pip -g $rg -o tsv --query ipAddress)
        # The remote alias includes the -n flag, which does not work with EOF
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch_ip <<EOF
        config t
            file prompt quiet
EOF
        echo "Sending config to IP $branch_ip..."
        scp $config_file_local ${branch_ip}:/${config_file_csr}
        # echo "Verifying file bootflash:${config_file_csr}:"
        # remote $branch_ip "dir bootflash:${config_file_csr}"
        remote $branch_ip "copy bootflash:/${config_file_csr} running-config"
        # Additional routing config
        default_gateway="10.${hub_id}.20${branch_id}.1"
        loopback_ip="${branch_id}.${branch_id}.${branch_id}.${branch_id} 255.255.255.255"
        # loopback_ip="10.${hub_id}.20${branch_id}.129 255.255.255.192"
        myip=$(curl -s4 ifconfig.co)
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch_ip <<EOF
        config t
            interface Loopback0
                ip address ${loopback_ip}
            router bgp ${branch_asn}
                redistribute connected
            ip route ${vpngw_gw0_pip} 255.255.255.255 ${default_gateway}
            ip route ${vpngw_gw1_pip} 255.255.255.255 ${default_gateway}
            ip route ${myip} 255.255.255.255 ${default_gateway}
        end
EOF
        # Save config and check
        remote $branch_ip "wr mem"
        # remote $branch_ip "sh ip int b"
    fi
}

# Configures CSR in branch x to connect to the VPN gateways in two hubs
function configure_csr_dualhomed {
    hub1_id=$1
    hub2_id=$2
    branch_id=$3
    # These 2 commands do not work if the GW has not been created yet
    # vpngw1_id=$(az network vhub show -n hub${hub1_id} -g $rg --query vpnGateway.id -o tsv)
    # vpngw1_name=$(echo $vpngw1_id | cut -d/ -f 9)
    vpngw1_name=hubvpn${hub1_id}
    # vpngw2_id=$(az network vhub show -n hub${hub2_id} -g $rg --query vpnGateway.id -o tsv)
    # vpngw2_name=$(echo $vpngw2_id | cut -d/ -f 9)
    vpngw2_name=hubvpn${hub2_id}
    wait_until_gw_finished $vpngw1_name
    wait_until_gw_finished $vpngw2_name
    wait_until_csr_finished $branch_id
    branch_asn=6550${branch_id}

    echo "Extracting IP information from VPN gateway $vpngw1_name..."
    vpngw1_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw1_name?api-version=$vwan_api_version"
    vpngw1=$(az rest --method get --uri $vpngw1_uri)
    vpngw1_gw0_pip=$(echo $vpngw1 | jq -r '.properties.ipConfigurations[0].publicIpAddress')
    vpngw1_gw1_pip=$(echo $vpngw1 | jq -r '.properties.ipConfigurations[1].publicIpAddress')
    vpngw1_gw0_bgp_ip=$(echo $vpngw1 | jq -r '.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw1_gw1_bgp_ip=$(echo $vpngw1 | jq -r '.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    echo "Extracted info for vpngw1: Gateway0 $vpngw1_gw0_pip, $vpngw1_gw0_bgp_ip. Gateway1 $vpngw1_gw1_pip, $vpngw1_gw1_bgp_ip."

    echo "Extracting IP information from VPN gateway $vpngw2_name..."
    vpngw2_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw2_name?api-version=$vwan_api_version"
    vpngw2=$(az rest --method get --uri $vpngw2_uri)
    vpngw2_gw0_pip=$(echo $vpngw2 | jq -r '.properties.ipConfigurations[0].publicIpAddress')
    vpngw2_gw1_pip=$(echo $vpngw2 | jq -r '.properties.ipConfigurations[1].publicIpAddress')
    vpngw2_gw0_bgp_ip=$(echo $vpngw2 | jq -r '.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw2_gw1_bgp_ip=$(echo $vpngw2 | jq -r '.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    echo "Extracted info for vpngw2: Gateway0 $vpngw2_gw0_pip, $vpngw2_gw0_bgp_ip. Gateway1 $vpngw2_gw1_pip, $vpngw2_gw1_bgp_ip."

    if [[ "$vpngw1_gw0_pip" == "null" ]] || [[ "$vpngw1_gw0_pip" == "null" ]] || [[ "$vpngw2_gw0_pip" == "null" ]] || [[ "$vpngw2_gw0_pip" == "null" ]]
    then
        echo "Could not extract IP information out of existing VPN gateways"
    else
        # Create config
        csr_config_url="https://raw.githubusercontent.com/erjosito/azure-wan-lab/master/csr_config_4tunnels_tokenized.txt"
        config_file_csr='branch${branch_id}_csr.cfg'
        config_file_local='/tmp/branch${branch_id}_csr.cfg'
        wget $csr_config_url -O $config_file_local
        sed -i "s|\*\*PSK\*\*|${password}|g" $config_file_local
        sed -i "s|\*\*GW0_Private_IP\*\*|${vpngw1_gw0_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW1_Private_IP\*\*|${vpngw1_gw1_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW2_Private_IP\*\*|${vpngw2_gw0_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW3_Private_IP\*\*|${vpngw2_gw1_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW0_Public_IP\*\*|${vpngw1_gw0_pip}|g" $config_file_local
        sed -i "s|\*\*GW1_Public_IP\*\*|${vpngw1_gw1_pip}|g" $config_file_local
        sed -i "s|\*\*GW2_Public_IP\*\*|${vpngw2_gw0_pip}|g" $config_file_local
        sed -i "s|\*\*GW3_Public_IP\*\*|${vpngw2_gw1_pip}|g" $config_file_local
        sed -i "s|\*\*BGP_ID\*\*|${branch_asn}|g" $config_file_local
        # eval "branch_ip=\"\${branch${branch_id}_ip}\""
        branch_ip=$(az network public-ip show -n branch${branch_id}-pip -g $rg -o tsv --query ipAddress)
        # The remote alias includes the -n flag, which does not work with EOF
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch_ip <<EOF
        config t
            file prompt quiet
EOF
        echo "Sending config to IP $branch_ip..."
        scp $config_file_local ${branch_ip}:/${config_file_csr}
        # echo "Verifying file bootflash:${config_file_csr}:"
        # remote $branch_ip "dir bootflash:${config_file_csr}"
        remote $branch_ip "copy bootflash:/${config_file_csr} running-config"
        # Additional routing config
        default_gateway="10.${hub_id}.20${branch_id}.1"
        loopback_ip="${branch_id}.${branch_id}.${branch_id}.${branch_id} 255.255.255.255"
        # loopback_ip="10.${hub_id}.20${branch_id}.129 255.255.255.192"
        myip=$(curl -s4 ifconfig.co)
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch_ip <<EOF
        config t
            interface Loopback0
                ip address ${loopback_ip}
            router bgp ${branch_asn}
                redistribute connected
            ip route ${vpngw1_gw0_pip} 255.255.255.255 ${default_gateway}
            ip route ${vpngw1_gw1_pip} 255.255.255.255 ${default_gateway}
            ip route ${vpngw2_gw0_pip} 255.255.255.255 ${default_gateway}
            ip route ${vpngw2_gw1_pip} 255.255.255.255 ${default_gateway}
            ip route ${myip} 255.255.255.255 ${default_gateway}
        end
EOF
        # Save config and check
        remote $branch_ip "wr mem"
        # remote $branch_ip "sh ip int b"
    fi
}

function get_vpngw_ips {
    hub_id=$1
    vpngw_name=hubvpn${hub_id}
    echo "Extracting IP information from VPN gateway $vpngw_name..."
    vpngw_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnGateways/$vpngw_name?api-version=$vwan_api_version"
    vpngw=$(az rest --method get --uri $vpngw_uri)
    vpngw_gw0_pip=$(echo $vpngw | jq -r '.properties.ipConfigurations[0].publicIpAddress')
    vpngw_gw1_pip=$(echo $vpngw | jq -r '.properties.ipConfigurations[1].publicIpAddress')
    vpngw_gw0_bgp_ip=$(echo $vpngw | jq -r '.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw_gw1_bgp_ip=$(echo $vpngw | jq -r '.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    echo "Extracted info for vpngw: Gateway0 $vpngw_gw0_pip, $vpngw_gw0_bgp_ip. Gateway1 $vpngw_gw1_pip, $vpngw_gw1_bgp_ip."
 }


############################
#  Create VWAN and hubs    #
############################

# Create VWAN
# https://docs.microsoft.com/en-us/rest/api/virtualwan/virtualwans/createorupdate
# az network vwan create -n $vwan -g $rg -l $location1 --branch-to-branch-traffic true --vnet-to-vnet-traffic true
function create_vwan {
    vwan_name=$1
    vwan_json_string=$(jq -n \
        --arg location "$location1" \
        --arg sku "Standard" \
        $vwan_json)
    vwan_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualWans/$vwan_name?api-version=$vwan_api_version"
    echo "Creating VWAN $vwan_name in $location1..."
    az rest --method put --uri $vwan_uri --body $vwan_json_string >/dev/null
    vwan_id=$(az network vwan show -n $vwan_name -g $rg --query id -o tsv)
}

# Create hub
# Example:
#   create_hub 1 vwantest
function create_hub {
    hub_id=$1
    vwan_name=$2
    location=$(get_location $hub_id)
    vhub_base_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/hub${hub_id}"
    vhub_uri="${vhub_base_uri}?api-version=$vwan_api_version"
    vwan_id=$(az network vwan show -n $vwan_name -g $rg --query id -o tsv)
    hub_prefix="192.168.${hub_id}.0/24"
    vhub_json_string=$(jq -n \
        --arg location "$location" \
        --arg vwan_id $vwan_id \
        --arg sku "Standard" \
        --arg hub_prefix $hub_prefix \
        $vhub_json)
    echo "Creating hub hub${hub_id} in $location with prefix ${hub_prefix}..."
    az rest --method put --uri $vhub_uri --body $vhub_json_string >/dev/null    # PUT
}

# Create an Azure Firewall in a hub
# Assumes a fw policy already exists
function create_fw {
    hub_id=$1
    location=$(get_location $hub_id)
    az network firewall create -n azfw${hub_id} -g $rg --vhub hub${hub_id} --policy $azfw_policy_name -l $location --sku AZFW_Hub --public-ip-count 1 >/dev/null
}

# Delete the Azure Firewall in a Virtual Secure Hub
function delete_fw {
    hub_id=$1
    az network firewall delete -n azfw${hub_id} -g $rg
}

# Creates an Az FW policy
function create_azfw_policy {
    az network firewall policy create -n $azfw_policy_name -g $rg >/dev/null
    az network firewall policy rule-collection-group create -n ruleset01 --policy-name $azfw_policy_name -g $rg --priority 100 >/dev/null
# Example network collections
# Allow SSH
echo "Creating rule to allow SSH..."
az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
    --name mgmt --collection-priority 101 --action Allow --rule-name allowSSH --rule-type NetworkRule --description "TCP 22" \
    --destination-addresses "10.0.0.0/8,1.1.1.1/32,2.2.2.2/32,3.3.3.3/32" --source-addresses "10.0.0.0/8,1.1.1.1/32,2.2.2.2/32,3.3.3.3/32" --ip-protocols TCP --destination-ports 22 >/dev/null
# Allow ICMP
# echo "Creating rule to allow ICMP..."
# az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
#     --name icmp --collection-priority 102 --action Allow --rule-name allowICMP --rule-type NetworkRule --description "ICMP traffic" \
#     --destination-addresses "10.0.0.0/8,1.1.1.1/32,2.2.2.2/32,3.3.3.3/32" --source-addresses "10.0.0.0/8,1.1.1.1/32,2.2.2.2/32,3.3.3.3/32" --ip-protocols ICMP --destination-ports "1-65535" >/dev/null
# Allow NTP
echo "Creating rule to allow NTP..."
az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
    --name ntp --collection-priority 103 --action Allow --rule-name allowNTP --rule-type NetworkRule --description "ICMP traffic" \
    --destination-addresses "10.0.0.0/8" --source-addresses "0.0.0.0/0" --ip-protocols UDP --destination-ports "123" >/dev/null
# Example application collection with 2 rules (ipconfig.co, api.ipify.org)
echo "Creating rule to allow ifconfig.co and api.ipify.org..."
az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
    --name ifconfig --collection-priority 201 --action Allow --rule-name allowIfconfig --rule-type ApplicationRule --description "ifconfig" \
    --target-fqdns "ifconfig.co" --source-addresses "10.0.0.0/8" --protocols Http=80 Https=443 >/dev/null
az network firewall policy rule-collection-group collection rule add -g $rg --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 --collection-name ifconfig \
    --name ipify --target-fqdns "api.ipify.org" --source-addresses "10.0.0.0/8" --protocols Http=80 Https=443 --rule-type ApplicationRule >/dev/null
# Example application collection with wildcards (*.ubuntu.com)
echo "Creating rule to allow *.ubuntu.com..."
az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
    --name ubuntu --collection-priority 202 --action Allow --rule-name repos --rule-type ApplicationRule --description "ubuntucom" \
    --target-fqdns '*.ubuntu.com' --source-addresses "10.0.0.0/8" --protocols Http=80 Https=443 >/dev/null
}

###################
#  Create vnets   #
###################

# Creates spoke vnets and connects it to hub
# create_spokes <hub_id> <number_of_spokes>
# create_spokes 1 5
function create_spokes {
    hub_id=$1
    hub_name=hub$hub_id
    vhub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    num_of_spokes=$2
    location=$(get_location $hub_id)
    # Create route-table to send traffic to this PC over Internet
    mypip=$(curl -s4 ifconfig.co)
    echo "Creating route table to send traffic to $mypip over the Internet..."
    az network route-table create -n jumphost-$location -g $rg -l $location >/dev/null
    az network route-table route create -n mypc -g $rg --route-table-name jumphost-$location --address-prefix "${mypip}/32" --next-hop-type Internet >/dev/null
    # Create spokes
    echo "Starting creating $num_of_spokes spokes in $location to attach to hub${hub_id}"
    for (( spoke_id=1 ; spoke_id <= ${num_of_spokes}; spoke_id++ ))
    do
        # Set variables
        # Create jump host
        vm_name=spoke${hub_id}${spoke_id}
        pip_name=${vm_name}-pip
        vnet_name=${vm_name}-$location
        vnet_prefix=10.${hub_id}.${spoke_id}.0/24
        subnet_prefix=10.${hub_id}.${spoke_id}.64/26
        vm_ip=10.${hub_id}.${spoke_id}.75
        echo "Creating VM ${vm_name}-jumphost..."
        vm_id=$(az vm show -n $vm_name-jumphost -g $rg --query id -o tsv 2>/dev/null)
        if [[ -z "$vm_id" ]]
        then
            az vm create -n ${vm_name}-jumphost -g $rg -l $location --image ubuntuLTS --generate-ssh-keys --size $vm_size \
                        --public-ip-address $pip_name --vnet-name $vnet_name --vnet-address-prefix $vnet_prefix \
                        --subnet jumphost --subnet-address-prefix $subnet_prefix --private-ip-address $vm_ip --no-wait
        else
            echo "VM $vm_name already exists"
        fi
        # Optionally, add VM without PIP
        # subnet_prefix=10.${hub_id}.${spoke_id}.0/26
        # vm_ip=10.${hub_id}.${spoke_id}.11
        # echo "Creating VM ${vm_name}-test..."
        # az vm create -n ${vm_name}-test -g $rg -l $location --image ubuntuLTS --generate-ssh-keys --size $vm_size \
        #     --public-ip-address "" --vnet-name $vnet_name --vnet-address-prefix $vnet_prefix \
        #     --subnet vm --subnet-address-prefix $subnet_prefix --private-ip-address $vm_ip --no-wait
    done
    # Do another pass to add the IPs to known_hosts and create vnet-hub connections
    for (( spoke_id=1 ; spoke_id <= ${num_of_spokes}; spoke_id++ ))
    do
        hub_id=$1
        vm_name=spoke${hub_id}${spoke_id}
        vnet_name=${vm_name}-$location
        # Attach route table to jumphost subnet for SSH traffic
        echo "Attaching route table jumphost-$location to vnet ${vnet_name}..."
        az network vnet subnet update -n jumphost --vnet-name $vnet_name -g $rg --route-table jumphost-$location >/dev/null
        # Associate vnet to hub
        connect_spoke $hub_id $spoke_id
    done
}

# Return the ip prefix of a spoke
function get_spoke_prefix {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    echo "10.${hub_id}.${spoke_id}${userspoke_id}.0/24"
}

# Return the private IP of the VM in a spoke
function get_spoke_ip {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    echo "10.${hub_id}.${spoke_id}.75"
}

# Return the private IP of the VM in a spoke
function get_spoke_pip {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    pip_name=spoke${hub_id}${spoke_id}${userspoke_id}-pip
    az network public-ip show -n $pip_name -g $rg --query ip Address -o tsv
}


# Connect spoke to hub
function connect_spoke {
    hub_id=$1
    spoke_id=$2
    # Variables
    hub_name=hub${hub_id}
    location=$(get_location $hub_id)
    vm_name=spoke${hub_id}${spoke_id}
    vnet_name=${vm_name}-$location
    echo "Finding out resource ID for vnet ${vnet_name}..."
    vnet_id=$(az network vnet show -n $vnet_name -g $rg --query id -o tsv)
    vhub_base_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/hub${hub_id}"
    vhub_vnetcx_uri="${vhub_base_uri}/hubVirtualNetworkConnections/${vm_name}?api-version=$vwan_api_version"
    # Create JSON
    vnet_cx_json_string=$(jq -n \
            --arg vnet_id "$vnet_id" \
            $vnet_cx_json)
    # Optionally, modify properties for the connection
    # vnet_cx_json_string=$(echo $vnet_cx_json_string | jq '.properties.routingConfiguration.propagatedRouteTables.labels = ["red"]')
    if [ -n "$BASH_VERSION" ]; then
        arr_opt=a
    elif [ -n "$ZSH_VERSION" ]; then
        arr_opt=A
    fi
    echo "Waiting for hub $hub_name and related objects to reach the Succeeded state..."
    wait_until_hub_finished $hub_name
    # Check: if hub is Failed, we can try to reset it
    # We dont do this inside of the wait_until_hub_finished function because we could have infinite recursion
    hub_state=$(get_vhub_state $hub_name)
    if [[ "$hub_state" == "Failed" ]]
    then
        echo "Hub $hub_name is Failed, trying to fix it with a reset"
        reset_vhub "$hub_name"
        wait_until_hub_finished "$hub_name"
    fi
    # Check: if hub is still Failed, do not do anything
    hub_state=$(get_vhub_state "$hub_name")
    if [[ "$hub_state" == "Succeeded" ]]
    then
        echo "Associating vnet $vnet_name to hub ${hub_name}..."
        az rest --method put --uri $vhub_vnetcx_uri --body $vnet_cx_json_string >/dev/null
    else
        echo "Hub $hub_name is $hub_state and could not fix it"
    fi
}

# Disconnect spoke from hub
function disconnect_spoke {
    hub_id=$1
    spoke_id=$2
    # Variables
    if [[ "$hub_id" == "1" ]]
    then
        location=$location1
    else
        location=$location2
    fi
    vm_name=spoke${hub_id}${spoke_id}
    vhub_base_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/hub${hub_id}"
    vhub_vnetcx_uri="${vhub_base_uri}/hubVirtualNetworkConnections/${vm_name}?api-version=$vwan_api_version"
    # DELETE
    echo "Deleting connection $vm_name..."
    az rest --method delete --uri $vhub_vnetcx_uri >/dev/null
}

# Get the PIP associated to the jump host in a spoke
# Example:
#   spoke15_pip=$(get_spoke_pip 1 5)
function get_spoke_pip {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    vm_name=spoke${hub_id}${spoke_id}${userspoke_id}
    pip_name=${vm_name}-pip
    az network public-ip show -n $pip_name -g $rg --query ipAddress -o tsv
}

# Converts the jump host in a vwan spoke to an nva
# Example: convert_to_nva 1 5
function convert_to_nva {
    # Parameters
    hub_id=$1
    spoke_id=$2
    hub_name=hub$1
    vhub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    location=$(get_location $hub_id)
    # IP forwarding
    vm_name=spoke${hub_id}${spoke_id}-jumphost
    echo "Configuring IP forwarding in NIC of VM ${vm_name}..."
    vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    az network nic update --ids $vm_nic_id --ip-forwarding >/dev/null
    # Configure IP forwarding in OS
    echo "Configuring IP forwarding over SSH..."
    vm_pip=$(get_spoke_pip $hub_id $spoke_id)
    remote $vm_pip "sudo sysctl -w net.ipv4.ip_forward=1"
    # Route table for future spokes
    vm_ip=10.${hub_id}.${spoke_id}.75
    rt_name=userhub${hub_id}${spoke_id}
    echo "Creating route table ${rt_name} for indirect spokes..."
    az network route-table create -n $rt_name -g $rg -l $location --disable-bgp-route-propagation >/dev/null
    az network route-table route create -n default -g $rg --route-table-name $rt_name \
        --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $vm_ip >/dev/null
    echo "Finding out our public IP..."
    mypip=$(curl -s4 ifconfig.co) && echo $mypip
    az network route-table route create -n mypc -g $rg --route-table-name $rt_name --address-prefix "${mypip}/32" --next-hop-type Internet >/dev/null
}

# Create a special VWAN spoke with an AzFW (to be used as NVA)
# It gets the number "0"
# Example: create_azfw_spoke 1 (create azfw spoke in hub1)
function create_azfw_spoke {
    hub_id=$1
    hub_name=hub$1
    vhub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    location=$(get_location $hub_id)
    user_hub_prefix="10.${hub_id}.0.0/24"
    user_hub_subnet="10.${hub_id}.0.0/26"
    user_hub_nva_ip="10.${hub_id}.0.10"
    user_hub_fw_subnet="10.${hub_id}.0.128/26"
    # Create FW
    fw_name=userfw${hub_id}
    az network vnet subnet create -n AzureFirewallSubnet --vnet-name userhub-$location -g $rg --address-prefixes $user_hub_fw_subnet
    az network public-ip create -g $rg -n ${fw_name}-pip --sku standard --allocation-method static -l $location
    az network firewall create -n $fw_name -g $rg -l $location
    az network firewall ip-config create -f $fw_name -n userfw-ipconfig -g $rg --public-ip-address userfw1_pip --vnet-name userhub-$location1
    echo "Getting AzFW private IP..."
    userfw_private_ip=$(az network firewall show -n $fw_name -g $rg -o tsv --query 'ipConfigurations[0].privateIpAddress') && echo $userfw_private_ip
}

# Creates "user spoke" or "nva spoke", a vnet peered to a vhub spoke (but not to a vhub)
# Example: create_userspoke 2 5 1 (creates userspoke 1 peered to spoke 5 in location2)
function create_userspoke {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    hub_name=hub$1
    vhub_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    location=$(get_location $hub_id)
    vm_name=spoke${hub_id}${spoke_id}${userspoke_id}
    pip_name=${vm_name}-pip
    vnet_name=${vm_name}-$location
    vnet_prefix=10.${hub_id}.${spoke_id}${userspoke_id}.0/24
    subnet_prefix=10.${hub_id}.${spoke_id}${userspoke_id}.64/26
    vm_ip=10.${hub_id}.${spoke_id}${userspoke_id}.75
    echo "Creating VM ${vm_name}-jumphost..."
    az vm create -n ${vm_name}-jumphost -g $rg -l $location --image ubuntuLTS --generate-ssh-keys --size $vm_size \
                --public-ip-address $pip_name --vnet-name $vnet_name --vnet-address-prefix $vnet_prefix \
                --subnet jumphost --subnet-address-prefix $subnet_prefix --private-ip-address $vm_ip --no-wait
}

# Peer "userspoke" (aka "indirect spoke" or "nva spoke") to vwan spoke
# Ex: connect_userspoke 2 5 1 (peer userspoke1 to spoke25)
function connect_userspoke {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    location=$(get_location $hub_id)
    # Vnet peerings
    hub_vnet_name=spoke${hub_id}${spoke_id}-$location
    spoke_vnet_name=spoke${hub_id}${spoke_id}${userspoke_id}-$location
    echo "Creating vnet peerings between $hub_vnet_name and $spoke_vnet_name"
    az network vnet peering create -n spoke${hub_id}${spoke_id}${userspoke_id}to${hub_id}${spoke_id} -g $rg \
        --vnet-name $spoke_vnet_name --remote-vnet $hub_vnet_name --allow-vnet-access --allow-forwarded-traffic >/dev/null
    az network vnet peering create -n spoke${hub_id}${spoke_id}to${hub_id}${spoke_id}${userspoke_id} -g $rg \
        --vnet-name $hub_vnet_name --remote-vnet $spoke_vnet_name --allow-vnet-access --allow-forwarded-traffic >/dev/null
    # Spoke RT
    rt_name=userhub${hub_id}${spoke_id}
    echo "Associating route table $rt_name to vnet $spoke_vnet_name"
    az network vnet subnet update -n vm --vnet-name $spoke_vnet_name -g $rg --route-table $rt_name >/dev/null 2>/dev/null
    az network vnet subnet update -n jumphost --vnet-name $spoke_vnet_name -g $rg --route-table $rt_name >/dev/null 2>/dev/null
}

#################
# CSR functions #
#################

function create_csr {
    hub_id=$1
    branch_id=$2
    location=$(get_location $hub_id)
    hub_name=hub${hub_id}
    branch_name=branch${branch_id}
    branch_vnet_prefix="10.${hub_id}.20${branch_id}.0/24"
    branch_subnet_prefix="10.${hub_id}.20${branch_id}.0/26"
    branch_bgp_ip="10.${hub_id}.20${branch_id}.10"
    # Create CSR
    echo "Creating VM branch${branch_id}-nva in Vnet $branch_vnet_prefix..."
    vm_id=$(az vm show -n branch${branch_id}-nva -g $rg --query id -o tsv 2>/dev/null)
    if [[ -z "$vm_id" ]]
    then
        az vm create -n branch${branch_id}-nva -g $rg -l $location --image ${publisher}:${offer}:${sku}:${version} --size $nva_size \
            --generate-ssh-keys --public-ip-address branch${branch_id}-pip --public-ip-address-allocation static \
            --vnet-name $branch_name --vnet-address-prefix $branch_vnet_prefix --subnet nva --subnet-address-prefix $branch_subnet_prefix \
            --private-ip-address $branch_bgp_ip --no-wait
        sleep 30 # Wait 30 seconds for the creation of the PIP
    else
        echo "VM branch${branch_id}-nva already exists"
    fi
    # Get public IP
    branch_ip=$(az network public-ip show -n branch${branch_id}-pip -g $rg --query ipAddress -o tsv)
    echo "CSR created with IP address $branch_ip"
    # Create site
    # create_site called from connect_branch
    # create_site $hub_id $branch_id $branch_ip $branch_bgp_ip
}

function create_site {
    hub_id=$1
    branch_id=$2
    branch_public_ip=$3
    branch_private_ip=$4
    site_name="hub${hub_id}branch${branch_id}"
    branch_name="branch${hub_id}${branch_id}"
    branch_asn="6550${branch_id}"
    location=$(get_location $hub_id)
    vwan_id=$(az network vwan show -n $vwan_name -g $rg --query id -o tsv) && echo $vwan_id
    vpnsite_json_string=$(jq -n \
        --arg location "$location" \
        --arg vwan_id "$vwan_id" \
        --arg link_name "$branch_name" \
        --arg remote_bgp_ip $branch_private_ip \
        --arg remote_asn $branch_asn \
        --arg remote_pip $branch_public_ip \
        --arg site_prefix ${branch_private_ip}/32 \
        --arg security 'false' \
        $vpnsite_json)
    vpnsite_uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/vpnSites/${site_name}?api-version=$vwan_api_version"
    echo "Creating site $site_name (hub${hub_id} to branch$branch_id)..."
    az rest --method put --uri $vpnsite_uri --body $vpnsite_json_string >/dev/null # PUT
}

##################
# Remote access  #
##################

# Sends a command to all branches
# Example: branch_cmd "show ip route bgp"
function remote_branch_all {
    if [[ -z "$1" ]]
    then
        cmd="sh ip int b"
    else
        cmd=$1
    fi
    branch_ip_list=$(az network public-ip list -g $rg -o tsv --query "[?contains(name,'branch')].[ipAddress]")
    while IFS= read -r branch_ip; do
        echo "\"$cmd\" on CSR with IP ${branch_ip}..."
        remote $branch_ip "$cmd"
    done <<< "$branch_ip_list"
}

function remote_cmd {
    pip_name=$1-pip
    cmd=$2
    pip_ip=$(az network public-ip show -g $rg -n $pip_name -o tsv --query ipAddress)
    remote $pip_ip "$cmd"
}

function ssh_to {
    pip_name=$1-pip
    pip_ip=$(az network public-ip show -g $rg -n $pip_name -o tsv --query ipAddress)
    ssh $pip_ip
}

function ssh_through {
    pip1_name=$1-pip
    pip1_ip=$(az network public-ip show -g $rg -n $pip1_name -o tsv --query ipAddress)
    ssh -J $pip1_ip $2
}


######################
#  Effective routes  #
######################

function get_async_routes {
    uri=$1
    body=$2
    location=$(az rest --method post --uri $uri --body $body --debug 2>&1 | grep Location | cut -d\' -f 4)
    echo "Waiting to get info from $location..."
    wait_interval=5
    sleep $wait_interval
    table=$(az rest --method get --uri $location --query 'value')
    # table=$(az rest --method get --uri $location --query 'value[]' -o table | sed "s|/subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/vwanlab2/providers/Microsoft.Network||g")
    until [[ -n "$table" ]]
    do
        sleep $wait_interval
        table=$(az rest --method get --uri $location --query 'value')
    done
    # Remove verbosity
    table=$(echo $table | sed "s|/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network||g")
    table=$(echo $table | sed "s|/virtualHubs/||g")
    table=$(echo $table | sed "s|/vpnGateways/||g")
    table=$(echo $table | sed "s|/hubVirtualNetworkConnections||g")
    # echo $table | jq
    echo "Route Origin\tAddress Prefixes\tNext Hop Type\tNext Hops\tAS Path"
    echo $table | jq -r '.[] | "\(.routeOrigin)\t\(.addressPrefixes[])\t\(.nextHopType)\t\(.nextHops[])\t\(.asPath)"'
}

function effective_routes_nic {
    hub_id=$1
    spoke_id=$2
    userspoke_id=$3
    nic_name=spoke${hub_id}${spoke_id}${userspoke_id}-jumphostVMNic
    az network nic show-effective-route-table -n $nic_name -g $rg -o table
}

function effective_routes_rt {
    hub_name=$1
    rt_name=$2
    rt_id="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub_name/hubRouteTables/$rt_name"
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$rt_id\", \"virtualWanResourceType\": \"RouteTable\"}"
    get_async_routes $uri $body
}

function effective_routes_vpncx {
    hub_name=$1
    vpncx_name=$2
    vpngw_id=$(az network vhub show -n ${hub_name} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpncx_id=$(az network vpn-gateway connection show -n $vpncx_name --gateway-name $vpngw_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$vpncx_id\", \"virtualWanResourceType\": \"VpnConnection \"}"
    get_async_routes $uri $body
}

function effective_routes_vnetcx {
    hub_name=$1
    cx_name=$2
    cx_id=$(az network vhub connection show -n $cx_name --vhub-name $hub_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$cx_id\", \"virtualWanResourceType\": \"ExpressRouteConnection\"}"
    get_async_routes $uri $body
}

function effective_routes_hub {
    hub_name=$1
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body=""
    get_async_routes $uri $body
}

######################
# Specific scenarios #
######################

function any_to_any {
    # Virtual Hubs
    hubs=$(list_vhub)
    while IFS= read -r hub_name; do
        # Route tables
        rts=$(list_rt $hub_name)
        if [[ -n "$rts" ]]
        then
            while IFS= read -r rt_name; do
                if [[ "$rt_name" == "defaultRouteTable" ]]
                then
                    echo "Deleting static routes from ${hub_name}/${rt_name}..."
                    rt_delete_routes $hub_name $rt_name
                    echo "Adding default label to ${hub_name}/${rt_name}..."
                    # First clear all labels, then add the right one
                    rt_delete_labels $hub_name $rt_name 
                    rt_add_label $hub_name $rt_name default
                elif [[ "$rt_name" == "noneRouteTable" ]]
                then
                    echo "Adding none label to ${hub_name}/${rt_name}..."
                    # First clear all labels, then add the right one
                    rt_delete_labels $hub_name $rt_name 
                    rt_add_label $hub_name $rt_name none
                else
                    echo "Deleting route table ${hub_name}/${rt_name}..."
                    delete_rt $hub_name $rt_name
                fi
                
            done <<< "$rts"
        else
            echo "No route tables in hub $hub_name"
        fi
        # Vnet connections
        vnet_cxs=$(list_vnetcx $hub_name)
        if [[ -n "$vnet_cxs" ]]
        then
            while IFS= read -r vnetcx_name; do
                echo "Setting vnet connection ${hub_name}/${vnetcx_name} to associate/propagate to default..."
                cx_set_rt hub1 spoke11 defaultRouteTable defaultRouteTable default
                echo "Deleting static routes from vnet connection ${hub_name}/${vnetcx_name}..."
                cx_delete_routes $hub_name $cx_name
            done <<< "$vnet_cxs"
        else
            echo "No vnet connections in hub $hub_name"
        fi
    done <<< "$hubs"
    # VPN connections
    vpngws=$(list_vpngw)
    while IFS= read -r gw_name; do
        hub_id=${gw_name: -1}       # This might not always work...
        echo "Looking for VPN connections in gateway ${gw_name}, hub ID $hub_id..."
        vpn_cxs=$(list_vpncx $gw_name)
        if [[ -n "$vpn_cxs" ]]
        then
            while IFS= read -r vpncx_name; do
                echo "Setting VPN connection ${gw_name}/${vpncx_name} to associate/propagate to default"
                vpncx_set_prop_rt $hub_id $vpncx_name hub${hub_id}/defaultRouteTable default
            done <<< "$vpn_cxs"
        else
            echo "No VPN connections in gateway $gw_name"
        fi
    done <<< "$vpngws"
}

###################
#      Help       #
###################

# Note: might not be complete with all functions
function get_help {
    echo 'These functions are defined:'
    echo 'Virtual hubs:'
    echo '  create_vwan <vwan_name>: creates VWAN'
    echo '  create_hub <hub_id> <vwan_name>: creates hub in a VWAN'
    echo '  get_vhub [hub_name]: get JSON for all or one hub'
    echo '  get_vhub_state [hub_name]: get state of all or one hub'
    echo '  reset_vhub <hub_name>: resends hub config'
    echo 'Virtual network connections:'
    echo '  create_spokes <hub_id> <no_of_spokes>: Creates a bunch of vnets in one location'
    echo '  connect_spoke <hub_id> <spoke_id>': connects a spoke to a hub
    echo '  connect_userspoke <hub_id> <spoke_id>': connects a spoke to an NVA vnet
    echo '  disconnect spoke <hub_id> <spoke_id>': disconnects a spoke from a hub
    echo '  get_vnetcx_state <hub_name> [cx_name]: JSON for all or one connections in a hub'
    echo '  get_vnetcx <hub_name> [cx_name]: state of all or one connections in a hub'
    echo '  get_cx_labels <hub_name> <cx_name>: get labels of a vnet connection'
    echo '  cx_set_ass_rt <gw_name> <cx_name> rt1: sets associated RT for a connection'
    echo '  cx_set_prop_rt <gw_name> <cx_name> <rt1,rt2>: sets propagation RT IDs for a connection'
    echo '  cx_set_rt <hub_name> <cx_name> <associated_rt> <prop_rt1,prop_rt2>: sets routing config in cx'
    echo '  cx_add_routes <hub_name> <cx_name> <prefix> <next_hop>: adds a static route to a connection'
    echo '  cx_delete_routes <hub_name> <cx_name>: deletes all static routes'
    echo '  cx_set_prop_labels <hub_name> <cx_name> <label1,label2>: sets propagation labels for a connection'
    echo '  cx_delete_labels <hub_name> <cx_name>: deletes all propagating labels'
    echo '  reset_vhub_cx <hub_name> <cx_name>: resends vnet connection config'
    echo '  get_spoke_ip <hub_id> <spoke_id> [userspoke_id]: gets the private IP of the VM in a spoke'
    echo '  get_spoke_pip <hub_id> <spoke_id> [userspoke_id]: gets the public IP of the VM in a spoke'
    echo 'NVA:'
    echo '  convert_to_nva: converts the Ubuntu VM deployed in a vnet into an NVA'
    echo '  create_userspoke <hub_id> <spoke_id> <userspoke_id>: creates an indirect spoke'
    echo '  create_azfw_spoke <hub_id>: deploys a spoke vnet with an AzFW inside'
    echo 'Route tables:'
    echo '  create_rt <hub_name> <rt_name>: creates a route table'
    echo '  get_rt <hub_name> [rt_name]: JSON for all or one route table'
    echo '  get_rt_state <hub_name> [rt_name]: state for all or one route table'
    echo '  get_rt_labels <hub_name> <rt_name>: get labels for a route table'
    echo '  rt_add_route <hub_name> <cx_name> <prefix> <next_hop>: adds a static route to a route table'
    echo '  rt_delete_routes <hub_name> <rt_name>: deletes all static routes in a route table'
    echo '  rt_add_label <hub_name> <rt_name> <label>'
    echo '  delete_rt_labels <hub_name> <rt_name>: delete all labels of a route table'
    echo '  delete_rt <hub_name> <rt_name>: deletes a route table'
    echo 'VPN gateways:'
    echo '  create_vpngw <hub_id>: creates VPN gateway'
    echo '  delete_vpngw <hub_id>: deletes VPN gateway'
    echo '  get_vpngw [gw_name]: JSON for all or one VPN gateway'
    echo '  get_vpngw [gw_name]: JSON for all or one VPN gateway'
    echo '  get_vpngw_state [gw_name]: state of vpn gateways'
    echo '  get_vpngw_ips <hub_id>: get IP address of VPN gateways in hub'
    echo 'VPN connections:'
    echo '  connect_branch <hub_id> <branch_id>: connect branch to hub'
    echo '  configure_csr <hub_id> <branch_id>: configure a certain CSR to connect to a certain branch'
    echo '  get_vpngw_cx <gw_name> [site_name]: get JSON for all or one connections of a VPN gateway'
    echo '  get_vpngw_cx_state <gw_name>: get state for all or one connections of a VPN gateway'
    echo '  get_vpncx_routing <gw_name>: get routing config for all or one connections of a VPN gateway'
    echo '  get_vpncx_labels <gw_name> <cx_name>: get labels for a connections of a VPN gateway'
    echo '  vpncx_set_prop_rt <gw_name> <cx_name> <rt1,rt2>: sets propagation labels for a connection'
    echo '  vpncx_set_prop_labels <gw_name> <cx_name> <label1,label2>: sets propagation labels for a connection'
    echo 'Cisco CSR routers:'
    echo '  connect_branch <hub_id> <branch_id>: creates a site a connects a CSR to a VPN gw'
    echo '  configure_csr <hub_id> <branch_id>: configures CSR to connect to the VPN GW in a hub'
    echo '  configure_csr_dualhomed <hub1_id> <hub2_id> <branch_id>: configures CSR to connect to the VPN GWs in 2 hubs'
    echo 'Azure Firewall:'
    echo '  create_azfw_policy: creates a preconfigured Azure Firewall policy'
    echo '  create_fw <hub_id>: creates an Azure Firewall in a hub. Assumes a pre-created fw policy'
    echo '  delete_fw <hub_id>: deletes the Azure Firewall in a hub'
    echo 'Connectivity:'
    echo '  remote <ip_address> <command>: sends a command to an IP address over SSH'
    echo '  remote_branch_all <cmd>: sends a command to all CSRs'
    echo '  remote_cmd <cx_name> <cmd>: sends a command to a vnet or vpn connection test device'
    echo '  ssh_to <cx_name>: ssh to the VM in a spoke or a branch'
    echo '  ssh_through <cx_name> <ip>: ssh through a VM in a spoke or a branch to an IP'
    echo 'Effective routes:'
    echo '  effective_routes_nic <hub_id> <spoke_id> [userspoke_id]: gets the effective routes of a NIC'
    echo '  effective_routes_rt <hub_name> <rt_name>: gets the effective routes of a route table'
    echo '  effective_routes_vpncx <hub_name> <cx_name>: gets the effective routes of a VPN connection'
    echo '  effective_routes_vnetcx <hub_name> <cx_name>: gets the effective routes of a vnet connection'
    echo '  effective_routes_hub <hub_name>: gets the effective routes of a hub'
    echo 'Summary:'
    echo '  labels: prints label configuration for all connections and route tables'
    echo '  routing: prints routing configuration for all connections and route tables'
    echo '  state: prints provisioningState for all connections and route tables'
    echo 'Firewall logs:'
    echo '  get_fw_logs_net: shows network rule logs'
    echo '  get_fw_logs_app: shows app rule logs'
    echo 'Maintenance:'
    echo '  stop_vms: stops all CSRs, jump hosts and test vms'
    echo '  start_vms: starts all CSRs, jump hosts and test vms'
    echo '  get_ips: get public IP addresses of jump hosts and CSRs'
}
