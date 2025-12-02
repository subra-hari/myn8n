###############################################################
# VARIABLES — UPDATE ONLY IF NEEDED
###############################################################

$Location               = "canadacentral"
$ResourceGroup          = "rg-n8n-prod"
$VnetName               = "vnet-n8n-prod"
$SubnetName             = "snet-aks-n8n"
$AddressSpace           = "10.232.0.0/16"
$SubnetPrefix           = "10.232.1.0/24"

$AksName                = "aks-n8n-prod"
$NodeSize               = "Standard_DS3_v2"
$NodeCount              = 2

$PostgresName           = "pgflex-n8n-prod"
$PostgresUser           = "n8nuser"
$PostgresPass           = (New-Guid).Guid + "!"
$PostgresDB             = "n8ndb"
$sendgridApiKey = "SG.mykey"
$KeyVaultName           = "kv-n8n-prod-$(Get-Random)"
$DomainName             = "n8n.sgrtech.ca"

$IngressNamespace       = "ingress-nginx"
$N8nNamespace           = "n8n"

###############################################################
# 1. CREATE RESOURCE GROUP
###############################################################
Write-Host "Creating Resource Group..." -ForegroundColor Cyan
az group create -n $ResourceGroup -l $Location

###############################################################
# 2. CREATE VNET + SUBNET (Shared for AKS + Private Endpoint)
###############################################################
Write-Host "Creating VNet + Subnet..." -ForegroundColor Cyan

az network vnet create `
  -g $ResourceGroup `
  -n $VnetName `
  --address-prefixes $AddressSpace `
  --subnet-name $SubnetName `
  --subnet-prefixes $SubnetPrefix

$SubnetId = az network vnet subnet show `
  -g $ResourceGroup `
  --vnet-name $VnetName `
  -n $SubnetName `
  --query id -o tsv

###############################################################
# 3. CREATE POSTGRESQL FLEXIBLE SERVER (PRIVATE ACCESS ONLY)
###############################################################
Write-Host "Creating PostgreSQL Flexible Server..." -ForegroundColor Cyan

az postgres flexible-server create `
  -g $ResourceGroup `
  -n $PostgresName `
  --location $Location `
  --vnet $VnetName `
  --subnet $SubnetName `
  --private-dns-zone "" `
  --admin-user $PostgresUser `
  --admin-password $PostgresPass `
  --version 16 `
  --storage-size 64 `
  --sku-name Standard_D2ds_v5

$PostgresHost = az postgres flexible-server show `
  -g $ResourceGroup `
  -n $PostgresName `
  --query "fullyQualifiedDomainName" -o tsv

###############################################################
# 4. CREATE KEY VAULT + STORE SECRETS
###############################################################
Write-Host "Creating Key Vault..." -ForegroundColor Cyan

az keyvault create `
  -g $ResourceGroup `
  -n $KeyVaultName `
  -l $Location `
  --enable-rbac-authorization true

# Store secrets
az keyvault secret set --vault-name $KeyVaultName -n "POSTGRES-USER"     --value $PostgresUser
az keyvault secret set --vault-name $KeyVaultName -n "POSTGRES-PASSWORD" --value $PostgresPass
az keyvault secret set --vault-name $KeyVaultName -n "POSTGRES-DB"       --value $PostgresDB

# Dummy SendGrid key - replace later
az keyvault secret set --vault-name $KeyVaultName -n "SENDGRID-API-KEY"  --value "REPLACE-ME"

###############################################################
# 5. CREATE AKS CLUSTER WITH SYSTEM-ASSIGNED MANAGED IDENTITY
###############################################################
Write-Host "Creating AKS Cluster..." -ForegroundColor Cyan

az aks create `
  -g $ResourceGroup `
  -n $AksName `
  --enable-managed-identity `
  --network-plugin azure `
  --vnet-subnet-id $SubnetId `
  --node-count $NodeCount `
  --node-vm-size $NodeSize `
  --generate-ssh-keys

# Get AKS cred
az aks get-credentials -g $ResourceGroup -n $AksName --overwrite-existing

# Get AKS kubelet MI principal ID
$KubeletId = az aks show `
  -g $ResourceGroup `
  -n $AksName `
  --query identityProfile.kubeletidentity.objectId -o tsv

###############################################################
# 6. ASSIGN KEY VAULT PERMISSIONS TO AKS IDENTITY
###############################################################
Write-Host "Assigning Key Vault Permissions..." -ForegroundColor Cyan

az role assignment create `
  --assignee $KubeletId `
  --role "Key Vault Secrets User" `
  --scope $(az keyvault show -n $KeyVaultName --query id -o tsv)

###############################################################
# 7. INSTALL SECRETS STORE CSI DRIVER
###############################################################
Write-Host "Installing Secrets Store CSI Driver..." -ForegroundColor Cyan

az aks addon enable `
  -n $AksName `
  -g $ResourceGroup `
  --addon azure-keyvault-secrets-provider

###############################################################
# 8. DEPLOY INGRESS-NGINX INTERNAL LOAD BALANCER
###############################################################
Write-Host "Deploying ingress-nginx..." -ForegroundColor Cyan

kubectl create namespace $IngressNamespace

kubectl apply -n $IngressNamespace -f https://raw.githubusercontent.com/subra-hari/myn8n/refs/heads/main/n8n-ingres.yaml

# Patch LB to internal
kubectl annotate svc ingress-nginx-controller -n $IngressNamespace `
  service.beta.kubernetes.io/azure-load-balancer-internal="true" `
  --overwrite

###############################################################
# 9. CREATE SecretProviderClass FOR n8n
###############################################################
Write-Host "Creating SecretProviderClass..." -ForegroundColor Cyan

@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: n8n-akv
  namespace: n8n
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    keyvaultName: "$KeyVaultName"
    tenantId: "$(az account show --query tenantId -o tsv)"
    objects: |
      array:
        - |
          objectName: POSTGRES-USER
          objectType: secret
        - |
          objectName: POSTGRES-PASSWORD
          objectType: secret
        - |
          objectName: POSTGRES-DB
          objectType: secret
        - |
          objectName: SENDGRID-API-KEY
          objectType: secret
    resourceGroup: "$ResourceGroup"
    subscriptionId: "$(az account show --query id -o tsv)"
"@ | kubectl apply -f -

###############################################################
# 10. DEPLOY n8n + PVC + SERVICE + INGRESS
###############################################################
Write-Host "Deploying n8n..." -ForegroundColor Cyan

@"
apiVersion: v1
kind: Namespace
metadata:
  name: n8n
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-pvc
  namespace: n8n
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: n8n
spec:
  replicas: 1
  selector:
    matchLabels: { app: n8n }
  template:
    metadata:
      labels: { app: n8n }
    spec:
      volumes:
      - name: akv-secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: n8n-akv
      - name: n8n-storage
        persistentVolumeClaim:
          claimName: n8n-pvc
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        ports:
        - containerPort: 5678
        env:
        - name: DB_TYPE
          value: postgres
        - name: DB_POSTGRESDB_HOST
          value: "$PostgresHost"
        - name: DB_POSTGRESDB_PORT
          value: "5432"
        - name: DB_POSTGRESDB_USER
          valueFrom:
            secretKeyRef:
              name: akv
              key: POSTGRES-USER
        - name: DB_POSTGRESDB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: akv
              key: POSTGRES-PASSWORD
        - name: DB_POSTGRESDB_DATABASE
          valueFrom:
            secretKeyRef:
              name: akv
              key: POSTGRES-DB
        - name: WEBHOOK_URL
          value: "https://$DomainName/"
        - name: N8N_HOST
          value: "0.0.0.0"
        - name: N8N_PORT
          value: "5678"
        - name: GENERIC_TIMEZONE
          value: "America/Toronto"
        volumeMounts:
        - name: akv-secrets
          mountPath: "/mnt/secrets-store"
          readOnly: true
        - name: n8n-storage
          mountPath: /home/node/.n8n
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: n8n
spec:
  selector: { app: n8n }
  ports:
  - port: 5678
    targetPort: 5678
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n-ingress
  namespace: n8n
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  rules:
  - host: "$DomainName"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: n8n
            port:
              number: 5678
"@ | kubectl apply -f -

###############################################################
# DONE
###############################################################
Write-Host "`n==================================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETED SUCCESSFULLY " -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green

Write-Host "`nPostgreSQL Host: $PostgresHost"
Write-Host "Key Vault: $KeyVaultName"
Write-Host "AKS: $AksName"
Write-Host "Ingress Domain: https://$DomainName"
Write-Host "`nIMPORTANT: Configure Azure Front Door with Private Link to the ingress-nginx internal load balancer." -ForegroundColor Yellow
