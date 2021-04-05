#!/usr/bin/python3

import os, sys, getopt, json, collections, requests
import datetime, hashlib, hmac, base64
import mrtparse
from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential

# Default values
default_mrt_file = "/tmp/bird-mrtdump_bgp"
consolidated_mrt_file = "/var/log/bird.mrt"
temp_mrt_file = "/tmp/bird-mrtdump_bgp.tmp"

# Build signature to authenticate message
# See https://docs.microsoft.com/azure/azure-monitor/logs/data-collector-api
def build_signature(customer_id, shared_key, date, content_length, method, content_type, resource):
    x_headers = 'x-ms-date:' + date
    string_to_hash = method + "\n" + str(content_length) + "\n" + content_type + "\n" + x_headers + "\n" + resource
    bytes_to_hash = bytes(string_to_hash, encoding="utf-8")  
    decoded_key = base64.b64decode(shared_key)
    encoded_hash = base64.b64encode(hmac.new(decoded_key, bytes_to_hash, digestmod=hashlib.sha256).digest()).decode()
    authorization = "SharedKey {}:{}".format(customer_id,encoded_hash)
    return authorization

# Build and send a request to the POST API
# See https://docs.microsoft.com/azure/azure-monitor/logs/data-collector-api
def post_data(customer_id, shared_key, body, log_type):
    method = 'POST'
    content_type = 'application/json'
    resource = '/api/logs'
    rfc1123date = datetime.datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
    content_length = len(body)
    signature = build_signature(customer_id, shared_key, rfc1123date, content_length, method, content_type, resource)
    uri = 'https://' + customer_id + '.ods.opinsights.azure.com' + resource + '?api-version=2016-04-01'
    # Headers
    headers = {
        'content-type': content_type,
        'Authorization': signature,
        'Log-Type': log_type,
        'x-ms-date': rfc1123date
    }
    # Send POST request
    response = requests.post(uri,data=body, headers=headers)
    if (response.status_code >= 200 and response.status_code <= 299):
        print('INFO: API request to Azure Monitor accepted')
    else:
        print(f'ERROR: Response code: {response.status_code}, Response body: {response.content}')

# Only 1-level JSON is accepted by Log Analytics
def flatten(d, parent_key=None, items=None):
    if items == None:
        items = {}
    # print(f'Called flatten on dictionary {str(d)}, parent_key is {parent_key}, items is {str(items)}')
    for key in d:
        # print(f'Processing key {key}, type is {str(type(d[key]))}...')
        if parent_key == None:
            new_key = key
        else:
            new_key = parent_key + '_' + key
        if type(d[key]) == collections.OrderedDict:
            items = flatten (d[key], parent_key=new_key, items=items)
        elif type(d[key]) == list:
            if len(d[key]) > 0:
                if type(d[key][0]) == collections.OrderedDict:
                    i=0
                    for element in d[key]:
                        element_parent_key = new_key + '_' + str(i)
                        items = flatten(d[key][i], parent_key=element_parent_key, items=items)
                        i += 1
                else:
                    if len(d[key]) == 1:
                        items[new_key] = d[key][0]
                    elif len(d[key]) == 2:
                        items[new_key] = d[key][1]
                    else:
                        print ('WARNING: List with more than 2 literal elements, this should not have happened')
        else:
            items[new_key] = d[key]
    # print (json.dumps(items))
    return items

# Main
def main(argv):
    # Get arguments
    akv_name = None
    mrt_file = default_mrt_file
    dry_run = False
    try:
        opts, args = getopt.getopt(argv,"hdv:f:",["help", "dry-run", "vault-name=", "mrt-file="])
    except getopt.GetoptError:
        print ('Options: -v <azure_key_vault_name> -f <mrt_file_name>')
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print ('Options: -v <azure_key_vault_name> -f <mrt_file_name>')
            sys.exit()
        if opt in ("-d", "--dry-run"):
            print ("INFO: running in dry-run mode")
            dry_run = True
        elif opt in ("-v", "--vault-name"):
            akv_name = arg
        elif opt in ("-f", "--mrt-file"):
            akv_name = arg
    # Print vault name
    if (akv_name == None):
        print ('Options: -v <azure_key_vault_name> -f <mrt_file_name>')
        sys.exit()
    else:
        print ('INFO: Getting configuration from Azure Key Vault', akv_name)
    # Get secrets
    akv_uri = f"https://{akv_name}.vault.azure.net"
    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=akv_uri, credential=credential)
    logws_id = client.get_secret('bgp-logws-id').value
    logws_key = client.get_secret('bgp-logws-key').value

    # Debug: print configuration
    print('INFO: Log Analytics workspace is', logws_id, 'and key is', logws_key)

    # Only do something if file is actually not empty
    if os.stat(mrt_file).st_size > 0:

        # Move mrt_file to temp_mrt_file, and append it to the consolidated_mrt_file
        os.system(f'mv {mrt_file} {temp_mrt_file}')
        os.system(f'touch {mrt_file}')
        os.system(f'chmod 666 {mrt_file}')
        os.system(f'cat {temp_mrt_file} >> {consolidated_mrt_file}')

        # Analyze temp MRT file and dump JSON into a flattened string variable
        body=None
        for entry in mrtparse.Reader(temp_mrt_file):
            bgp_entry=flatten(entry.data)
            bgp_entry['raw']=str(json.dumps(entry.data))   # Add raw JSON for troubleshooting
            if body == None:
                body = '['
                body += json.dumps(bgp_entry)
            else:
                body += ',\n'
                body += json.dumps(bgp_entry)
        body += ']'

        if dry_run:
            # Print the JSON variable
            print('INFO: Dry-run mode. Data to send:')
            print(body)
        else:
            # Send message to Azure Monitor
            post_data(logws_id, logws_key, body, 'BgpAnalytics')
    else:
        print ('INFO: MRT file {mrt_file} is empty, not sending any logs')

if __name__ == "__main__":
   main(sys.argv[1:])
