#!/bin/bash
#
# Générateur de configuration WireGuard pour les clients
# Usage: sudo bash generate-wireguard-client.sh <nom> <ip-client>
# Exemple: sudo bash generate-wireguard-client.sh master01 10.10.0.2
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration du serveur
SERVER_PUBLIC_IP="185.x.x.x"  # À modifier
SERVER_VPN_IP="10.10.0.1"
WG_PORT="51820"
VPN_NETWORK="10.10.0.0/24"

# Vérification des arguments
if [ "$#" -ne 2 ]; then
    echo -e "${RED}Usage: $0 <nom> <ip-client>${NC}"
    echo -e "${YELLOW}Exemple: $0 master01 10.10.0.2${NC}"
    exit 1
fi

CLIENT_NAME=$1
CLIENT_IP=$2

# Vérification root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Ce script doit être exécuté en tant que root${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Génération de configuration WireGuard${NC}"
echo -e "${GREEN}Client: ${CLIENT_NAME} (${CLIENT_IP})${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Créer le répertoire pour les configurations clients
CLIENTS_DIR="/etc/wireguard/clients"
mkdir -p ${CLIENTS_DIR}/${CLIENT_NAME}
cd ${CLIENTS_DIR}/${CLIENT_NAME}

# Générer les clés du client
echo -e "${YELLOW}[1/4] Génération des clés...${NC}"
wg genkey | tee private.key | wg pubkey > public.key
chmod 600 private.key

CLIENT_PRIVATE_KEY=$(cat private.key)
CLIENT_PUBLIC_KEY=$(cat public.key)

echo -e "${GREEN}✓ Clés générées${NC}\n"

# Récupérer la clé publique du serveur
if [ ! -f /etc/wireguard/server_public.key ]; then
    echo -e "${RED}Erreur: Clé publique du serveur non trouvée${NC}"
    echo -e "${YELLOW}Ce script doit être exécuté sur le serveur Load Balancer${NC}"
    exit 1
fi

SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)

# Créer la configuration pour le client
echo -e "${YELLOW}[2/4] Création de la configuration client...${NC}"

cat > ${CLIENT_NAME}.conf << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/24
# DNS = 10.43.0.10  # Décommentez pour utiliser le DNS Kubernetes

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${VPN_NETWORK}
PersistentKeepalive = 25
EOF

chmod 600 ${CLIENT_NAME}.conf

echo -e "${GREEN}✓ Configuration créée${NC}\n"

# Ajouter le peer au serveur
echo -e "${YELLOW}[3/4] Ajout du peer au serveur...${NC}"

# Vérifier si le peer existe déjà
if grep -q "# Peer: ${CLIENT_NAME}" /etc/wireguard/wg0.conf; then
    echo -e "${YELLOW}⚠ Le peer ${CLIENT_NAME} existe déjà dans la configuration${NC}"
    echo -e "${YELLOW}Voulez-vous le remplacer ? (y/n)${NC}"
    read -r REPLACE
    
    if [[ "$REPLACE" =~ ^[Yy]$ ]]; then
        # Supprimer l'ancienne configuration
        sed -i "/# Peer: ${CLIENT_NAME}/,/PersistentKeepalive/d" /etc/wireguard/wg0.conf
        echo -e "${GREEN}✓ Ancienne configuration supprimée${NC}"
    else
        echo -e "${YELLOW}Configuration non modifiée${NC}"
        exit 0
    fi
fi

# Ajouter le nouveau peer
cat >> /etc/wireguard/wg0.conf << EOF

# Peer: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
PersistentKeepalive = 25
EOF

# Recharger la configuration WireGuard sans interruption
wg syncconf wg0 <(wg-quick strip wg0)

echo -e "${GREEN}✓ Peer ajouté et configuration rechargée${NC}\n"

# Générer un QR code (utile pour les appareils mobiles)
echo -e "${YELLOW}[4/4] Génération du QR code...${NC}"

if command -v qrencode &> /dev/null; then
    qrencode -t ansiutf8 < ${CLIENT_NAME}.conf
    qrencode -o ${CLIENT_NAME}-qr.png < ${CLIENT_NAME}.conf
    echo -e "${GREEN}✓ QR code généré: ${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}-qr.png${NC}\n"
else
    echo -e "${YELLOW}⚠ qrencode non installé, QR code non généré${NC}"
    echo -e "${YELLOW}Installez avec: apt install qrencode${NC}\n"
fi

# Créer un fichier d'instructions
cat > INSTRUCTIONS.txt << EOF
Configuration WireGuard pour ${CLIENT_NAME}
═══════════════════════════════════════════

Date de création: $(date)

Client: ${CLIENT_NAME}
IP VPN: ${CLIENT_IP}
Serveur: ${SERVER_PUBLIC_IP}:${WG_PORT}

═══════════════════════════════════════════
INSTALLATION SUR LE CLIENT
═══════════════════════════════════════════

1. Installer WireGuard:
   sudo apt install wireguard wireguard-tools

2. Copier la configuration:
   sudo cp ${CLIENT_NAME}.conf /etc/wireguard/wg0.conf
   sudo chmod 600 /etc/wireguard/wg0.conf

3. Démarrer WireGuard:
   sudo systemctl enable wg-quick@wg0
   sudo systemctl start wg-quick@wg0

4. Vérifier la connexion:
   ping ${SERVER_VPN_IP}
   sudo wg show

═══════════════════════════════════════════
CONFIGURATION MANUELLE
═══════════════════════════════════════════

Si vous préférez créer la configuration manuellement:

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/24

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${VPN_NETWORK}
PersistentKeepalive = 25

═══════════════════════════════════════════
DÉPANNAGE
═══════════════════════════════════════════

Vérifier le statut:
sudo systemctl status wg-quick@wg0
sudo wg show

Logs:
sudo journalctl -u wg-quick@wg0

Redémarrer:
sudo systemctl restart wg-quick@wg0

Test de connectivité:
ping ${SERVER_VPN_IP}
ping 10.10.0.2  # Si master RKE2 configuré

═══════════════════════════════════════════
INFORMATIONS DE SÉCURITÉ
═══════════════════════════════════════════

IMPORTANT: Gardez la clé privée sécurisée!

Clé privée (NE PAS PARTAGER):
${CLIENT_PRIVATE_KEY}

Clé publique (peut être partagée):
${CLIENT_PUBLIC_KEY}

EOF

# Résumé final
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Configuration générée avec succès !${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${YELLOW}Fichiers créés dans: ${CLIENTS_DIR}/${CLIENT_NAME}/${NC}"
ls -lh ${CLIENTS_DIR}/${CLIENT_NAME}/
echo ""

echo -e "${YELLOW}Informations du client:${NC}"
echo -e "═══════════════════════════\n"
echo -e "Nom: ${GREEN}${CLIENT_NAME}${NC}"
echo -e "IP VPN: ${GREEN}${CLIENT_IP}${NC}"
echo -e "Clé publique: ${YELLOW}${CLIENT_PUBLIC_KEY}${NC}\n"

echo -e "${YELLOW}Pour transférer la configuration au client:${NC}"
echo -e "${BLUE}scp ${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf user@client-host:/tmp/${NC}"
echo ""

echo -e "${YELLOW}Sur le client, exécutez:${NC}"
echo -e "${BLUE}sudo mv /tmp/${CLIENT_NAME}.conf /etc/wireguard/wg0.conf${NC}"
echo -e "${BLUE}sudo chmod 600 /etc/wireguard/wg0.conf${NC}"
echo -e "${BLUE}sudo systemctl enable wg-quick@wg0${NC}"
echo -e "${BLUE}sudo systemctl start wg-quick@wg0${NC}\n"

echo -e "${YELLOW}Vérifier la connexion WireGuard:${NC}"
wg show
echo ""

echo -e "${GREEN}✓ Le peer a été ajouté à la configuration du serveur${NC}"
echo -e "${GREEN}✓ Instructions complètes disponibles dans INSTRUCTIONS.txt${NC}\n"

# Sauvegarder un récapitulatif dans un fichier central
echo "${CLIENT_NAME},${CLIENT_IP},${CLIENT_PUBLIC_KEY},$(date)" >> /etc/wireguard/clients-registry.csv

echo -e "${BLUE}Configuration sauvegardée dans le registre: /etc/wireguard/clients-registry.csv${NC}\n"
