#!/usr/bin/python3
import requests
import json

# Returns the price for a specific SKU and region
def get_prices_sku(region, sku, base_url="https://prices.azure.com/api/retail/prices", api_version="2023-01-01-preview", currency="USD", format="details"):
    api_url = base_url + "?api-version=" + api_version + "&currencyCode=" + currency
    query = f"armRegionName eq '{region}' and armSkuName eq '{sku}'"
    # print("DEBUG: sending REST request with query '{0}'".format(query))
    response = requests.get(api_url, params={'$filter': query})
    json_data = json.loads(response.text)
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
                print(f"{item['armSkuName']:<20} {item['skuName']:<20} {item['retailPrice']:<10} {item['armRegionName']:<15} {item['productName']:<50} {item["type"]:<20}")
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
    api_url = base_url + "?api-version=" + api_version + "&currencyCode=" + currency
    query = f"armSkuName eq '{sku}' and type eq 'Consumption'"
    # print("DEBUG: sending REST request with query '{0}'".format(query))
    response = requests.get(api_url, params={'$filter': query})
    json_data = json.loads(response.text)
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

def main():
    base_url = "https://prices.azure.com/api/retail/prices"
    api_version = "2023-01-01-preview"
    currency = "USD"

    # Examples:
    # get_prices_sku("swedencentral", "Standard_D16as_v6", base_url=base_url, api_version=api_version, currency=currency, format="details")
    get_prices_sku_all_regions("Standard_D16as_v6", base_url=base_url, api_version=api_version, currency=currency, format="table")
        
if __name__ == "__main__":
    main()