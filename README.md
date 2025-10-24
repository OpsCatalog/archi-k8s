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

## 🎯 Architecture

```
                        🌍 Internet
                             │
                             ▼
┌──────────────────────────────────────────────┐
│ VPS Load Balancer (185.x.x.x)                │
│  • WireGuard Server (10.10.0.1)              │
│  • HAProxy (HTTP/HTTPS/K8s API)              │
└──────────────────────────────────────────────┘
         │
         │ WireGuard VPN (10.10.0.0/24)
         ▼
─────────────────────────────────────────────────
| 10.10.0.2 → master01 (RKE2 Server)            |
| 10.10.0.3 → worker01 (RKE2 Agent)             |
| 10.10.0.4 → worker02 (RKE2 Agent)             |
| 10.10.0.10 → infra-node (GitLab, MinIO...)    |
─────────────────────────────────────────────────
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

### Étape 2️⃣ : Configuration du Master RKE2

**Sur master01 (qui deviendra 10.10.0.2) :**

```bash
# 1. Copier le script
scp setup-rke2-node.sh root@master01:/root/

# 2. Se connecter au master
ssh root@master01

# 3. Éditer le script si nécessaire
nano setup-rke2-node.sh
# Vérifier : LB_PUBLIC_IP="185.x.x.x"

# 4. Lancer l'installation
chmod +x setup-rke2-node.sh
./setup-rke2-node.sh master 10.10.0.2 10.10.0.1

# 5. Suivre les instructions :
#    - Entrer la clé publique du Load Balancer
#    - Générer un nouveau token (répondre 'y')
#    - NOTER LE TOKEN affiché (pour les workers)
```

**⏱️ Temps d'installation : ~5 minutes**

**✅ À la fin de cette étape :**
- ✓ WireGuard connecté (ping 10.10.0.1 fonctionne)
- ✓ RKE2 Server actif
- ✓ Token RKE2 généré et noté
- ✓ kubectl fonctionnel
- ✓ Master en état "Ready"

### Étape 3️⃣ : Ajouter le peer Master sur le Load Balancer

**Retour sur le Load Balancer :**

```bash
# 1. Utiliser le script helper
sudo add-wireguard-peer.sh master01 10.10.0.2

# 2. Entrer la clé publique du master01
#    (affichée lors de l'installation du master)

# 3. Vérifier la connexion
wg show
ping 10.10.0.2
```

**✅ Vérification :** `ping 10.10.0.2` doit fonctionner

### Étape 4️⃣ : Configuration des Workers

**Sur worker01 (qui deviendra 10.10.0.3) :**

```bash
# 1. Copier le script
scp setup-rke2-node.sh root@worker01:/root/

# 2. Se connecter
ssh root@worker01

# 3. Lancer l'installation
chmod +x setup-rke2-node.sh
./setup-rke2-node.sh worker 10.10.0.3 10.10.0.1

# 4. Suivre les instructions :
#    - Entrer la clé publique du Load Balancer
#    - Entrer le TOKEN RKE2 du master
#    - Confirmer l'IP du master (10.10.0.2)
```

**Sur worker02 (qui deviendra 10.10.0.4) :**

```bash
# Même procédure
./setup-rke2-node.sh worker 10.10.0.4 10.10.0.1
```

**⏱️ Temps par worker : ~3 minutes**

### Étape 5️⃣ : Ajouter les peers Workers sur le Load Balancer

**Sur le Load Balancer :**

```bash
# Ajouter worker01
sudo add-wireguard-peer.sh worker01 10.10.0.3
# Entrer sa clé publique

# Ajouter worker02
sudo add-wireguard-peer.sh worker02 10.10.0.4
# Entrer sa clé publique

# Vérifier
wg show
ping 10.10.0.3
ping 10.10.0.4
```

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
# Tester via l'IP publique
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
