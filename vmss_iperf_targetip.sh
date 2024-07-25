#!/bin/bash

# Controls whether printing debugging info
debug=no
dev_name=eth0
remote_cidr=10.0.0.0/24

# Get local IP address and split it in ip and mask
local_cidr=$(ip address show dev $dev_name | grep inet | grep $dev_name | awk '{print $2}')
if [[ "$debug" == "yes" ]]; then echo "Local CIDR: $local_cidr"; fi
local_ip=$(echo $local_cidr | cut -d/ -f 1)
local_mask_int=$(echo $local_cidr | cut -d/ -f 2)
if [[ "$debug" == "yes" ]]; then echo "Local IP address: $local_ip, mask: $local_mask_int"; fi

# Convert the /24 mask to 255.255.255.0 format
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$(( cidr / 8 ))
    local partial_octet=$(( cidr % 8 ))
    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask+="255"
        elif [ $i -eq $full_octets ]; then
            mask+=$(( 256 - (1 << (8 - partial_octet)) ))
        else
            mask+="0"
        fi
        [ $i -lt 3 ] && mask+="."
    done
    echo $mask
}
local_mask=$(cidr_to_netmask $local_mask_int)
if [[ "$debug" == "yes" ]]; then echo "Local mask: $local_mask"; fi

# Convert to hex, and then to dec
local_ip_hex=$(printf '%.2X%.2X%.2X%.2X\n' `echo $local_ip | sed -e 's/\./ /g'`)
local_mask_hex=$(printf '%.2X%.2X%.2X%.2X\n' `echo $local_mask | sed -e 's/\./ /g'`)
if [[ "$debug" == "yes" ]]; then echo "Local IP address in hex: $local_ip_hex, mask: $local_mask_hex"; fi

# Now we can get the subnet with a binary AND between the IP and the mask
local_subnet_hex=$(printf %.8X `echo $(( 0x$local_ip_hex & 0x$local_mask_hex ))`)
if [[ "$debug" == "yes" ]]; then echo "Local subnet in hex: $local_subnet_hex"; fi

# Now we have the offset
local_offset=$(printf %.8X `echo $(( 0x$local_ip_hex - 0x$local_subnet_hex ))`)
if [[ "$debug" == "yes" ]]; then echo "Local offset: $local_offset"; fi

# Before adding it to the remote subnet, we need to convert it to hex too
remote_subnet=$(echo $remote_cidr | cut -d/ -f 1)
if [[ "$debug" == "yes" ]]; then echo "Remote subnet address: $remote_subnet"; fi
remote_subnet_hex=$(printf '%.2X%.2X%.2X%.2X\n' `echo $remote_subnet | sed -e 's/\./ /g'`)
if [[ "$debug" == "yes" ]]; then echo "Remote subnet address in hex: $remote_subnet_hex"; fi

# Now we can have the remote IP in hex adding the offset to the remote subnet
remote_ip_hex=$(printf %.8X `echo $(( 0x$remote_subnet_hex + 0x$local_offset ))`)
if [[ "$debug" == "yes" ]]; then echo "Remote IP address in hex: $remote_ip_hex"; fi

# Finally we convert the remote IP in hex to an IPv4 format
remote_ip=$(printf '%d.%d.%d.%d\n' `echo $remote_ip_hex | sed -r 's/(..)/0x\1 /g'`)
if [[ "$debug" == "yes" ]]; then echo "Remote IP address: $remote_ip"; fi

# Output
echo $remote_ip

