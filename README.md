# 🚀 Déploiement RKE2 avec WireGuard - Scripts d'Automatisation

Ce repository contient tous les scripts nécessaires pour déployer automatiquement un cluster RKE2 sécurisé avec WireGuard.

## 📁 Fichiers Disponibles

```
.
├── README.md                           # Ce fichier
├── guide-rke2-wireguard-deployment.md  # Guide complet détaillé
├── setup-loadbalancer.sh               # Configuration du Load Balancer
├── setup-rke2-node.sh                  # Installation RKE2 (master/worker)
├── generate-wireguard-client.sh        # Génération config WireGuard
├── install-traefik.sh                  # Installation Traefik Ingress
└── verify-infrastructure.sh            # Vérification de l'installation
```

## 📋 Prérequis

- **OS**: Ubuntu 20.04/22.04/24.04 ou Debian 11/12
- **Accès root** sur tous les serveurs
- **IP publique** pour le Load Balancer
- **Ressources minimum par nœud**:
  - Master: 2 vCPU, 4 GB RAM, 50 GB disque
  - Worker: 2 vCPU, 4 GB RAM, 50 GB disque
  - Load Balancer: 1 vCPU, 2 GB RAM, 20 GB disque

## 🚦 Ordre d'Installation (IMPORTANT)

### Étape 1️⃣ : Configuration du Load Balancer

**Sur le VPS Load Balancer (185.x.x.x) :**

```bash
# 1. Copier le script
wget https://github.com/OpsCatalog/archi-k8s/setup-loadbalancer.sh

# 2. Éditer les variables si nécessaire
nano setup-loadbalancer.sh
# Modifier : PUBLIC_IP="185.x.x.x"

# 3. Exécuter le script
chmod +x setup-loadbalancer.sh
sudo ./setup-loadbalancer.sh

# 4. IMPORTANT: Noter la clé publique du serveur affichée
# Exemple: ServerPublicKey = AbCd1234EfGh5678...
```

**✅ À la fin de cette étape, vous devez avoir :**
- ✓ WireGuard actif sur le Load Balancer
- ✓ HAProxy configuré
- ✓ Clé publique du serveur notée
- ✓ Firewall configuré

## 📐 Architecture HA

```
                        🌍 Internet (185.x.x.x)
                               │
                    ┌──────────┴──────────┐
                    │  Load Balancer (LB) │
                    │  • HAProxy           │
                    │  • WireGuard         │
                    │  • 10.10.0.1         │
                    └──────────┬──────────┘
                               │
           ┌───────────────────┼───────────────────┐
           │                   │                   │
    ┌──────▼──────┐     ┌──────▼──────┐    ┌──────▼──────┐
    │  master01   │     │  master02   │    │  worker01   │
    │  10.10.0.2  │◄────┤  10.10.0.3  │    │  10.10.0.4  │
    │  RKE2 HA    │etcd │  RKE2 HA    │    │  RKE2 Agent │
    └─────────────┘     └─────────────┘    └─────────────┘
                                                   │
                                            ┌──────▼──────┐
                                            │  worker02   │
                                            │  10.10.0.5  │
                                            │  RKE2 Agent │
                                            └─────────────┘
```

## 🔑 Avantages de la Configuration HA

✅ **Haute disponibilité du Control Plane** - Si un master tombe, l'autre prend le relai
✅ **etcd distribué** - Base de données Kubernetes répliquée sur 2 nœuds
✅ **Load balancing automatique** - HAProxy distribue le trafic entre les masters
✅ **Zero downtime** - Maintenance possible sans interruption de service

## 📋 Plan d'Adressage

| Serveur | IP WireGuard | Rôle | Services |
|---------|-------------|------|----------|
| loadbalancer | 10.10.0.1 | Load Balancer | HAProxy, WireGuard |
| master01 | 10.10.0.2 | Master HA #1 | RKE2 Server, etcd |
| master02 | 10.10.0.3 | Master HA #2 | RKE2 Server, etcd |
| worker01 | 10.10.0.4 | Worker | RKE2 Agent, Ingress |
| worker02 | 10.10.0.5 | Worker | RKE2 Agent, Ingress |

### ⚡ Étape 0 : Configurer HAProxy pour 2 Masters

**Sur le Load Balancer :**

```bash
# Appliquer la configuration HAProxy
chmod +x configure-haproxy-ha.sh
sudo ./configure-haproxy-ha.sh

# Vérifier que HAProxy est bien configuré
sudo systemctl status haproxy

# Vérifier les ports
sudo netstat -tlnp | grep haproxy
```

**✅ Vous devez voir les ports : 80, 443, 6443, 8404, 9345**

---

### 1️⃣ Étape 1 : Configuration du PREMIER Master (master01)

**Sur master01 (qui deviendra 10.10.0.2) :**

```bash
# 1. Copier le script
scp setup-rke2-node.sh root@master01:/root/

# 2. Se connecter
ssh root@master01

# 3. Lancer l'installation
chmod +x setup-rke2-node.sh
./setup-rke2-node.sh master 10.10.0.2 10.10.0.1

# 4. Suivre les instructions :
#    - Entrer la clé publique du Load Balancer
#    - Générer un nouveau token (répondre 'y')
#    - IMPORTANT : NOTER LE TOKEN (nécessaire pour master02 ET les workers)
```

**⏱️ Temps : ~5 minutes**

**Configuration appliquée sur master01 :**
```yaml
# /etc/rancher/rke2/config.yaml
node-ip: 10.10.0.2
advertise-address: 10.10.0.2
tls-san:
  - 185.x.x.x
  - 10.10.0.1
  - 10.10.0.2
  - 10.10.0.3
  - master01
  - master02
token: "VotreTokenSecurise123456789"
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16
cni:
  - calico
```

**Vérifier que master01 est prêt :**

```bash
# Sur master01
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Attendre que le nœud soit Ready (peut prendre 2-3 minutes)
kubectl get nodes

# Devrait afficher :
# NAME       STATUS   ROLES                       AGE   VERSION
# master01   Ready    control-plane,etcd,master   3m    v1.28.x+rke2r1
```

---

### 2️⃣ Étape 2 : Ajouter le Peer master01 sur le Load Balancer

**Retour sur le Load Balancer :**

```bash
# Ajouter master01 au réseau WireGuard
sudo add-wireguard-peer.sh master01 10.10.0.2

# Entrer la clé publique de master01 (affichée lors de son installation)

# Vérifier la connectivité
ping 10.10.0.2

# Tester l'API Kubernetes
nc -zv 10.10.0.2 6443
```

**✅ Les deux commandes doivent réussir**

---

### 3️⃣ Étape 3 : Configuration du SECOND Master (master02)

**⚠️ IMPORTANT : Attendre que master01 soit complètement opérationnel avant de continuer !**

**Sur master02 (qui deviendra 10.10.0.3) :**

```bash
# 1. Copier le script
scp setup-rke2-node.sh root@master02:/root/

# 2. Se connecter
ssh root@master02

# 3. Créer la configuration WireGuard MANUELLEMENT d'abord
apt update && apt install -y wireguard wireguard-tools

# Générer les clés
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

# Noter la clé publique
cat /etc/wireguard/public.key

# Créer la config WireGuard
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $(cat /etc/wireguard/private.key)
Address = 10.10.0.3/24

[Peer]
PublicKey = <CLÉ_PUBLIQUE_DU_LOAD_BALANCER>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

# Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Vérifier la connectivité
ping 10.10.0.1
ping 10.10.0.2
```

**4. Ajouter master02 au Load Balancer**

**Sur le Load Balancer :**

```bash
sudo add-wireguard-peer.sh master02 10.10.0.3
# Entrer la clé publique de master02
```

**5. Installer RKE2 sur master02 (rejoint le cluster)**

**Sur master02 :**

```bash
# Télécharger RKE2 Server
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -

# Créer la configuration - IMPORTANT: il rejoint master01
mkdir -p /etc/rancher/rke2

cat > /etc/rancher/rke2/config.yaml << EOF
# Rejoindre le cluster existant via le Load Balancer
server: https://10.10.0.1:9345

# LE MÊME TOKEN que master01
token: "VotreTokenSecurise123456789"

# Configuration du nœud
node-ip: 10.10.0.3
advertise-address: 10.10.0.3

# TLS SANs
tls-san:
  - 185.x.x.x
  - 10.10.0.1
  - 10.10.0.2
  - 10.10.0.3
  - master01
  - master02

# Configuration réseau (doit être identique à master01)
cluster-cidr: 10.42.0.0/16
service-cidr: 10.43.0.0/16

# CNI
cni:
  - calico

# Désactiver l'ingress par défaut
disable:
  - rke2-ingress-nginx

# Permissions
write-kubeconfig-mode: "0644"
EOF

# Démarrer RKE2 Server
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Suivre les logs (peut prendre 3-5 minutes pour rejoindre le cluster)
journalctl -u rke2-server -f
```

**6. Vérifier que master02 a rejoint le cluster**

**Sur master01 ou master02 :**

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

kubectl get nodes

# Devrait maintenant afficher LES DEUX masters :
# NAME       STATUS   ROLES                       AGE   VERSION
# master01   Ready    control-plane,etcd,master   10m   v1.28.x+rke2r1
# master02   Ready    control-plane,etcd,master   3m    v1.28.x+rke2r1

# Vérifier etcd (doit avoir 2 membres)
kubectl get nodes -o wide
kubectl get pods -n kube-system | grep etcd
```

**✅ Vous avez maintenant un Control Plane HA avec etcd distribué !**

---

### 4️⃣ Étape 4 : Configuration des Workers

**Sur worker01 (10.10.0.4) :**

```bash
scp setup-rke2-node.sh root@worker01:/root/
ssh root@worker01

chmod +x setup-rke2-node.sh
./setup-rke2-node.sh worker 10.10.0.4 10.10.0.1

# Entrer :
# - Clé publique du Load Balancer
# - LE MÊME TOKEN que les masters
# - IP du serveur : 10.10.0.1 (le Load Balancer - pas un master directement!)
```

**Ajouter le peer sur le Load Balancer :**

```bash
# Sur le LB
sudo add-wireguard-peer.sh worker01 10.10.0.4
```

**Sur worker02 (10.10.0.5) :**

```bash
scp setup-rke2-node.sh root@worker02:/root/
ssh root@worker02

chmod +x setup-rke2-node.sh
./setup-rke2-node.sh worker 10.10.0.5 10.10.0.1

# Même processus que worker01
```

**Ajouter le peer sur le Load Balancer :**

```bash
# Sur le LB
sudo add-wireguard-peer.sh worker02 10.10.0.5
```

**⚠️ IMPORTANT pour les workers :**
Les workers se connectent via le Load Balancer (`10.10.0.1:9345`), pas directement aux masters. HAProxy distribue automatiquement entre master01 et master02.

---

### 5️⃣ Étape 5 : Vérification Complète

**Sur master01 :**

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Tous les nœuds doivent être Ready
kubectl get nodes -o wide

# Résultat attendu :
# NAME       STATUS   ROLES                       AGE   VERSION        INTERNAL-IP
# master01   Ready    control-plane,etcd,master   15m   v1.28.x+rke2   10.10.0.2
# master02   Ready    control-plane,etcd,master   8m    v1.28.x+rke2   10.10.0.3
# worker01   Ready    worker                      5m    v1.28.x+rke2   10.10.0.4
# worker02   Ready    worker                      3m    v1.28.x+rke2   10.10.0.5

# Vérifier les pods système
kubectl get pods -A

# Vérifier etcd HA
kubectl get pods -n kube-system | grep etcd
# Doit montrer etcd sur master01 ET master02

# Vérifier les endpoints de l'API
kubectl get endpoints kubernetes -n default
# Doit montrer master01:6443 ET master02:6443
```

**Sur le Load Balancer :**

```bash
# Vérifier HAProxy Stats
curl http://localhost:8404/stats

# Ou dans un navigateur :
# http://185.x.x.x:8404/stats
# admin / ChangeMe123!

# Vérifier que les 2 masters sont UP
```

---

### 6️⃣ Étape 6 : Installation de Traefik

**Sur master01 :**

```bash
chmod +x install-traefik.sh
./install-traefik.sh

# Vérifier
kubectl get pods -n traefik
kubectl get svc -n traefik
kubectl get pods -n test-app
```

---

### 7️⃣ Étape 7 : Test de Haute Disponibilité

**Test 1 : Arrêter master01**

```bash
# Sur master01
sudo systemctl stop rke2-server

# Sur master02 (ou worker)
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

kubectl get nodes
# L'API Kubernetes doit TOUJOURS fonctionner via master02

# Sur le Load Balancer, vérifier les logs HAProxy
journalctl -u haproxy -f
# Doit montrer que master01 est DOWN et le trafic va vers master02
```

**Test 2 : Redémarrer master01**

```bash
# Sur master01
sudo systemctl start rke2-server

# Attendre 2 minutes

# Vérifier qu'il rejoint le cluster
kubectl get nodes
# master01 doit revenir en Ready

# HAProxy doit automatiquement re-distribuer le trafic
```

---

## 🎯 Configuration Spéciale pour Workers

Les workers doivent se connecter via le Load Balancer, pas directement aux masters.

**Configuration worker (/etc/rancher/rke2/config.yaml) :**

```yaml
# SE CONNECTE VIA LE LOAD BALANCER
server: https://10.10.0.1:9345

# Token partagé
token: "VotreTokenSecurise123456789"

# IP du worker
node-ip: 10.10.0.4  # ou 10.10.0.5 pour worker02

# Labels
node-label:
  - "node-role.kubernetes.io/worker=true"
  - "workload=application"
```

**Pourquoi via le Load Balancer ?**
- ✅ Haute disponibilité automatique
- ✅ Si un master tombe, les workers continuent via l'autre
- ✅ Load balancing automatique du trafic d'enregistrement

---

## 🔍 Commandes de Diagnostic HA

```bash
# Vérifier l'état des masters
kubectl get nodes -l node-role.kubernetes.io/master

# Vérifier etcd sur les deux masters
kubectl get pods -n kube-system -o wide | grep etcd

# Voir les membres etcd
kubectl exec -n kube-system etcd-master01 -- etcdctl member list

# Vérifier les endpoints Kubernetes API
kubectl get endpoints kubernetes -n default

# HAProxy : voir les backends actifs
echo "show stat" | socat stdio /run/haproxy/admin.sock | grep k8s_api_backend

# Tester l'API via le Load Balancer
curl -k https://10.10.0.1:6443/healthz
```

---

## 🛡️ Avantages de cette Configuration

1. **Tolérance aux pannes** : Un master peut tomber sans interruption
2. **Maintenance sans downtime** : Mise à jour des masters l'un après l'autre
3. **Performance** : Charge distribuée entre les masters
4. **Évolutivité** : Facile d'ajouter un 3ème master si nécessaire
5. **Production-ready** : Configuration recommandée par Rancher

---

## 📊 Résumé de l'Architecture

```
Réseau WireGuard : 10.10.0.0/24
├─ 10.10.0.1 : Load Balancer (HAProxy)
│  ├─ Port 6443  → master01 + master02 (K8s API)
│  ├─ Port 9345  → master01 + master02 (RKE2 Registration)
│  ├─ Port 80    → worker01 + worker02 (HTTP)
│  └─ Port 443   → worker01 + worker02 (HTTPS)
│
├─ 10.10.0.2 : master01 (RKE2 Server + etcd)
├─ 10.10.0.3 : master02 (RKE2 Server + etcd)
├─ 10.10.0.4 : worker01 (RKE2 Agent + Ingress)
└─ 10.10.0.5 : worker02 (RKE2 Agent + Ingress)
```

---

## ✅ Checklist Finale

- [ ] Load Balancer : HAProxy configuré pour 2 masters
- [ ] Load Balancer : WireGuard actif
- [ ] master01 : RKE2 Server installé et Ready
- [ ] master01 : Peer ajouté sur le LB
- [ ] master02 : RKE2 Server installé et Ready (rejoint master01)
- [ ] master02 : Peer ajouté sur le LB
- [ ] etcd : 2 membres actifs
- [ ] worker01 : RKE2 Agent installé et Ready
- [ ] worker01 : Peer ajouté sur le LB
- [ ] worker02 : RKE2 Agent installé et Ready
- [ ] worker02 : Peer ajouté sur le LB
- [ ] Traefik : Installé et fonctionnel
- [ ] Test HA : Arrêt/redémarrage d'un master sans impact
- [ ] HAProxy Stats : Les 2 masters sont UP

Vous avez maintenant un cluster Kubernetes **production-ready** avec haute disponibilité ! 🎉🚀


### Étape 6️⃣ : Vérifier le Cluster

**Sur le master01 :**

```bash
# Vérifier que tous les nœuds sont Ready
kubectl get nodes -o wide

# Devrait afficher :
# NAME       STATUS   ROLES                       AGE   VERSION
# master01   Ready    control-plane,etcd,master   10m   v1.28.x+rke2r1
# worker01   Ready    worker                      5m    v1.28.x+rke2r1
# worker02   Ready    worker                      5m    v1.28.x+rke2r1

# Vérifier les pods système
kubectl get pods -A

# Tous les pods doivent être en Running
```

### Étape 7️⃣ : Installer Traefik Ingress

**Sur le master01 :**

```bash
# 1. Copier le script
scp install-traefik.sh root@master01:/root/

# 2. Exécuter
chmod +x install-traefik.sh
./install-traefik.sh

# 3. Vérifier l'installation
kubectl get pods -n traefik
kubectl get svc -n traefik

# 4. Tester l'application whoami
kubectl get pods -n test-app
```

**⏱️ Temps d'installation : ~2 minutes**

### Étape 8️⃣ : Test de Bout en Bout

**Sur le Load Balancer :**

```bash
# Tester l'application whoami via HAProxy
curl -H "Host: whoami.local" http://localhost

# Devrait retourner des informations sur le conteneur
```

**Depuis Internet :**

```bash
# Tester via l'IP publique du LoadBalancer
curl -H "Host: whoami.local" http://185.x.x.x
```

### Étape 9️⃣ : Vérification Complète

**Sur n'importe quel nœud :**

```bash
# Copier le script de vérification
scp verify-infrastructure.sh root@master01:/root/

# Exécuter
chmod +x verify-infrastructure.sh
./verify-infrastructure.sh

# Devrait afficher un rapport complet avec :
# ✓ Tous les services actifs
# ✓ Connectivité réseau OK
# ✓ Cluster Kubernetes opérationnel
```

## 🔧 Configuration Additionnelle

### Configuration du nœud Infrastructure (optionnel)

**Sur infra-node (10.10.0.10) :**

```bash
# 1. Installer WireGuard
apt install -y wireguard

# 2. Générer les clés
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

# 3. Créer la configuration
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $(cat /etc/wireguard/private.key)
Address = 10.10.0.10/24

[Peer]
PublicKey = <CLÉ_PUBLIQUE_DU_LB>
Endpoint = 185.x.x.x:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

# 4. Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 5. Ajouter le peer sur le Load Balancer
# (sur le LB) sudo add-wireguard-peer.sh infra-node 10.10.0.10
```

### Installation de services sur le nœud infra

```bash
# Installer Docker
curl -fsSL https://get.docker.com | sh

# Installer Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Exemple : MinIO
mkdir -p /opt/minio
cd /opt/minio

cat > docker-compose.yml << EOF
version: '3.8'
services:
  minio:
    image: minio/minio:latest
    restart: always
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: VotreMotDePasseSecurise
    volumes:
      - ./data:/data
    command: server /data --console-address ":9001"
EOF

docker-compose up -d
```

## 📊 Monitoring et Logs

### Logs des services

```bash
# Sur le Load Balancer
journalctl -u wg-quick@wg0 -f
journalctl -u haproxy -f

# Sur le master
journalctl -u rke2-server -f

# Sur les workers
journalctl -u rke2-agent -f

# Logs Kubernetes
kubectl logs -f -n kube-system <pod-name>
kubectl logs -f -n traefik <traefik-pod>
```

### HAProxy Stats

Accéder à : `http://185.x.x.x:8404/stats`
- Username: `admin`
- Password: `ChangeMe123!` (à changer !)

### Traefik Dashboard

```bash
# Port-forward depuis le master
kubectl port-forward -n traefik $(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik -o name) 9000:9000

# Accéder à http://localhost:9000/dashboard/
```

## 🛠️ Commandes Utiles

### WireGuard

```bash
# Statut
wg show

# Redémarrer
systemctl restart wg-quick@wg0

# Logs
journalctl -u wg-quick@wg0 -f
```

### RKE2

```bash
# Nœuds
kubectl get nodes
kubectl describe node <node-name>

# Pods
kubectl get pods -A
kubectl logs -f <pod-name> -n <namespace>

# Services
kubectl get svc -A

# Ingress
kubectl get ingress -A
```

### HAProxy

```bash
# Tester la config
haproxy -c -f /etc/haproxy/haproxy.cfg

# Redémarrer
systemctl restart haproxy

# Logs
journalctl -u haproxy -f
```

## 🔒 Sécurité

### Changements recommandés

1. **Changer le mot de passe HAProxy**
```bash
nano /etc/haproxy/haproxy.cfg
# Modifier la ligne : stats auth admin:NouveauMotDePasse
systemctl restart haproxy
```

2. **Utiliser des certificats SSL**
```bash
# Installer cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

3. **Limiter l'accès SSH**
```bash
# Configurer l'accès par clé uniquement
nano /etc/ssh/sshd_config
# PasswordAuthentication no
# PermitRootLogin prohibit-password
systemctl restart sshd
```

4. **Activer les mises à jour automatiques**
```bash
apt install unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades
```

## 🐛 Dépannage

### Worker ne rejoint pas le cluster

```bash
# 1. Vérifier la connectivité VPN
ping 10.10.0.2

# 2. Vérifier que le port 9345 est accessible
nc -zv 10.10.0.2 9345

# 3. Vérifier le token
cat /etc/rancher/rke2/config.yaml

# 4. Consulter les logs
journalctl -u rke2-agent -f
```

### HAProxy ne route pas le trafic

```bash
# 1. Vérifier qu'HAProxy écoute
netstat -tlnp | grep haproxy

# 2. Tester les backends
curl -v http://10.10.0.3:80

# 3. Vérifier les logs
journalctl -u haproxy -f

# 4. Tester la config
haproxy -c -f /etc/haproxy/haproxy.cfg
```

### WireGuard ne se connecte pas

```bash
# 1. Vérifier le service
systemctl status wg-quick@wg0

# 2. Vérifier la config
wg show

# 3. Vérifier le firewall
ufw status

# 4. Redémarrer
systemctl restart wg-quick@wg0
```

## 📚 Documentation

- [Guide complet détaillé](./guide-rke2-wireguard-deployment.md)
- [RKE2 Documentation](https://docs.rke2.io/)
- [WireGuard Documentation](https://www.wireguard.com/)
- [HAProxy Documentation](https://www.haproxy.org/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)

## 📞 Support

Pour toute question ou problème :
1. Consultez le guide détaillé
2. Exécutez le script de vérification
3. Consultez les logs des services
4. Vérifiez la connectivité réseau

## ✅ Checklist de Production

Avant de passer en production, vérifiez :

- [ ] Toutes les IPs sont correctement configurées
      
- [ ] Tous les nœuds sont en état "Ready"
      
- [ ] WireGuard fonctionne entre tous les nœuds
      
- [ ] HAProxy route correctement le trafic
      
- [ ] Traefik répond aux requêtes HTTP/HTTPS
      
- [ ] Les certificats SSL sont configurés
      
- [ ] Les mots de passe par défaut sont changés
      
- [ ] Le firewall est correctement configuré
      
- [ ] Les sauvegardes etcd sont configurées
      
- [ ] Le monitoring est en place
    
- [ ] La documentation est à jour

## 🎉 Félicitations !

Si vous êtes arrivé jusqu'ici et que tous les tests passent, vous avez maintenant :

✅ Un cluster Kubernetes RKE2 fonctionnel
✅ Un réseau privé sécurisé avec WireGuard
✅ Un Load Balancer avec haute disponibilité
✅ Un Ingress Controller prêt pour vos applications
✅ Une infrastructure scalable et sécurisée

**Prochaines étapes recommandées :**
1. Déployer vos applications
2. Configurer le monitoring avancé
3. Mettre en place les sauvegardes
4. Configurer la CI/CD
5. Documenter vos procédures

Bon déploiement ! 🚀
