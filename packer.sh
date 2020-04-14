# https://docs.microsoft.com/en-us/azure/virtual-machines/linux/build-image-with-packer
# https://www.packer.io/docs/builders/azure.html

az ad sp create-for-rbac
keyvault_name="erjositoKeyvault"
az keyvault secret set -n "packer-app-id" --vault-name $keyvault_name --value "..myappid…"
az keyvault secret set -n "packer-app-secret" --vault-name $keyvault_name --value "…myappsecret…"

keyvault_name="erjositoKeyvault"
appid=$(az keyvault secret show -n packer-app-id --vault-name $keyvault_name --query value -o tsv 2>/dev/null)
appsecret=$(az keyvault secret show -n packer-app-secret --vault-name $keyvault_name --query value -o tsv 2>/dev/null)

az account set -s 'Azure CXP FTA Internal Subscription JOMORE'
sub=$(az account show --query id -o tsv)
tenant=$(az account show --query tenantId -o tsv)

packer build -var azure_app_id=$appid -var azure_app_secret=$appsecret -var azure_sub_id=$sub -var azure_tenant_id=$tenant -var azure_location=westeurope ./ubuntu.json

# From Azure Pipelines build task
packer --version
packer fix -validate=./ubuntu.json >./ubuntu-fixed.json
packer validate -var-file=myvars.json -var-file=myvars.json ubuntu-fixed.json
packer build -force -color=false -var-file=myvars.json ubuntu-fixed.json

# Custom Images
az image list -o table
az image show -g $rg -n $imagename --query id
az image delete -g $rg -n $imagename

# Shared Image Gallery
# https://docs.microsoft.com/en-us/azure/virtual-machines/linux/shared-images
rg=customimages
sig=erjositoSIG
az sig create -g $rg --gallery-name $sig
az sig image-definition create -g $rg --gallery-name $sig  \
   --gallery-image-definition UbuntuWeb \
   --publisher erjosito \
   --offer ubuntuweb \
   --sku 18.04-LTS \
   --os-type Linux 
az sig image-definition list -g $rg --gallery-name $sig -o table
sigdef=UbuntuWeb
az sig image-version list -g $rg --gallery-name $sig -i $sigdef -o table
az sig image-version delete -g $rg --gallery-name $sig -i $sigdef -e 1.0.116

imagename=ubuntuweb_116
imageid=$(az image show -g $rg -n $imagename --query id -o tsv)
az sig image-version create -g $rg --gallery-name $sig \
   --gallery-image-definition $sigdef \
   --gallery-image-version 1.0.121 \
   --target-regions "westeurope" \
   --replica-count 1 \
   --managed-image "$imageid"
az sig image-version show -g $rg --gallery-name $sig -i $sigdef -e 1.0.121
imageid=$(az sig image-version show -g $rg --gallery-name $sig -i $sigdef -e 1.0.121 --query id -o tsv)
# the ID is used to reference a certain SIG version. This is actually suboptimal, a combination of publisher/offer/sku/version would be better

# "latest" (this bash code removes the image version from the id
IFS='/' read -r -a array <<< "$imageid"
arraylen=$(echo ${#array[@]})
newarraylen=$(($arraylen-2))
function join { local IFS="$1"; shift; echo "$*"; }
latestimageid=\/$(join / ${array[@]: 0:$newarraylen})

# Custom image (not SIG!)
az image list -o table
imagename=ubuntuweb_116
imageid=$(az image show -g $rg -n $imagename --query id -o tsv)


# VMSS
user=lab-user
mypass=$(az keyvault secret show -n defaultPassword --vault-name $keyvault_name --query value -o tsv 2>/dev/null)
vmssname=myVmss

# Note: updating the imageReference.id of a VMSS is not supported (see below), hence using the latest image method might be better
# No LB:
az vmss create -g $rg -n $vmssname --image $imageid --authentication-type password --admin-username $user --admin-password $mypass --vm-sku Standard_B1s --instance-count 2 --public-ip-per-vm
az vmss create -g $rg -n $vmssname --image $latestimageid --authentication-type password --admin-username $user --admin-password $mypass --vm-sku Standard_B1s --instance-count 2 --public-ip-per-vm
# With LB and inbound pool (no lb-rule!!):
az vmss create -g $rg -n $vmssname --image $latestimageid --authentication-type password --admin-username $user --admin-password $mypass --vm-sku Standard_B1s --instance-count 2 --lb $vmssname-lb --lb-nat-pool-name $vmssname-natpool --backend-port 80 --backend-pool-name $vmssname-backend --upgrade-policy-mode automatic

# Check reference image for vmss and instances
az vmss list -g $rg -o table
az vmss show -g $rg -n $vmssname --query virtualMachineProfile.storageProfile.imageReference.id -o tsv # VMSS model
az vmss list-instances -g $rg -n $vmssname -o table
az vmss show -g $rg -n $vmssname --instance-id 1  # Instance model
az vmss show -g $rg -n $vmssname --instance-id 1 --query storageProfile.imageReference.id -o tsv # Instance model
az vmss list-instance-public-ips -g $rg -n $vmssname -o table
az vmss list-instances -g $rg -n $vmssname --query [].storageProfile.imageReference.id -o tsv
az vmss get-instance-view -g $rg -n $vmssname # Instance state
az vmss get-instance-view -g $rg -n $vmssname --instance-id 1 # Instance state

# scale vmss
az vmss scale -g $rg -n $vmssname --new-capacity 3 --no-wait

# Inbound nat
az network lb inbound-nat-pool list -g $rg --lb-name $vmssname-lb -o table
az network lb inbound-nat-pool show -g $rg --lb-name $vmssname-lb -n $vmssname-natpool
az network lb inbound-nat-rule list -g $rg --lb-name $vmssname-lb -o table
az network public-ip list -g $rg -o tsv --query [].[name,ipAddress]

#  Create inbound nat rule for SSH
frontend=$(az network lb frontend-ip list -g $rg --lb-name $vmssname-lb -o tsv --query [0].name)
az network lb inbound-nat-pool create -g $rg --lb-name $vmssname-lb -n inboundSSH --protocol Tcp --frontend-port-range-start 22000 --frontend-port-range-end 22009 --backend-port 22 --frontend-ip-nam
e $frontend
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools="[{\"id\":\"/subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/customimages/providers/Microsoft.Network/loadBalancers/myVmss-lb/inboundNatPools/myVmss-natpool\",\"resourceGroup\": \"customimages\"},{\"id\":\"/subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/customimages/providers/Microsoft.Network/loadBalancers/myVmss-lb/inboundNatPools/inboundSSH\",\"resourceGroup\": \"customimages\"}]"
az network lb inbound-nat-rule list -g $rg --lb-name $vmssname-lb -o table

# Create LB rule (does not work with inbound nat rules to port 80)
backend=$(az network lb address-pool list -g $rg --lb-name $vmssname-lb -o tsv --query [0].name)
probe=$(az network lb probe list -g $rg --lb-name $vmssname-lb -o tsv --query [0].name)
frontend=$(az network lb frontend-ip list -g $rg --lb-name $vmssname-lb -o tsv --query [0].name)
port=8080
az network lb rule create --lb-name $vmssname-lb -g $rg -n HttpRule --protocol Tcp --frontend-port $port --backend-port $port --frontend-ip-name $frontend --backend-pool-name $backend --probe-name $probe
# Error:
# Load balancer rules /subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/customimages/providers/Microsoft.Network/loadBalancers/myVmss-lb/inboundNatPools/myVmss-natpool and /subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/customimages/providers/Microsoft.Network/loadBalancers/myVmss-lb/loadBalancingRules/HttpRule belong to the load balancer of the same type and use the same backend port 80 and protocol Tcp with floatingIP disabled, must not be used with the same vmss backend IP config. The backend IP config is generated from vmss: /subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/customimages/providers/Microsoft.Compute/virtualMachineScaleSets/myVmss, networkIntefaceConfiguration: myvms760fNic, ipConfiguration: myvms760fIPConfig.

az vmss show -g $rg -n $vmssname --query virtualMachineProfile.storageProfile.imageReference.id -o tsv # VMSS model


imageid=$(az sig image-version show -g $rg --gallery-name $sig -i $sigdef -e 1.0.118 --query id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.storageProfile.imageReference.id=$imageid  # Does NOT work!
# https://github.com/terraform-providers/terraform-provider-azurerm/issues/2284

az vmss reimage -g $rg -n $vmssname --no-wait


# Set upgrade policy
# https://docs.microsoft.com/en-us/rest/api/compute/virtualmachinescalesets/createorupdate#rollingupgradepolicy
az vmss show -g $rg -n $vmssname --query upgradePolicy
az vmss update -g $rg -n $vmssname --set upgradePolicy.rollingUpgradePolicy='{"maxBatchInstancePercent": 50, "maxUnhealthyInstancePercent": 50,  "maxUnhealthyUpgradedInstancePercent": 50, "pauseTimeBetweenBatches": "PT0S"}'
az vmss update -g $rg -n $vmssname --set upgradePolicy.automaticOSUpgradePolicy='{"enableAutomaticOSUpgrade": true, "disableAutomaticRollback": false }'
az vmss update -g $rg -n $vmssname --set upgradePolicy.mode='Automatic'


# Manual upgrade
az vmss update -g $rg -n $vmssname --set upgradePolicy.mode='manual'
az vmss rolling-upgrade get-latest -g $rg -n $vmssname
az vmss rolling-upgrade start -g $rg -n $vmssname
az vmss rolling-upgrade cancel -g $rg -n $vmssname

# Last upgrades
az vmss get-os-upgrade-history -n $vmssname -g $rg --query "[].{StartTime:properties.runningStatus.startTime, CompletedTime:properties.runningStatus.completedTime, Code:properties.runningStatus.code, Type:type, StartedBy:properties.startedBy, SuccessfulInstanceCount:properties.progress.successfulInstanceCount}" -o table

# Set health to LB probe (you need a LB rule, create a dummy one to a random port if you don’t have any)
probeid=$(az network lb probe list -g $rg --lb-name $vmssname-lb --query [0].id -o tsv)
#az vmss update -n $vmssname -g $rg --set virtualMachineProfile.networkProfile.healthProbe="{\"id\":\"$probeid\"}"
az vmss update -n $vmssname -g $rg --set virtualMachineProfile.networkProfile.healthProbe="{\"id\":\"/subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/CUSTOMIMAGES/providers/Microso
ft.Network/loadBalancers/myVmss-lb/probes/port80\"}"
Automatic OS Upgrade is not supported for this Virtual Machine Scale Set because both a health probe and a health extension were provided. Remove the health probe or health extension prior to enabling automatic OS upgrade.
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.healthProbe

# Health extension
az vm extension image list-names --publisher Microsoft.ManagedServices -l westeurope -o table
az vm extension image list-versions --publisher Microsoft.ManagedServices -l westeurope -o table -n ApplicationHealthLinux
az vmss extension set -n ApplicationHealthLinux --publisher Microsoft.ManagedServices --version 1.0 -g $rg --vmss-name $vmssname --settings ./extension_settings_tcp.json 
# extension_settings.json:
# { 
#   "protocol": "http", // Can be "http", "https", or "tcp", 
#   "port": 80, // optional when protocol is "http" or "https"; required when protocol is "tcp" 
#   "requestPath": "/healthEndpoint" // required when protocol is "http" or "https"; not allowed when protocol is "tcp" 
# } 


# Test VM (to ssh to the VMSS instances)
# Create test vm
#rg=vmssTest
vmname=testvm
vnet=myVnet
subnet=vmssSubnet
keyvault_name=erjositoKeyvault
az network nsg create -n $vmname-nsg -g $rg
myip=$(curl -s4 ifconfig.co)
echo Our public IP: $myip
az network nsg rule create -g $rg --nsg-name $vmname-nsg -n SSHfromHome --priority 500 --source-address-prefixes $myip/32 --destination-port-ranges 22 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow SSH from home"
mypassword=$(az keyvault secret show -n defaultPassword --vault-name $keyvault_name --query value -o tsv 2>/dev/null)
az vm create --image ubuntults --size Standard_B1s -g $rg -n $vmname --admin-password $mypassword --admin-username jose --public-ip-address $vmname-pip --vnet-name $vnet --subnet $subnet --os-disk-size 30 --storage-sku Standard_LRS --nsg $vmname-nsg
publicip=$(az network public-ip show -n $vmname-pip -g $rg --query ipAddress -o tsv)
echo Public IP address: $publicip 
az vmss list-instance-connection-info -o table -g $rg -n $vmssname


# Cleanup
az vmss delete -g $rg -n $vmssname --no-wait
az vm delete -g $rg -n $vmname -y
az network nic delete -g $rg -n "$vmname"VMNic
az network nsg delete -g $rg -n $vmname-nsg
diskname=$(az disk list -g $rg --query [0].name -o tsv)
az disk delete -g $rg -n $diskname --no-wait -y
