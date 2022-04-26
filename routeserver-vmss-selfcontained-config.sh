#!/bin/bash
log_file='/root/routeserver.log'
date >>$log_file
metadata=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01")
echo "$metadata" >>$log_file
az login --identity >>$log_file
rg=$(echo $metadata | jq -r '.compute.resourceGroupName')
rs_name=$(az network routeserver list -g $rg --query '[0].name' -o tsv)
asn=$(grep 'local as' /etc/bird/bird.conf | head -1)
asn=$(echo $asn | cut -d ' ' -f 3 | cut -d ';' -f 1)
myip=$(hostname -I)
echo "ARS $rs_name in RG $rg should be configured to peer with $myip on ASN $asn"
