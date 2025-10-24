# Guide Complet : Déploiement RKE2 avec WireGuard et Load Balancer

## 📋 Architecture Cible

```
Internet (185.x.x.x)
        ↓
[VPS Load Balancer]
  WireGuard + HAProxy
        ↓
   10.10.0.0/24
        ↓
├─ 10.10.0.2 → master01 (RKE2 Server)
├─ 10.10.0.3 → worker01 (RKE2 Agent)
├─ 10.10.0.4 → worker02 (RKE2 Agent)
└─ 10.10.0.10 → infra-node (GitLab, MinIO, etc.)
```

---

## 🚀 Étape 1 : Configuration du VPS Load Balancer

### 1.1 Installation des prérequis

```bash
# Mise à jour du système
apt update && apt upgrade -y

# Installation des outils nécessaires
apt install -y wireguard wireguard-tools haproxy ufw curl wget net-tools
```

### 1.2 Configuration de WireGuard sur le Load Balancer

#### Générer les clés WireGuard

```bash
# Générer la clé privée du serveur
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key

# Sécuriser les permissions
chmod 600 /etc/wireguard/server_private.key
```

#### Créer la configuration WireGuard `/etc/wireguard/wg0.conf`

```ini
[Interface]
PrivateKey = <CONTENU_DE_server_private.key>
Address = 10.10.0.1/24
ListenPort = 51820
SaveConfig = false

# Activer le routage IP
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Peer: master01
[Peer]
PublicKey = <PUBLIC_KEY_MASTER01>
AllowedIPs = 10.10.0.2/32
PersistentKeepalive = 25

# Peer: worker01
[Peer]
PublicKey = <PUBLIC_KEY_WORKER01>
AllowedIPs = 10.10.0.3/32
PersistentKeepalive = 25

# Peer: worker02
[Peer]
PublicKey = <PUBLIC_KEY_WORKER02>
AllowedIPs = 10.10.0.4/32
PersistentKeepalive = 25

# Peer: infra-node
[Peer]
PublicKey = <PUBLIC_KEY_INFRA>
AllowedIPs = 10.10.0.10/32
PersistentKeepalive = 25
```

#### Activer le forwarding IP de manière permanente

```bash
# Éditer /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

#### Démarrer WireGuard

```bash
# Activer et démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Vérifier le statut
wg show
```

### 1.3 Configuration du Firewall (UFW)

```bash
# Autoriser SSH
ufw allow 22/tcp

# Autoriser WireGuard
ufw allow 51820/udp

# Autoriser HAProxy (HTTP/HTTPS)
ufw allow 80/tcp
ufw allow 443/tcp

# Autoriser Kubernetes API (6443)
ufw allow 6443/tcp

# Activer le firewall
ufw --force enable
```

### 1.4 Configuration de HAProxy

#### Créer `/etc/haproxy/haproxy.cfg`

```haproxy
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
    stats auth admin:VotreMotDePasse123

# Kubernetes API Server (RKE2)
frontend k8s_api_frontend
    bind *:6443
    mode tcp
    default_backend k8s_api_backend

backend k8s_api_backend
    mode tcp
    balance roundrobin
    option tcp-check
    # Vérification de santé du serveur Kubernetes
    tcp-check connect port 6443
    server master01 10.10.0.2:6443 check inter 2000 fall 3 rise 2

# HTTP Frontend (pour Ingress)
frontend http_frontend
    bind *:80
    mode http
    default_backend http_backend

backend http_backend
    mode http
    balance roundrobin
    option httpchk GET /healthz
    server worker01 10.10.0.3:80 check
    server worker02 10.10.0.4:80 check

# HTTPS Frontend (pour Ingress)
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
```

#### Démarrer HAProxy

```bash
# Tester la configuration
haproxy -c -f /etc/haproxy/haproxy.cfg

# Redémarrer HAProxy
systemctl restart haproxy
systemctl enable haproxy
systemctl status haproxy
```

---

## 🖥️ Étape 2 : Configuration des Nœuds RKE2

### 2.1 Préparation de tous les nœuds (master et workers)

**Exécuter sur TOUS les nœuds (master01, worker01, worker02) :**

```bash
# Mise à jour du système
apt update && apt upgrade -y

# Installation des prérequis
apt install -y curl wget wireguard wireguard-tools

# Désactiver le swap (requis pour Kubernetes)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Charger les modules kernel nécessaires
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configuration sysctl pour Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
```

### 2.2 Configuration WireGuard sur master01 (10.10.0.2)

#### Générer les clés

```bash
# Sur master01
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

# Afficher la clé publique (à ajouter sur le serveur)
cat /etc/wireguard/public.key
```

#### Créer `/etc/wireguard/wg0.conf`

```ini
[Interface]
PrivateKey = <CONTENU_DE_private.key>
Address = 10.10.0.2/24

[Peer]
PublicKey = <PUBLIC_KEY_DU_SERVEUR_LB>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

#### Démarrer WireGuard

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Tester la connectivité
ping 10.10.0.1
```

### 2.3 Configuration WireGuard sur worker01 (10.10.0.3)

```bash
# Générer les clés
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

**Créer `/etc/wireguard/wg0.conf` :**

```ini
[Interface]
PrivateKey = <CONTENU_DE_private.key>
Address = 10.10.0.3/24

[Peer]
PublicKey = <PUBLIC_KEY_DU_SERVEUR_LB>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
ping 10.10.0.1
```

### 2.4 Configuration WireGuard sur worker02 (10.10.0.4)

```bash
# Générer les clés
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

**Créer `/etc/wireguard/wg0.conf` :**

```ini
[Interface]
PrivateKey = <CONTENU_DE_private.key>
Address = 10.10.0.4/24

[Peer]
PublicKey = <PUBLIC_KEY_DU_SERVEUR_LB>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
ping 10.10.0.1
```

---

## 🎯 Étape 3 : Installation de RKE2

### 3.1 Installation du Master Node (master01)

```bash
# Sur master01 (10.10.0.2)

# Télécharger et installer RKE2
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -

# Créer le répertoire de configuration
mkdir -p /etc/rancher/rke2

# Créer le fichier de configuration
cat <<EOF > /etc/rancher/rke2/config.yaml
# Adresse IP du nœud
node-ip: 10.10.0.2
advertise-address: 10.10.0.2

# Configuration du load balancer
tls-san:
  - 185.x.x.x
  - 10.10.0.1
  - 10.10.0.2
  - master01

# Désactiver les composants non nécessaires
disable:
  - rke2-ingress-nginx
  
# Configuration CNI
cni:
  - calico

# Token pour rejoindre le cluster (générez un token fort)
token: "VotreTokenSecurise123456789"

# Configuration du cluster
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16

# Activer les logs
write-kubeconfig-mode: "0644"
EOF

# Activer et démarrer RKE2 server
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Vérifier les logs
journalctl -u rke2-server -f
```

#### Vérifier l'installation

```bash
# Attendre que RKE2 démarre complètement (2-3 minutes)
sleep 120

# Configurer kubectl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Ajouter au .bashrc
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc

# Vérifier le cluster
kubectl get nodes
kubectl get pods -A
```

### 3.2 Installation des Worker Nodes (worker01 & worker02)

**Sur worker01 (10.10.0.3) :**

```bash
# Télécharger et installer RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -

# Créer le répertoire de configuration
mkdir -p /etc/rancher/rke2

# Créer le fichier de configuration
cat <<EOF > /etc/rancher/rke2/config.yaml
# Adresse du serveur RKE2 (via le réseau privé)
server: https://10.10.0.2:9345

# Token (le même que sur le master)
token: "VotreTokenSecurise123456789"

# Adresse IP du nœud
node-ip: 10.10.0.3

# Labels pour ce worker
node-label:
  - "node-role.kubernetes.io/worker=true"
  - "workload=application"
EOF

# Activer et démarrer RKE2 agent
systemctl enable rke2-agent.service
systemctl start rke2-agent.service

# Vérifier les logs
journalctl -u rke2-agent -f
```

**Sur worker02 (10.10.0.4) :**

```bash
# Télécharger et installer RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -

mkdir -p /etc/rancher/rke2

cat <<EOF > /etc/rancher/rke2/config.yaml
server: https://10.10.0.2:9345
token: "VotreTokenSecurise123456789"
node-ip: 10.10.0.4

node-label:
  - "node-role.kubernetes.io/worker=true"
  - "workload=application"
EOF

systemctl enable rke2-agent.service
systemctl start rke2-agent.service
journalctl -u rke2-agent -f
```

### 3.3 Vérification du Cluster

**Sur le master01 :**

```bash
# Vérifier que tous les nœuds sont prêts
kubectl get nodes -o wide

# Devrait afficher quelque chose comme :
# NAME       STATUS   ROLES                       AGE   VERSION
# master01   Ready    control-plane,etcd,master   5m    v1.28.x+rke2r1
# worker01   Ready    worker                      3m    v1.28.x+rke2r1
# worker02   Ready    worker                      3m    v1.28.x+rke2r1

# Vérifier les pods système
kubectl get pods -A

# Vérifier la version du cluster
kubectl version
```

---

## 🌐 Étape 4 : Configuration de l'Ingress Controller

### 4.1 Installation de Traefik (recommandé pour RKE2)

**Sur le master01 :**

```bash
# Créer le namespace
kubectl create namespace traefik

# Installer Traefik via Helm
cat <<EOF > traefik-values.yaml
deployment:
  kind: DaemonSet

service:
  type: NodePort
  
ports:
  web:
    port: 80
    nodePort: 30080
    hostPort: 80
  websecure:
    port: 443
    nodePort: 30443
    hostPort: 443

ingressRoute:
  dashboard:
    enabled: true

additionalArguments:
  - "--api.insecure=true"
  - "--providers.kubernetesingress.ingressclass=traefik"
  - "--log.level=INFO"

nodeSelector:
  node-role.kubernetes.io/worker: "true"
EOF

# Installer Traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik -n traefik -f traefik-values.yaml
```

### 4.2 Vérifier Traefik

```bash
# Vérifier que Traefik est en cours d'exécution
kubectl get pods -n traefik
kubectl get svc -n traefik

# Tester l'accès via le load balancer
curl http://185.x.x.x
```

---

## 🔒 Étape 5 : Sécurisation et Optimisations

### 5.1 Configuration des Politiques Réseau

**Créer un NetworkPolicy de base :**

```yaml
# network-policy-default.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-traefik
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: traefik
```

```bash
kubectl apply -f network-policy-default.yaml
```

### 5.2 Configuration du Monitoring (optionnel)

```bash
# Installer kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set grafana.adminPassword=VotreMotDePasse
```

---

## 📦 Étape 6 : Déploiement d'une Application Test

### 6.1 Déployer une application exemple

```yaml
# app-test.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: default
spec:
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-test
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: test.votredomaine.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-test
            port:
              number: 80
```

```bash
kubectl apply -f app-test.yaml

# Vérifier le déploiement
kubectl get pods
kubectl get ingress

# Tester l'accès
curl -H "Host: test.votredomaine.com" http://185.x.x.x
```

---

## 🔧 Étape 7 : Configuration du Nœud Infrastructure (10.10.0.10)

### 7.1 Configuration WireGuard

```bash
# Sur infra-node
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = <CONTENU_DE_private.key>
Address = 10.10.0.10/24

[Peer]
PublicKey = <PUBLIC_KEY_DU_SERVEUR_LB>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

### 7.2 Installation de Docker (pour GitLab, MinIO, etc.)

```bash
# Installer Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Installer Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

### 7.3 Exemple de docker-compose pour MinIO

```yaml
# /opt/infra/docker-compose.yml
version: '3.8'

services:
  minio:
    image: minio/minio:latest
    container_name: minio
    restart: always
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: VotreMotDePasseSecurise
    volumes:
      - ./minio-data:/data
    command: server /data --console-address ":9001"
    networks:
      - infra-network

networks:
  infra-network:
    driver: bridge
```

```bash
cd /opt/infra
docker-compose up -d
```

---

## 📝 Commandes Utiles pour la Maintenance

### Vérification du statut WireGuard

```bash
# Sur n'importe quel nœud
wg show
sudo wg show wg0

# Tester la connectivité
ping 10.10.0.1  # Load Balancer
ping 10.10.0.2  # Master
```

### Gestion du cluster RKE2

```bash
# Sur le master
kubectl get nodes
kubectl get pods -A
kubectl top nodes
kubectl top pods -A

# Drainer un nœud pour maintenance
kubectl drain worker01 --ignore-daemonsets --delete-emptydir-data

# Remettre le nœud en service
kubectl uncordon worker01
```

### Logs RKE2

```bash
# Sur le master
journalctl -u rke2-server -f

# Sur les workers
journalctl -u rke2-agent -f
```

### Sauvegarde du cluster

```bash
# Sur le master - Sauvegarde etcd
rke2 etcd-snapshot save --name backup-$(date +%Y%m%d-%H%M%S)

# Lister les sauvegardes
rke2 etcd-snapshot list

# Restaurer une sauvegarde
rke2 etcd-snapshot restore --name backup-20250101-120000
```

---

## 🚨 Dépannage

### Problème : Les workers ne rejoignent pas le cluster

```bash
# Sur les workers, vérifier :
1. Connectivité réseau vers le master
ping 10.10.0.2

2. Vérifier que le port 9345 est accessible
nc -zv 10.10.0.2 9345

3. Vérifier le token dans /etc/rancher/rke2/config.yaml

4. Consulter les logs
journalctl -u rke2-agent -f
```

### Problème : HAProxy ne redirige pas le trafic

```bash
# Sur le load balancer
# Vérifier qu'HAProxy écoute
netstat -tlnp | grep haproxy

# Tester la connectivité vers les backends
curl -v http://10.10.0.3:80
curl -v https://10.10.0.2:6443 --insecure

# Redémarrer HAProxy
systemctl restart haproxy
```

### Problème : WireGuard ne se connecte pas

```bash
# Vérifier la configuration
wg show

# Vérifier que le port UDP est ouvert
nc -u -v 185.x.x.x 51820

# Redémarrer WireGuard
systemctl restart wg-quick@wg0

# Vérifier les logs
journalctl -u wg-quick@wg0
```

---

## 📚 Checklist de Déploiement

- [ ] VPS Load Balancer configuré avec WireGuard
- [ ] HAProxy configuré et fonctionnel
- [ ] Firewall configuré sur le Load Balancer
- [ ] WireGuard configuré sur tous les nœuds
- [ ] Connectivité réseau vérifiée (ping entre tous les nœuds)
- [ ] RKE2 server installé sur master01
- [ ] RKE2 agent installé sur worker01 et worker02
- [ ] Tous les nœuds affichent "Ready" dans kubectl get nodes
- [ ] Ingress controller (Traefik) déployé et fonctionnel
- [ ] Application de test déployée et accessible
- [ ] Nœud infrastructure configuré
- [ ] Monitoring installé (optionnel)
- [ ] Sauvegardes etcd configurées

---

## 🎉 Conclusion

Votre cluster RKE2 est maintenant déployé avec :

- ✅ Réseau privé sécurisé via WireGuard
- ✅ Load balancing avec HAProxy
- ✅ Haute disponibilité possible (ajoutez d'autres masters)
- ✅ Isolation réseau entre Internet et les nœuds
- ✅ Prêt pour des déploiements en production

### Prochaines étapes recommandées :

1. **Configurer les certificats SSL** avec Let's Encrypt
2. **Mettre en place des sauvegardes automatiques** de etcd
3. **Configurer le monitoring** avec Prometheus/Grafana
4. **Implémenter des politiques de sécurité** (Pod Security Standards)
5. **Documenter votre infrastructure** avec des runbooks

---

## 📞 Support

Pour toute question ou problème :
- Documentation RKE2 : https://docs.rke2.io/
- Documentation WireGuard : https://www.wireguard.com/
- Documentation HAProxy : https://www.haproxy.org/

Bon déploiement ! 🚀
