############################################################################
# Created by Jose Moreno
# March 2020
#
# The script reads a JSON file with Azure's IP addresses and does something
#   with it, in this case confiuguring UDRs
############################################################################

# Configure routes to Azure Service (Azure Batch mgmt nodes in this example)
# Variables
rg=myrg
rt=myroutetable
printonly=yes
# URLs
url1=https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519
url2=$(curl -Lfs "${url1}" | grep -Eoi '<a [^>]+>' | grep -Eo 'href="[^\"]+"' | grep "download.microsoft.com/download/" | grep -m 1 -Eo '(http|https)://[^"]+')
prefixes_json=$(curl -s $url2)
# All categories
categories=$(echo $prefixes_json | jq -rc '.values[] | .name')
# Find category for a prefix
prefix="20.36.105.0"
echo $prefixes_json | jq -rc ".values[] | select(.properties.addressPrefixes[] | contains (\"$prefix\")) | .name"
# Find complete prefix, for a partial one
echo $prefixes_json | grep -i $prefix
# Find prefixes for a category
category=BatchNodeManagement.WestEurope
prefixes=$(echo $prefixes_json | jq -rc ".values[] | select(.name | contains (\"$category\")) | .properties.addressPrefixes[]")
echo $prefixes
# Browse prefixes
i=0
while IFS= read -r prefix; do
    echo "$((i++)): $prefix"
done <<< "$prefixes"

# Check
az network route-table route list -g $rg --route-table-name $rt -o table