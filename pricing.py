#!/usr/bin/python
from azure.mgmt.compute import ComputeManagementClient
from azure.identity import DefaultAzureCredential
import requests
import json
import argparse

# Get input arguments
parser = argparse.ArgumentParser(description='Azure pricing CLI', prog='pricing')
subparsers = parser.add_subparsers(dest='command', help='Command help')
# Define common shared arguments
base_subparser = argparse.ArgumentParser(add_help=False)
base_subparser.add_argument('--verbose', dest='verbose', action='store_true',
                    default=False,
                    help='run in verbose mode (default: False)')
# Create the 'compare-regions' command
compare_parser = subparsers.add_parser('compare-regions', help='Compare prices of a SKU across regions', parents=[base_subparser])
compare_parser.add_argument('--sku', '-s', dest='sku', metavar= 'SKU', action='store',
                    help='SKU to be analyzed across regions, for example Standard_NC24ads_A100_v4')
# Create the 'get-skus' command
get_skus_parser = subparsers.add_parser('get-skus', help='Get available VM sizes in a region', parents=[base_subparser])
get_skus_parser.add_argument('--region', '--location', '-l', dest='region', metavar= 'REGION', action='store',
                    help='Azure region to get available VM sizes for, for example eastus2')
get_skus_parser.add_argument('--cores', '-c', dest='cores', metavar= 'CORES', type=int, action='store',
                    help='Number of CPUs for the VM sizes to be listed. Either single number or range (e.g., 4-16)')
get_skus_parser.add_argument('--memory', '-m', dest='memory', metavar= 'MEMORY_GB', type=int, action='store',
                    help='Amount of memory (in GB) for the VM sizes to be listed. Either single number or range (e.g., 16-64)')
get_skus_parser.add_argument('--cpu-arch', dest='cpu_arch', metavar= 'CPU_ARCH', action='store',
                    help='CPU architecture for the VM sizes to be listed ("i" for Intel, "a" for AMD, "p" for ARM)'),
get_skus_parser.add_argument('--subscription-id', dest='subscription_id', metavar= 'SUBSCRIPTION_ID', action='store',
                    help='Azure Subscription ID to use for authentication')
# Create the 'get-price' command
get_price_parser = subparsers.add_parser('get-price', help='Get price for a specific SKU in a region', parents=[base_subparser])
get_price_parser.add_argument('--region', '--location', '-l', dest='region', metavar= 'REGION', action='store',
                    help='Azure region to get the price for, for example eastus2')
get_price_parser.add_argument('--sku', '-s', dest='sku', metavar= 'SKU', action='store',
                    help='SKU to get the price for, for example Standard_NC24ads_A100_v4')
get_price_parser.add_argument('--format', '-f', '-o', dest='format', metavar= 'FORMAT', action='store', default='details',
                    help='Output format: details (default), json, table')

# Parse the command-line arguments
args = parser.parse_args()


# Returns JSON from a REST API call to the Azure Retail Prices API with a specific filter
def get_prices_json(query=None, base_url="https://prices.azure.com/api/retail/prices", api_version="2023-01-01-preview", currency="USD"):
    api_url = base_url + "?api-version=" + api_version + "&currencyCode=" + currency
    if args.verbose:
        print("DEBUG: sending REST request to URL '{0}'".format(api_url))
    response = requests.get(api_url, params={'$filter': query})
    json_data = json.loads(response.text)
    while 'NextPageLink' in json_data and json_data['NextPageLink']:
        next_page_url = json_data['NextPageLink']
        if args.verbose:
            print("DEBUG: retrieving next page from URL '{0}'".format(next_page_url))
        response = requests.get(next_page_url)
        next_page_data = json.loads(response.text)
        json_data['Items'].extend(next_page_data['Items'])
        json_data['NextPageLink'] = next_page_data.get('NextPageLink', None)
    return json_data

# Returns the price for a specific SKU and region
def get_prices_sku(region, sku, base_url="https://prices.azure.com/api/retail/prices", api_version="2023-01-01-preview", currency="USD", format="details"):
    api_url = base_url + "?api-version=" + api_version + "&currencyCode=" + currency
    query = f"armRegionName eq '{region}' and armSkuName eq '{sku}'"
    if args.verbose:
        print("DEBUG: sending REST request with query '{0}'".format(query))
    json_data = get_prices_json(query=query, base_url=base_url, api_version=api_version, currency=currency)
    if 'Items' in json_data:
        if format == "json":
            print(json.dumps(json_data['Items'], indent=4))
            return json_data['Items']
        elif format == "table":
            # Print header row using text padding for constant width
            print(f"{'ARM SKU':<20} {'SKU':<20} {'Price':<10} {'Region':<15} {'Product':<50} {'Type':<20}")
            print("-" * 140)
            # Print rows
            for item in json_data['Items']:
                print(f"{item['armSkuName']:<20} {item['skuName']:<20} {item['retailPrice']:<10} {item['armRegionName']:<15} {item['productName']:<50} {item['type']:<20}")
        elif format == "details":
            for item in json_data['Items']:
                if item.get("type") == "Reservation":
                    if item.get("reservationTerm") == "1 Year":
                        price_r1y = item['retailPrice']
                    elif item.get("reservationTerm") == "3 Years":
                        price_r3y = item['retailPrice']
                    else:
                        print("ERROR: reservation term {0} could not be interpreted".format(item.get("reservationTerm")))
                elif item.get("type") == "Consumption":
                    if 'Windows' in item.get("productName", ""):
                        if 'Spot' in item.get("skuName", ""):
                            price_win_spot = item['retailPrice']
                        elif 'Low Priority' in item.get("skuName", ""):
                            price_win_lp = item['retailPrice']
                        else:
                            price_win = item['retailPrice']
                    else:
                        if 'Spot' in item.get("skuName", ""):
                            price_lin_spot = item['retailPrice']
                        elif 'Low Priority' in item.get("skuName", ""):
                            price_lin_lp = item['retailPrice']
                        else:
                            price_lin = item['retailPrice']
            print("Pricing for SKU '{0}' in region '{1}':".format(sku, region))
            print("  Linux on-demand price: ${0}/hour, ${1}/month".format(price_lin, round(price_lin * 730, 2)))
            if 'price_lin_spot' in locals():
                print("    Linux spot price: ${0}/hour".format(price_lin_spot))
            if 'price_lin_lp' in locals():
                print("    Linux low-priority price: (for Azure Batch) ${0}/hour".format(price_lin_lp))
            print("  Windows on-demand price: ${0}/hour, ${1}/month".format(price_win, round(price_win * 730, 2)))
            if 'price_win_spot' in locals():
                print("    Windows spot price: ${0}/hour".format(price_win_spot))
            if 'price_win_lp' in locals():
                print("    Windows low-priority price (for Azure Batch): ${0}/hour".format(price_win_lp))
            if 'price_r1y' in locals():
                print("  1Y reservation price (Linux/AHB): ${0}, ${1}/month".format(price_r1y, round(price_r1y / 12, 2)))
                win_license = (price_win - price_lin) * 730
                price_r1y_win = round(price_r1y + (win_license * 12), 2)
                print("  1Y reservation price (Windows, no AHB): ${0}, ${1}/month".format(price_r1y_win, round(price_r1y_win / 12, 2)))
            if 'price_r3y' in locals():
                print("  3Y reservation price (Linux/AHB): ${0}, ${1}/month".format(price_r3y, round(price_r3y / 36, 2)))
                win_license = (price_win - price_lin) * 730
                price_r3y_win = round(price_r3y + (win_license * 36), 2)
                print("  3Y reservation price (Windows, no AHB): ${0}, ${1}/month".format(price_r3y_win, round(price_r3y_win / 36, 2)))
        else:
            print("ERROR: Unsupported format specified ({0}).".format(format))
    else:
        print("ERROR: No pricing data found for the specified SKU ({0}) and region ({1}).".format(sku, region))
        return None

# Returns a sorted listed with the on-demand Linux prices in all available regions for a specific SKU
def get_prices_sku_all_regions(sku, base_url="https://prices.azure.com/api/retail/prices", api_version="2023-01-01-preview", currency="USD", format="table"):
    query = f"armSkuName eq '{sku}' and type eq 'Consumption'"
    if args.verbose:
        print("DEBUG: sending REST request with query '{0}'".format(query))
    json_data = get_prices_json(query=query, base_url=base_url, api_version=api_version, currency=currency)
    prices = []
    if 'Items' in json_data:
        for item in json_data['Items']:
            if not ('Windows' in item.get("productName", "") or "Low Priority" in item.get("skuName", "") or "Spot" in item.get("skuName", "")):
                prices.append((item['armRegionName'], item['retailPrice'], item['productName'], item['skuName']))
        # Sort prices by price
        prices.sort(key=lambda x: x[1])
        if format == "json":
            print(json.dumps(prices, indent=4))
        elif format == "table":
            print(f"{'Region':<20} {'SKU name':<15} {'Product name':<35} {'Price (USD/hour)':<20} {'Price (USD/month)':<20}")
            print("-" * 105)
            for region, price, product_name, sku_name in prices:
                print(f"{region:<20} {sku_name:<15} {product_name:<35} {price:<20} {round(price * 730, 2):<20}")
        else:
            print("ERROR: Unsupported format specified ({0}).".format(format))
    else:
        print("ERROR: No pricing data found for the specified SKU ({0}).".format(sku))
        return None

# Helper function to check if a number is in a range or equals a single value
# The parameter can be a single digit (e.g., 4) or a range (e.g., 4-16)
def number_in_range(value, range_param):
    if isinstance(range_param, int):
        return value == range_param
    elif isinstance(range_param, str) and '-' in range_param:
        parts = range_param.split('-')
        if len(parts) == 2:
            try:
                lower = int(parts[0])
                upper = int(parts[1])
                return lower <= value <= upper
            except ValueError:
                return False
    return False

# Get available VM sizes from the region, equivalent to the Azure CLI command `az vm list-sizes --location <region>`
# Use the Azure python SDK for Microsoft.Compute/VirtualMachines
# Authenticate and initialize the client
def get_vm_sizes(region, subscription_id="", cores=None, memory=None, cpu_arch=None):
    credential = DefaultAzureCredential()
    if len(subscription_id) != 36:
        print("ERROR: subscription_id must be provided to get VM sizes.")
        return
    compute_client = ComputeManagementClient(credential, subscription_id)
    # Get the prices for the specified region
    region_prices = get_prices_json(query=f"armRegionName eq '{region}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption'")
    if region_prices is None or 'Items' not in region_prices:
        print("ERROR: Could not get pricing data for region '{0}'.".format(region))
        return
    if args.verbose:
        print("DEBUG: Retrieved pricing data for region '{0}'. {1} items found.".format(region, len(region_prices['Items'])))
    # List VM sizes for a specific region
    vm_sizes = compute_client.virtual_machine_sizes.list(location=region)
    size_list = []
    for size in vm_sizes:
        if (cores is not None and not number_in_range(size.number_of_cores, cores)):
            continue
        if (memory is not None and not number_in_range(round(size.memory_in_mb/1024, 0), memory)):
            continue
        # Find the price for this VM size in the region_prices data
        vm_price = None
        for item in region_prices['Items']:
            if item.get("armSkuName").lower() == size.name.lower():
                if 'Windows' in item.get("productName", ""):
                    # if args.verbose:
                    #     print("DEBUG: Skipping Windows price for VM size '{0}'".format(size.name))
                    continue
                if "Low Priority" in item.get("skuName", "") or "Spot" in item.get("skuName", ""):
                    # if args.verbose:
                    #     print("DEBUG: Skipping Spot/Low Priority price for VM size '{0}'".format(size.name))
                    continue
                vm_price = item.get("retailPrice")
                break
        if vm_price is not None:
            size_list.append({'size': size, 'price': vm_price, 'cores': size.number_of_cores, 'memory_gb': round(size.memory_in_mb / 1024, 0), 'price_per_core_month': round((vm_price * 730) / size.number_of_cores, 2)})
    # Sort the list by price per core per month
    size_list.sort(key=lambda x: x['price_per_core_month'])
    # Print the header
    print(f"{'VM Size':<25} {'Cores':>5} {'Memory':>7} {'Price (USD/hour)':>15} {'Price (USD/month)':>20} {'Price/core/month':>20}")
    print("-" *  105)
    # Print the sizes and prices
    for entry in size_list:
        print(f"{entry['size'].name:<25} {entry['size'].number_of_cores:>3}   {entry['memory_gb']:6.0f}      ${entry['price']:7.4f}/h      ${round(entry['price'] * 730, 2):8.2f}/month      ${entry['price_per_core_month']:6.2f}/month*core")

    # Print the VM sizes and prices
    # Print line with VM size and price (if available)
    # print(f"{size.name:<25} - {size.number_of_cores:>3} cores - {round(size.memory_in_mb/1024, 0):4.0f} GB - ${vm_price:7.4f}/h - ${round(vm_price * 730, 2):8.2f}/month - ${round(vm_price * 730 / size.number_of_cores, 2):8.2f}/month*core")

################
# Main program #
################

# Global parameters
base_url = "https://prices.azure.com/api/retail/prices"
api_version = "2023-01-01-preview"
currency = "USD"    # Could become an input argument later

# Compare
if args.command == 'compare':
    if args.sku:
        get_prices_sku_all_regions(args.sku, base_url=base_url, api_version=api_version, currency=currency, format="table")
    else:
        print("ERROR: --sku argument is required for 'compare' command.")
elif args.command == 'get-price':
    if args.region and args.sku:
        get_prices_sku(args.region, args.sku, base_url=base_url, api_version=api_version, currency=currency, format=args.format)
    else:
        print("ERROR: --region and --sku arguments are required for 'get-price' command.")
elif args.command == 'get-skus':
    if args.region and args.subscription_id:
        if args.cores or args.memory:
            get_vm_sizes(args.region, subscription_id=args.subscription_id, cores=args.cores, memory=args.memory, cpu_arch=args.cpu_arch)
        else:
            print("ERROR: At least one of --cores or --memory arguments must be provided to filter VM sizes.")
    else:
        print("ERROR: --region and --subscription-id arguments are required for 'get-skus' command.")
else:
    parser.print_help()