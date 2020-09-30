# Get password from keyvault and define variables
# https://github.com/microsoft/Azure-data-services-on-Azure-Arc/blob/master/scenarios-new/002-create-data-controller.md
akv_name=erjositoKeyvault
password=$(az keyvault secret show -n defaultPassword --vault-name $akv_name --query value -o tsv)
export AZDATA_USERNAME=jose
export AZDATA_PASSWORD=$password
export ACCEPT_EULA=yes
export REGISTRY_USERNAME="22cda7bb-2eb1-419e-a742-8710c313fe79"
export REGISTRY_PASSWORD="cb892016-5c33-4135-acbf-7b15bc8cb0f7"

# Install azdata
# https://github.com/microsoft/Azure-data-services-on-Azure-Arc/blob/master/scenarios-new/001-install-client-tools.md#step-1-install-azdata
# For example, for Ubuntu 20.04:
apt-get update
apt-get install -y curl apt-transport-https unixodbc libkrb5-dev libssl1.1
curl -SL https://private-repo.microsoft.com/python/azure-arc-data/private-preview-aug-2020-new/ubuntu-focal/azdata-cli_20.1.1-1~focal_all.deb -o azdata-cli_20.1.1-1~focal_all.deb
dpkg -i azdata-cli_20.1.1-1~focal_all.deb
apt-get -f install

# Deploy controller
rg=arcdata
location=westeurope
az group create -n $rg -l $location
subscription_id=$(az account show --query id -o tsv)
azdata arc dc create --profile-name azure-arc-aks-premium-storage \
                     --namespace arc --name arc \
                     --subscription $subscription_id \
                     --resource-group $rg --location $location \
                     --connectivity-mode indirect
azdata arc dc status show
azdata arc dc endpoint list -o table  # Notice the Grafana and Kibana endpoints

# Login
azdata login --namespace arc

# Deploy Azure SQL Database
# https://github.com/microsoft/Azure-data-services-on-Azure-Arc/blob/master/scenarios-new/003-create-sqlmiaa-instance.md
sqldb_name=mysqldb
azdata arc sql mi create -n $sqldb_name \
    --storage-class-data managed-premium --storage-class-logs managed-premium
azdata arc sql mi list
azdata arc sql mi show -n $sqldb_name

# Upload info to AzMonitor
# https://github.com/microsoft/Azure-data-services-on-Azure-Arc/blob/master/scenarios-new/007-upload-metrics-and-logs-to-Azure-Monitor.md
# 1. Create SP and assign 'Monitoring Metrics Publisher role'
az role assignment create --assignee $sp_app_id --role 'Monitoring Metrics Publisher' --scope subscriptions/$subscription_id
# az role assignment create --assignee $sp_app_id --role 'Contributor' --scope subscriptions/$subscription_id
echo $SPN_CLIENT_ID
echo $SPN_CLIENT_SECRET
# 2. Create LA workspace
logws_name=log$RANDOM
az monitor log-analytics workspace create -g $rg -n $logws_name
export WORKSPACE_ID=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
export WORKSPACE_SHARED_KEY=$(az monitor log-analytics workspace get-shared-keys -g $rg -n $logws_name --query primarySharedKey -o tsv)
export SPN_AUTHORITY='https://login.microsoftonline.com'
export SPN_TENANT_ID=$(az account show --query tenantId -o tsv)
# 3. upload metrics/logs
azdata arc dc upload --path metrics.json  # One-time task, you should crontab this
azdata arc dc upload --path logs.json     # One-time task, you should crontab this


# Deploy Posgres DB
# https://github.com/microsoft/Azure-data-services-on-Azure-Arc/blob/master/scenarios-new/004-create-Postgres-instances.md
postgres_name=myps
azdata arc postgres server create -n $postgres_name --workers 2 \
    --storage-class-data managed-premium --storage-class-logs managed-premium
azdata arc postgres server list
azdata arc postgres server endpoint list -n $postgres_name
