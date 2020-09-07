############################################################################
# Created by Jose Moreno
# September 2020
#
# Creates a VWAN environment using the 2020-05-01 APIs for custom routing
# It leverages the functions defined in 'vwan-functions.sh'
############################################################################

# Variables
rg=vwanlab
rg_location=westeurope
vwan_name=vwan

#########################
# Create infrastructure #
#########################

# RG
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
configure_csr 1 1
connect_branch 1 1

create_vpngw 2
create_csr 2 2
configure_csr 2 2
connect_branch 2 2

# Vnets
create_spokes 1 5
create_spokes 2 5

# User spokes (aka nva spokes, indirect spokes)
# We will use spoke5 as user hub (aka nva spoke)
create_userspoke 1 5 1
convert_to_nva 1 5
connect_userspoke 1 5 1
create_userspoke 2 5 1
convert_to_nva 2 5
connect_userspoke 2 5 1

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
cx_set_rt hub1 spoke11 hub1RedRT hub1/hub1RedRT,hub1/defaultRouteTable vnet,default

# Modify vpn connections
vpncx_set_prop_rt 1 branch1 hub1/defaultRouteTable,hub1/hub2VnetRT default
vpncx_set_prop_rt 2 branch2 hub2/defaultRouteTable,hub2/hub2VnetRT default

# Create static routes in route table
rt_add_route 1 defaultRouteTable "10.0.0.0/16" $(get_azfw_id 1)
rt_add_route 2 defaultRouteTable "10.0.0.0/16" $(get_azfw_id 2)
rt_add_route 2 defaultRouteTable $(get_spoke_prefix 1 5 1) $(get_vnetcx_id 1 5)

# Create static routes in connections (NVA scenarios)
cx_add_routes 1 spoke15 $(get_spoke_prefix 1 5 1) $(get_spoke_ip 1 5)
