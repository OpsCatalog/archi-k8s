#!/bin/bash
#
# Script de vérification complète de l'infrastructure RKE2 + WireGuard
# Usage: sudo bash verify-infrastructure.sh
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Compteurs
PASSED=0
FAILED=0
WARNINGS=0

# Fonction pour afficher les résultats
print_result() {
    local status=$1
    local message=$2
    
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}✓${NC} $message"
        ((PASSED++))
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}✗${NC} $message"
        ((FAILED++))
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
        ((WARNINGS++))
    else
        echo -e "${BLUE}ℹ${NC} $message"
    fi
}

# Fonction pour exécuter une commande et vérifier le résultat
check_command() {
    local description=$1
    local command=$2
    local expected_output=$3
    
    if eval "$command" &> /dev/null; then
        if [ -z "$expected_output" ] || eval "$command" | grep -q "$expected_output"; then
            print_result "OK" "$description"
            return 0
        else
            print_result "FAIL" "$description - sortie inattendue"
            return 1
        fi
    else
        print_result "FAIL" "$description"
        return 1
    fi
}

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       Vérification de l'Infrastructure RKE2 + WireGuard       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

# Déterminer le type de nœud
NODE_TYPE="unknown"
if systemctl is-active --quiet rke2-server; then
    NODE_TYPE="master"
elif systemctl is-active --quiet rke2-agent; then
    NODE_TYPE="worker"
fi

echo -e "${YELLOW}Type de nœud détecté: ${GREEN}${NODE_TYPE}${NC}\n"

# ============================================
# Section 1: Configuration Système
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}[1] Configuration Système${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# Vérifier le swap
if [ "$(swapon --show | wc -l)" -eq 0 ]; then
    print_result "OK" "Swap désactivé"
else
    print_result "FAIL" "Swap est actif (doit être désactivé pour Kubernetes)"
fi

# Vérifier le forwarding IP
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
    print_result "OK" "IP forwarding activé"
else
    print_result "FAIL" "IP forwarding désactivé"
fi

# Vérifier les modules kernel
for module in overlay br_netfilter; do
    if lsmod | grep -q "^${module}"; then
        print_result "OK" "Module $module chargé"
    else
        print_result "FAIL" "Module $module non chargé"
    fi
done

# Vérifier les paramètres sysctl
check_command "net.bridge.bridge-nf-call-iptables" "sysctl -n net.bridge.bridge-nf-call-iptables" "1"
check_command "net.bridge.bridge-nf-call-ip6tables" "sysctl -n net.bridge.bridge-nf-call-ip6tables" "1"

echo ""

# ============================================
# Section 2: WireGuard
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}[2] WireGuard VPN${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# Vérifier le service WireGuard
if systemctl is-active --quiet wg-quick@wg0; then
    print_result "OK" "Service WireGuard actif"
else
    print_result "FAIL" "Service WireGuard inactif"
fi

# Vérifier l'interface wg0
if ip link show wg0 &> /dev/null; then
    print_result "OK" "Interface wg0 présente"
    
    # Afficher l'IP de l'interface
    WG_IP=$(ip -4 addr show wg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo -e "   ${BLUE}→${NC} IP WireGuard: ${GREEN}${WG_IP}${NC}"
else
    print_result "FAIL" "Interface wg0 absente"
fi

# Vérifier les peers WireGuard
if command -v wg &> /dev/null; then
    PEER_COUNT=$(wg show wg0 peers 2>/dev/null | wc -l)
    if [ "$PEER_COUNT" -gt 0 ]; then
        print_result "OK" "Peers WireGuard: $PEER_COUNT"
    else
        print_result "WARN" "Aucun peer WireGuard configuré"
    fi
fi

# Test de connectivité VPN
echo -e "\n${YELLOW}Tests de connectivité VPN:${NC}"
for ip in 10.10.0.1 10.10.0.2 10.10.0.3 10.10.0.4; do
    if [ "$WG_IP" != "$ip" ]; then
        if ping -c 1 -W 2 $ip &> /dev/null; then
            print_result "OK" "Connectivité vers $ip"
        else
            print_result "WARN" "Pas de réponse de $ip"
        fi
    fi
done

echo ""

# ============================================
# Section 3: RKE2
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}[3] RKE2 Kubernetes${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# Vérifier le service RKE2
if [ "$NODE_TYPE" = "master" ]; then
    if systemctl is-active --quiet rke2-server; then
        print_result "OK" "Service RKE2 Server actif"
    else
        print_result "FAIL" "Service RKE2 Server inactif"
    fi
elif [ "$NODE_TYPE" = "worker" ]; then
    if systemctl is-active --quiet rke2-agent; then
        print_result "OK" "Service RKE2 Agent actif"
    else
        print_result "FAIL" "Service RKE2 Agent inactif"
    fi
fi

# Vérifier kubectl (uniquement sur le master)
if [ "$NODE_TYPE" = "master" ]; then
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    
    if command -v kubectl &> /dev/null; then
        print_result "OK" "kubectl disponible"
        
        # Vérifier la connexion au cluster
        if kubectl get nodes &> /dev/null; then
            print_result "OK" "Connexion au cluster Kubernetes"
            
            # Afficher l'état des nœuds
            echo -e "\n${YELLOW}État des nœuds:${NC}"
            kubectl get nodes -o wide | while IFS= read -r line; do
                if echo "$line" | grep -q "Ready"; then
                    echo -e "${GREEN}$line${NC}"
                elif echo "$line" | grep -q "NotReady"; then
                    echo -e "${RED}$line${NC}"
                else
                    echo -e "${BLUE}$line${NC}"
                fi
            done
            
            # Compter les nœuds
            TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
            READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready ")
            print_result "INFO" "Nœuds: $READY_NODES/$TOTAL_NODES prêts"
            
            # Vérifier les pods système
            echo -e "\n${YELLOW}Pods système:${NC}"
            CRITICAL_PODS=("kube-apiserver" "etcd" "kube-controller-manager" "kube-scheduler")
            
            for pod in "${CRITICAL_PODS[@]}"; do
                POD_STATUS=$(kubectl get pods -n kube-system -l component=$pod --no-headers 2>/dev/null | awk '{print $3}' | head -1)
                if [ "$POD_STATUS" = "Running" ]; then
                    print_result "OK" "$pod: Running"
                else
                    print_result "FAIL" "$pod: $POD_STATUS"
                fi
            done
            
            # Vérifier Calico
            CALICO_PODS=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
            CALICO_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c "Running")
            print_result "INFO" "Calico: $CALICO_RUNNING/$CALICO_PODS pods actifs"
            
        else
            print_result "FAIL" "Impossible de se connecter au cluster"
        fi
    else
        print_result "WARN" "kubectl non trouvé dans le PATH"
    fi
fi

echo ""

# ============================================
# Section 4: Load Balancer (si sur le LB)
# ============================================
if [ -f /etc/haproxy/haproxy.cfg ]; then
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}[4] Load Balancer (HAProxy)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
    
    # Vérifier HAProxy
    if systemctl is-active --quiet haproxy; then
        print_result "OK" "Service HAProxy actif"
        
        # Vérifier les ports
        for port in 80 443 6443 8404; do
            if netstat -tln | grep -q ":$port "; then
                print_result "OK" "Port $port en écoute"
            else
                print_result "FAIL" "Port $port non actif"
            fi
        done
        
        # Tester la configuration
        if haproxy -c -f /etc/haproxy/haproxy.cfg &> /dev/null; then
            print_result "OK" "Configuration HAProxy valide"
        else
            print_result "FAIL" "Configuration HAProxy invalide"
        fi
    else
        print_result "FAIL" "Service HAProxy inactif"
    fi
    
    echo ""
fi

# ============================================
# Section 5: Traefik (si sur le master)
# ============================================
if [ "$NODE_TYPE" = "master" ] && command -v kubectl &> /dev/null; then
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}[5] Traefik Ingress Controller${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
    
    if kubectl get namespace traefik &> /dev/null; then
        print_result "OK" "Namespace Traefik existe"
        
        # Vérifier le déploiement Traefik
        TRAEFIK_PODS=$(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l)
        TRAEFIK_RUNNING=$(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | grep -c "Running")
        
        if [ "$TRAEFIK_RUNNING" -eq "$TRAEFIK_PODS" ] && [ "$TRAEFIK_PODS" -gt 0 ]; then
            print_result "OK" "Traefik: $TRAEFIK_RUNNING/$TRAEFIK_PODS pods actifs"
        else
            print_result "FAIL" "Traefik: $TRAEFIK_RUNNING/$TRAEFIK_PODS pods actifs"
        fi
        
        # Vérifier l'IngressClass
        if kubectl get ingressclass traefik &> /dev/null; then
            print_result "OK" "IngressClass Traefik configurée"
        else
            print_result "WARN" "IngressClass Traefik absente"
        fi
        
    else
        print_result "WARN" "Traefik non installé"
    fi
    
    echo ""
fi

# ============================================
# Section 6: Firewall
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}[6] Firewall (UFW)${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

if command -v ufw &> /dev/null; then
    UFW_STATUS=$(ufw status | grep -c "Status: active")
    if [ "$UFW_STATUS" -eq 1 ]; then
        print_result "OK" "UFW actif"
        
        # Vérifier les règles importantes
        if ufw status | grep -q "51820/udp"; then
            print_result "OK" "Port WireGuard (51820/udp) autorisé"
        else
            print_result "WARN" "Port WireGuard non autorisé dans UFW"
        fi
        
        if ufw status | grep -q "22/tcp"; then
            print_result "OK" "Port SSH (22/tcp) autorisé"
        else
            print_result "WARN" "Port SSH non autorisé dans UFW"
        fi
    else
        print_result "WARN" "UFW inactif"
    fi
else
    print_result "INFO" "UFW non installé"
fi

echo ""

# ============================================
# Section 7: Stockage et Ressources
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}[7] Ressources Système${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# Vérifier l'espace disque
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -lt 80 ]; then
    print_result "OK" "Utilisation disque: ${DISK_USAGE}%"
else
    print_result "WARN" "Utilisation disque élevée: ${DISK_USAGE}%"
fi

# Vérifier la mémoire
MEMORY_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
if [ "$MEMORY_USAGE" -lt 90 ]; then
    print_result "OK" "Utilisation mémoire: ${MEMORY_USAGE}%"
else
    print_result "WARN" "Utilisation mémoire élevée: ${MEMORY_USAGE}%"
fi

# Vérifier le load average
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
CPU_COUNT=$(nproc)
LOAD_PERCENT=$(echo "scale=0; ($LOAD_AVG * 100) / $CPU_COUNT" | bc)
if [ "$LOAD_PERCENT" -lt 70 ]; then
    print_result "OK" "Load average: $LOAD_AVG (${LOAD_PERCENT}% des CPU)"
else
    print_result "WARN" "Load average élevé: $LOAD_AVG (${LOAD_PERCENT}% des CPU)"
fi

echo ""

# ============================================
# Résumé
# ============================================
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}Résumé${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

TOTAL=$((PASSED + FAILED + WARNINGS))

echo -e "${GREEN}✓ Réussis:      $PASSED${NC}"
echo -e "${RED}✗ Échecs:       $FAILED${NC}"
echo -e "${YELLOW}⚠ Avertissements: $WARNINGS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Total vérifié:  $TOTAL${NC}\n"

# Score global
if [ "$FAILED" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ Infrastructure en parfait état !   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    exit 0
elif [ "$FAILED" -eq 0 ]; then
    echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠ Infrastructure OK avec warnings    ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}\n"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ Problèmes détectés !               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
    exit 1
fi
