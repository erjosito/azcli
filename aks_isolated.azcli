#!/usr/bin/env zsh
###############################################
# Created by Jose Moreno                      #
# December 2025                               #
# Extract from more complex script aks.azcli  #
# Some useful commands around AKS isolated    #
# Tested with zsh on WSL2                     #
###############################################

# Control variables
rg=akstest
location=eastus2
wait_interval=5s
flow_logs=yes

# AKS settings
# k8s_version=1.34        # Comment this line to deploy the last version available
aks_private_mode=vnet   # plink/vnet
aks_name=aks
aks_service_cidr=10.0.0.0/16
vm_size=Standard_B2ms         # Some possible values: Standard_B2ms, Standard_D2_v3
gpuvm_size=Standard_NC24ads_A100_v4   # For GPU nodepool
preview_version=yes
network_plugin=azure           # azure/kubenet/none/azure_overlay/azure_cilium
network_policy=none            # azure/calico/cilium/none
azure_cni_pod_subnet=no        # yes/no
az_monitor=no
# VNet and subnets
vnet_name=aksVnet
vnet_prefix=10.13.0.0/16
aks_subnet_name=akspool1
aks_subnet_prefix=10.13.76.0/24  # Min /25 with Azure CNI!
pod_subnet_name=pods
pod_subnet_prefix=10.13.80.0/24
aks_api_subnet_name=aksapi
aks_api_subnet_prefix=10.13.81.0/24
vm_subnet_name=vm
vm_subnet_prefix=10.13.1.0/24
gw_subnet_name=GatewaySubnet
gw_subnet_prefix=10.13.0.0/24
ep_subnet_name=ep
ep_subnet_prefix=10.13.101.0/24
# DNS VM
vm_name=testlinuxvm
vm_size=Standard_B2ms
# VPN GW for P2S connectivity
gw_name=${vnet_name}-gw
gw_pip_name=${vnet_name}-gw-pip
p2s_address_pool='100.64.0.0/24'
p2s_config_file="$HOME/downloads/$(date +%Y%m%d)-vpnclientpackage.zip"
# To create ACR cache for Docker images
docker_username='your_dockerhub_username'
docker_pat='your_dockerhub_pat'

####################
# Helper functions #
####################

# Wait for a resource to be successfully created (when its creation was triggered with the --no-wait option)
function wait_until_finished {
     wait_interval=15
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo "INFO: Waiting for resource $resource_name to finish provisioning..."
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
        echo "ERROR: Something really bad happened..."
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        echo "INFO: Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}

###################
# Enable features #
###################

# Function to enable features on the AKS resource provider
function enableAksFeature () {
    feature_name=$1
    state=$(az feature list -o table --query "[?contains(name, 'microsoft.containerservice/$feature_name')].properties.state" -o tsv)
    if [[ "$state" == "Registered" ]]
    then
        echo "INFO: $feature_name is already registered"
    else
        echo "INFO: Registering feature $feature_name..."
        az feature register --name "$feature_name" --namespace microsoft.containerservice -o none --only-show-errors
        state=$(az feature list -o table --query "[?contains(name, 'microsoft.containerservice/$feature_name')].properties.state" -o tsv)
        echo "INFO: Waiting for feature $feature_name to finish registering..."
        wait_interval=15
        until [[ "$state" == "Registered" ]]
        do
            sleep $wait_interval
            state=$(az feature list -o table --query "[?contains(name, 'microsoft.containerservice/$feature_name')].properties.state" -o tsv)
            echo "INFO: Current registration status for feature $feature_name is $state"
        done
        echo "INFO: Registering resource provider Microsoft.ContainerService now..."
        az provider register --namespace Microsoft.ContainerService -o none --only-show-errors
    fi
}
enableAksFeature "EnableAPIServerVnetIntegrationPreview"
enableAksFeature "ManagedGPUExperiencePreview"

# Update required Az CLI extensions
echo "INFO: Installing/updating aks-preview extension..."
az extension add -n aks-preview --upgrade --only-show-errors

# Configure Az CLI to use extensions if required
echo "INFO: this script configures Az CLI to use extensions as needed, please change back if you don't want this behavior..."
az config set extension.dynamic_install_allow_preview=true --only-show-errors
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

########
# Main #
########

# Create RG, LA workspace, VNet, AKS
echo "INFO: Creating RG and VNet (ignore errors if VNet already exists)..."
az group create -n $rg -l $location -o none
arg_query="resources | where type=~'Microsoft.Network/virtualNetworks' and resourceGroup=~'$rg' and name=~'$vnet_name'"
vnet_id=$(az graph query -q "$arg_query" --query 'data[0].id' -o tsv)
if [[ -n "$vnet_id" ]]; then
    echo "INFO: VNet $vnet_name found in resource group $rg, no need to create a new one"
else
    az network vnet create -g $rg -n $vnet_name --address-prefix $vnet_prefix -l $location -o none
    az network vnet subnet create -g $rg -n $aks_subnet_name --vnet-name $vnet_name --address-prefix $aks_subnet_prefix --default-outbound true -o none
    az network vnet subnet create -g $rg -n $pod_subnet_name --vnet-name $vnet_name --address-prefix $pod_subnet_prefix --default-outbound true -o none
    az network vnet subnet create -g $rg -n $aks_api_subnet_name --vnet-name $vnet_name --address-prefix $aks_api_subnet_prefix -o none
    az network vnet subnet create -g $rg -n $ep_subnet_name --vnet-name $vnet_name --address-prefix $ep_subnet_prefix -o none
    az network vnet subnet create -g $rg -n $vm_subnet_name --vnet-name $vnet_name --address-prefix $vm_subnet_prefix -o none
fi
aks_subnet_id=$(az network vnet subnet show -n $aks_subnet_name --vnet-name $vnet_name -g $rg --query id -o tsv)
pod_subnet_id=$(az network vnet subnet show -n $pod_subnet_name --vnet-name $vnet_name -g $rg --query id -o tsv)

# Create LA workspace if it did not exist
arg_query="resources | where type=~'Microsoft.OperationalInsights/workspaces' and resourceGroup=~'$rg'"
logws_name=$(az graph query -q "$arg_query" --query 'data[0].name' -o tsv)
if [[ -z "$logws_name" ]]
then
    logws_name=log$RANDOM
    echo "INFO: Creating log analytics workspace ${logws_name}..."
    az monitor log-analytics workspace create -n $logws_name -g $rg -o none
else
    echo "INFO: Log Analytics workspace $logws_name found in resource group $rg, no need to create a new one"
fi
logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)

# Flow logs in VNet (optional)
if [[  "$flow_logs" == "yes" ]]; then
    arg_query="resources | where type=~'Microsoft.Storage/storageAccounts' and resourceGroup=~'$rg'"
    storage_account_name=$(az graph query -q "$arg_query" --query 'data[0].name' -o tsv)
    if [[ -z "$storage_account_name" ]]; then
        storage_account_name="logs$RANDOM"  # max 24 characters
        echo "INFO: No storage account found in resource group $rg, creating one..."
        az storage account create -n $storage_account_name -g $rg --sku Standard_LRS --kind StorageV2 -l $location -o none
    else
        echo "INFO: Storage account $storage_account_name found in $location, using it for VNet flow flogs"
    fi
    echo "INFO: Enabling VNet Flow Logs for VNet $vnet_name in storage account $storage_account_name and Log Analytics workspace $logws_name..."
    if [[ -z "$logws_name" ]]; then
        echo "ERROR: Log Analytics workspace is not defined, cannot enable traffic analytics"
    else
        az network watcher flow-log create -l $location -g $rg --name "aks-${aks_name}-${location}" --vnet $vnet_name \
          --storage-account $storage_account_name --workspace $logws_name --interval 10 --traffic-analytics true -o none
    fi
fi

############
# Identity #
############

# Create user assigned managed identity if it did not exist
id_name=aksid
arg_query="resources | where type=~'Microsoft.ManagedIdentity/userAssignedIdentities' and resourceGroup=~'$rg' and name=~'$id_name'"
id_id=$(az graph query -q "$arg_query" --query 'data[0].id' -o tsv)
if [[ -z "$id_id" ]]
then
    echo "INFO: Identity $id_name not found, creating a new one..."
    az identity create -n $id_name -g $rg -o none
    id_id=$(az identity show -n $id_name -g $rg --query id -o tsv)
else
    echo "INFO: Identity $id_name found with ID $id_id"
fi
id_principal_id=$(az identity show -n $id_name -g $rg --query principalId -o tsv)
vnet_id=$(az network vnet show -n $vnet_name -g $rg --query id -o tsv)
sleep 15 # Time for creation to propagate
echo "INFO: Assigning contributor role for identity $id_name on VNet $vnet_name..."
az role assignment create --scope $vnet_id --assignee $id_principal_id --role Contributor -o none
# Kubelet identity
kid_name="${id_name}-kubelet"
arg_query="resources | where type=~'Microsoft.ManagedIdentity/userAssignedIdentities' and resourceGroup=~'$rg' and name=~'$kid_name'"
kid_id=$(az graph query -q "$arg_query" --query 'data[0].id' -o tsv)
if [[ -z "$kid_id" ]]
then
    echo "INFO: Kubelet identity $kid_name not found, creating a new one..."
    az identity create -n $kid_name -g $rg -o none
    kid_id=$(az identity show -n $kid_name -g $rg --query id -o tsv)
else
    echo "INFO: Kubelet identity $kid_name found with ID $kid_id"
fi
kid_principal_id=$(az identity show -n $kid_name -g $rg --query principalId -o tsv)

##############
# Networking #
##############

# CNI options
aks_subnet_id=$(az network vnet subnet show -n $aks_subnet_name --vnet-name $vnet_name -g $rg --query id -o tsv)
pod_subnet_id=$(az network vnet subnet show -n $pod_subnet_name --vnet-name $vnet_name -g $rg --query id -o tsv)
if [[ "$network_plugin" == 'azure' ]]; then
    if [[ "$azure_cni_pod_subnet" == "yes" ]]; then
      cni_options="--network-plugin azure --pod-subnet-id $pod_subnet_id"
    else
      cni_options="--network-plugin azure"
    fi
elif [[ "$network_plugin" == 'kubenet' ]]; then
    cni_options="--network-plugin kubenet"
elif [[ "$network_plugin" == 'azure_cilium' ]]; then
    cni_options="--network-plugin azure --network-dataplane cilium --pod-subnet-id $pod_subnet_id"
    if [[ "$network_policy" != "cilium" ]]; then
        echo "ERROR: Network policy must be cilium when using azure_cilium. Setting network policy to cilium..."
        network_policy=cilium
    fi
elif [[ "$network_plugin" == 'azure_overlay' ]]; then
    cni_options="--network-plugin azure --network-dataplane cilium --network-plugin-mode overlay"
    if [[ "$network_policy" != "cilium" ]]; then
        echo "ERROR: Network policy must be cilium when using azure_cilium. Setting network policy to cilium..."
    fi
    network_policy=cilium
else
    echo "ERROR: Network plugin $network_plugin not supported"
    exit 1
fi
# Change network policy format if none specified
if [[ "$network_policy" == 'none' ]]; then
    network_policy="''"
fi
if [[ -n "$network_policy" ]] && [[ "$network_policy" != "''" ]]; then
    cni_options+=" --network-policy $network_policy"
fi

###############
# VPN and DNS #
###############

# Create VPN gateway (using the --no-wait flag). An alternative is to create an Azure Bastion host
echo "INFO: Creating VPN gateway for isolated AKS cluster (using '--no-wait' flag)..."
az network public-ip create -g $rg -n $gw_pip_name --sku Standard --allocation-method Static -o none
az network vnet subnet create -g $rg -n $gw_subnet_name --vnet-name $vnet_name --address-prefix $gw_subnet_prefix -o none
az network vnet-gateway create -g $rg -n $gw_name --public-ip-address $gw_pip_name --vnet $vnet_name --sku VpnGw1 -o none --only-show-errors --no-wait

# Create DNS server on a Linux VM with dnsmasq
echo "INFO: creating DNS server VM '${vm_name}' in subnet '${vm_subnet_name}'..."
vm_pip_name="${vm_name}-pip"
az vm create -n $vm_name -g $rg --image Ubuntu2204 --generate-ssh-keys --size $vm_size -l $location \
    --vnet-name $vnet_name --subnet $vm_subnet_name --public-ip-address $vm_pip_name --public-ip-sku Standard -o none --only-show-errors
vm_pip=$(az network public-ip show -n $vm_pip_name -g $rg --query ipAddress -o tsv)
vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
vm_privateip=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].privateIPAddress' -o tsv)
echo "DNS server deployed to $vm_privateip, $vm_pip"
echo "Installing dnsmasq in VM ${vm_name}..."
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo apt update -y && sudo apt -y install dnsmasq"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo sed -i '$ a\log-queries' /etc/dnsmasq.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo sed -i '/\-\-local\-service/s/^/#/' /etc/init.d/dnsmasq"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo systemctl disable systemd-resolved"
# From now on until DNS is fully configured, commands will be very slow, as DNS is not working
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$vm_pip" "sudo sed -i \"\$ a 168.63.129.16 dnsserver\" /etc/hosts"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$vm_pip" "sudo sed -i \"\$ a 127.0.0.1 $vm_name\" /etc/hosts"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo systemctl stop systemd-resolved"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo unlink /etc/resolv.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "echo nameserver 168.63.129.16 | sudo tee /etc/resolv.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo systemctl restart dnsmasq"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo systemctl enable dnsmasq"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo systemctl status dnsmasq"

###############
#     ACR     #
###############

# Create ACR with private link
arg_query="resources | where type=~'Microsoft.ContainerRegistry/registries' and resourceGroup=~'$rg'"
acr_name=$(az graph query -q "$arg_query" --query 'data[0].name' -o tsv)
if [[ -n "$acr_name" ]]; then
    echo "INFO: ACR $acr_name found in resource group $rg, using it for isolated AKS cluster"
    acr_id=$(az acr show -n $acr_name -g $rg --query id -o tsv)
else
    # ACR name must be globally unique
    #acr_name=$(echo $aks_name | tr '[:upper:]' '[:lower:]' | tr -d '-' | tr -d '_')acr$RANDOM
    acr_name=aksacr$RANDOM
    echo "INFO: Creating ACR $acr_name for isolated AKS cluster..."
    az acr create -n $acr_name -g $rg  --sku Premium --public-network-enabled false -o none
    echo "INFO: Configuring cache for ACR $acr_name..."
    az acr cache create -n aks-managed-mcr -r $acr_name -g $rg --source-repo "mcr.microsoft.com/*" --target-repo "aks-managed-repository/*" -o none
    echo "INFO: configuring diagnostic settings for ACR $acr_name..."
    acr_id=$(az acr show -n $acr_name -g $rg --query id -o tsv)
    az monitor diagnostic-settings create -n mydiag --resource $acr_id --workspace $logws_id \
            --logs '[{"category": "ContainerRegistryRepositoryEvents", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
                    {"category": "ContainerRegistryLoginEvents", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' -o none
    # Private endpoint
    echo "INFO: Creating private endpoint for ACR $acr_name..."
    pe_name=${acr_name}-pe
    az network private-endpoint create -n $pe_name -g $rg --vnet-name $vnet_name --subnet $ep_subnet_name \
      --private-connection-resource-id $acr_id --group-id registry --connection-name myConnection -o none
    echo "INFO: Configuring DNS for private endpoint $pe_name..."
    zone_name="privatelink.azurecr.io"
    az network private-dns zone create -g $rg -n $zone_name -o none
    az network private-dns link vnet create -g $rg --zone-name $zone_name -n $vnet_name --virtual-network $vnet_name --registration-enabled false -o none
    az network private-endpoint dns-zone-group create --endpoint-name $pe_name -g $rg -n myzonegroup --zone-name zone1 --private-dns-zone $zone_name -o none
    # RBAC for kubelet identity
    echo "INFO: Assigning AcrPull role for kubelet identity $kid_name on ACR $acr_name..."
    az role assignment create --assignee $kid_principal_id --role AcrPull --scope $acr_id -o none
fi
# AKS isolated options (depends if using vnet or private link)
api_subnet_id=$(az network vnet subnet show -n $aks_api_subnet_name --vnet-name $vnet_name -g $rg --query id -o tsv)
if [[ "$aks_private_mode" == "vnet" ]]; then
    isolated_options="--bootstrap-artifact-source Cache --bootstrap-container-registry-resource-id $acr_id --outbound-type none --enable-private-cluster --enable-apiserver-vnet-integration --apiserver-subnet-id $api_subnet_id"
elif [[ "$aks_private_mode" == "plink" ]]; then
    isolated_options="--bootstrap-artifact-source Cache --bootstrap-container-registry-resource-id $acr_id --outbound-type none --enable-private-cluster --private-dns-zone System --disable-public-fqdn"
fi

###############
#     AKS     #
###############

# Get last version if none was specified
if [[ -z $k8s_version ]]; then
    k8s_last_minor_version=$(az aks get-versions -l $location -o tsv --only-show-errors --query 'values[].version' | sort -u | tail -1)
    k8s_version=$(az aks get-versions -l $location -o json --only-show-errors | jq -r --arg jq_k8s_version $k8s_last_minor_version '.values[] | select(.version == $jq_k8s_version) | .patchVersions | keys[]' | sort -u | tail -1)
fi

# Create AKS (--no-wait)
echo "INFO: Deploying cluster ${aks_name} (with --no-wait option)..."
az aks create -g $rg -n $aks_name -l $location -o none --only-show-errors --no-wait \
    -c 1 -s $vm_size --generate-ssh-keys -u $(whoami) -k $aks_version \
    --enable-managed-identity --assign-identity $id_id --assign-kubelet-identity $kid_id \
    ${(z)cni_options} \
    ${(z)isolated_options} \
    --vnet-subnet-id $aks_subnet_id --service-cidr $aks_service_cidr \
    --load-balancer-sku Standard \
    --node-resource-group "$aks_name"-iaas-"$RANDOM"

#############
# NFS Share #
#############

########################
# NFS Azure file share #
########################

# Create file share (as of today, not all Azure regions support NFS file shares)
file_share_name=myshare$RANDOM
echo "INFO: Creating NFS Azure file share $file_share_name..."
az resource create \
  --resource-type "Microsoft.FileShares/fileShares" \
  --name $file_share_name \
  --location $location \
  --resource-group $rg \
  --properties "{
    \"redundancy\": \"Local\",
    \"protocol\": \"NFS\",
    \"provisionedStorageGiB\": 32,
    \"ProvisionedIoPerSec\": 3032,
    \"ProvisionedThroughputMiBPerSec\": 128,
    \"mediaTier\": \"SSD\",
    \"nfsProtocolProperties\": {
      \"rootSquash\": \"RootSquash\"
    }
}" -o none
# Verify that file share was created successfully
arg_query="resources | where type=~'Microsoft.FileShares/fileShares' and resourceGroup=~'$rg' and name=~'$file_share_name'"
file_share_id=$(az graph query -q "$arg_query" --query 'data[0].id' -o tsv)
if [[ -z "$file_share_id" ]]; then
    echo "ERROR: File share $file_share_name was not created successfully"
else
    echo "INFO: File share $file_share_name created successfully with ID $file_share_id"
    # Create private endpoint
    echo "INFO: Creating private endpoint for file share $file_share_name..."
    file_share_id=$(az resource show -g $rg -n $file_share_name --resource-type "Microsoft.FileShares/fileShares" --query id -o tsv)
    ep_name="${file_share_name}-ep"
    az network private-endpoint create -n $ep_name -g $rg --vnet-name $vnet_name --subnet $ep_subnet_name \
      --private-connection-resource-id $file_share_id --group-ids FileShare --connection-name "${ep_name}-conn" -o none
    # Create DNS zone and records
    echo "INFO: Configuring DNS for private endpoint $ep_name..."
    dns_zone_name="privatelink.file.core.windows.net"
    az network private-dns zone create -g $rg -n $dns_zone_name -o none
    az network private-dns link vnet create -g $rg -n "${vnet_name}-link" --virtual-network $vnet_name --zone-name $dns_zone_name --registration-enabled false -o none
    az network private-endpoint dns-zone-group create -g $rg -n "${ep_name}-dnszonegroup" --endpoint-name $ep_name --private-dns-zone $dns_zone_name --zone-name file -o none
    # Check the A records in the DNS zone
    echo "INFO: Listing A records in DNS zone $dns_zone_name..."
    az network private-dns record-set a list -z $dns_zone_name -g $rg --query '[].{IP:aRecords[0].ipv4Address, FQDN:fqdn, Creator:metadata.creator}' -o table
    # Output instructions
    file_share_hostname=$(az resource show -g $rg -n $file_share_name --resource-type "Microsoft.FileShares/fileShares" --query properties.hostName -o tsv)
    storage_account_name=$(echo $file_share_hostname | cut -d'.' -f1)
    echo "INFO: File share created: $file_share_name"
    echo "INFO: To mount the file share in a VM, use the following command:"
    echo "INFO: sudo mount -t nfs ${file_share_hostname}:/${storage_account_name}/${file_share_name} /mnt/azure -o vers=4,minorversion=1,sec=sys"
fi

####################
# Add GPU nodepool #
####################

# Wait until AKS is created
aks_id=$(az aks show -n $aks_name -g $rg --query id -o tsv)
wait_until_finished $aks_id
echo "INFO: AKS cluster $aks_name is ready, adding GPU nodepool..."
az aks nodepool add -g $rg --cluster-name $aks_name --name nodepoolgpu --node-count 1 \
    --node-vm-size $gpuvm_size --node-taints sku=gpu:NoSchedule --priority spot \
    --tags EnableManagedGPUExperience=true \
    -o none --only-show-errors

# Get credentials for kubectl
echo "INFO: Downloading AKS cluster $aks_name credentials..."
az aks get-credentials -n $aks_name -g $rg --overwrite

#####################
# Finish P2S config #
#####################

# Finish VPN GW and download P2S configuration
gw_id=$(az network vnet-gateway show -n $gw_name -g $rg --query id -o tsv)
wait_until_finished $gw_id
echo "INFO: VPN gateway for isolated AKS cluster is ready, creating P2S configuration (this could take a few minutes)..."
aad_audience="c632b3df-fb67-4d84-bdcf-b95ad541b5c8"
tenant_id=$(az account show --query tenantId -o tsv)
aad_issuer="https://sts.windows.net/${tenant_id}/"
aad_tenant="https://login.microsoftonline.com/${tenant_id}/"
az network vnet-gateway update -g $rg -n $gw_name --address-prefixes $p2s_address_pool --client-protocol OpenVPN -o none
az network vnet-gateway aad assign --gateway-name $gw_name -g $rg --tenant "$aad_tenant" --audience "$aad_audience" --issuer "$aad_issuer" -o none
echo "INFO: Creating VPN client configuration package..."
az network vnet-gateway vpn-client generate -n $gw_name -g $rg --processor-architecture Amd64 -o none
download_url=$(az network vnet-gateway vpn-client show-url -n $gw_name -g $rg -o tsv)
p2s_config_file_abs=$(readlink -f "$p2s_config_file")
curl -s -o $p2s_config_file_abs $download_url
unzip -o $p2s_config_file_abs -d "$(dirname $p2s_config_file_abs)"
echo "INFO: VPN client configuration downloaded to $p2s_config_file_abs and unzipped"

############################################################################################################
# You should now connect your Azure VPN client to the VPN using the configuration package downloaded above #
# You should also configure your local DNS to use the DNS server VM created above to resolve cluster names #
############################################################################################################

# Test connectivity to the API server private IP
echo "INFO: Please make sure that your DNS server is configured to $vm_privateip and that you are connected to the VPN"
kubectl get nodes

####################
# Cleanup - DANGER #
####################

# Uncomment the following lines to delete the resource group and all its resources
# echo "INFO: Deleting resource group $rg and all its resources..."
# az group delete -n $rg --yes --no-wait