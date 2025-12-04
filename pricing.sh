###############################
# Azure pricing API
#
# Some examples of interacting
#   with Azure retail pricing API.
#
# Requirements: curl, jq
#
# Jose Moreno, December 2025
###############################

# Variables
base_url="https://prices.azure.com/api/retail/prices"
api_version=2023-01-01-preview
currency=USD

sku="Standard_D16as_v6"
region="eastus2"

# Example 1: get prices for a specific SKU on a specific region
curl -s --get \
    --data-urlencode "api-version=${api_version}" \
    --data-urlencode "currencyCode='${currency}'" \
    --data-urlencode "\$filter=armSkuName eq '${sku}' and armRegionName eq '${region}'" \
    $base_url | jq

#Example 2: filter output
output=$(curl -s --get \
    --data-urlencode "api-version=${api_version}" \
    --data-urlencode "currencyCode='${currency}'" \
    --data-urlencode "\$filter=armSkuName eq '${sku}' and armRegionName eq '${region}'" \
    $base_url)
echo $output | jq '.Items[] | {armSkuName: .armSkuName, armRegionName: .armRegionName, price: .retailPrice, type: .type, skuName: .skuName, productName: .productName}'
echo $output | jq -r '.Items[] | [.armSkuName, .armRegionName, .retailPrice, .type, .skuName, .productName] | @tsv'
