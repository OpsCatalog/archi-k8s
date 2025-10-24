#!/bin/bash
#
# Script d'installation et configuration du Load Balancer
# Usage: sudo bash setup-loadbalancer.sh
#

set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PUBLIC_IP="185.x.x.x"  # À modifier avec votre IP publique
VPN_NETWORK="10.10.0.0/24"
VPN_IP="10.10.0.1"
WG_PORT="51820"
INTERFACE="eth0"  # À modifier selon votre interface réseau

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Configuration du Load Balancer avec WireGuard${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Vérification des privilèges root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
    exit 1
fi

# Mise à jour du système
echo -e "${YELLOW}[1/7] Mise à jour du système...${NC}"
apt update && apt upgrade -y

# Installation des packages nécessaires
echo -e "${YELLOW}[2/7] Installation des packages...${NC}"
apt install -y wireguard wireguard-tools haproxy ufw curl wget net-tools qrencode

# Configuration de WireGuard
echo -e "${YELLOW}[3/7] Configuration de WireGuard...${NC}"

# Créer le répertoire WireGuard
mkdir -p /etc/wireguard
cd /etc/wireguard

# Générer les clés du serveur
if [ ! -f server_private.key ]; then
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    chmod 600 server_private.key
    echo -e "${GREEN}✓ Clés WireGuard générées${NC}"
else
    echo -e "${YELLOW}⚠ Clés WireGuard déjà existantes${NC}"
fi

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)

echo -e "\n${GREEN}Clé publique du serveur (à partager avec les clients):${NC}"
echo -e "${YELLOW}${SERVER_PUBLIC_KEY}${NC}\n"

# Créer la configuration WireGuard
echo -e "${YELLOW}[4/7] Création de la configuration WireGuard...${NC}"

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${VPN_IP}/24
ListenPort = ${WG_PORT}
SaveConfig = false

# Activer le routage IP
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${INTERFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${INTERFACE} -j MASQUERADE

# Les peers seront ajoutés ici
# Utilisez le script add-wireguard-peer.sh pour ajouter des clients
EOF

chmod 600 /etc/wireguard/wg0.conf

# Activer le forwarding IP de manière permanente
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configuration de HAProxy
echo -e "${YELLOW}[5/7] Configuration de HAProxy...${NC}"

# Sauvegarder la configuration originale
if [ -f /etc/haproxy/haproxy.cfg ]; then
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
fi

cat > /etc/haproxy/haproxy.cfg << 'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4000

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

# Stats page
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth admin:ChangeMe123!

# Kubernetes API Server
frontend k8s_api_frontend
    bind *:6443
    mode tcp
    default_backend k8s_api_backend

backend k8s_api_backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect port 6443
    server master01 10.10.0.2:6443 check inter 2000 fall 3 rise 2

# HTTP Frontend
frontend http_frontend
    bind *:80
    mode http
    default_backend http_backend

backend http_backend
    mode http
    balance roundrobin
    option httpchk GET /
    http-check expect status 200-499
    server worker01 10.10.0.3:80 check
    server worker02 10.10.0.4:80 check

# HTTPS Frontend
frontend https_frontend
    bind *:443
    mode tcp
    default_backend https_backend

backend https_backend
    mode tcp
    balance roundrobin
    option tcp-check
    server worker01 10.10.0.3:443 check
    server worker02 10.10.0.4:443 check
EOF

# Tester la configuration HAProxy
haproxy -c -f /etc/haproxy/haproxy.cfg

# Configuration du Firewall
echo -e "${YELLOW}[6/7] Configuration du firewall...${NC}"

# Réinitialiser UFW
ufw --force reset

# Autoriser SSH
ufw allow 22/tcp comment 'SSH'

# Autoriser WireGuard
ufw allow ${WG_PORT}/udp comment 'WireGuard VPN'

# Autoriser HTTP/HTTPS
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Autoriser Kubernetes API
ufw allow 6443/tcp comment 'Kubernetes API'

# Autoriser HAProxy Stats (optionnel, restreindre en production)
ufw allow 8404/tcp comment 'HAProxy Stats'

# Activer le firewall
echo "y" | ufw enable

# Démarrage des services
echo -e "${YELLOW}[7/7] Démarrage des services...${NC}"

# Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Démarrer HAProxy
systemctl enable haproxy
systemctl restart haproxy

# Vérification finale
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Configuration terminée !${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${GREEN}✓ WireGuard installé et démarré${NC}"
echo -e "${GREEN}✓ HAProxy installé et démarré${NC}"
echo -e "${GREEN}✓ Firewall configuré${NC}\n"

# Afficher les informations importantes
echo -e "${YELLOW}Informations importantes:${NC}"
echo -e "═══════════════════════════\n"

echo -e "IP publique: ${GREEN}${PUBLIC_IP}${NC}"
echo -e "IP VPN: ${GREEN}${VPN_IP}${NC}"
echo -e "Port WireGuard: ${GREEN}${WG_PORT}${NC}\n"

echo -e "Clé publique du serveur:"
echo -e "${YELLOW}${SERVER_PUBLIC_KEY}${NC}\n"

echo -e "HAProxy Stats: ${GREEN}http://${PUBLIC_IP}:8404/stats${NC}"
echo -e "Credentials: ${YELLOW}admin/ChangeMe123!${NC}\n"

# Afficher le statut des services
echo -e "${YELLOW}Statut des services:${NC}"
echo -e "═══════════════════════════\n"

systemctl status wg-quick@wg0 --no-pager | head -n 5
echo ""
systemctl status haproxy --no-pager | head -n 5

echo -e "\n${YELLOW}État WireGuard:${NC}"
wg show

# Créer un script helper pour ajouter des peers
cat > /usr/local/bin/add-wireguard-peer.sh << 'EOFSCRIPT'
#!/bin/bash
#
# Script pour ajouter un peer WireGuard
# Usage: sudo add-wireguard-peer.sh <nom> <ip>
# Exemple: sudo add-wireguard-peer.sh master01 10.10.0.2
#

if [ "$EUID" -ne 0 ]; then 
    echo "Ce script doit être exécuté en tant que root"
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <nom> <ip>"
    echo "Exemple: $0 master01 10.10.0.2"
    exit 1
fi

NAME=$1
IP=$2
PUBLIC_KEY=""

echo "Ajout du peer: $NAME ($IP)"
echo ""
echo "Entrez la clé publique du peer:"
read PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo "Erreur: clé publique vide"
    exit 1
fi

# Ajouter le peer à la configuration
cat >> /etc/wireguard/wg0.conf << EOF

# Peer: $NAME
[Peer]
PublicKey = $PUBLIC_KEY
AllowedIPs = $IP/32
PersistentKeepalive = 25
EOF

# Recharger WireGuard
wg syncconf wg0 <(wg-quick strip wg0)

echo ""
echo "✓ Peer ajouté avec succès!"
echo ""
echo "Configuration pour le client $NAME:"
echo "═══════════════════════════════════"
echo "[Interface]"
echo "PrivateKey = <CLÉ_PRIVÉE_DU_CLIENT>"
echo "Address = $IP/24"
echo ""
echo "[Peer]"
echo "PublicKey = $(cat /etc/wireguard/server_public.key)"
echo "Endpoint = $(curl -s ifconfig.me):51820"
echo "AllowedIPs = 10.10.0.0/24"
echo "PersistentKeepalive = 25"
EOFSCRIPT

chmod +x /usr/local/bin/add-wireguard-peer.sh

echo -e "\n${GREEN}Script helper créé: /usr/local/bin/add-wireguard-peer.sh${NC}"
echo -e "Usage: ${YELLOW}sudo add-wireguard-peer.sh <nom> <ip>${NC}\n"

# Créer un fichier avec les informations du serveur
cat > /root/wireguard-server-info.txt << EOF
Configuration du serveur WireGuard Load Balancer
═══════════════════════════════════════════════

Date de création: $(date)

IP publique: ${PUBLIC_IP}
IP VPN: ${VPN_IP}
Port WireGuard: ${WG_PORT}

Clé publique du serveur:
${SERVER_PUBLIC_KEY}

Pour ajouter un nouveau peer:
sudo add-wireguard-peer.sh <nom> <ip>

HAProxy Stats:
http://${PUBLIC_IP}:8404/stats
Credentials: admin/ChangeMe123!

IMPORTANT: Changez le mot de passe HAProxy dans /etc/haproxy/haproxy.cfg
EOF

echo -e "${GREEN}✓ Fichier d'information créé: /root/wireguard-server-info.txt${NC}\n"

echo -e "${YELLOW}Prochaines étapes:${NC}"
echo "1. Configurer les nœuds clients (master, workers)"
echo "2. Ajouter les peers avec: sudo add-wireguard-peer.sh"
echo "3. Changer le mot de passe HAProxy"
echo "4. Tester la connectivité réseau"
echo ""
echo -e "${GREEN}Installation terminée avec succès! 🎉${NC}"
