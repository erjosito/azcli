#!/bin/bash
# Variables
storage_account_name1=sweden1138
storage_account_name2=germany1138
storage_container_name=files
file_name=sample100M.txt
limit=10
wait_time=5
weight_write=1
weight_read=4
if [[ -n "$1" ]]; then
  limit=$1
fi
# Main loop
echo "Running $limit upload/download operations"
for ((i=1; i<=$limit; i++))
do
  echo "Operation $i from $limit"
  # Upload to account 1
  echo "Uploading 100MB to $storage_account_name1 (x${weight_write})..."
  for ((j=1; j<=$weight_write; j++))
  do
    az storage blob upload -n $file_name -c $storage_container_name -f "./${file_name}" --auth-mode login --account-name $storage_account_name1 --overwrite -o none
    sleep $wait_time
  done
  # Upload to account 2
  echo "Uploading 100MB to $storage_account_name2 (x${weight_write})..."
  for ((j=1; j<=$weight_write; j++))
  do
    az storage blob upload -n $file_name -c $storage_container_name -f "./${file_name}" --auth-mode login --account-name $storage_account_name2 --overwrite -o none
    sleep $wait_time
  done
  # Download from account #1
  echo "Downloading 100MB from $storage_account_name1 (x${weight_read})..."
  for ((j=1; j<=$weight_read; j++))
  do
    az storage blob download -n $file_name -c $storage_container_name -f "./${file_name}.copy" --account-name $storage_account_name1 --auth-mode login -o none
    rm "./${file_name}.copy"
    sleep $wait_time
  done
  # Download from account #2
  echo "Downloading 100MB from $storage_account_name2 (x${weight_read})..."
  for ((j=1; j<=$weight_read; j++))
  do
    az storage blob download -n $file_name -c $storage_container_name -f "./${file_name}.copy" --account-name $storage_account_name2 --auth-mode login -o none
    rm "./${file_name}.copy"
  done
done
