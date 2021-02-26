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
    wget "https://${storage_account_name}.blob.core.windows.net/${storage_container_name}/vti.csv?${sas}" -O ./vti.csv.new
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
    touch ./vti.csv
    if [[ -n "$(diff ./vti.csv.new ./vti.csv)" ]]
    then
        while read line; do
            local_pip=$(echo "$line" | cut -d, -f 1)
            local_ip=$(echo "$line" | cut -d, -f 2)
            remote_pip=$(echo "$line" | cut -d, -f 3)
            remote_ip=$(echo "$line" | cut -d, -f 4)
            if_name=$(echo "$line" | cut -d, -f 5)
            if_mark=$(echo "$line" | cut -d, -f 6)
            ip tunnel add "$if_name" local "$local_ip" remote "$remote_pip" mode vti key "$if_mark"
            ip link set up dev "$if_name"
            sysctl -w "net.ipv4.conf.${if_name}.disable_policy=1"
            sudo ip route add "${remote_ip}/32" dev "${if_name}"
            sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf
        done <./vti.csv.new
        mv ./vti.csv.new ./vti.csv
    else
        rm ./vti.csv.new
    fi
else
    echo "ERROR: Configuration files not found"
fi