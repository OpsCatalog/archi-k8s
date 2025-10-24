#!/bin/bash
#
# Installation de Traefik Ingress Controller sur RKE2
# Usage: sudo bash install-traefik.sh
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
TRAEFIK_NAMESPACE="traefik"
TRAEFIK_VERSION="v2.10"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation de Traefik Ingress${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Vérification kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl n'est pas installé ou pas dans le PATH${NC}"
    echo -e "${YELLOW}Configurez l'environnement:${NC}"
    echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin"
    echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
    exit 1
fi

# Vérifier que le cluster est accessible
echo -e "${YELLOW}[1/6] Vérification du cluster...${NC}"
if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}Impossible de se connecter au cluster Kubernetes${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Cluster accessible${NC}"
kubectl get nodes
echo ""

# Créer le namespace
echo -e "${YELLOW}[2/6] Création du namespace ${TRAEFIK_NAMESPACE}...${NC}"
kubectl create namespace ${TRAEFIK_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace créé${NC}\n"

# Installer Helm si nécessaire
echo -e "${YELLOW}[3/6] Vérification de Helm...${NC}"
if ! command -v helm &> /dev/null; then
    echo -e "${BLUE}Installation de Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo -e "${GREEN}✓ Helm installé${NC}\n"
else
    echo -e "${GREEN}✓ Helm déjà installé${NC}\n"
fi

# Ajouter le repo Traefik
echo -e "${YELLOW}[4/6] Configuration du repository Traefik...${NC}"
helm repo add traefik https://traefik.github.io/charts
helm repo update
echo -e "${GREEN}✓ Repository ajouté${NC}\n"

# Créer les valeurs personnalisées pour Traefik
echo -e "${YELLOW}[5/6] Configuration de Traefik...${NC}"

cat > /tmp/traefik-values.yaml << 'EOF'
# Deployment configuration
deployment:
  enabled: true
  kind: DaemonSet
  replicas: 1

# Service configuration
service:
  enabled: true
  type: NodePort
  annotations: {}
  labels: {}
  spec:
    externalTrafficPolicy: Local
  loadBalancerSourceRanges: []

# Ports configuration
ports:
  web:
    port: 80
    expose: true
    exposedPort: 80
    protocol: TCP
    nodePort: 30080
    hostPort: 80
  websecure:
    port: 443
    expose: true
    exposedPort: 443
    protocol: TCP
    nodePort: 30443
    hostPort: 443
    tls:
      enabled: true
  traefik:
    port: 9000
    expose: false
    exposedPort: 9000
    protocol: TCP

# Logs
logs:
  general:
    level: INFO
  access:
    enabled: true

# Dashboard
ingressRoute:
  dashboard:
    enabled: true
    annotations: {}
    labels: {}

# Providers
providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true
    allowExternalNameServices: true
  kubernetesIngress:
    enabled: true
    allowExternalNameServices: true
    publishedService:
      enabled: true

# Node selector - déployer sur les workers
nodeSelector:
  node-role.kubernetes.io/worker: "true"

# Tolerations
tolerations: []

# Additional arguments
additionalArguments:
  - "--api.insecure=true"
  - "--providers.kubernetesingress.ingressclass=traefik"
  - "--serversTransport.insecureSkipVerify=true"

# Resource limits
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "1000m"
    memory: "512Mi"

# Health checks
readinessProbe:
  failureThreshold: 1
  initialDelaySeconds: 2
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 2
livenessProbe:
  failureThreshold: 3
  initialDelaySeconds: 2
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 2
EOF

echo -e "${GREEN}✓ Configuration créée${NC}\n"

# Installer Traefik
echo -e "${YELLOW}[6/6] Installation de Traefik...${NC}"
helm upgrade --install traefik traefik/traefik \
  --namespace ${TRAEFIK_NAMESPACE} \
  --values /tmp/traefik-values.yaml \
  --wait \
  --timeout 5m

echo -e "${GREEN}✓ Traefik installé${NC}\n"

# Attendre que Traefik soit prêt
echo -e "${BLUE}Attente du démarrage de Traefik...${NC}"
kubectl wait --for=condition=available --timeout=300s \
  deployment/traefik -n ${TRAEFIK_NAMESPACE} 2>/dev/null || \
kubectl wait --for=condition=ready --timeout=300s \
  pod -l app.kubernetes.io/name=traefik -n ${TRAEFIK_NAMESPACE}

# Créer un IngressClass par défaut
echo -e "\n${YELLOW}Création de l'IngressClass...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: traefik.io/ingress-controller
EOF

echo -e "${GREEN}✓ IngressClass créé${NC}\n"

# Créer un Middleware pour les redirections HTTPS (optionnel)
echo -e "${YELLOW}Création du Middleware HTTPS redirect...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: ${TRAEFIK_NAMESPACE}
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF

echo -e "${GREEN}✓ Middleware créé${NC}\n"

# Afficher les informations
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation terminée !${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${YELLOW}Statut de Traefik:${NC}"
kubectl get pods -n ${TRAEFIK_NAMESPACE}
echo ""

echo -e "${YELLOW}Services:${NC}"
kubectl get svc -n ${TRAEFIK_NAMESPACE}
echo ""

# Obtenir les NodePorts
HTTP_NODEPORT=$(kubectl get svc traefik -n ${TRAEFIK_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}')
HTTPS_NODEPORT=$(kubectl get svc traefik -n ${TRAEFIK_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="websecure")].nodePort}')

echo -e "${YELLOW}NodePorts configurés:${NC}"
echo -e "HTTP: ${GREEN}${HTTP_NODEPORT}${NC}"
echo -e "HTTPS: ${GREEN}${HTTPS_NODEPORT}${NC}\n"

# Créer une application de test
echo -e "${YELLOW}Création d'une application de test...${NC}"

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: test-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: test-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
      - name: whoami
        image: traefik/whoami
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: test-app
spec:
  selector:
    app: whoami
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: test-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: whoami.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              number: 80
EOF

echo -e "${GREEN}✓ Application de test créée${NC}\n"

# Attendre le déploiement
sleep 10
kubectl wait --for=condition=available --timeout=60s deployment/whoami -n test-app

echo -e "${YELLOW}Vérification de l'application de test:${NC}"
kubectl get pods -n test-app
echo ""

# Instructions de test
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Instructions de test${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Récupérer l'IP d'un worker
WORKER_IP=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo -e "${YELLOW}1. Tester l'application whoami depuis le Load Balancer:${NC}"
echo -e "${BLUE}curl -H \"Host: whoami.local\" http://\${LOAD_BALANCER_IP}${NC}\n"

echo -e "${YELLOW}2. Tester depuis un worker directement:${NC}"
echo -e "${BLUE}curl -H \"Host: whoami.local\" http://${WORKER_IP}${NC}\n"

echo -e "${YELLOW}3. Accéder au Dashboard Traefik (sur le Load Balancer):${NC}"
echo -e "${BLUE}kubectl port-forward -n ${TRAEFIK_NAMESPACE} \$(kubectl get pods -n ${TRAEFIK_NAMESPACE} -l app.kubernetes.io/name=traefik -o name) 9000:9000${NC}"
echo -e "Puis ouvrir: ${GREEN}http://localhost:9000/dashboard/${NC}\n"

echo -e "${YELLOW}4. Pour exposer le dashboard via un Ingress:${NC}"
cat <<'DASHEOF'
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: traefik-dashboard
  namespace: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: traefik.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api@internal
            port:
              number: 9000
EOF
DASHEOF

echo -e "\n${YELLOW}Commandes utiles:${NC}"
echo -e "═══════════════════\n"
echo -e "Voir les logs Traefik:"
echo -e "${BLUE}kubectl logs -f -n ${TRAEFIK_NAMESPACE} -l app.kubernetes.io/name=traefik${NC}\n"

echo -e "Lister les Ingress:"
echo -e "${BLUE}kubectl get ingress -A${NC}\n"

echo -e "Voir les routes Traefik:"
echo -e "${BLUE}kubectl get ingressroute -A${NC}\n"

echo -e "Redémarrer Traefik:"
echo -e "${BLUE}kubectl rollout restart deployment traefik -n ${TRAEFIK_NAMESPACE}${NC}\n"

# Sauvegarder les informations
cat > /root/traefik-installation-info.txt << EOF
Installation Traefik
════════════════════

Date: $(date)
Namespace: ${TRAEFIK_NAMESPACE}
Version: Installée via Helm

NodePorts:
- HTTP: ${HTTP_NODEPORT}
- HTTPS: ${HTTPS_NODEPORT}

Worker IP: ${WORKER_IP}

Application de test:
- Namespace: test-app
- Service: whoami
- Ingress host: whoami.local

Test:
curl -H "Host: whoami.local" http://\${WORKER_IP}

Dashboard:
kubectl port-forward -n ${TRAEFIK_NAMESPACE} \$(kubectl get pods -n ${TRAEFIK_NAMESPACE} -l app.kubernetes.io/name=traefik -o name) 9000:9000

Configuration:
/tmp/traefik-values.yaml

Commandes utiles:
- helm list -n ${TRAEFIK_NAMESPACE}
- kubectl get all -n ${TRAEFIK_NAMESPACE}
- kubectl logs -f -n ${TRAEFIK_NAMESPACE} -l app.kubernetes.io/name=traefik
EOF

echo -e "${GREEN}✓ Informations sauvegardées dans /root/traefik-installation-info.txt${NC}\n"

echo -e "${GREEN}Installation de Traefik terminée avec succès ! 🎉${NC}\n"
