#!/bin/bash
#
# Configuration HAProxy pour 2 Masters RKE2 en HA
# Usage: sudo bash configure-haproxy-ha.sh
#

set -e

# Couleurs
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}Configuration HAProxy - 2 Masters HA${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}\n"

# Sauvegarder la configuration actuelle
if [ -f /etc/haproxy/haproxy.cfg ]; then
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)
    echo -e "${GREEN}✓ Sauvegarde créée${NC}\n"
fi

# Créer la nouvelle configuration
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

# ═══════════════════════════════════════════════════════════
# Stats Page
# ═══════════════════════════════════════════════════════════
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth username:Password

# ═══════════════════════════════════════════════════════════
# Kubernetes API Server (2 Masters en HA)
# ═══════════════════════════════════════════════════════════
frontend k8s_api_frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend k8s_api_backend

backend k8s_api_backend
    mode tcp
    balance roundrobin
    option tcp-check
    # Health check sur le port API
    tcp-check connect port 6443

    # Master 01
    server master-1 10.10.0.2:6443 check inter 5000 fall 3 rise 2

    # Master 02
    server master-2 10.10.0.3:6443 check inter 5000 fall 3 rise 2

# ═══════════════════════════════════════════════════════════
# RKE2 Registration (pour que les workers rejoignent le cluster)
# Port 9345 - Load balance entre les masters
# ═══════════════════════════════════════════════════════════
frontend rke2_registration_frontend
    bind *:9345
    mode tcp
    option tcplog
    default_backend rke2_registration_backend

backend rke2_registration_backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect port 9345

    # Master 01
    server master-1 10.10.0.2:9345 check inter 5000 fall 3 rise 2

    # Master 02
    server master-2 10.10.0.3:9345 check inter 5000 fall 3 rise 2

# ═══════════════════════════════════════════════════════════
# HTTP Frontend (Ingress - Workers uniquement)
# ═══════════════════════════════════════════════════════════
frontend http_frontend
    bind *:80
    mode http
    option httplog
    default_backend http_backend

backend http_backend
    mode http
    balance roundrobin
    option httpchk GET /
    http-check expect status 200-499

    # Worker 01
    server worker-1 10.10.0.4:80 check inter 5000 fall 3 rise 2

    # Worker 02
    server worker-2 10.10.0.5:80 check inter 5000 fall 3 rise 2

# ═══════════════════════════════════════════════════════════
# HTTPS Frontend (Ingress - Workers uniquement)
# ═══════════════════════════════════════════════════════════
frontend https_frontend
    bind *:443
    mode tcp
    option tcplog
    default_backend https_backend

backend https_backend
    mode tcp
    balance roundrobin
    option tcp-check

    # Worker 01
    server worker-1 10.10.0.4:443 check inter 5000 fall 3 rise 2

    # Worker 02
    server worker-2 10.10.0.5:443 check inter 5000 fall 3 rise 2
EOF

# Tester la configuration
echo -e "${YELLOW}Test de la configuration...${NC}"
if haproxy -c -f /etc/haproxy/haproxy.cfg; then
    echo -e "${GREEN}✓ Configuration valide${NC}\n"

    # Recharger HAProxy
    echo -e "${YELLOW}Rechargement de HAProxy...${NC}"
    systemctl reload haproxy
    echo -e "${GREEN}✓ HAProxy rechargé${NC}\n"
else
    echo -e "${RED}✗ Erreur de configuration${NC}"
    echo -e "${YELLOW}Restauration de la sauvegarde...${NC}"
    cp /etc/haproxy/haproxy.cfg.backup.* /etc/haproxy/haproxy.cfg
    exit 1
fi

# Afficher l'architecture
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}Architecture Configurée${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}\n"

cat << 'ARCH'
                    Internet (164.68.122.34)
                            │
                    [Load Balancer]
                    HAProxy + WireGuard
                            │
            ┌───────────────┼───────────────┐
            │               │               │
      Port 6443        Port 9345       Port 80/443
            │               │               │
    ┌───────┴────────┐      │       ┌───────┴────────┐
    │                │      │       │                │
  master-1        master-2  │    worker-1        worker-2
10.10.0.2       10.10.0.3   │   10.10.0.4       10.10.0.5
  (HA)            (HA)       │   (Ingress)       (Ingress)
    └────────────────────────┘
    Control Plane HA - etcd distribué
ARCH

echo ""
echo -e "${GREEN}✓ Configuration terminée !${NC}\n"

echo -e "${YELLOW}Nouvelle architecture réseau :${NC}"
echo "  • 10.10.0.1  → Load Balancer (HAProxy)"
echo "  • 10.10.0.2  → master01 (RKE2 Server)"
echo "  • 10.10.0.3  → master02 (RKE2 Server)"
echo "  • 10.10.0.4  → worker01 (RKE2 Agent)"
echo "  • 10.10.0.5  → worker02 (RKE2 Agent)"
echo ""

echo -e "${YELLOW}Ports exposés :${NC}"
echo "  • 6443  → API Kubernetes (load balanced entre master01 et master02)"
echo "  • 9345  → RKE2 Registration (load balanced entre master01 et master02)"
echo "  • 80    → HTTP Ingress (load balanced entre workers)"
echo "  • 443   → HTTPS Ingress (load balanced entre workers)"
echo "  • 8404  → HAProxy Stats"
echo ""

echo -e "${YELLOW}Prochaines étapes :${NC}"
echo "1. Configurer master01 (10.10.0.2) - PREMIER master"
echo "2. Attendre que master01 soit complètement opérationnel"
echo "3. Configurer master02 (10.10.0.3) - SECOND master (rejoindra master01)"
echo "4. Configurer worker01 (10.10.0.4)"
echo "5. Configurer worker02 (10.10.0.5)"
echo ""

echo -e "${BLUE}HAProxy Stats : http://LB_IP:8404/stats${NC}"
echo -e "${BLUE}Credentials : username / Password${NC}"
echo ""
