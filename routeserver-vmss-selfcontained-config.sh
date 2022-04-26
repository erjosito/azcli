#!/bin/bash
log_file='/root/routeserver.log'
metadata=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq)
echo $metadata >$log_file