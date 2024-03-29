#!/bin/bash

# Initialization
log_file='/root/routeserver.log'

# Function to add date to log message
function adddate() {
    while IFS= read -r line; do
        printf '%s %s\n' "$(date --iso-8601=seconds)" "$line";
    done
}

# Start
echo "Starting configuration process..." | adddate >>$log_file
# Read metadata
metadata=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01")
# echo "$metadata" | adddate >>$log_file
az login --identity -o none
subscription_id=$(az account show --query id -o tsv)
echo "Logged into subscription ID $subscription_id" | adddate >>$log_file
myname=$(echo "$metadata" | jq -r '.compute.name')
rg=$(echo "$metadata" | jq -r '.compute.resourceGroupName')

# Get RS name (assuming it is the only one in the same RG)
rs_name=$(az network routeserver list -g "$rg" --query '[0].name' -o tsv)

# Get local IP and ASN
myasn=$(grep 'local as' /etc/bird/bird.conf.template | head -1)
myasn=$(echo "$myasn" | awk '{print $3}' | cut -d ';' -f 1)
myip=$(hostname -I | tr -d ' ')

# Sometimes cloudinit doesnt make it on time to create the /etc/bird/bird.conf.template file
if [[ -z "$myasn" ]]; then
    sleep 30
    myasn=$(grep 'local as' /etc/bird/bird.conf.template | head -1)
    myasn=$(echo "$myasn" | awk '{print $3}' | cut -d ';' -f 1)
fi

if [[ -z "$myasn" ]] || [[ -z "$rs_name" ]] || [[ -z "$subscription_id" ]]; then
    echo "Could not retrieve required variables, exiting now..." | adddate >>$log_file
    exit 1
fi

# Look for another peer with the same IP
existing_peer=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query "[?peerIp=='$myip']" -o json)
existing_peer_name=$(echo "$existing_peer" | jq -r '.[0].name' 2>/dev/null)
existing_peer_asn=$(echo "$existing_peer" | jq -r '.[0].peerAsn' 2>/dev/null)
existing_peer_state=$(echo "$existing_peer" | jq -r '.[0].provisioningState' 2>/dev/null)
if [[ -n $existing_peer_name ]]; then
    if [[ "$existing_peer_name" == "$myname" ]] && [[ "$existing_peer_asn" == "$myasn" ]]; then
        if [[ "$existing_peer_state" == "Failed" ]]; then
            echo "Peer $existing_peer_name already found in ARS $rs_name with state $existing_peer_state, deleting and recreating..." | adddate >>$log_file
            az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$existing_peer_name" -y -o none
            az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
        else
            echo "Peer $existing_peer_name already found in ARS $rs_name with state $existing_peer_state, no need to do anything" | adddate >>$log_file
        fi
    else
        echo "Deleting existing peer $existing_peer_name with IP $myip and ASN $existing_peer_asn, does not match $myname and $myasn..." | adddate >>$log_file
        az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$existing_peer_name" -y -o none
        echo "Configuring ARS $rs_name in RG $rg to peer to $myname on IP address $myip and ASN $myasn..." | adddate >>$log_file
        az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
    fi
else
    # Look for an existing peer with the same name
    echo "No existing RS peer found with the IP address $myip" | adddate >>$log_file
    existing_peer=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query "[?name=='$myname']" -o json)
    existing_peer_ip=$(echo "$existing_peer" | jq -r '.[0].peerIp' 2>/dev/null)
    existing_peer_asn=$(echo "$existing_peer" | jq -r '.[0].peerAsn' 2>/dev/null)
    existing_peer_state=$(echo "$existing_peer" | jq -r '.[0].provisioningState' 2>/dev/null)
    if [[ -n $existing_peer_ip ]]; then
        if [[ "$existing_peer_ip" == "$myip" ]] && [[ "$existing_peer_asn" == "$myasn" ]]; then
            if [[ "$existing_peer_state" == "Failed" ]]; then
                echo "Peer $myname already found in ARS $rs_name with state $existing_peer_state, deleting and recreating..." | adddate >>$log_file
                az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$myname" -y -o none
                az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
            else
                echo "Peer $existing_peer_name already found in ARS $rs_name, no need to do anything" | adddate >>$log_file
            fi
        else
            echo "Deleting existing peer $myname with IP $existing_peer_ip ASN $existing_peer_asn, does not match $myip and $myasn..." | adddate >>$log_file
            az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$myname" -y -o none
            echo "Configuring ARS $rs_name in RG $rg to peer to $myname on IP address $myip and ASN $myasn..." | adddate >>$log_file
            az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
        fi
    # No peer was found with the same name or IP
    else
        echo "No existing RS peer found with the name $myname" | adddate >>$log_file
        echo "Configuring ARS $rs_name in RG $rg to peer to $myname on IP address $myip and ASN $myasn..." | adddate >>$log_file
        az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
    fi
fi

# Update routes in bird.conf if the files have changed
# First download the routes and compare to the existing ones
routes_url=$(cat /root/routes_url)
if [[ -e /root/routes.txt ]]; then
    mv /root/routes.txt /root/routes.old.txt
else
    touch /root/routes.old.txt
fi
wget -q -O /root/routes.txt "$routes_url"
route_no=$(cat /root/routes.txt | wc -l)
echo "$route_no routes downloaded from $routes_url, adding now to BIRD configuration..." | adddate >>$log_file
if cmp -s /root/routes.txt /root/routes.old.txt; then
    echo "No change in downloaded routes, nothing else to do." | adddate >>$log_file
else
    file_name=/etc/bird/bird.conf
    cp /etc/bird/bird.conf.template $file_name
    default_gw=$(/sbin/ip route | awk '/default/ { print $3 }')
    line_no=$(grep -n '# Routes advertised' $file_name | cut -d: -f1)
    line_no=$((line_no+1))
    routes=$(cat /root/routes.txt)
    for prefix in $routes; do
        echo "Adding route for $prefix to BIRD configuration..." | adddate >>$log_file
        sed -i "${line_no}i\\    route $prefix via ${default_gw};" "$file_name"
    done
    systemctl restart bird
fi
rm /root/routes.old.txt

# Cleanup not used adjacencies from ARS. Get private IP addresses of the VMSS
vmss_name=$(echo "$metadata" | jq -r '.compute.vmScaleSetName')
vmss_ips=$(az vmss nic list --vmss-name "$vmss_name" -g "$rg" --query '[].ipConfigurations[].privateIpAddress' -o tsv)
peer_ips=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query '[].peerIp' -o tsv)
for peer_ip in $peer_ips; do
    echo "Seeing if RS peer $peer_ip can be deleted..." | adddate >>$log_file
    match="false"
    for vmss_ip in $vmss_ips; do
        if [[ "$peer_ip" == "$vmss_ip" ]]; then
            match="true"
        fi
    done
    # If no match was found, it means that there is a BGP peer for some IP that does not exist in the VMSS
    if [[ "$match" == "false" ]]; then
        rs_peer=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query "[?peerIp=='$peer_ip']" -o json)
        rs_peer_name=$(echo "$rs_peer" | jq -r '.[0].name' 2>/dev/null)
        if [[ -n "$rs_peer_name" ]]; then
            echo "Deleting BGP peer $rs_peer_name with IP address $peer_ip..." | adddate >>$log_file
            az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$rs_peer_name" -y -o none
        else
            echo "Could not find name for BGP peer with IP address $peer_ip" | adddate >>$log_file
        fi
    fi
done
