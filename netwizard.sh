#!/bin/zsh

#######################################################
# MVP for an Azure Networking Wizard
# This file contains sh functions to:
# - Define IP address space (IPAM for the poor man)
# - Create regions (hub VNets)
# - Create spokes
# - Create subnets in those spokes
# - Create network segmentation (AzFW/NSG)
# - Inspect network segmentation logs (AzFW/flowlogs)
#
# Usage:
#  source ./netwizard.sh
#
# You can then use the functions defined here
#######################################################

# IPAM
onprem_range=10.128.0.0/9
azure_range=10.0.0.0/9
region_size=16
hub_size=22
spoke_size=24

# Control variables
rg=netwizard
create_bastion=no
create_fw=yes
create_vpngw=no
create_ergw=no

##################
# IPAM functions #
##################

# Get the next free block for a new region
function get_next_region_prefix {

}

# Get the next prefix for a hub
function get_next_hub_prefix {

}

# Get the next ID for a region (starting with 0)
function get_next_region_id {

}


####################
# Region functions #
####################

# Creates a new region
function create_region {
    region_id=$(get_next_region_id)
}
