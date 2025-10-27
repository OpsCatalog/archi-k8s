#!/bin/bash
#
# Installation Worker RKE2 (Agent) - VERSION INTERACTIVE
# Usage: sudo bash setup-worker-interactive.sh
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Vérification root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
    exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Installation Worker RKE2 (Agent) - Mode Interactif    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

# Détecter le hostname
HOSTNAME=$(hostname)
echo -e "${YELLOW}Hostname détecté: ${GREEN}${HOSTNAME}${NC}\n"

# Demander l'IP du worker
echo -e "${YELLOW}Quelle est l'IP WireGuard de ce worker ?${NC}"
echo -e "${BLUE}(worker-1 = 10.10.0.4, worker-2 = 10.10.0.5)${NC}"
read -p "IP du worker : " WORKER_IP

if [ -z "$WORKER_IP" ]; then
    echo -e "${RED}Erreur: IP vide${NC}"
    exit 1
fi

echo -e "${GREEN}✓ IP du worker: ${WORKER_IP}${NC}\n"

# Demander le token
echo -e "${YELLOW}Entrez le token RKE2 (généré sur master-1):${NC}"
echo -e "${BLUE}(Le token qui a été affiché lors de l'installation de master-1)${NC}"
read -r TOKEN

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Erreur: token vide${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Token: ${TOKEN:0:20}...${NC}\n"

# Configuration
LB_IP="10.10.0.1"
LB_PUBLIC_IP="164.68.122.34"

echo -e "${YELLOW}Configuration:${NC}"
echo -e "  Hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "  IP Worker: ${GREEN}${WORKER_IP}${NC}"
echo -e "  Load Balancer: ${GREEN}${LB_IP}${NC}"
echo -e "  Token: ${GREEN}${TOKEN:0:20}...${NC}\n"

echo -e "${RED}⚠️  IMPORTANT: Le cluster master doit être opérationnel !${NC}\n"

read -p "Les masters sont-ils Ready ? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Vérifiez d'abord que les masters sont Ready${NC}"
    exit 1
fi

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

echo -e "${YELLOW}Configuration de WireGuard...${NC}"

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
Address = ${WORKER_IP}/24

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

# Vérifier WireGuard
echo -e "\n${YELLOW}Vérification de WireGuard...${NC}"
if systemctl is-active --quiet wg-quick@wg0; then
    echo -e "${GREEN}✓ WireGuard actif${NC}"
    wg show wg0 | head -n 3
else
    echo -e "${RED}✗ WireGuard n'est pas actif${NC}"
    echo -e "${YELLOW}WireGuard doit être configuré d'abord${NC}"
    exit 1
fi

# Test connectivité
echo -e "\n${YELLOW}Test de connectivité...${NC}"
if ping -c 3 ${LB_IP} > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Connectivité vers Load Balancer OK${NC}"
else
    echo -e "${RED}✗ Pas de connectivité vers le Load Balancer${NC}"
    exit 1
fi

if ping -c 3 10.10.0.2 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Connectivité vers master-1 OK${NC}\n"
else
    echo -e "${RED}✗ Pas de connectivité vers master-1${NC}"
    exit 1
fi

# Installation RKE2 Agent
echo -e "${YELLOW}[1/4] Installation de RKE2 Agent...${NC}"
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -

echo -e "${GREEN}✓ RKE2 Agent installé${NC}\n"

# Configuration
echo -e "${YELLOW}[2/4] Configuration de RKE2 Agent...${NC}"

mkdir -p /etc/rancher/rke2

cat > /etc/rancher/rke2/config.yaml << EOF
# Serveur RKE2 à rejoindre (via Load Balancer pour HA)
server: https://${LB_IP}:9345

# Token de sécurité (identique aux masters)
token: "${TOKEN}"

# Configuration du nœud
node-ip: ${WORKER_IP}

EOF

echo -e "${GREEN}✓ Configuration créée${NC}\n"

# Démarrage
echo -e "${YELLOW}[3/4] Démarrage de RKE2 Agent...${NC}"
echo -e "${BLUE}Connexion au cluster en cours...${NC}\n"

systemctl enable rke2-agent.service
systemctl start rke2-agent.service

# Suivre les logs pendant 30 secondes
timeout 30 journalctl -u rke2-agent -f || true

echo -e "\n${BLUE}Attente de la synchronisation (30 secondes)...${NC}"
sleep 30

# Vérification
echo -e "${YELLOW}[4/4] Vérification...${NC}"

if systemctl is-active --quiet rke2-agent; then
    echo -e "${GREEN}✓ RKE2 Agent actif${NC}\n"
    systemctl status rke2-agent --no-pager | head -n 10
else
    echo -e "${RED}✗ RKE2 Agent n'est pas actif${NC}"
    echo -e "${YELLOW}Vérifiez les logs: journalctl -u rke2-agent -n 50${NC}"
    exit 1
fi

# Sauvegarder les informations
cat > /root/worker-info.txt << EOF
Configuration Worker RKE2
═════════════════════════

Date: $(date)
Hostname: ${HOSTNAME}
IP: ${WORKER_IP}
Load Balancer: ${LB_IP}
Token: ${TOKEN}

Commandes utiles:
═════════════════

Statut du service:
systemctl status rke2-agent

Logs en temps réel:
journalctl -u rke2-agent -f

Redémarrer le service:
systemctl restart rke2-agent

Vérifier depuis le master:
kubectl get nodes
kubectl get pods -A -o wide | grep ${HOSTNAME}
EOF

echo -e "${GREEN}✓ Informations sauvegardées dans /root/worker-info.txt${NC}\n"

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Installation Worker terminée !                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

echo -e "${YELLOW}Prochaines étapes:${NC}"
echo -e "1. ${BLUE}Sur un master, vérifiez que le nœud apparaît:${NC}"
echo -e "   ${GREEN}kubectl get nodes${NC}\n"

echo -e "2. ${BLUE}Le nœud devrait apparaître comme:${NC}"
echo -e "   ${GREEN}${HOSTNAME}   Ready    worker   Xm   v1.33.x${NC}\n"

echo -e "3. ${BLUE}Surveillez les logs si nécessaire:${NC}"
echo -e "   ${GREEN}journalctl -u rke2-agent -f${NC}\n"

echo -e "${GREEN}🎉 Worker configuré avec succès !${NC}\n"
