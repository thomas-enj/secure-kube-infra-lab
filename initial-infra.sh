#!/bin/bash

set -e

# Chargement des variables d'environnement
if [ -f "vars.env" ]; then
  source vars.env
  echo "✅ Variables chargées depuis vars.env"
else
  echo "❌ Erreur : Le fichier vars.env est introuvable."
  exit 1
fi

echo "Début du déploiement de l'infrastructure initiale" 

# Création du cluster AKS (Configuration non sécurisée)
echo "Création du cluster AKS : $CLUSTER_NAME"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --node-vm-size "Standard_D2_v3" \
  --node-count "$NODE_COUNT" \
  --no-ssh-key \
  --tags OWNER="$OWNER" \
  --output none

echo "✅ Cluster AKS $CLUSTER_NAME créé avec succès"

# Récupération des credentials du cluster AKS (kubeconfig)
echo "Récupération des identifiants du cluster AKS : $CLUSTER_NAME"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing \
  --output none

echo "Déploiement terminé !"
echo "L'accès peut être testé avec: kubectl get nodes"