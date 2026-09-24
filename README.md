# Sécurisation d'une infrastructure Kubernetes (AKS) sur Azure

Ce dépôt décrit un lab de création et de sécurisation d'un cluster Azure Kubernetes Service (AKS). Le scénario est le suivant : déploiement d'une infrastructure de base vulnérable, restriction des accès réseau au control-plane, mise en place d'une gestion des identités basée sur Microsoft Entra ID (RBAC), limitation des ressources applicatives, et implémentation des bonnes pratiques d'authentification Cloud-Native.

Une entreprise fait tourner en production un cluster Kubernetes public sans restriction IP, où tous les utilisateurs partagent les mêmes accès critiques via des comptes locaux. De plus, une application s'authentifie sur Azure à l'aide d'une clé d'accès inscrite en dur dans un Secret. 

L'objectif est de remédier à ces vulnérabilités à travers chaque étape de ce lab.

## 1 - Prérequis et variables

Prérequis :

* Azure CLI installé et connecté avec `az login`.
* `kubectl` installé pour interagir avec le cluster.
* `kubelogin` installé pour accéder au cluster après l'activation de Microsoft Entra ID. Le script `deploy-all.sh` tente de l'installer automatiquement avec `az aks install-cli` s'il est absent.
* Un Resource Group Azure existant.
* L'adresse IP publique des locaux de l'entreprise, autorisée à joindre le cluster.
* Les Object IDs de deux groupes de sécurité Microsoft Entra ID préalablement créés (un groupe "Admins" et un groupe "Readers").

> Les variables d'environnement nécessaires au déploiement sont chargées depuis un fichier `vars.env` local. Afin de ne pas exposer de données sensibles, ce fichier est ignoré par Git grâce à la configuration du fichier `.gitignore`.

```bash
export OWNER="<prenom-nom>"
export LOCATION="westeurope"
export RESOURCE_GROUP="<groupe_de_ressources>"
export CLUSTER_NAME="<nom_du_cluster>"
export NODE_COUNT=1

# Variables additionnelles pour les étapes de sécurisation
export CORPORATE_PUBLIC_IP="<IP_publique_entreprise>/32"
export ENTRA_ADMIN_GROUP_ID="<object_id_groupe_admin>"
export ENTRA_READER_GROUP_ID="<object_id_groupe_reader>"
```

## 2 - Déploiement de l'infrastructure de base (Vulnérable)

Le déploiement de l'infrastructure initiale est automatisé par le script `initial-infra.sh`. Ce script vérifie d'abord la présence du fichier `vars.env` pour charger les variables, puis procède à la création du cluster.

Pour refléter la situation critique, le cluster est déployé publiquement, sans restriction d'IP, sans monitoring Azure, et en s'appuyant sur les comptes locaux (Local RBAC). Les nœuds sont configurés en `Standard_D2_v3` et l'accès SSH est désactivé (`--no-ssh-key`).

Exécution du script :

```bash
./initial-infra.sh
```

À titre informatif, voici la commande principale exécutée par le script :

```bash
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --node-vm-size "Standard_D2_v3" \
  --node-count "$NODE_COUNT" \
  --no-ssh-key \
  --tags OWNER="$OWNER" \
  --output none
```

Le script récupère ensuite automatiquement les identifiants d'administration locale (kubeconfig) à l'aide de la commande `az aks get-credentials`. L'accès peut être testé avec :

```bash
kubectl get nodes
```

## 3 - Restriction de l'accès réseau par IP (Whitelist)

Afin de sécuriser le control-plane (API Server) de Kubernetes, une restriction réseau est appliquée. Seule l'adresse IP publique des locaux de l'entreprise est autorisée à interagir avec l'API Kubernetes.

```bash
az aks update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --api-server-authorized-ip-ranges "$CORPORATE_PUBLIC_IP"
```

Toute tentative de connexion avec `kubectl` provenant d'une autre adresse IP, même avec les bons identifiants, sera désormais rejetée par un *timeout* réseau.

## 4 - Authentification et Autorisation via Microsoft Entra ID

Avant de configurer le cluster, les groupes de sécurité doivent être créés dans Microsoft Entra ID. Les Object IDs de ces groupes sont récupérés dynamiquement dans des variables.

Création des groupes "Admins" et "Readers" :

```bash
# Création du groupe Admins et récupération de son ID
ENTRA_ADMIN_GROUP_ID=$(az ad group create --display-name "aks-admins-group" --mail-nickname "aksadmins" --query id -o tsv)

# Création du groupe Readers et récupération de son ID
ENTRA_READER_GROUP_ID=$(az ad group create --display-name "aks-readers-group" --mail-nickname "aksreaders" --query id -o tsv)

```

> **Note :** À ce stade, les comptes utilisateurs peuvent être ajoutés dans les groupes `aks-admins-group` et `aks-readers-group` (via le portail Azure ou avec la commande `az ad group member add`).

Pour supprimer l'utilisation des comptes locaux partagés, l'intégration Microsoft Entra ID est activée, et l'authentification locale est désactivée. Le groupe Entra ID "Admins" est défini comme administrateur du cluster.

```bash
az aks update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --enable-aad \
    --aad-admin-group-object-ids "$ENTRA_ADMIN_GROUP_ID" \
    --disable-local-accounts
```

Après la récupération du nouveau kubeconfig, celui-ci doit utiliser le contexte de connexion Azure CLI :

```bash
kubelogin convert-kubeconfig -l azurecli
```

### Configuration des accès "Readers"

Le groupe "Readers" doit pouvoir se connecter, mais avec des droits limités. Un `ClusterRole` et un `ClusterRoleBinding` doivent être appliqués via des manifestes Kubernetes (par un membre du groupe Admins).

> **Important :** Avant d'appliquer le binding, il faut s'assurer d'avoir renseigné l'Object ID du groupe Readers (contenu dans la variable `$ENTRA_READER_GROUP_ID`) dans le fichier `manifests/reader-clusterrolebinding.yaml`.

Application des manifestes :

```bash
kubectl apply -f manifests/reader-clusterrole.yaml
kubectl apply -f manifests/reader-clusterrolebinding.yaml
```

## 5 - Limitation des ressources (Namespace "prod")

Une politique de limitation des ressources peut être appliquée pour contrôler la consommation de CPU et de mémoire par les différents namespaces.  
Ici, le namespace dédié à la production (nommé "prod") est créé et une politique de quotas de ressources lui est appliquée.

Création du namespace :

```bash
kubectl create namespace prod
```

Application du manifeste `quota-prod.yaml` pour brider l'usage du CPU et de la mémoire :

```bash
kubectl apply -f manifests/quota-prod.yaml
```

## 6 - Authentification Cloud Native : Supprimer les clés d'accès

L'utilisation d'une clé d'accès ("access-key"), stockée en dur dans un Secret Kubernetes pour s'authentifier sur Azure, est une pratique qui peut s'avérer risquée. Elle peut poser des problèmes de sécurité (fuite potentielle, absence de rotation, difficulté d'audit).  

Pour éviter ces problèmes et se passer d'une clé d'accès stockée en dur, il faut utiliser la fédération d'identités OIDC (OpenID Connect) via **Azure Workload Identity**.  

Concrètement, le mécanisme fonctionne de la manière suivante :

1. **Identité Managée :** Une *User Assigned Managed Identity* est créée dans Azure. Elle possède les permissions (RBAC Azure) d'accéder aux ressources cibles (ex: Storage Account).
2. **Service Account Kubernetes :** Un *Service Account* est créé dans Kubernetes et est annoté avec l'ID client de l'Identité Managée Azure.
3. **Fédération (OIDC) :** Une relation de confiance est établie entre Azure Entra ID et le cluster AKS via un émetteur OIDC.
4. **Authentification du Pod :** Le Pod est lancé en utilisant le *Service Account* configuré. Le kubelet injecte automatiquement un token JWT (JSON Web Token) de courte durée dans le Pod. Le SDK (Software Development Kit) Azure de l'application utilise ce token pour demander un jeton d'accès valide à Microsoft Entra ID.

**Mise en place sur AKS :**

* Activer l'émetteur OIDC et Workload Identity sur le cluster AKS (`az aks update --enable-oidc-issuer --enable-workload-identity`).
* Créer l'identité managée Azure.
* Lier le *Service Account* Kubernetes à cette identité via les *Federated Identity Credentials* dans Entra ID.
* Assigner le *Service Account* au Pod applicatif.

## 7 - Bonus : Automatisation de la sécurisation du cluster

Le script `deploy-all.sh` permet de dérouler l'intégralité des étapes de cette documentation de manière séquentielle à partir d'un nom de cluster fourni en argument.
