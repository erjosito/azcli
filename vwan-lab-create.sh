############################################################################
# Created by Jose Moreno
# September 2020
#
# Creates a VWAN environment using the 2020-05-01 APIs for custom routing
# It leverages the functions defined in 'vwan-functions.sh'
# It takes a single parameter, the resource group name. Everything else
#   is defined as variables here or in vwan-functions.sh
# The recommended way to use this is with source, like:
# $ source ./vwan-lab-create.sh yourRGname
############################################################################

# Parameters
if [[ -n "$1" ]]
then
    rg=$1
else
    rg=vwanlab # Default value if no param is provided
fi

# Variables
rg_location=westeurope
vwan_name=vwan

#########################
# Create infrastructure #
#########################

# RG
echo "Creating resource group $rg in $rg_location..."
az group create -n $rg -l $rg_location >/dev/null
source ./vwan-functions.sh

# vwan and hubs
create_vwan $vwan_name
create_hub 1 $vwan_name
create_hub 2 $vwan_name

# Gateways and branches
# Creating 2 gateways in parallel normally ends up in one of them Failed
# Going sequentially here
create_vpngw 1
create_csr 1 1

# Example of a single-homed branch (VPN tunnels to 1 hub):
configure_csr 1 1
connect_branch 1 1

# Example of a dual-homed branch (VPN tunnels to 2 hubs):
# configure_csr_dualhomed 1 2 1  # Configures CSR 1 to connect to hubs 1 and 2
# connect_branch 1 1  # Connect hub1 to branch1
# connect_branch 2 1  # Connect hub2 to branch1

create_vpngw 2
create_csr 2 2
configure_csr 2 2
connect_branch 2 2

# Tunnel verification
echo "Giving the IPsec tunnels 60s to start..." && sleep 60
branch_cmd "show ip int brief"

# Vnets
create_spokes 1 3
create_spokes 2 3

# User spokes (aka nva spokes, aka indirect spokes)
# We will use spoke3 as user hub (aka nva spoke)
create_userspoke 1 3 1
convert_to_nva 1 3
connect_userspoke 1 3 1
create_userspoke 2 3 1
convert_to_nva 2 3
connect_userspoke 2 3 1

# Virtual Secure Hub
create_azfw_policy
create_fw 1
create_fw 2

# Logging from all VPN gateways and Azure Firewalls
create_logs

##################
# Custom Routing #
##################

# Create route tables
create_rt hub1 hub1VnetRT vnet
create_rt hub2 hub2VnetRT vnet

# Modify vnet connections
# cx_set_rt hub1 spoke11 hub1VnetRT hub2/hub1VnetRT
# cx_set_prop_labels hub1 spoke11
# cx_set_rt hub1 spoke12 hub1VnetRT hub2/hub1VnetRT
# cx_set_prop_labels hub1 spoke12
# cx_set_rt hub2 spoke21 hub1VnetRT hub1/hub1VnetRT
# cx_set_prop_labels hub2 spoke21
# cx_set_rt hub2 spoke22 hub1VnetRT hub1/hub1VnetRT
# cx_set_prop_labels hub2 spoke22

# Modify vpn connections
# vpncx_set_prop_rt 1 branch1 hub2/defaultRouteTable,hub2/hub2VnetRT default
# vpncx_set_prop_rt 2 branch2 hub1/defaultRouteTable,hub1/hub2VnetRT default

# Create static routes in route tables for Secure Virtual Hub
# rt_add_route 1 defaultRouteTable "10.0.0.0/16" "$(get_azfw_id 1)"
# rt_add_route 2 defaultRouteTable "10.0.0.0/16" "$(get_azfw_id 2)"
# rt_add_route 1 hub1VnetRT "0.0.0.0/0" "$(get_azfw_id 1)"
# rt_add_route 2 hub2VnetRT "0.0.0.0/0" "$(get_azfw_id 2)"

# Create static routes in route tables for NVA routing
# rt_add_route 1 defaultRouteTable "$(get_spoke_prefix 1 5 1)" "$(get_vnetcx_id 1 5)"
# rt_add_route 2 defaultRouteTable "$(get_spoke_prefix 1 5 1)" "$(get_vnetcx_id 1 5)"

# Create static routes in connections for NVA routing
# cx_add_routes 1 spoke15 "$(get_spoke_prefix 1 5 1)" "$(get_spoke_ip 1 5)"

# Done
echo "Your VWAN $vwan_name in resource group $rg is ready"
