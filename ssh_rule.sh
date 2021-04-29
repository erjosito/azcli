#!/usr/bin/zsh

#################################################
# Add SSH allow/deny rules to running VMs
# It assumes that the NSG is in the same RG as the VM
# It creates the rules with prio 100
#
# Jose Moreno, March 2021
#################################################

# Function to inject a deny rule for SSH
function deny_ssh () {
    while IFS= read -r vm; do
        ssh_vm_name=$(echo $vm | cut -f1 -d$'\t')
        ssh_rg=$(echo $vm | cut -f2 -d$'\t')
        echo "Getting NSG for VM $ssh_vm_name in RG $ssh_rg..."
        ssh_nic_id=$(az vm show -n $ssh_vm_name -g $ssh_rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        ssh_nsg_id=$(az network nic show --ids $ssh_nic_id --query 'networkSecurityGroup.id' -o tsv)
        if [[ -z "$ssh_nsg_id" ]]
        then
            echo "No NSG could be found for NIC $ssh_nic_id"
        else
            ssh_nsg_name=$(basename $ssh_nsg_id)
            echo "Adding SSH-deny rule to NSG $ssh_nsg_name for VM $ssh_vm_name in RG $ssh_rg..."
            az network nsg rule create -n "${rule_prefix}SSH" --nsg-name $ssh_nsg_name -g $ssh_rg --priority $rule_prio --destination-port-ranges 22 --access Deny --protocol Tcp -o none
            az network nsg rule create -n "${rule_prefix}RDP" --nsg-name $ssh_nsg_name -g $ssh_rg --priority $(($rule_prio+1)) --destination-port-ranges 3389 --access Deny --protocol Tcp -o none
        fi
    done <<< "$vm_list"
}

# Function to inject an allow rule for SSH
function allow_ssh () {
    while IFS= read -r vm; do
        ssh_vm_name=$(echo $vm | cut -f1 -d$'\t')
        ssh_rg=$(echo $vm | cut -f2 -d$'\t')
        echo "Getting NSG for VM $ssh_vm_name in RG $ssh_rg..."
        ssh_nic_id=$(az vm show -n $ssh_vm_name -g $ssh_rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        ssh_nsg_id=$(az network nic show --ids $ssh_nic_id --query 'networkSecurityGroup.id' -o tsv)
        if [[ -z "$ssh_nsg_id" ]]
        then
            echo "No NSG could be found for NIC $ssh_nic_id"
        else
            ssh_nsg_name=$(basename $ssh_nsg_id)
            echo "Adding SSH-allow rule to NSG $ssh_nsg_name for VM $ssh_vm_name in RG $ssh_rg..."
            az network nsg rule create -n "${rule_prefix}SSH" --nsg-name $ssh_nsg_name -g $ssh_rg --priority $rule_prio --destination-port-ranges 22 --access Allow --protocol Tcp -o none
            az network nsg rule create -n "${rule_prefix}RDP" --nsg-name $ssh_nsg_name -g $ssh_rg --priority $(($rule_prio+1)) --destination-port-ranges 3389 --access Allow --protocol Tcp -o none
        fi
    done <<< "$vm_list"
}

# Function to inject an allow rule for SSH
function delete_ssh_rule () {
    while IFS= read -r vm; do
        ssh_vm_name=$(echo $vm | cut -f1 -d$'\t')
        ssh_rg=$(echo $vm | cut -f2 -d$'\t')
        echo "Getting NSG for VM $ssh_vm_name in RG $ssh_rg..."
        ssh_nic_id=$(az vm show -n $ssh_vm_name -g $ssh_rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        ssh_nsg_id=$(az network nic show --ids $ssh_nic_id --query 'networkSecurityGroup.id' -o tsv)
        if [[ -z "$ssh_nsg_id" ]]
        then
            echo "No NSG could be found for NIC $ssh_nic_id"
        else
            ssh_nsg_name=$(basename $ssh_nsg_id)
            echo "Deleting SSH-allow rule from NSG $ssh_nsg_name for VM $ssh_vm_name in RG $ssh_rg..."
            az network nsg rule delete -n "${rule_prefix}SSH" --nsg-name $ssh_nsg_name -g $ssh_rg -o none
            az network nsg rule delete -n "${rule_prefix}RDP" --nsg-name $ssh_nsg_name -g $ssh_rg -o none
        fi
    done <<< "$vm_list"
}

# Variables
rule_prefix=auto
rule_prio=100

# Get arguments
scope_rg=''
action=''
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               scope_rg="${i#*=}"
               shift # past argument=value
               ;;
          -a=*|--action=*)
               action="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Check there is an action
if [[ -z "$action" ]]
then
    echo "ERROR: You need to specify an action with -a/--action, and optionally a resource group with -g/--resource-group"
    exit 1
fi

# Create VM list
subscription=$(az account show --query name -o tsv)
if [[ -z $scope_rg ]]
then
    echo "Getting the list of VMs powered on in subscription $subscription..."
    vm_list=$(az vm list -o tsv -d --query "[?powerState=='VM running'].[name,resourceGroup]")
else
    echo "Getting the list of VMs powered on in subscription $subscription and resource group $scope_rg..."
    vm_list=$(az vm list -g $scope_rg -o tsv -d --query "[?powerState=='VM running'].[name,resourceGroup]")
fi
echo "$(echo $vm_list | wc -l) VMs found"

# Run action
case $action in
    allow|Allow|permit|Permit)
        allow_ssh
        ;;
    deny|Deny|drop|Drop)
        deny_ssh
        ;;
    delete|remove)
        delete_ssh_rule
        ;;
esac
