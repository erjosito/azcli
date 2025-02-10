#!/usr/bin/bash

#########################################
# Script to get possible outbound IP addresses
#   from Azure Function and configure them
#   as allowed IPs in a Cosmos DB.
#
#
# Jose Moreno, June 2024
##########################################

# Get arguments
for i in "$@"
do
     case $i in
          -f=*|--function=*)
               function="${i#*=}"
               shift # past argument=value
               ;;
          -c=*|--cosmosdb=*)
               cosmosdb="${i#*=}"
               shift # past argument=value
               ;;
          -g=*|-rg=*|--resourcegroup=*)     # Assumes same RG for Azure Function and CosmosDB
               rg="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Verify that all parameters have been provided
if [[ -z $function || -z $cosmosdb || -z $rg ]]; then
     echo "ERROR: Usage: $0 -f|--function=<function_name> -c|--cosmosdb=<cosmosdb_name> -g|--resourcegroup=<resource_group>"
     exit 1
fi

# Verify that the resources exist with the Azure CLI (assuming we are already authenticated and in the right subscription)
function_id=$(az functionapp show --name $function --resource-group $rg --query id --output tsv)
if [[ -z $function_id ]]; then
     echo "ERROR: Azure Function $function not found in resource group $rg"
     exit 1
else
    echo "DEBUG: Azure Function found with ID $function_id"
fi  
cosmosdb_id=$(az cosmosdb show --name $cosmosdb --resource-group $rg --query id --output tsv --only-show-errors)
if [[ -z $cosmosdb_id ]]; then
     echo "ERROR: Cosmos DB $cosmosdb not found in resource group $rg"
     exit 1
else
    echo "DEBUG: Cosmos DB found with ID $cosmosdb_id"
fi

# Get the possible outbound IP addresses for the Azure Function
function_ips=$(az functionapp show --resource-group $rg --name $function --query possibleOutboundIpAddresses --output tsv --only-show-errors)
echo "DEBUG: Azure Function $function has the following possible outbound IP addresses: $function_ips"

# Get the current firewall rules for the Cosmos DB
cosmosdb_ips_current=$(az cosmosdb show -n $cosmosdb -g $rg --only-show-errors -o json | jq -r '.ipRules | .[] | .ipAddressOrRange' | paste -sd "," -)
cosmosdb_ips_new="${cosmosdb_ips_current},${function_ips}"
# Eliminate duplicates in the comma-separated list of values
cosmosdb_ips_new=$(echo $cosmosdb_ips_new | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
echo "DEBUG: Updating Cosmos DB $cosmosdb firewall rules to: $cosmosdb_ips_new"
az cosmosdb update -n $cosmosdb -g $rg --ip-range-filter "$cosmosdb_ips_new" -o none --only-show-errors
