############################################################
# Create a BGP lab in Azure using VNGs and Cisco CSR NVAs
# Jose Moreno, August 2020
#
# Example:
# zsh bgp.sh "1:vng:65501,2:vng:65502,3:csr:65001,4:csr:65001" "1:2,1:3,2:4,3:4" mybgprg northeurope Microsoft123!
############################################################

# Waits until a resourced finishes provisioning
# Example: wait_until_finished <resource_id> 
function wait_until_finished {
     wait_interval=60
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
        echo "Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}

# Wait until a public IP address answers via SSH
# The only thing CSR-specific is the command sent
function wait_until_csr_available {
    wait_interval=15
    csr_id=$1
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg --query ipAddress -o tsv)
    echo "Waiting for IP address $csr_ip to answer over SSH..."
    start_time=`date +%s`
    # ssh_command="pwd"  # Using something that works both in IOS and Linux
    ssh_command="show version | include uptime"  # A bit more info (contains VM name and uptime)
    ssh_output=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no $csr_ip $ssh_command 2>/dev/null)
    until [[ -n "$ssh_output" ]]
    do
        sleep $wait_interval
        ssh_output=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no $csr_ip $ssh_command)
    done
    run_time=$(expr `date +%s` - $start_time)
    ((minutes=${run_time}/60))
    ((seconds=${run_time}%60))
    echo "IP address $csr_ip is available (wait time $minutes minutes and $seconds seconds). Answer to SSH command \"$ssh_command\":"
    echo $ssh_output
}

# Wait until all VNGs in the router list finish provisioning
function wait_for_csrs_finished {
    for router in "${routers[@]}"
    do
        type=$(get_router_type $router)
        id=$(get_router_id $router)
        if [[ "$type" == "csr" ]]
        then
            wait_until_csr_available $id
        fi
    done
}


# Creates BGP-enabled VNG
# ASN as parameter is optional
function create_vng {
    id=$1
    asn=$2
    if [[ -n "$2" ]]
    then
        asn=$2
    else
        asn=$(get_router_asn_from_id ${id})
    fi
    vnet_name=azurevnet${id}
    vnet_prefix=10.${id}.0.0/16
    subnet_prefix=10.${id}.0.0/24
    echo "Creating vnet $vnet_name and public IPs..."
    az network vnet create -g $rg -n $vnet_name --address-prefix $vnet_prefix --subnet-name GatewaySubnet --subnet-prefix $subnet_prefix >/dev/null
    az network public-ip create -g $rg -n pip${id}a >/dev/null
    az network public-ip create -g $rg -n pip${id}b >/dev/null
    vng_id=$(az network vnet-gateway show -n vng${id} -g $rg --query id -o tsv 2>/dev/null)
    if [[ -z "${vng_id}" ]]
    then
        echo "Creating VNG vng${id}..."
        az network vnet-gateway create -g $rg --sku VpnGw1 --gateway-type Vpn --vpn-type RouteBased \
        --vnet $vnet_name -n vng${id} --asn $asn --public-ip-address pip${id}a pip${id}b --no-wait
    else
        echo "VNG vng${id} already exists"
    fi
}

# Connect 2 VPN gateways to each other
function connect_gws {
    gw1_id=$1
    gw2_id=$2
    echo "Connecting vng${gw1_id} and vng${gw2_id}. Finding out information about the gateways..." 

    # Using Vnet-to-Vnet connections (no BGP supported)
    # az network vpn-connection create -g $rg -n ${gw1_id}to${gw2_id} \
    #   --enable-bgp --shared-key $psk \
    #   --vnet-gateway1 vng${gw1_id} --vnet-gateway2 vng${gw2_id}

    # Using local gws
    # Create Local Gateways for vpngw1
    vpngw1_name=vng${gw1_id}
    vpngw1_bgp_json=$(az network vnet-gateway show -n $vpngw1_name -g $rg --query 'bgpSettings')
    vpngw1_gw0_pip=$(echo $vpngw1_bgp_json | jq -r '.bgpPeeringAddresses[0].tunnelIpAddresses[0]')
    vpngw1_gw1_pip=$(echo $vpngw1_bgp_json | jq -r '.bgpPeeringAddresses[1].tunnelIpAddresses[0]')
    vpngw1_gw0_bgp_ip=$(echo $vpngw1_bgp_json | jq -r '.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw1_gw1_bgp_ip=$(echo $vpngw1_bgp_json | jq -r '.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    vpngw1_asn=$(echo $vpngw1_bgp_json | jq -r '.asn')
    echo "Extracted info for vpngw1: ASN $vpngw1_asn, GW0 $vpngw1_gw0_pip, $vpngw1_gw0_bgp_ip. GW1 $vpngw1_gw1_pip, $vpngw1_gw1_bgp_ip."
    echo "Creating local network gateways for vng${gw1_id}..."
    az network local-gateway create -g $rg -n ${vpngw1_name}a --gateway-ip-address $vpngw1_gw0_pip \
        --local-address-prefixes ${vpngw1_gw0_bgp_ip}/32 --asn $vpngw1_asn --bgp-peering-address $vpngw1_gw0_bgp_ip --peer-weight 0 >/dev/null
    az network local-gateway create -g $rg -n ${vpngw1_name}b --gateway-ip-address $vpngw1_gw1_pip \
        --local-address-prefixes ${vpngw1_gw1_bgp_ip}/32 --asn $vpngw1_asn --bgp-peering-address $vpngw1_gw1_bgp_ip --peer-weight 0 >/dev/null
    # Create Local Gateways for vpngw2
    vpngw2_name=vng${gw2_id}
    vpngw2_bgp_json=$(az network vnet-gateway show -n $vpngw2_name -g $rg --query 'bgpSettings')
    vpngw2_gw0_pip=$(echo $vpngw2_bgp_json | jq -r '.bgpPeeringAddresses[0].tunnelIpAddresses[0]')
    vpngw2_gw1_pip=$(echo $vpngw2_bgp_json | jq -r '.bgpPeeringAddresses[1].tunnelIpAddresses[0]')
    vpngw2_gw0_bgp_ip=$(echo $vpngw2_bgp_json | jq -r '.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw2_gw1_bgp_ip=$(echo $vpngw2_bgp_json | jq -r '.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    vpngw2_asn=$(echo $vpngw2_bgp_json | jq -r '.asn')
    echo "Extracted info for vpngw2: ASN $vpngw2_asn GW0 $vpngw2_gw0_pip, $vpngw2_gw0_bgp_ip. GW1 $vpngw2_gw1_pip, $vpngw2_gw1_bgp_ip."
    echo "Creating local network gateways for vng${gw2_id}..."
    az network local-gateway create -g $rg -n ${vpngw2_name}a --gateway-ip-address $vpngw2_gw0_pip \
        --local-address-prefixes ${vpngw2_gw0_bgp_ip}/32 --asn $vpngw2_asn --bgp-peering-address $vpngw2_gw0_bgp_ip --peer-weight 0 >/dev/null
    az network local-gateway create -g $rg -n ${vpngw2_name}b --gateway-ip-address $vpngw2_gw1_pip \
        --local-address-prefixes ${vpngw2_gw1_bgp_ip}/32 --asn $vpngw2_asn --bgp-peering-address $vpngw2_gw1_bgp_ip --peer-weight 0 >/dev/null
    # Create connections
    echo "Connecting vng${gw1_id} to local gateways for vng${gw2_id}..."
    az network vpn-connection create -n vng${gw1_id}tovng${gw2_id}a -g $rg --vnet-gateway1 vng${gw1_id} \
        --shared-key $psk --local-gateway2 ${vpngw2_name}a --enable-bgp --routing-weight 0 >/dev/null
    az network vpn-connection create -n vng${gw1_id}tovng${gw2_id}b -g $rg --vnet-gateway1 vng${gw1_id} \
        --shared-key $psk --local-gateway2 ${vpngw2_name}b --enable-bgp --routing-weight 0 >/dev/null
    echo "Connecting vng${gw2_id} to local gateways for vng${gw1_id}..."
    az network vpn-connection create -n vng${gw2_id}tovng${gw1_id}a -g $rg --vnet-gateway1 vng${gw2_id} \
        --shared-key $psk --local-gateway2 ${vpngw1_name}a --enable-bgp --routing-weight 0 >/dev/null
    az network vpn-connection create -n vng${gw2_id}tovng${gw1_id}b -g $rg --vnet-gateway1 vng${gw2_id} \
        --shared-key $psk --local-gateway2 ${vpngw1_name}b --enable-bgp --routing-weight 0 >/dev/null
}

# Creates a CSR NVA to simulate an onprem device
# Example: create_csr 1
function create_csr {
    csr_id=$1
    csr_name=csr${csr_id}
    csr_vnet_prefix="10.20${csr_id}.0.0/16"
    csr_subnet_prefix="10.20${csr_id}.0.0/24"
    csr_bgp_ip="10.20${csr_id}.0.10"
    publisher=cisco
    offer=cisco-csr-1000v
    sku=16_12-byol
    version=$(az vm image list -p $publisher -f $offer -s $sku --all --query '[0].version' -o tsv)
    nva_size=Standard_B2ms
    # Create CSR
    echo "Creating VM csr${csr_id}-nva in Vnet $csr_vnet_prefix..."
    vm_id=$(az vm show -n csr${csr_id}-nva -g $rg --query id -o tsv 2>/dev/null)
    if [[ -z "$vm_id" ]]
    then
        az vm create -n csr${csr_id}-nva -g $rg -l $location --image ${publisher}:${offer}:${sku}:${version} --size $nva_size \
            --generate-ssh-keys --public-ip-address csr${csr_id}-pip --public-ip-address-allocation static \
            --vnet-name $csr_name --vnet-address-prefix $csr_vnet_prefix --subnet nva --subnet-address-prefix $csr_subnet_prefix \
            --private-ip-address $csr_bgp_ip --no-wait
        sleep 30 # Wait 30 seconds for the creation of the PIP
    else
        echo "VM csr${csr_id}-nva already exists"
    fi
    # Adding UDP ports 500 and 4500 to NSG
    nsg_name=csr${csr_id}-nvaNSG
    az network nsg rule create --nsg-name $nsg_name -g $rg -n ike --priority 1010 \
      --source-address-prefixes Internet --destination-port-ranges 500 4500 --access Allow --protocol Udp \
      --description "UDP ports for IKE"  >/dev/null
    # Get public IP
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg --query ipAddress -o tsv)
    # Create Local Network Gateway
    echo "CSR created with IP address $csr_ip. Creating Local Network Gateway now..."
    asn=$(get_router_asn_from_id $csr_id)
    az network local-gateway create -g $rg -n $csr_name --gateway-ip-address $csr_ip \
        --local-address-prefixes ${csr_bgp_ip}/32 --asn $asn --bgp-peering-address $csr_bgp_ip --peer-weight 0 >/dev/null
}

# Connects a CSR to one or two VNGs
function connect_csr {
    csr_id=$1
    gw1_id=$2
    gw2_id=$3
    csr_asn=$(get_router_asn_from_id $csr_id)

    vpngw1_name=vng${gw1_id}
    vpngw1_gw0_pip=$(az network vnet-gateway show -n $vpngw1_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
    vpngw1_gw1_pip=$(az network vnet-gateway show -n $vpngw1_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)
    vpngw1_gw0_bgp_ip=$(az network vnet-gateway show -n $vpngw1_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
    vpngw1_gw1_bgp_ip=$(az network vnet-gateway show -n $vpngw1_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
    echo "Extracted info for vpngw1: Gateway0 $vpngw1_gw0_pip, $vpngw1_gw0_bgp_ip. Gateway1 $vpngw1_gw1_pip, $vpngw1_gw1_bgp_ip."

    if [[ -n "$gw2_id" ]]
    then
        vpngw2_name=vng${gw2_id}
        vpngw2_gw0_pip=$(az network vnet-gateway show -n $vpngw2_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
        vpngw2_gw1_pip=$(az network vnet-gateway show -n $vpngw2_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)
        vpngw2_gw0_bgp_ip=$(az network vnet-gateway show -n $vpngw2_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
        vpngw2_gw1_bgp_ip=$(az network vnet-gateway show -n $vpngw2_name -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
        echo "Extracted info for vpngw1: Gateway0 $vpngw2_gw0_pip, $vpngw2_gw0_bgp_ip. Gateway1 $vpngw2_gw1_pip, $vpngw2_gw1_bgp_ip."
    fi

    # Baseline config for IPsec and BGP
    # config_csr_base $csr_id

    # Tunnels for vpngw1
    echo "Configuring tunnels between CSR $csr_id and VPN GW $gw1_d"
    config_csr_tunnel $csr_id ${csr_id}${gw1_id}0 $vpngw1_gw0_pip $vpngw1_gw0_bgp_ip $(get_router_asn_from_id $gw1_id)
    config_csr_tunnel $csr_id ${csr_id}${gw1_id}1 $vpngw1_gw1_pip $vpngw1_gw1_bgp_ip $(get_router_asn_from_id $gw1_id)
    if [[ -n "$gw2_id" ]]
    then
      echo "Configuring tunnels between CSR $csr_id and VPN GW $gw2_d"
      config_csr_tunnel $csr_id ${csr_id}${gw2_id}0 $vpngw2_gw0_pip $vpngw2_gw0_bgp_ip $(get_router_asn_from_id $gw2_id)
      config_csr_tunnel $csr_id ${csr_id}${gw2_id}1 $vpngw2_gw1_pip $vpngw2_gw1_bgp_ip $(get_router_asn_from_id $gw2_id)
    fi

    # Connect Local GWs to VNGs
    echo "Creating VPN connections in Azure..."
    az network vpn-connection create -n vng${gw1_id}tocsr${csr_id} -g $rg --vnet-gateway1 vng${gw1_id} \
        --shared-key $psk --local-gateway2 csr${csr_id} --enable-bgp --routing-weight 0 >/dev/null
    if [[ -n "$gw2_id" ]]
    then
        az network vpn-connection create -n vng${gw2_id}tocsr${csr_id} -g $rg --vnet-gateway1 vng${gw2_id} \
            --shared-key $psk --local-gateway2 csr${csr_id} --enable-bgp --routing-weight 0 >/dev/null
    fi

}

# Run "show interface ip brief" on CSR
function sh_csr_int {
    csr_id=$1
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg -o tsv --query ipAddress)
    ssh $csr_ip -o StrictHostKeyChecking=no "sh ip int b"
}

# Open an interactive SSH session to a CSR
function ssh_csr {
    csr_id=$1
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg -o tsv --query ipAddress)
    ssh $csr_ip $2
}

# Deploy baseline VPN and BGP config to a Cisco CSR
function config_csr_base {
    csr_id=$1
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg -o tsv --query ipAddress)
    asn=$(get_router_asn_from_id $csr_id)
    myip=$(curl -s4 ifconfig.co)
    # Check we have a valid IP
    until [[ $myip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
    do
        sleep 5
        myip=$(curl -s4 ifconfig.co)
    done
    echo "Our IP seems to be $myip"
    default_gateway="10.20${csr_id}.0.1"
    echo "Configuring CSR ${csr_ip} for VPN and BGP..."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $csr_ip <<EOF
    config t
      crypto ikev2 keyring azure-keyring
      crypto ikev2 proposal azure-proposal
        encryption aes-cbc-256 aes-cbc-128 3des
        integrity sha1
        group 2
      crypto ikev2 policy azure-policy
        proposal azure-proposal
      crypto ikev2 profile azure-profile
        match address local interface GigabitEthernet1
        authentication remote pre-share
        authentication local pre-share
        keyring local azure-keyring
      crypto ipsec transform-set azure-ipsec-proposal-set esp-aes 256 esp-sha-hmac
        mode tunnel
      crypto ipsec profile azure-vti
        set security-association lifetime kilobytes 102400000
        set transform-set azure-ipsec-proposal-set
        set ikev2-profile azure-profile
      router bgp $asn
        bgp router-id interface GigabitEthernet1
        bgp log-neighbor-changes
        redistribute connected
      ip route $myip 255.255.255.255 $default_gateway
    end
    wr mem
EOF
}

# Configure a tunnel a BGP neighbor for a specific remote endpoint on a Cisco CSR
function config_csr_tunnel {
    csr_id=$1
    tunnel_id=$2
    public_ip=$3
    private_ip=$4
    remote_asn=$5
    asn=$(get_router_asn_from_id ${csr_id})
    default_gateway="10.20${csr_id}.0.1"
    csr_ip=$(az network public-ip show -n csr${csr_id}-pip -g $rg -o tsv --query ipAddress)
    echo "Configuring tunnel $tunnel_id in CSR ${csr_ip}..."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $csr_ip <<EOF
    config t
      crypto ikev2 keyring azure-keyring
        peer $public_ip
          address $public_ip
          pre-shared-key $psk
      crypto ikev2 profile azure-profile
        match identity remote address $public_ip 255.255.255.255
      interface Tunnel${tunnel_id}
        ip unnumbered GigabitEthernet1
        ip tcp adjust-mss 1350
        tunnel source GigabitEthernet1
        tunnel mode ipsec ipv4
        tunnel destination $public_ip
        tunnel protection ipsec profile azure-vti
      router bgp $asn
        neighbor $private_ip remote-as $remote_asn
        neighbor $private_ip ebgp-multihop 5
        neighbor $private_ip update-source GigabitEthernet1
      ip route $private_ip 255.255.255.255 Tunnel${tunnel_id}
      ip route $public_ip 255.255.255.255 $default_gateway
    end
    wr mem
EOF
}

# Connect two CSRs to each other over IPsec and BGP
function connect_csrs {
    csr1_id=$1
    csr2_id=$2
    csr1_ip=$(az network public-ip show -n csr${csr1_id}-pip -g $rg -o tsv --query ipAddress)
    csr2_ip=$(az network public-ip show -n csr${csr2_id}-pip -g $rg -o tsv --query ipAddress)
    csr1_asn=$(get_router_asn_from_id ${csr1_id})
    csr2_asn=$(get_router_asn_from_id ${csr2_id})
    csr1_bgp_ip="10.20${csr1_id}.0.10"
    csr2_bgp_ip="10.20${csr2_id}.0.10"
    # Tunnel from csr1 to csr2
    tunnel_id=${csr1_id}${csr2_id}
    config_csr_tunnel $csr1_id $tunnel_id $csr2_ip $csr2_bgp_ip $csr2_asn
    # Tunnel from csr2 to csr1
    tunnel_id=${csr2_id}${csr1_id}
    config_csr_tunnel $csr2_id $tunnel_id $csr1_ip $csr1_bgp_ip $csr1_asn
}

# Configure logging
function init_log {
    logws_created=$(az monitor log-analytics workspace list -g $rg --query '[0].name' -o tsv)
    if [[ -z $logws_created ]]
    then
        logws_name=log$RANDOM
        echo "Creating LA workspace $logws_name..."
        az monitor log-analytics workspace create -n $logws_name -g $rg >/dev/null
    else
        logws_name=$(az monitor log-analytics workspace list -g $rg --query '[0].name' -o tsv)  # In case the log analytics workspace already exists
        echo "Found log analytics workspace $logws_name"
    fi
    logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
    logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
}

# Configures a certain VNG for logging to a previously created LA workspace
function log_gw {
  gw_id=$1
  vpngw_id=$(az network vnet-gateway show -n vng${gw_id} -g $rg --query id -o tsv)
  echo "Configuring diagnostic settings for gateway vng${gw_id}"
  az monitor diagnostic-settings create -n mydiag --resource $vpngw_id --workspace $logws_id \
      --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
      --logs '[{"category": "GatewayDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
              {"category": "TunnelDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
              {"category": "RouteDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
              {"category": "IKEDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
}

# Gets IKE logs from Log Analytics
# Possible improvements:
# - Supply time and max number of msgs as parameters
function get_ike_logs {
  query='AzureDiagnostics 
  | where ResourceType == "VIRTUALNETWORKGATEWAYS" 
  | where Category == "IKEDiagnosticLog" 
  | where TimeGenerated >= ago(5m) 
  | project Message
  | take 20'
  az monitor log-analytics query -w $logws_customerid --analytics-query $query -o tsv
}

# Creates a connection between two routers
# The function to call depends on whether they are CSRs or VNGs
function create_connection {
      # Split router_params, different syntax for BASH and ZSH
      if [ -n "$BASH_VERSION" ]; then
          arr_opt=a
      elif [ -n "$ZSH_VERSION" ]; then
          arr_opt=A
      fi
      IFS=':' read -r"$arr_opt" router_params <<< "$1"
      if [ -n "$BASH_VERSION" ]; then
          router1_id="${router_params[0]}"
          router2_id="${router_params[1]}"
      elif [ -n "$ZSH_VERSION" ]; then
          router1_id="${router_params[1]}"
          router2_id="${router_params[2]}"
      fi
      router1_type=$(get_router_type_from_id $router1_id)
      router2_type=$(get_router_type_from_id $router2_id)
      echo "Creating connection between ${router1_type}${router1_id} and ${router2_type}${router2_id}..."
      if [[ "$router1_type" == "vng" ]]
      then
          # VNG-to-VNG
          if [[ "$router2_type" == "vng" ]]
          then
              connect_gws $router1_id $router2_id
          # VNG-to-CSR
          else
              connect_csr $router2_id $router1_id
          fi
      else
          # CSR-to-VNG
          if [[ "$router2_type" == "vng" ]]
          then
              connect_csr $router1_id $router2_id
          # CSR-to-CSR
          else
              connect_csrs $router1_id $router2_id
          fi
      fi
}

# Get router type for a specific router ID
function get_router_type_from_id {
    id=$1
    for router in "${routers[@]}"
    do
        this_id=$(get_router_id $router)
        if [[ "$id" -eq "$this_id" ]]
        then
            get_router_type $router
        fi
    done
}

# Get router ASN for a specific router ID
function get_router_asn_from_id {
    id=$1
    for router in "${routers[@]}"
    do
        this_id=$(get_router_id $router)
        if [[ "$id" -eq "$this_id" ]]
        then
            get_router_asn $router
        fi
    done
}


# Create a VNG or a CSR, configuration given by a colon-separated parameter string (like "1:vng:65515")
function create_router {
    type=$(get_router_type $router)
    id=$(get_router_id $router)
    asn=$(get_router_asn $router)
    echo "Creating $type $id with ASN $asn..."
    case $type in
    "vng")
        create_vng $id $asn
        ;;
    "csr")
        create_csr $id
        ;;
    esac
}

# Gets the type out of a router configuration (like csr in "1:csr:65515")
function get_router_type {
      # Split router_params, different syntax for BASH and ZSH
      if [ -n "$BASH_VERSION" ]; then
          arr_opt=a
      elif [ -n "$ZSH_VERSION" ]; then
          arr_opt=A
      fi
      IFS=':' read -r"$arr_opt" router_params <<< "$1"
      # In BASH array indexes start with 0, in ZSH with 1
      if [ -n "$BASH_VERSION" ]; then
          echo "${router_params[1]}"
      elif [ -n "$ZSH_VERSION" ]; then
          echo "${router_params[2]}"
      fi
}

# Gets the ID out of a router configuration (like 1 in "1:csr:65515")
function get_router_id {
      # Split router_params, different syntax for BASH and ZSH
      if [ -n "$BASH_VERSION" ]; then
          arr_opt=a
      elif [ -n "$ZSH_VERSION" ]; then
          arr_opt=A
      fi
      IFS=':' read -r"$arr_opt" router_params <<< "$1"
      # In BASH array indexes start with 0, in ZSH with 1
      if [ -n "$BASH_VERSION" ]; then
          echo "${router_params[0]}"
      elif [ -n "$ZSH_VERSION" ]; then
          echo "${router_params[1]}"
      fi
}

# Gets the ASN out of a router configuration (like 65001 in "1:csr:65001")
function get_router_asn {
      # Split router_params, different syntax for BASH and ZSH
      if [ -n "$BASH_VERSION" ]; then
          arr_opt=a
      elif [ -n "$ZSH_VERSION" ]; then
          arr_opt=A
      fi
      IFS=':' read -r"$arr_opt" router_params <<< "$1"
      # In BASH array indexes start with 0, in ZSH with 1
      if [ -n "$BASH_VERSION" ]; then
          echo "${router_params[2]}"
      elif [ -n "$ZSH_VERSION" ]; then
          echo "${router_params[3]}"
      fi
}

# Wait until all VNGs in the router list finish provisioning
function wait_for_gws_finished {
    for router in "${routers[@]}"
    do
        type=$(get_router_type $router)
        id=$(get_router_id $router)
        if [[ "$type" == "vng" ]]
        then
            vng_name=vng${id}
            vpngw_id=$(az network vnet-gateway show -n $vng_name -g $rg --query id -o tsv)
            wait_until_finished $vpngw_id
        fi
    done
}

# Configure logging to LA for all gateways
function config_gw_logging {
    for router in "${routers[@]}"
    do
        type=$(get_router_type $router)
        id=$(get_router_id $router)
        if [[ "$type" == "vng" ]]
        then
            log_gw $id
        fi
    done
}

# Deploy base config for all CSRs
function config_csrs_base {
    for router in "${routers[@]}"
    do
        type=$(get_router_type $router)
        id=$(get_router_id $router)
        if [[ "$type" == "csr" ]]
        then
            config_csr_base $id
        fi
    done
}

# Converts a CSV list to a shell array
function convert_csv_to_array {
    if [ -n "$BASH_VERSION" ]; then
        arr_opt=a
    elif [ -n "$ZSH_VERSION" ]; then
        arr_opt=A
    fi
    IFS=',' read -r"$arr_opt" array <<< "$1"
    echo $array
}

########
# Main #
########

# Create lab variable from arguments, or use default
if [[ -n "$1" ]]
then
    routers=($(convert_csv_to_array $1))
else
    routers=("1:vng:65501" "2:vng:65502" "3:csr:65001" "4:csr:65001")
fi
if [[ -n "$2" ]]
then
    connections=($(convert_csv_to_array $2))
else
    connections=("1:2" "1:3" "2:4" "3:4")
fi
if [[ -n "$3" ]]
then
    rg=$3
else
    rg=bgp
fi
if [[ -n "$4" ]]
then
    location=$4
else
    location=westeurope
fi
if [[ -n "$5" ]]
then
    psk=$5
else
    psk=Microsoft123!
fi

# Create resource group
echo "Creating resource group $rg..."
az group create -n $rg -l $location >/dev/null

# Deploy CSRs and VNGs
for router in "${routers[@]}"
do
    create_router $router
done

# Config BGP routers
wait_for_csrs_finished
config_csrs_base

# Wait for VNGs to finish provisioning and configuring logging
wait_for_gws_finished
init_log
config_gw_logging

# Configure connections
for connection in "${connections[@]}"
do
    create_connection $connection
done

# Sample diagnostics commands:
# az network vnet-gateway list -g $rg -o table
# az network local-gateway list -g $rg -o table
# az network vpn-connection list -g $rg -o table
# az network public-ip list -g $rg -o table
# az network vnet-gateway list-bgp-peer-status -n vng1 -g $rg -o table
# az network vnet-gateway list-learned-routes -n vng1 -g $rg -o table
# az network vnet-gateway list-advertised-routes -n vng1 -g $rg -o table
# sh_csr_int 4

