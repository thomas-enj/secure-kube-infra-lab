#!/bin/bash

# Arrêt du script en cas d'erreur
set -e

if ! command -v az >/dev/null 2>&1; then
  echo "❌ Erreur : Azure CLI (az) est requis."
  exit 1
fi

if ! command -v kubelogin >/dev/null 2>&1; then
  echo "Installation de kubelogin..."
  az aks install-cli
  export PATH="$PATH:$HOME/.azure-kubelogin"
  hash -r
fi

if ! command -v kubelogin >/dev/null 2>&1; then
  echo "❌ Erreur : kubelogin est installé mais reste introuvable dans le PATH."
  echo "Ajoutez $HOME/.azure-kubelogin au PATH, puis relancez le script."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ Erreur : kubectl est requis. Exécutez 'az aks install-cli', puis relancez le script."
  exit 1
fi

# Chargement des variables d'environnement
if [ -f "vars.env" ]; then
  source vars.env
  echo "✅ Variables chargées depuis vars.env"
else
  echo "❌ Erreur : Le fichier vars.env est introuvable."
  exit 1
fi

# Récupération du nom du cluster (par argument de script, sinon via vars.env)
TARGET_CLUSTER=${1:-$CLUSTER_NAME}

echo "================================================================="
echo "Début de la sécurisation du cluster : $TARGET_CLUSTER"
echo "================================================================="

# Restriction réseau (IP Whitelist)
echo "Configuration de l'IP Whitelist..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$TARGET_CLUSTER" \
  --api-server-authorized-ip-ranges "$CORPORATE_PUBLIC_IP" \
  --output none

# Configuration Microsoft Entra ID
echo "Création des groupes de sécurité Entra ID..."
ENTRA_ADMIN_GROUP_ID=$(az ad group create --display-name "aks-admins-group-$RANDOM" --mail-nickname "aksadmins$RANDOM" --query id -o tsv)
ENTRA_READER_GROUP_ID=$(az ad group create --display-name "aks-readers-group-$RANDOM" --mail-nickname "aksreaders$RANDOM" --query id -o tsv)

echo "Ajout de votre compte utilisateur au groupe Administrateur..."
CURRENT_USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az ad group member add --group "$ENTRA_ADMIN_GROUP_ID" --member-id "$CURRENT_USER_OBJECT_ID"

echo "Activation de Microsoft Entra ID sur le cluster (désactivation des comptes locaux)..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$TARGET_CLUSTER" \
  --enable-aad \
  --aad-admin-group-object-ids "$ENTRA_ADMIN_GROUP_ID" \
  --disable-local-accounts \
  --output none

# Récupération des identifiants (Entra ID)
echo "Récupération des nouveaux identifiants de connexion..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$TARGET_CLUSTER" \
  --overwrite-existing \
  --output none

kubelogin convert-kubeconfig -l azurecli

# Application du RBAC pour le groupe Reader
echo "Application des droits RBAC pour les Readers..."
kubectl apply -f manifests/reader-clusterrole.yaml
sed "s/<object_id_groupe_reader>/$ENTRA_READER_GROUP_ID/g" manifests/reader-clusterrolebinding.yaml | kubectl apply -f -

# Limitation des ressources (Namespace Prod)
echo "Création du namespace 'prod' et application des quotas..."
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/quota-prod.yaml

# Préparation Cloud Native (Workload Identity)
echo "Activation de l'émetteur OIDC et de Workload Identity..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$TARGET_CLUSTER" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --output none

echo "================================================================="
echo "Sécurisation terminée avec succès pour le cluster $TARGET_CLUSTER !"
echo "================================================================="