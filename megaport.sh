#!/usr/bin/bash

#########################################
# Scripts to interact with Megaport API
#
# Existing functionality
# - Get credentials from Azure Key Vault
# - List services containing a certain string
#
# Jose Moreno, April 2021
##########################################

# Megaport API variables
base_url=https://api.megaport.com
# base_url=https://api-staging.megaport.com
product_string="jomore"  # This is the string that will be used to identify products to be displayed/modified/deleted
action=list

# Variables to get credentials
akv_name="erjositoKeyvault"
usr_secret_name="megaport-username"
pwd_secret_name="megaport-password"
mcr_asn=65001
quiet=no

# Get arguments
for i in "$@"
do
     case $i in
          -a=*|--action=*)
               action="${i#*=}"
               shift # past argument=value
               ;;
          -k=*|--service-key=*)
               service_key="${i#*=}"
               shift # past argument=value
               ;;
          -v=*|--key-vault=*)
               akv_name="${i#*=}"
               shift # past argument=value
               ;;
          -s=*|--product-string=*)
               product_string="${i#*=}"
               shift # past argument=value
               ;;
          -i=*|--product-id=*)
               product_id="${i#*=}"
               shift # past argument=value
               ;;
          -l=*|--location-id=*)
               location_id="${i#*=}"
               shift # past argument=value
               ;;
          -n=*|--name-suffix=*)
               name_suffix="${i#*=}"
               shift # past argument=value
               ;;
          --asn=*)
               mcr_asn="${i#*=}"
               shift # past argument=value
               ;;
          -g|--google-cloud)
               gcp=yes
               shift # past argument=value
               ;;
          -q|--quiet)
               quiet=yes
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

function log_msg () {
    if [[ "$quiet" == "no" ]]
    then
        echo $1 1>&2
    fi
}

function get_mcr_name () {
    # Optional parameter with provisioningStatus
    product_id=$1
    # Sending call to get product by UID
    products_url="${base_url}/v2/products"
    products_json=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}"  -X GET "$products_url" 2>/dev/null)
    output=$(echo "$products_json" | jq -r "[ .data[] | select( .productUid | contains(\"${product_id}\")) | { productName } ] | .[].productName")
    echo $output
}

function get_mcr_status () {
    # Optional parameter with provisioningStatus
    product_id=$1
    # Sending call to get product by UID
    products_url="${base_url}/v2/products"
    products_json=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}"  -X GET "$products_url" 2>/dev/null)
    output=$(echo "$products_json" | jq -r "[ .data[] | select( .productUid | contains(\"${product_id}\")) | { provisioningStatus } ] | .[].provisioningStatus")
    if [[ "$quiet" == "no" ]]; then
        echo $output
    fi
}

function list_products () {
    # Optional parameter with provisioningStatus
    status=$1
    # Sending call to get services, and associated VXCs
    products_url="${base_url}/v2/products"
    products_json=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}"  -X GET "$products_url" 2>/dev/null)
    output=$(echo "$products_json" | jq -r "[ .data[] | select( .productName | contains(\"${product_string}\")) | { productName, productType, provisioningStatus, productUid, vxcs: [ .associatedVxcs[]? | { productName, productType, provisioningStatus, productUid }] } ]")
    # Only show products with a certain state
    if [[ -n "$status" ]]
    then
        output=$(echo $output | jq -r "[ .[] | select(.provisioningStatus==\"${status}\") ]")
    fi
    # Validate we have an output
    if [[ -n $output ]]
    then
        if [[ "$quiet" == "no" ]]; then
            echo $output | jq
        fi
    else
        log_msg "ERROR: output: $output"
    fi
}

function create_mcr () {
    # Defaults
    mcr_name="${product_string}-mcr"
    if [[ -n "$name_suffix" ]]
    then
        mcr_name="${mcr_name}-${name_suffix}"
    fi
    # Try to find an existing MCR (LIVE or otherwise):
    log_msg "INFO: Checking if a live MCR with the string $product_string already exists..."
    product_json=$(list_products LIVE)
    mcr_id=$(echo "$product_json" | jq -r '.[].productUid')
    mcr_status=$(echo "$product_json" | jq -r '.[].provisioningStatus')
    if [[ -z "$mcr_id" ]]
    then
        log_msg "INFO: Creating MCR $mcr_name in Megaport location '$location_id' and ASN '$mcr_asn'..."
        # Sending call to create MCR
        buy_url="${base_url}/v2/networkdesign/buy" 
        buy_payload_template='[{locationId: $locationId, productName: $productName, productType: "MCR2", portSpeed: 5000, config: { mcrAsn: $mcrAsn } } ]'
        buy_payload=$(jq -n \
            --arg locationId "$location_id" \
            --arg productName "$mcr_name" \
            --arg mcrAsn "$mcr_asn" \
            "$buy_payload_template")
        buy_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" --data-raw "$buy_payload" -X POST "$buy_url" 2>/dev/null)
        if [[ "$quiet" == "no" ]]; then
            echo "$buy_response" | jq
        fi
    else
        log_msg "INFO: MCR $mcr_id already found (status $mcr_status), skipping creation"
    fi
}

function validate_key () {
    if [[ -z "$service_key" ]]
    then
        log_msg "ERROR: no service_key identified, please use the argument -k or --service-key" 1>&2
    else
        validate_url="${base_url}/v2/secure/azure/${service_key}"
        log_msg "INFO: Sending request to URL $validate_url..."
        validate_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" -X GET "$validate_url" 2>/dev/null)
        filtered_response=$(echo $validate_response | jq -r ".data | { bandwidth, service_key, ports: [ .megaports[]? | { name, locationId, productUid }] }")
        # Validate we have an output
        if [[ -n $filtered_response ]]
        then
            if [[ "$quiet" == "no" ]]; then
                echo $filtered_response | jq
            fi
        else
            log_msg "ERROR: output: $validate_response"
        fi
    fi
}

function create_vxc () {
    # Defaults
    vxc_name="${product_string}-${1}"
    mcr_id=$2
    er_port=$3
    log_msg "INFO: Creating VXC $vxc_name associated to MCR $mcr_id on ExpressRoute port $er_port..."
    # Append name suffix if required
    if [[ -n "$name_suffix" ]]
    then
        vxc_name="${vxc_name}-${name_suffix}"
    fi
    # Sending call to create VXC
    buy_url="${base_url}/v2/networkdesign/buy" 
    buy_payload_template='[{ productUid: $mcrId, associatedVxcs: [{ productName: $vxcName, rateLimit: 200, aEnd: { vlan: 0 }, bEnd: { productUid: $erPort, partnerConfig: { connectType: "AZURE", serviceKey: $serviceKey, peers: [{ type: "private" }] }} }] }]'
    buy_payload=$(jq -n \
        --arg mcrId "$mcr_id" \
        --arg vxcName "$vxc_name" \
        --arg erPort "$er_port" \
        --arg serviceKey "$service_key" \
        "$buy_payload_template")
    buy_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" --data-raw "$buy_payload" -X POST "$buy_url" 2>/dev/null)
    if [[ "$quiet" == "no" ]]; then
        echo "$buy_response" | jq
    fi
}

function validate_gcp_key () {
    if [[ -z "$service_key" ]]
    then
        log_msg "ERROR: no attachment key identified, please use the argument -k or --service-key" 1>&2
    else
        validate_url="${base_url}/v2/secure/google/${service_key}"
        log_msg "INFO: Sending request to URL $validate_url..."
        validate_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" -X GET "$validate_url" 2>/dev/null)
        filtered_response=$(echo $validate_response | jq -r ".data | { ports: [ .megaports[0]? | { name, locationId, productId, productUid }] }")
        # Validate we have an output
        if [[ -n $filtered_response ]]
        then
            echo $filtered_response | jq
        else
            log_msg "ERROR: output: $validate_response"
        fi
    fi
}

function create_gcp_vxc () {
    # Defaults
    vxc_name="${product_string}-gcp"
    mcr_id=$1
    port_id=$2
    # Append name suffix if required
    if [[ -n "$name_suffix" ]]
    then
        vxc_name="${vxc_name}-${name_suffix}"
    fi
    # Sending call to create VXC
    buy_url="${base_url}/v2/networkdesign/buy" 
    buy_payload_template='[{ productUid: $mcrId, associatedVxcs: [{ productName: $vxcName, rateLimit: 50, aEnd: { vlan: 0 }, bEnd: { productUid: $portId, partnerConfig: { connectType: "Google", pairingKey: $serviceKey }} }] }]'
    buy_payload=$(jq -n \
        --arg mcrId "$mcr_id" \
        --arg vxcName "$vxc_name" \
        --arg portId "$port_id" \
        --arg serviceKey "$service_key" \
        "$buy_payload_template")
    buy_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" --data-raw "$buy_payload" -X POST "$buy_url" 2>/dev/null)
    echo "$buy_response" | jq

}

function cancel_product () {
    # Sending call to delete product
    product_id=$1
    cancel_url="${base_url}/v2/product/${product_id}/action/CANCEL_NOW" 
    log_msg "INFO: sending POST request to $cancel_url..."
    cancel_response=$(curl -H "Content-Type: application/json" -H "X-Auth-Token: ${megaport_token}" -X POST "$cancel_url" 2>/dev/null)
    if [[ "$quiet" == "no" ]]; then
        echo "$cancel_response" | jq
    fi
}

# Checking dependencies
for binary in "az" "jq" "curl"
do
    binary_path=$(which "$binary")
    if [[ -z "$binary_path" ]]
    then
        echo "ERROR: It seems that $binary is not installed in the system. Please install it before trying this script again"
        exit
    fi
done
log_msg "INFO: All dependencies checked successfully"

# Authenticate only if there is not an environment variable with the token
if [[ -n $megaport_token ]]
then
    log_msg "INFO: environment variable with Megaport authentication token found"
else
    # Day zero: create Azure Key Vault if required, and create secrets
    akv_rg_found=$(az keyvault list -o tsv --query "[?name=='$akv_name'].resourceGroup" 2>/dev/null)
    if [[ -n ${akv_rg_found} ]]
    then
        log_msg "INFO: AKV ${akv_name} found in resource group $akv_rg_found"
        akv_rg="$akv_rg_found"
    else
        akv_location=westeurope
        akv_rg=mykeyvault
        log_msg "INFO: Creating AKV ${akv_name} in RG ${akv_rg}, in Azure region ${akv_location}..."
        az group create -n $akv_rg -l $akv_location -o none
        az keyvault create -n $akv_name -g $akv_rg -l $akv_location -o none
        user_name=$(az account show --query 'user.name' -o tsv)
        log_msg "INFO: Setting policies for user ${user_name}..."
        az keyvault set-policy -n $akv_name -g $akv_rg --upn $user_name -o none\
            --certificate-permissions backup create delete deleteissuers get getissuers import list listissuers managecontacts manageissuers purge recover restore setissuers update \
            --key-permissions backup create decrypt delete encrypt get import list purge recover restore sign unwrapKey update verify wrapKey \
            --secret-permissions backup delete get list purge recover restore set \
            --storage-permissions backup delete deletesas get getsas list listsas purge recover regeneratekey restore set setsas update
    fi

    # Read secrets, or set them if not found
    megaport_user=$(az keyvault secret show --vault-name $akv_name -n $usr_secret_name --query 'value' -o tsv 2>/dev/null)
    if [[ -z "$megaport_user" ]]
    then
        read -p "I could not find any username in AKV $akv_name, please enter your Megaport user name to add it as secret: " megaport_user
        az keyvault secret set --vault-name $akv_name --name $usr_secret_name --value $megaport_user -o none
    else
        log_msg "INFO: Megaport username successfully retrieved from Azure Key Vault $akv_name"
    fi
    megaport_password=$(az keyvault secret show --vault-name $akv_name -n $pwd_secret_name --query 'value' -o tsv 2>/dev/null)
    if [[ -z "$megaport_password" ]]
    then
        read -sp "I could not find any username in AKV $akv_name, please enter your Megaport password to add it as secret: " megaport_password
        az keyvault secret set --vault-name $akv_name --name $pwd_secret_name --value $megaport_password -o none
    else
        log_msg "INFO: Megaport password successfully retrieved from Azure Key Vault $akv_name"
    fi

    # Sending authentication call to Megaport
    auth_url="${base_url}/v2/login"
    auth_json=$(curl --data-urlencode "username=${megaport_user}" --data-urlencode "password=${megaport_password}" -H "Content-Type: application/x-www-form-urlencoded" -X POST "$auth_url" 2>/dev/null)
    megaport_token=$(echo "$auth_json" | jq -r '.data.token')
    if [[ -z $megaport_token ]]
    then
        echo "ERROR: Authentication failed"
        echo $auth_json | jq
        exit 1
    else
        log_msg "INFO: Authentication successful"
    fi
fi

# Run action
case $action in
    list)
        list_products
        ;;
    list_live)
        mcr_ids=$(list_products "LIVE" | jq -r '.[].productUid')
        mcr_ids=($mcr_ids)
        if [[ -z "$mcr_ids" ]]
        then
            log_msg "INFO: No MCR found matching that string"
        else
            for mcr_id in "${mcr_ids[@]}"
            do
                mcr_name=$(get_mcr_name $mcr_id)
                mcr_status=$(get_mcr_status $mcr_id)
                log_msg "INFO: Found MCR $mcr_name, ID $mcr_id, status $mcr_status"
            done
        fi
        ;;
    delete)
        cancel_product "$product_id"
        ;;
    create_mcr)
        if [[ -z "$location_id" ]]
        then
            if [[ -z $service_key ]]
            then
                log_msg "ERROR: you need to specifiy either a location ID (-l) or an ExpressRoute service key (-k)"
                exit 1
            else
                log_msg "INFO: Getting Location ID from existing ER..."
                er_json=$(validate_key "$service_key")
                location_id=$(echo "$er_json" | jq -r '.ports[] | select (.name | contains("Primary")) | .locationId')
                log_msg "INFO: Location ID derived from the supplied service key: $location_id"
            fi
        fi
        create_mcr
        ;;
    delete_mcr)
        mcr_ids=$(list_products "LIVE" | jq -r '.[].productUid')
        mcr_ids=($mcr_ids)
        for mcr_id in "${mcr_ids[@]}"
        do
            mcr_name=$(get_mcr_name $mcr_id)
            log_msg "INFO: Deleting MCR $mcr_name, ID $mcr_id..."
            cancel_product "$mcr_id"
        done
        ;;
    validate)
        if [[ "$gcp" == "yes" ]]; then
            validate_gcp_key "$service_key"
        else
            validate_key "$service_key"
        fi
        ;;
    create_vxc)
        log_msg "INFO: Getting MCR ID from the list of LIVE products..."
        mcr_id=$(list_products "LIVE" | jq -r '.[].productUid')
        log_msg "INFO: MCR ID $mcr_id"
        if [[ "$gcp" == "yes" ]]; then
            log_msg "INFO: Getting GUIDs for ExpressRoute ports..."
            validation_json=$(validate_gcp_key "$service_key")
            port_id=$(echo "$validation_json" | jq -r '.ports[0] | .productUid')
            log_msg "INFO: Port ID found: $port_id"
            create_gcp_vxc "$mcr_id" "$port_id"
        else
            log_msg "INFO: Getting GUIDs for ExpressRoute ports..."
            er_json=$(validate_key "$service_key")
            id_1ary=$(echo "$er_json" | jq -r '.ports[] | select (.name | contains("Primary")) | .productUid')
            id_2ary=$(echo "$er_json" | jq -r '.ports[] | select (.name | contains("Secondary")) | .productUid')
            log_msg "INFO: ExpressRoute port GUIDs are $id_1ary and $id_2ary"
            create_vxc "1ary" "$mcr_id" "$id_1ary"
            create_vxc "2ary" "$mcr_id" "$id_2ary"
        fi
        ;;
    *)
        log_msg "ERROR: sorry, I didnt quite understand the action $action"
        ;;
esac
