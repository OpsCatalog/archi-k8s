#!/bin/bash
#
# Script d'installation RKE2 pour Master et Worker
# Usage: sudo bash setup-rke2-node.sh [master|worker] <node-ip> <server-ip>
# Exemple Master: sudo bash setup-rke2-node.sh master 10.10.0.2 10.10.0.1
# Exemple Worker: sudo bash setup-rke2-node.sh worker 10.10.0.3 10.10.0.2
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Vérification des arguments
if [ "$#" -lt 3 ]; then
    echo -e "${RED}Usage: $0 [master|worker] <node-ip> <server-ip>${NC}"
    echo -e "${YELLOW}Exemple Master: $0 master 10.10.0.2 10.10.0.1${NC}"
    echo -e "${YELLOW}Exemple Worker: $0 worker 10.10.0.3 10.10.0.2${NC}"
    exit 1
fi

NODE_TYPE=$1
NODE_IP=$2
SERVER_IP=$3
LB_PUBLIC_IP="185.x.x.x"  # À modifier
WG_PORT="51820"

# Vérification root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
    exit 1
fi

# Validation du type de nœud
if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" ]]; then
    echo -e "${RED}Type de nœud invalide. Utilisez 'master' ou 'worker'${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation RKE2 - Nœud ${NODE_TYPE^^}${NC}"
echo -e "${GREEN}IP: ${NODE_IP}${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Fonction pour demander le token
get_token() {
    if [ -z "$RKE2_TOKEN" ]; then
        echo -e "${YELLOW}Entrez le token RKE2 (généré sur le master):${NC}"
        read -s RKE2_TOKEN
        echo ""
    fi
}

# Étape 1: Mise à jour du système
echo -e "${YELLOW}[1/8] Mise à jour du système...${NC}"
apt update && apt upgrade -y

# Étape 2: Installation des prérequis
echo -e "${YELLOW}[2/8] Installation des prérequis...${NC}"
apt install -y curl wget wireguard wireguard-tools net-tools

# Étape 3: Configuration système pour Kubernetes
echo -e "${YELLOW}[3/8] Configuration système pour Kubernetes...${NC}"

# Désactiver le swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Charger les modules kernel
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configuration sysctl
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Étape 4: Configuration de WireGuard
echo -e "${YELLOW}[4/8] Configuration de WireGuard...${NC}"

mkdir -p /etc/wireguard
cd /etc/wireguard

# Générer les clés si elles n'existent pas
if [ ! -f private.key ]; then
    wg genkey | tee private.key | wg pubkey > public.key
    chmod 600 private.key
    echo -e "${GREEN}✓ Clés WireGuard générées${NC}"
else
    echo -e "${YELLOW}⚠ Clés WireGuard déjà existantes${NC}"
fi

PRIVATE_KEY=$(cat private.key)
PUBLIC_KEY=$(cat public.key)

echo -e "\n${GREEN}Clé publique de ce nœud (à ajouter sur le load balancer):${NC}"
echo -e "${YELLOW}${PUBLIC_KEY}${NC}\n"

# Demander la clé publique du serveur
echo -e "${YELLOW}Entrez la clé publique du serveur Load Balancer:${NC}"
read SERVER_PUBLIC_KEY

if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo -e "${RED}Erreur: clé publique du serveur vide${NC}"
    exit 1
fi

# Créer la configuration WireGuard
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${NODE_IP}/24

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${LB_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

# Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

sleep 3

# Test de connectivité
echo -e "\n${YELLOW}Test de connectivité vers le serveur...${NC}"
if ping -c 3 ${SERVER_IP} > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Connectivité VPN OK${NC}\n"
else
    echo -e "${RED}✗ Échec de la connectivité VPN${NC}"
    echo -e "${YELLOW}Vérifiez que le peer est ajouté sur le serveur${NC}\n"
    exit 1
fi

# Étape 5: Installation de RKE2
echo -e "${YELLOW}[5/8] Installation de RKE2...${NC}"

mkdir -p /etc/rancher/rke2

if [ "$NODE_TYPE" = "master" ]; then
    # Installation RKE2 Server
    echo -e "${BLUE}Installation du serveur RKE2...${NC}"
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -
    
    # Demander le token ou en générer un
    echo -e "${YELLOW}Générer un nouveau token pour ce cluster ? (y/n)${NC}"
    read -r GENERATE_TOKEN
    
    if [[ "$GENERATE_TOKEN" =~ ^[Yy]$ ]]; then
        RKE2_TOKEN=$(openssl rand -base64 32)
        echo -e "${GREEN}Token généré: ${YELLOW}${RKE2_TOKEN}${NC}"
        echo -e "${RED}IMPORTANT: Sauvegardez ce token pour les workers!${NC}\n"
    else
        get_token
    fi
    
    # Étape 6: Configuration RKE2 Master
    echo -e "${YELLOW}[6/8] Configuration du serveur RKE2...${NC}"
    
    cat > /etc/rancher/rke2/config.yaml << EOF
# Configuration du nœud
node-ip: ${NODE_IP}
advertise-address: ${NODE_IP}

# Configuration TLS
tls-san:
  - ${LB_PUBLIC_IP}
  - ${SERVER_IP}
  - ${NODE_IP}
  - master01
  - localhost
  - 127.0.0.1

# Token de sécurité
token: "${RKE2_TOKEN}"

# Configuration réseau
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
cluster-dns: 10.43.0.10

# CNI
cni:
  - calico

# Désactiver l'ingress par défaut (on installera Traefik)
disable:
  - rke2-ingress-nginx

# Permissions kubeconfig
write-kubeconfig-mode: "0644"
EOF
    
    # Étape 7: Démarrage du service
    echo -e "${YELLOW}[7/8] Démarrage du serveur RKE2...${NC}"
    systemctl enable rke2-server.service
    systemctl start rke2-server.service
    
    echo -e "${BLUE}Attente du démarrage complet (cela peut prendre 2-3 minutes)...${NC}"
    sleep 120
    
    # Configuration de kubectl
    echo -e "${YELLOW}[8/8] Configuration de kubectl...${NC}"
    
    # Ajouter RKE2 au PATH
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
    
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    
    # Créer un lien symbolique pour kubectl
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
    
    # Vérification
    echo -e "\n${GREEN}Vérification du cluster...${NC}"
    kubectl get nodes
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Installation MASTER terminée !${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    
    # Sauvegarder les informations importantes
    cat > /root/rke2-master-info.txt << EOF
Configuration RKE2 Master
═════════════════════════

Date: $(date)
Nœud: ${NODE_IP}

Token RKE2:
${RKE2_TOKEN}

Clé publique WireGuard:
${PUBLIC_KEY}

Pour ajouter des workers:
sudo bash setup-rke2-node.sh worker <worker-ip> ${NODE_IP}

Configuration kubectl:
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=\$PATH:/var/lib/rancher/rke2/bin

Commandes utiles:
kubectl get nodes
kubectl get pods -A
journalctl -u rke2-server -f
EOF
    
    echo -e "${GREEN}✓ Informations sauvegardées dans /root/rke2-master-info.txt${NC}\n"
    echo -e "${YELLOW}Token RKE2 (pour les workers):${NC}"
    echo -e "${RED}${RKE2_TOKEN}${NC}\n"
    
else
    # Installation RKE2 Agent (Worker)
    echo -e "${BLUE}Installation de l'agent RKE2...${NC}"
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -
    
    # Demander le token
    get_token
    
    # Étape 6: Configuration RKE2 Worker
    echo -e "${YELLOW}[6/8] Configuration de l'agent RKE2...${NC}"
    
    # Demander l'IP du master
    echo -e "${YELLOW}IP du serveur RKE2 master (par défaut: 10.10.0.2):${NC}"
    read MASTER_IP
    MASTER_IP=${MASTER_IP:-10.10.0.2}
    
    cat > /etc/rancher/rke2/config.yaml << EOF
# Serveur RKE2 à rejoindre
server: https://${MASTER_IP}:9345

# Token de sécurité
token: "${RKE2_TOKEN}"

# Configuration du nœud
node-ip: ${NODE_IP}

# Labels pour ce worker
node-label:
  - "node-role.kubernetes.io/worker=true"
  - "workload=application"
EOF
    
    # Étape 7: Démarrage du service
    echo -e "${YELLOW}[7/8] Démarrage de l'agent RKE2...${NC}"
    systemctl enable rke2-agent.service
    systemctl start rke2-agent.service
    
    echo -e "${BLUE}Attente de la connexion au master...${NC}"
    sleep 30
    
    # Étape 8: Vérification
    echo -e "${YELLOW}[8/8] Vérification...${NC}"
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Installation WORKER terminée !${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    
    # Sauvegarder les informations
    cat > /root/rke2-worker-info.txt << EOF
Configuration RKE2 Worker
═════════════════════════

Date: $(date)
Nœud: ${NODE_IP}
Master: ${MASTER_IP}

Clé publique WireGuard:
${PUBLIC_KEY}

Vérifier le statut:
systemctl status rke2-agent

Logs:
journalctl -u rke2-agent -f

Sur le master, vérifier avec:
kubectl get nodes
EOF
    
    echo -e "${GREEN}✓ Informations sauvegardées dans /root/rke2-worker-info.txt${NC}\n"
fi

# Afficher les statuts finaux
echo -e "${YELLOW}Statut du réseau WireGuard:${NC}"
wg show

echo -e "\n${YELLOW}Statut du service RKE2:${NC}"
if [ "$NODE_TYPE" = "master" ]; then
    systemctl status rke2-server --no-pager | head -n 10
else
    systemctl status rke2-agent --no-pager | head -n 10
fi

echo -e "\n${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}Installation terminée avec succès ! 🎉${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}\n"

if [ "$NODE_TYPE" = "master" ]; then
    echo -e "${YELLOW}Prochaines étapes:${NC}"
    echo "1. Vérifier que le nœud est 'Ready': kubectl get nodes"
    echo "2. Installer Traefik Ingress Controller"
    echo "3. Configurer les workers avec le token fourni"
    echo ""
else
    echo -e "${YELLOW}Prochaines étapes:${NC}"
    echo "1. Sur le master, vérifier: kubectl get nodes"
    echo "2. Répéter pour les autres workers"
    echo ""
fi

echo -e "${BLUE}Logs en temps réel:${NC}"
if [ "$NODE_TYPE" = "master" ]; then
    echo "journalctl -u rke2-server -f"
else
    echo "journalctl -u rke2-agent -f"
fi
echo ""
