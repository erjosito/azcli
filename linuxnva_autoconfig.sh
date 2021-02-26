#!/bin/bash
if [[ -f /root/azure.nva.sas ]] && [[ -f /root/azure.nva.account ]] && [[ -f /root/azure.nva.guid ]]
then
    echo "INFO: Configuration files found"
    sas=$(sudo cat /root/azure.nva.sas)
    storage_account_name=$(sudo cat /root/azure.nva.account)
    storage_container_name=$(sudo cat /root/azure.nva.guid)
    wget "https://${storage_account_name}.blob.core.windows.net/${storage_container_name}/ipsec.conf?${sas}" -O ./ipsec.conf
    wget "https://${storage_account_name}.blob.core.windows.net/${storage_container_name}/ipsec.secrets?${sas}" -O ./ipsec.secrets
    wget "https://${storage_account_name}.blob.core.windows.net/${storage_container_name}/bird.conf?${sas}" -O ./bird.conf
    if [[ -n "$(diff ./ipsec.conf /etc/ipsec.conf)" ]] || [[ -n "$(diff ./ipsec.secrets /etc/ipsec.secrets)" ]]
    then
        sudo cp ./ipsec.conf /etc/ipsec.conf
        sudo cp ./ipsec.secrets /etc/ipsec.secrets
        sudo systemctl restart ipsec
    fi
    if [[ -n "$(diff ./bird.conf /etc/bird/bird.conf)" ]]
    then
        sudo cp ./bird.conf /etc/bird/bird.conf
        sudo systemctl restart bird
    fi
else
    echo "ERROR: Configuration files not found"
fi