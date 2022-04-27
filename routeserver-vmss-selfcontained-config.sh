#!/bin/bash

# Initialization
log_file='/root/routeserver.log'
date >>$log_file

# Read metadata
metadata=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01")
# echo "$metadata" >>$log_file
az login --identity
subscription_id=$(az account show --query id -o tsv)
echo "Logged into subscription ID $subscription_id" >>$log_file
myname=$(echo "$metadata" | jq -r '.compute.name')
rg=$(echo "$metadata" | jq -r '.compute.resourceGroupName')

# Get RS name (assuming it is the only one in the same RG)
rs_name=$(az network routeserver list -g "$rg" --query '[0].name' -o tsv)

# Get local IP and ASN
myasn=$(grep 'local as' /etc/bird/bird.conf | head -1)
myasn=$(echo "$myasn" | cut -d ' ' -f 3 | cut -d ';' -f 1)
myip=$(hostname -I)

# Configure ARS
echo "Configuring ARS $rs_name in RG $rg to peer to $myname on IP address $myip and ASN $myasn..." >>$log_file
az network routeserver peering create --routeserver "$rs_name" -g "$rg" --peer-ip "$myip" --peer-asn "$myasn" -n "$myname" -o none