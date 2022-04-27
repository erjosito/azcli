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
myasn=$(grep 'local as' /etc/bird/bird.conf | head -1)
myasn=$(echo "$myasn" | awk '{print $3}' | cut -d ';' -f 1)
myip=$(hostname -I | tr -d ' ')

# Look for another peer with the same IP
existing_peer=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query "[?peerIp=='$myip']" -o json)
existing_peer_name=$(echo "$existing_peer" | jq -r '.[0].name' 2>/dev/null)
existing_peer_asn=$(echo "$existing_peer" | jq -r '.[0].peerAsn' 2>/dev/null)
if [[ -n $existing_peer_name ]]; then
    if [[ "$existing_peer_name" == "$myname" ]] && [[ "$existing_peer_asn" == "$myasn" ]]; then
        echo "Peer $existing_peer_name already found in ARS $rs_name, no need to do anything" | adddate >>$log_file
    else
        echo "Deleting existing peer $existing_peer_name with ASN $existing_peer_asn, does not match $myname and $myasn..." | adddate >>$log_file
        az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$existing_peer_name" -o none
        echo "Configuring ARS $rs_name in RG $rg to peer to $myname on IP address $myip and ASN $myasn..." | adddate >>$log_file
        az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none
    fi
else
    # Look for an existing peer with the same name
    echo "No existing RS peer found with the IP address $myip" | adddate >>$log_file
    existing_peer=$(az network routeserver peering list --routeserver "$rs_name" -g "$rg" --query "[?name=='$myname']" -o json)
    existing_peer_ip=$(echo "$existing_peer" | jq -r '.[0].peerIp' 2>/dev/null)
    existing_peer_asn=$(echo "$existing_peer" | jq -r '.[0].peerAsn' 2>/dev/null)
    if [[ -n $existing_peer_ip ]]; then
        if [[ "$existing_peer_ip" == "$myip" ]] && [[ "$existing_peer_asn" == "$myasn" ]]; then
            echo "Peer $existing_peer_name already found in ARS $rs_name, no need to do anything" | adddate >>$log_file
        else
            echo "Deleting existing peer with IP $existing_peer_ip ASN $existing_peer_asn, does not match $myip and $myasn..." | adddate >>$log_file
            az network routeserver peering delete --routeserver "$rs_name" -g "$rg" -n "$myname" -o none
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

# Update routes in bird.conf
# sed -i "27i\\$text$station" /etc/bird/bird.conf