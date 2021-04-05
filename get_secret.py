#!/usr/bin/python3

import sys, getopt
from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential

def main(argv):
    # Get arguments
    akv_name = None
    secret_name = None
    try:
        opts, args = getopt.getopt(argv,"hv:s:",["help", "vault-name=", "secret-name="])
    except getopt.GetoptError:
        print ('Options: -v <azure_key_vault_name> -s <secret_name>')
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print ('Options: -v <azure_key_vault_name> -s <secret_name>')
            sys.exit()
        elif opt in ("-v", "--vault-name"):
            akv_name = arg
        elif opt in ("-s", "--secret-name"):
            secret_name = arg
    # Print vault name
    if (akv_name == None) or (secret_name == None):
        print ('Options: -v <azure_key_vault_name> -s <secret_name>')
        sys.exit()
    else:
        print ('Getting secret', secret_name, 'from Azure Key Vault', akv_name)
    # Get secret
    akv_uri = f"https://{akv_name}.vault.azure.net"
    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=akv_uri, credential=credential)
    secret_value = client.get_secret(secret_name)

    # Debug: print secret
    print('Secret value:', secret_value.value)

if __name__ == "__main__":
   main(sys.argv[1:])
