# HA Jenkins on Kubernetes — Corporate-Grade Setup Guide
> 6-Year Experience Level | Production Ready | DR Included

---

## TABLE OF CONTENTS
1. [Architecture Overview](#architecture)
2. [Prerequisites](#prerequisites)
3. [Namespace & RBAC Setup](#rbac)
4. [Persistent Storage Setup](#storage)
5. [Jenkins Controller Deployment (StatefulSet)](#controller)
6. [Service & Ingress Setup](#ingress)
7. [TLS / Cert-Manager Setup](#tls)
8. [Network Policies](#network)
9. [First-Time Jenkins Configuration](#firsttime)
10. [Dynamic Agent Configuration (Kubernetes Plugin)](#agents)
11. [Jenkins Security Hardening](#security)
12. [HA Strategy — Active/Passive with Standby](#ha)
13. [Backup Strategy](#backup)
14. [Disaster Recovery Plan](#dr)
15. [Monitoring & Alerting](#monitoring)
16. [Scenario-Based Q&A (6-Year Experience Level)](#qa)

---

## 1. ARCHITECTURE OVERVIEW <a name="architecture"></a>

```
                        ┌─────────────────────────────────────┐
                        │          CORPORATE NETWORK           │
                        └────────────────┬────────────────────┘
                                         │
                              ┌──────────▼──────────┐
                              │   Ingress Controller  │
                              │  (NGINX / ALB / Istio)│
                              │   TLS Termination     │
                              └──────────┬────────────┘
                                         │
                    ┌────────────────────▼───────────────────┐
                    │           Jenkins Namespace              │
                    │                                          │
                    │  ┌──────────────────────────────────┐   │
                    │  │     Jenkins Controller (Primary)   │   │
                    │  │     StatefulSet — 1 Replica        │   │
                    │  │     Pod: jenkins-0                 │   │
                    │  │     Port: 8080 (UI), 50000 (JNLP) │   │
                    │  └──────────────┬───────────────────┘   │
                    │                 │ mounts                  │
                    │  ┌──────────────▼───────────────────┐   │
                    │  │   Persistent Volume (JENKINS_HOME) │   │
                    │  │   StorageClass: EFS / NFS / Ceph   │   │
                    │  │   ReadWriteMany (RWX)              │   │
                    │  └──────────────────────────────────┘   │
                    │                                          │
                    │  ┌──────────────────────────────────┐   │
                    │  │   Jenkins Agent Pods (Dynamic)     │   │
                    │  │   Spawned per Job — Ephemeral      │   │
                    │  │   Namespace: jenkins-agents        │   │
                    │  └──────────────────────────────────┘   │
                    └──────────────────────────────────────────┘
                                         │
                    ┌────────────────────▼───────────────────┐
                    │          Backup & DR                     │
                    │   Velero → S3 / Object Store             │
                    │   CronJob → tar JENKINS_HOME → S3        │
                    └──────────────────────────────────────────┘
```

### Why StatefulSet and NOT Deployment?
- Jenkins controller is **stateful** — JENKINS_HOME must persist across restarts
- StatefulSet gives a **stable pod name** (`jenkins-0`) — critical for agent → controller connectivity
- Pod identity remains consistent across rescheduling
- Ordered pod startup and graceful shutdown

### HA Reality Check (Corporate Truth)
> Jenkins **does NOT support active-active** natively. Corporate HA means:
> - **Active/Passive** — one controller running, standby ready to take over
> - **Shared persistent storage (RWX)** — both can mount same JENKINS_HOME
> - **Fast failover** via Kubernetes StatefulSet self-healing (typically < 60s)
> - **Velero + S3** for full DR in another region/cluster

---

## 2. PREREQUISITES <a name="prerequisites"></a>

### Infrastructure Required
```
- Kubernetes cluster: 1.24+ (EKS / GKE / AKS / On-prem)
- kubectl configured with cluster-admin or scoped admin role
- Helm 3.x installed
- Storage Class that supports ReadWriteMany (EFS on AWS, Filestore on GCP, Azure Files, NFS on bare metal)
- Cert-Manager installed (for TLS)
- NGINX Ingress Controller installed
- DNS entry pointing to Ingress IP/LB
```

### Node Sizing (Corporate Minimum)
```
Jenkins Controller Node:
  CPU:    4 vCPU
  Memory: 8 GB RAM
  Disk:   Root 50 GB

Agent Nodes (Auto-scaled pool):
  CPU:    2–8 vCPU (per agent pod)
  Memory: 4–16 GB RAM (per agent pod)
  Count:  Managed by Cluster Autoscaler
```

### Verify Prerequisites
```bash
# Check kubectl connectivity
kubectl cluster-info

# Check storage classes
kubectl get storageclass

# Verify cert-manager
kubectl get pods -n cert-manager

# Verify ingress controller
kubectl get pods -n ingress-nginx

# Verify Helm
helm version
```

---

## 3. NAMESPACE & RBAC SETUP <a name="rbac"></a>

### Step 3.1 — Create Namespaces
```bash
# Controller lives here
kubectl create namespace jenkins

# Agent pods live here (separation of concerns)
kubectl create namespace jenkins-agents

# Label namespaces
kubectl label namespace jenkins purpose=cicd team=platform
kubectl label namespace jenkins-agents purpose=cicd-agents team=platform
```

### Step 3.2 — Create Service Account for Jenkins Controller
```yaml
# File: jenkins-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    app: jenkins
```
```bash
kubectl apply -f jenkins-sa.yaml
```

### Step 3.3 — Create ClusterRole (Jenkins needs to spawn agent pods)
```yaml
# File: jenkins-clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-role
rules:
  # Pod management for dynamic agents
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list", "watch"]
  # Secret access for credentials
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
  # ConfigMap access
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create", "delete", "get", "list", "update", "watch"]
  # Events (for debugging)
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
```
```bash
kubectl apply -f jenkins-clusterrole.yaml
```

### Step 3.4 — Bind Role to Service Account
```yaml
# File: jenkins-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins-role
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
```
```bash
kubectl apply -f jenkins-rolebinding.yaml

# Also give Jenkins SA permission to manage pods in jenkins-agents namespace
kubectl create rolebinding jenkins-agents-binding \
  --clusterrole=jenkins-role \
  --serviceaccount=jenkins:jenkins \
  --namespace=jenkins-agents
```

---

## 4. PERSISTENT STORAGE SETUP <a name="storage"></a>

> **Critical**: Jenkins JENKINS_HOME must use RWX storage for HA/DR

### Step 4.1 — Create PersistentVolumeClaim
```yaml
# File: jenkins-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pvc
  namespace: jenkins
  labels:
    app: jenkins
spec:
  accessModes:
    - ReadWriteMany          # RWX required for HA failover
  resources:
    requests:
      storage: 100Gi         # Adjust based on job history retention
  storageClassName: efs-sc   # Use your RWX storage class name
                             # AWS:  efs-sc
                             # GCP:  standard-rwx or filestore-sc
                             # Azure: azurefile
                             # NFS:  nfs-client
```
```bash
kubectl apply -f jenkins-pvc.yaml

# Verify PVC is bound
kubectl get pvc -n jenkins
# STATUS should be: Bound
```

### Step 4.2 — AWS EFS StorageClass Example (if using EKS)
```yaml
# File: efs-storageclass.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-XXXXXXXXX   # Your EFS filesystem ID
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/jenkins"
```

---

## 5. JENKINS CONTROLLER DEPLOYMENT (STATEFULSET) <a name="controller"></a>

### Step 5.1 — Create ConfigMap for JVM Options
```yaml
# File: jenkins-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-config
  namespace: jenkins
data:
  JAVA_OPTS: >-
    -Xmx4g
    -Xms2g
    -XX:+UseG1GC
    -XX:MaxGCPauseMillis=200
    -Djenkins.install.runSetupWizard=true
    -Dhudson.model.DirectoryBrowserSupport.CSP="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
    -Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=300
  JENKINS_OPTS: "--httpPort=8080"
```
```bash
kubectl apply -f jenkins-configmap.yaml
```

### Step 5.2 — Jenkins StatefulSet
```yaml
# File: jenkins-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    app: jenkins
    component: controller
spec:
  serviceName: jenkins
  replicas: 1                        # Active/Passive HA — always 1 active
  selector:
    matchLabels:
      app: jenkins
      component: controller
  template:
    metadata:
      labels:
        app: jenkins
        component: controller
    spec:
      serviceAccountName: jenkins
      securityContext:
        fsGroup: 1000                # jenkins user GID
        runAsUser: 1000              # jenkins user UID
        runAsNonRoot: true
      
      # Init container to fix permissions on mounted volume
      initContainers:
        - name: volume-permissions
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 1000:1000 /var/jenkins_home"]
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
          securityContext:
            runAsUser: 0             # Root only for permission fix

      containers:
        - name: jenkins
          image: jenkins/jenkins:lts-jdk17    # Always use LTS
          imagePullPolicy: IfNotPresent
          
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: jnlp
              containerPort: 50000
              protocol: TCP
          
          envFrom:
            - configMapRef:
                name: jenkins-config
          
          resources:
            requests:
              memory: "2Gi"
              cpu: "1000m"
            limits:
              memory: "6Gi"
              cpu: "4000m"
          
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
          
          # Liveness: Is Jenkins alive?
          livenessProbe:
            httpGet:
              path: /login
              port: 8080
            initialDelaySeconds: 120    # Give Jenkins time to start
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          
          # Readiness: Is Jenkins ready to serve traffic?
          readinessProbe:
            httpGet:
              path: /login
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 3
          
          # Startup: Give Jenkins extra time on cold start
          startupProbe:
            httpGet:
              path: /login
              port: 8080
            failureThreshold: 30      # 30 * 10s = 5 minutes max startup
            periodSeconds: 10
          
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false   # Jenkins needs to write
            capabilities:
              drop: ["ALL"]
      
      volumes:
        - name: jenkins-home
          persistentVolumeClaim:
            claimName: jenkins-pvc
      
      # Prefer scheduling on dedicated CI nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values: ["jenkins"]
                topologyKey: "kubernetes.io/hostname"
      
      # Tolerate dedicated CI node taint (if using dedicated nodes)
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "jenkins"
          effect: "NoSchedule"
      
      # Graceful shutdown — let jobs finish before pod dies
      terminationGracePeriodSeconds: 120
```
```bash
kubectl apply -f jenkins-statefulset.yaml

# Watch pod come up
kubectl get pods -n jenkins -w

# Check logs
kubectl logs -f jenkins-0 -n jenkins
```

---

## 6. SERVICE & INGRESS SETUP <a name="ingress"></a>

### Step 6.1 — Create Services
```yaml
# File: jenkins-service.yaml
---
# Headless service for StatefulSet DNS
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    app: jenkins
spec:
  clusterIP: None           # Headless for StatefulSet
  selector:
    app: jenkins
    component: controller
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: jnlp
      port: 50000
      targetPort: 50000

---
# Regular ClusterIP service for Ingress routing
apiVersion: v1
kind: Service
metadata:
  name: jenkins-ui
  namespace: jenkins
  labels:
    app: jenkins
spec:
  type: ClusterIP
  selector:
    app: jenkins
    component: controller
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: jnlp
      port: 50000
      targetPort: 50000
```
```bash
kubectl apply -f jenkins-service.yaml
```

### Step 6.2 — Create Ingress
```yaml
# File: jenkins-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins-ingress
  namespace: jenkins
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # Important: large file uploads (artifacts)
    nginx.ingress.kubernetes.io/proxy-body-size: "500m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    # Security headers
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Frame-Options: SAMEORIGIN";
      more_set_headers "X-Content-Type-Options: nosniff";
      more_set_headers "X-XSS-Protection: 1; mode=block";
    cert-manager.io/cluster-issuer: "letsencrypt-prod"   # or your issuer
spec:
  tls:
    - hosts:
        - jenkins.company.com
      secretName: jenkins-tls
  rules:
    - host: jenkins.company.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jenkins-ui
                port:
                  number: 8080
```
```bash
kubectl apply -f jenkins-ingress.yaml
```

---

## 7. TLS / CERT-MANAGER SETUP <a name="tls"></a>

### Step 7.1 — ClusterIssuer (Let's Encrypt or Internal CA)
```yaml
# File: clusterissuer.yaml
# Option A: Let's Encrypt (Internet-facing)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform-team@company.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx

---
# Option B: Internal CA (Corporate / Air-gapped)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca-issuer
spec:
  ca:
    secretName: internal-ca-secret   # Your corporate CA cert/key as a secret
```
```bash
kubectl apply -f clusterissuer.yaml

# Verify certificate is issued
kubectl get certificate -n jenkins
kubectl describe certificate jenkins-tls -n jenkins
```

---

## 8. NETWORK POLICIES <a name="network"></a>

### Step 8.1 — Restrict Jenkins Controller Traffic
```yaml
# File: jenkins-networkpolicy.yaml
---
# Default deny all ingress in jenkins namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: jenkins
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# Allow only ingress-nginx to reach Jenkins UI
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-jenkins
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app: jenkins
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080

---
# Allow agents to connect to Jenkins JNLP port
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-agents-to-jenkins-jnlp
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app: jenkins
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: jenkins-agents
      ports:
        - protocol: TCP
          port: 50000

---
# Allow Jenkins egress to kube-apiserver (to spawn agent pods)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-jenkins-to-apiserver
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app: jenkins
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443

---
# Allow Jenkins DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-jenkins-dns
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app: jenkins
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```
```bash
kubectl apply -f jenkins-networkpolicy.yaml
```

---

## 9. FIRST-TIME JENKINS CONFIGURATION <a name="firsttime"></a>

### Step 9.1 — Get Initial Admin Password
```bash
# Get the password from the pod
kubectl exec -it jenkins-0 -n jenkins -- \
  cat /var/jenkins_home/secrets/initialAdminPassword

# OR via logs
kubectl logs jenkins-0 -n jenkins | grep -A 5 "initialAdminPassword"
```

### Step 9.2 — Access Jenkins UI
```
Open browser: https://jenkins.company.com
Enter the initial admin password
```

### Step 9.3 — Plugin Selection
```
When prompted:
→ Click "Install suggested plugins"
→ Wait for all plugins to install (5–10 minutes)
→ These are safe defaults — you can add more later
```

### Step 9.4 — Create First Admin User
```
Username: jenkins-admin           (Do NOT keep 'admin' — change it)
Password: <strong-password>       (min 16 chars, mixed case, symbols)
Full name: Jenkins Admin
Email:    platform-team@company.com
```

### Step 9.5 — Configure Jenkins URL
```
Manage Jenkins → System → Jenkins URL
Set to: https://jenkins.company.com
Save
```

### Step 9.6 — Configure Agent → Controller Security
```
Manage Jenkins → Security → Agents
TCP port for inbound agents: Fixed → 50000
Agent protocols: Check only "JNLP4-connect" (most secure)
Save
```

---

## 10. DYNAMIC AGENT CONFIGURATION (KUBERNETES PLUGIN) <a name="agents"></a>

> The Kubernetes plugin is included in suggested plugins. After setup:

### Step 10.1 — Configure Kubernetes Cloud
```
Manage Jenkins → Clouds → New Cloud → Kubernetes

Name: kubernetes
Kubernetes URL: https://kubernetes.default.svc.cluster.local
  (leave blank — Jenkins will auto-discover since it runs in K8s)

Kubernetes Namespace: jenkins-agents
  (agents will spawn in this namespace)

Jenkins URL: http://jenkins.jenkins.svc.cluster.local:8080
  (internal service URL — NOT the external ingress URL)

Jenkins Tunnel: jenkins.jenkins.svc.cluster.local:50000
  (JNLP tunnel — internal service)

Container Cap: 20   (max concurrent agent pods)

Test Connection → Should say: "Connected to Kubernetes..."
```

### Step 10.2 — Create Pod Template for Agents
```
Under Kubernetes Cloud → Pod Templates → Add Pod Template

Name: jenkins-agent-default
Namespace: jenkins-agents
Labels: jenkins-agent

Container:
  Name: jnlp
  Docker Image: jenkins/inbound-agent:latest-jdk17
  Working Directory: /home/jenkins/agent
  
  Resource Limits:
    CPU: 2
    Memory: 4Gi
  Resource Requests:
    CPU: 500m
    Memory: 1Gi

Service Account: default   (or create dedicated SA for agents)
```

### Step 10.3 — Test Agent Spawning
```groovy
// Create a test pipeline job with this Jenkinsfile:
pipeline {
    agent {
        kubernetes {
            label 'jenkins-agent'
            defaultContainer 'jnlp'
        }
    }
    stages {
        stage('Test') {
            steps {
                sh 'echo "Agent is running on: $(hostname)"'
                sh 'kubectl version --client || true'
            }
        }
    }
}
```
```bash
# Watch agent pods spawn
kubectl get pods -n jenkins-agents -w
```

---

## 11. JENKINS SECURITY HARDENING <a name="security"></a>

### Step 11.1 — Matrix-Based Security (Role-Based Access)
```
Manage Jenkins → Security → Authorization
Select: Matrix-based security

Recommended matrix:
Role          | Overall Admin | Job Read | Job Build | Job Configure | View
Admins        | ✓ All         |          |           |               |
Developers    |               | ✓        | ✓         |               | ✓
Read-only     |               | ✓        |           |               | ✓
Anonymous     |               |          |           |               |
```

### Step 11.2 — Enable CSRF Protection
```
Manage Jenkins → Security → CSRF Protection
✓ Enable proxy compatibility (if behind Ingress/Load Balancer)
Default Crumb Issuer: Selected
```

### Step 11.3 — Disable Old/Insecure Agent Protocols
```
Manage Jenkins → Security → Agent Protocols
Uncheck: JNLP-connect (old)
Uncheck: JNLP2-connect (old)
Keep only: JNLP4-connect
```

### Step 11.4 — Secure Script Console Access
```
Manage Jenkins → Security → Script Security
Ensure only admin role can access /script endpoint

Add to Matrix: Only jenkins-admin user gets 'Overall/RunScripts'
```

### Step 11.5 — Configure Audit Logging
```
After installing Audit Trail plugin:
Manage Jenkins → System → Audit Trail

Log Location: /var/jenkins_home/audit/audit.log
Log File Count: 30
Log File Size: 50 MB

Events to log:
✓ Login/Logout
✓ Job Build Started/Finished
✓ Job Configuration Changed
✓ Plugin Installed/Uninstalled
✓ System Configuration Changed
```

### Step 11.6 — Kubernetes Secret for Jenkins Credentials
```bash
# Store sensitive values as K8s secrets
kubectl create secret generic jenkins-credentials \
  --from-literal=github-token=<your-token> \
  --from-literal=docker-registry-pass=<your-pass> \
  --namespace jenkins

# Reference in Jenkins: Manage Jenkins → Credentials
# Add credential → Kind: Secret text → Reference K8s secret
```

### Step 11.7 — Resource Quotas (Prevent Agent Runaway)
```yaml
# File: jenkins-agents-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: jenkins-agents-quota
  namespace: jenkins-agents
spec:
  hard:
    pods: "30"
    requests.cpu: "20"
    requests.memory: "80Gi"
    limits.cpu: "60"
    limits.memory: "120Gi"
```
```bash
kubectl apply -f jenkins-agents-quota.yaml
```

### Step 11.8 — PodSecurityContext for Agents
```yaml
# File: agents-podsecuritypolicy.yaml  (or PodSecurityAdmission in 1.25+)
# In kubernetes 1.25+, use Pod Security Admission labels on namespace:
kubectl label namespace jenkins-agents \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

---

## 12. HA STRATEGY — ACTIVE/PASSIVE WITH STANDBY <a name="ha"></a>

### How Corporate HA Works for Jenkins

```
Normal Operation:
  jenkins-0 (ACTIVE) ──── JENKINS_HOME (RWX PV) ──── Serves all traffic

Failure Scenario:
  jenkins-0 CRASHES
  ↓
  Kubernetes detects pod failure (liveness probe fails × 5)
  ↓
  StatefulSet controller reschedules jenkins-0 on healthy node
  ↓
  New jenkins-0 mounts SAME JENKINS_HOME PV (data intact)
  ↓
  Jenkins starts, loads all jobs/configs from JENKINS_HOME
  ↓
  Readiness probe passes → Service routes traffic to new pod
  Total downtime: ~60–120 seconds
```

### Step 12.1 — Pod Disruption Budget (Prevent Accidental Downtime)
```yaml
# File: jenkins-pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: jenkins-pdb
  namespace: jenkins
spec:
  maxUnavailable: 0          # Never voluntarily evict Jenkins controller
  selector:
    matchLabels:
      app: jenkins
      component: controller
```
```bash
kubectl apply -f jenkins-pdb.yaml
# This prevents: kubectl drain, node upgrades from killing Jenkins without warning
```

### Step 12.2 — Node Anti-Affinity (Spread from Critical Nodes)
```yaml
# Already included in StatefulSet affinity section above
# Ensures Jenkins never lands on same node as other critical workloads
```

### Step 12.3 — Dedicated Jenkins Node Pool (Corporate Best Practice)
```bash
# Taint dedicated nodes for Jenkins only
kubectl taint nodes <jenkins-node> dedicated=jenkins:NoSchedule

# Label them
kubectl label nodes <jenkins-node> role=jenkins

# The tolerations and nodeSelector in the StatefulSet handle this
```

---

## 13. BACKUP STRATEGY <a name="backup"></a>

### What Needs to Backup in Jenkins
```
/var/jenkins_home/
├── jobs/                   ← ALL job configurations and build history
├── plugins/                ← Installed plugins
├── secrets/                ← Credentials encryption keys (CRITICAL)
├── users/                  ← User configurations
├── credentials.xml         ← Encrypted credentials
├── config.xml              ← Main Jenkins config
├── hudson.model.UpdateCenter.xml
└── jenkins.model.JenkinsLocationConfiguration.xml
```

### Step 13.1 — CronJob-Based Backup to S3
```yaml
# File: jenkins-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: jenkins-backup
  namespace: jenkins
spec:
  schedule: "0 2 * * *"          # 2 AM daily
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: jenkins
          containers:
            - name: backup
              image: amazon/aws-cli:latest    # Or google/cloud-sdk / az-cli
              env:
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: aws-backup-creds
                      key: access-key
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: aws-backup-creds
                      key: secret-key
                - name: S3_BUCKET
                  value: "s3://company-jenkins-backup"
              command:
                - /bin/sh
                - -c
                - |
                  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                  echo "Starting Jenkins backup at $TIMESTAMP"
                  
                  # Exclude build logs to reduce size (keep last 30 days)
                  tar -czf /tmp/jenkins-backup-${TIMESTAMP}.tar.gz \
                    --exclude=/var/jenkins_home/workspace \
                    --exclude=/var/jenkins_home/caches \
                    --exclude=/var/jenkins_home/logs \
                    /var/jenkins_home
                  
                  # Upload to S3
                  aws s3 cp /tmp/jenkins-backup-${TIMESTAMP}.tar.gz \
                    ${S3_BUCKET}/backups/jenkins-backup-${TIMESTAMP}.tar.gz
                  
                  # Cleanup old backups (keep 30 days)
                  aws s3 ls ${S3_BUCKET}/backups/ | \
                    sort | head -n -30 | \
                    awk '{print $4}' | \
                    xargs -I {} aws s3 rm ${S3_BUCKET}/backups/{}
                  
                  echo "Backup completed successfully"
              volumeMounts:
                - name: jenkins-home
                  mountPath: /var/jenkins_home
                  readOnly: true
          volumes:
            - name: jenkins-home
              persistentVolumeClaim:
                claimName: jenkins-pvc
          restartPolicy: OnFailure
```
```bash
kubectl apply -f jenkins-backup-cronjob.yaml

# Verify backup runs
kubectl get cronjob -n jenkins
kubectl get jobs -n jenkins
```

### Step 13.2 — Velero for Full PV Backup (Corporate Standard)
```bash
# Install Velero with S3 backend
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket company-velero-backup \
  --secret-file ./aws-credentials \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1

# Create scheduled backup for Jenkins namespace
velero schedule create jenkins-daily-backup \
  --schedule="0 1 * * *" \
  --include-namespaces jenkins,jenkins-agents \
  --ttl 720h    # 30 days retention

# Manual backup on-demand
velero backup create jenkins-manual-$(date +%Y%m%d) \
  --include-namespaces jenkins
```

---

## 14. DISASTER RECOVERY PLAN <a name="dr"></a>

### DR Tiers (Corporate Definition)
```
Tier 1 — Pod Failure (Most common, ~60-120s recovery)
  Cause:  Jenkins pod OOM killed / node failure
  Impact: Builds interrupted, queued jobs waiting
  Fix:    StatefulSet auto-heals — NO manual action needed

Tier 2 — Node Failure (Uncommon, ~2-5 min recovery)
  Cause:  Physical/VM node goes down
  Impact: Jenkins pod rescheduled to another node
  Fix:    Kubernetes reschedules automatically
         PV must be accessible from new node

Tier 3 — Storage Failure (Rare, ~30-60 min recovery)
  Cause:  JENKINS_HOME PV corrupted / EFS unavailable
  Impact: Jenkins cannot start, data potentially lost
  Fix:    Restore from S3 backup to new PV

Tier 4 — Full Cluster Failure / Regional Outage (DR)
  Cause:  Full AWS region down, cluster deleted
  Impact: Total Jenkins outage
  Fix:    Restore to DR cluster using Velero + S3 backup
  RTO:    4 hours
  RPO:    24 hours (daily backup window)
```

### DR Runbook — Tier 3: Storage Recovery
```bash
# Step 1: Create new PV in same or new availability zone
kubectl apply -f jenkins-pvc.yaml  # New PVC on new storage

# Step 2: Create restore job
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: jenkins-restore
  namespace: jenkins
spec:
  template:
    spec:
      containers:
        - name: restore
          image: amazon/aws-cli:latest
          env:
            - name: BACKUP_FILE
              value: "jenkins-backup-20240115-020000.tar.gz"
            - name: S3_BUCKET
              value: "s3://company-jenkins-backup"
          command:
            - /bin/sh
            - -c
            - |
              aws s3 cp ${S3_BUCKET}/backups/${BACKUP_FILE} /tmp/
              cd /
              tar -xzf /tmp/${BACKUP_FILE}
              echo "Restore complete"
          volumeMounts:
            - name: jenkins-home
              mountPath: /var/jenkins_home
      volumes:
        - name: jenkins-home
          persistentVolumeClaim:
            claimName: jenkins-pvc
      restartPolicy: Never
EOF

# Step 3: Monitor restore
kubectl logs -f jenkins-restore-xxxxx -n jenkins

# Step 4: Scale up Jenkins after restore
kubectl scale statefulset jenkins --replicas=1 -n jenkins

# Step 5: Verify Jenkins comes up
kubectl get pods -n jenkins -w
```

### DR Runbook — Tier 4: Full Cluster DR
```bash
# On DR cluster:

# Step 1: Install Velero on DR cluster pointing to same S3 bucket
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket company-velero-backup \
  --secret-file ./aws-credentials \
  --backup-location-config region=us-east-1

# Step 2: List available backups
velero backup get

# Step 3: Restore the latest backup
velero restore create jenkins-dr-restore \
  --from-backup jenkins-daily-backup-<timestamp> \
  --include-namespaces jenkins,jenkins-agents

# Step 4: Monitor restore
velero restore describe jenkins-dr-restore
velero restore logs jenkins-dr-restore

# Step 5: Update DNS to point to DR cluster ingress IP
# (Update Route53 / CloudFlare / Corporate DNS)
# A record: jenkins.company.com → <DR-cluster-ingress-IP>
# TTL: 60s (pre-set low TTL before disaster for faster cutover)

# Step 6: Verify
curl -k https://jenkins.company.com/login
```

### DR Testing Schedule (Corporate Requirement)
```
Frequency: Quarterly DR drills
Test:       Restore from backup to staging cluster
Validate:   
  ✓ All jobs visible
  ✓ All credentials accessible (test decryption)
  ✓ Pipelines can execute
  ✓ Agents can spawn
  ✓ Artifacts accessible

Document:   DR drill report with RTO achieved
Sign-off:   Platform lead + Security team
```

### Pre-DR Checklist
```
□ Verify S3 backup exists and is recent (< 24h)
□ Verify backup is readable (do a test extract)
□ Confirm DR cluster is healthy
□ Confirm DNS TTL is set low (60s) for fast cutover
□ Confirm EFS/NFS is accessible in DR region
□ Notify stakeholders of maintenance window
□ Document current Jenkins version for exact match on restore
□ Keep list of manually-installed plugins with versions
```

---

## 15. MONITORING & ALERTING <a name="monitoring"></a>

### Step 15.1 — Prometheus Metrics (Jenkins Prometheus Plugin)
```
Install: Prometheus Metrics plugin (after initial setup)
Endpoint: https://jenkins.company.com/prometheus/
```
```yaml
# File: jenkins-servicemonitor.yaml (for Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: jenkins-monitor
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: jenkins
  namespaceSelector:
    matchNames:
      - jenkins
  endpoints:
    - port: http
      path: /prometheus/
      interval: 30s
```

### Key Metrics to Alert On
```
jenkins_builds_failed_build_count         → Alert if > 10 in 5min
jenkins_builds_unstable_build_count       → Warn if high
jenkins_executor_count_value             → Alert if 0 (no agents)
jenkins_queue_size_value                 → Alert if > 50 (backlog)
jvm_memory_used_bytes                    → Alert if > 80% of limit
up{job="jenkins"}                        → Alert if == 0 (Jenkins down)
```

### Step 15.2 — Alert Rules
```yaml
# File: jenkins-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: jenkins-alerts
  namespace: monitoring
spec:
  groups:
    - name: jenkins
      rules:
        - alert: JenkinsDown
          expr: up{job="jenkins"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Jenkins is DOWN"
            
        - alert: JenkinsHighQueueDepth
          expr: jenkins_queue_size_value > 30
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Jenkins build queue is building up"
            
        - alert: JenkinsHighMemory
          expr: jvm_memory_used_bytes / jvm_memory_max_bytes > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Jenkins JVM memory > 85%"
```

---

## 16. SCENARIO-BASED Q&A <a name="qa"></a>

### CATEGORY A: Architecture & Design

---

**Q1. Your Jenkins pod keeps getting OOMKilled every Monday morning. What's your diagnosis and fix?**

**A:** Monday morning = weekend batch + sprint kickoff = all teams triggering builds simultaneously.
- Check: `kubectl describe pod jenkins-0 -n jenkins` → look for OOMKilled in last state
- Check JVM heap: `kubectl exec jenkins-0 -n jenkins -- jcmd 1 VM.heap_info`
- Root cause: Either heap is too small OR too many concurrent builds × per-build memory
- **Fix 1**: Increase JVM heap — change `-Xmx4g` to `-Xmx6g` in ConfigMap, rolling restart
- **Fix 2**: Limit concurrent builds via "Throttle Concurrent Builds" plugin
- **Fix 3**: Limit executor count to prevent parallel overload
- **Fix 4**: Move to dynamic agents — moves memory load off controller to agent pods
- **Long-term**: Set up memory alerting at 80% threshold before it OOMKills

---

**Q2. A developer says "my pipeline was running for 3 hours then disappeared with no log." What happened?**

**A:** This is a classic Jenkins pod restart mid-build scenario.
- The pod was restarted (OOM, liveness probe failure, node eviction)
- Builds running on **inline controller executors** (not agents) are lost on restart
- **Diagnosis**: Check `kubectl describe pod jenkins-0` for restart count, events
- Check: `kubectl get events -n jenkins --sort-by='.lastTimestamp'`
- **Fix**: All builds MUST run on dynamic agent pods. If agent pod dies, only that build is lost — controller is unaffected.
- **Immediate**: Enable "Durable Task" plugin settings — increases heartbeat interval
- **Long-term**: Set `terminationGracePeriodSeconds: 300` — gives jobs time to finish on graceful shutdown
- Never run actual workloads on the controller — it's a scheduler, not a builder.

---

**Q3. You need zero-downtime Jenkins upgrades. How do you do it in Kubernetes?**

**A:** There's no true zero-downtime for a stateful singleton. Corporate approach:
1. **Announce maintenance window** (even if it's 5 minutes)
2. **Put Jenkins in quiet mode**: `Manage Jenkins → Prepare for Shutdown` — queues new builds, lets running ones finish
3. **Backup JENKINS_HOME** before upgrade: `velero backup create pre-upgrade-$(date +%Y%m%d)`
4. **Update image tag** in StatefulSet: `kubectl set image statefulset/jenkins jenkins=jenkins/jenkins:2.X.Y-lts-jdk17 -n jenkins`
5. **Monitor**: `kubectl rollout status statefulset/jenkins -n jenkins`
6. **Verify**: Login, check plugin compatibility, run a test build
7. **Rollback plan**: If broken → `kubectl rollout undo statefulset/jenkins -n jenkins`
- **Key point**: Never update minor versions by more than one LTS at a time — always go 2.xxx.1 → 2.xxx.2 → never skip LTS releases.

---

**Q4. Your JENKINS_HOME is 500GB and growing. What's your strategy?**

**A:** Classic Jenkins storage bloat. Multi-pronged approach:
- **Immediate relief**: Run `Disk Usage` plugin to identify largest jobs
- **Build log rotation**: Every job should have "Discard Old Builds" configured — max 30 builds or 30 days
- **Workspace cleanup**: Use `cleanWs()` at end of every pipeline
- **Artifact management**: Don't store artifacts in JENKINS_HOME — ship to Nexus/Artifactory/S3
- **Thin backup**: Exclude `/workspace`, `/caches` from backups
- **Job templates**: Create shared library that enforces log rotation as default
- **Script to enforce rotation**:
  ```groovy
  // In shared library — apply to all jobs
  buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '30'))
  ```
- **Monitor**: Alert when PV usage > 70%

---

### CATEGORY B: Pipeline & Build Issues

---

**Q5. A Jenkinsfile works locally (developers tested with Jenkins on their laptop) but fails in your corporate Kubernetes Jenkins. Why?**

**A:** Environment parity issue — most common corporate pain point:
- **Tool version mismatch**: Corporate Jenkins agent image has Maven 3.6, developer had 3.9
- **Network access**: Corporate agents can't reach external repos — missing proxy settings
- **Secret/credential**: Local has credentials in ~/.m2/settings.xml, agent doesn't
- **Docker socket**: Developer's local Jenkins has Docker socket mounted, K8s agents don't by default
- **Fix approach**:
  1. Define agent image as code in Jenkinsfile → `image: 'company-registry/build-tools:1.2.3'`
  2. Use corporate Nexus proxy for all dependency resolution
  3. Store credentials in Jenkins credential store, inject as env vars
  4. Use Kaniko or BuildKit for container builds without Docker socket
- **Rule**: "Works on my machine" = missing infrastructure-as-code — agent image should be version-pinned and stored in Git

---

**Q6. How do you handle secrets in pipelines without hardcoding them?**

**A:** Defense in depth approach:
- **Never** put secrets in Jenkinsfile or environment variables directly
- **Jenkins Credential Store**: `withCredentials([usernamePassword(credentialsId: 'nexus-creds', ...)])` — secrets injected at runtime, masked in logs
- **Kubernetes Secrets → Jenkins**: Store in K8s secret, reference in Jenkins credential by ID
- **Vault Integration** (corporate): HashiCorp Vault plugin — secrets fetched at runtime, short TTL tokens
- **Detect accidental leaks**: Enable `Secret Scanning` in Git provider (GitHub Advanced Security, GitLab)
- **Rotation**: Credentials should be rotated quarterly — Jenkins stores by ID, rotation just means updating the credential in Jenkins, all pipelines pick up automatically
- **Mask in logs**: Jenkins auto-masks credentials injected via `withCredentials`, but `echo $PASSWORD` will still leak it — train developers

---

**Q7. You have 200 pipelines. How do you manage them at scale without Config Hell?**

**A:** This is about shared libraries and pipeline-as-code governance:
- **Jenkins Shared Libraries**: Common functions in Git → all pipelines import → single place to update
- **Pipeline templates**: Create "standard" Jenkinsfiles for types: maven-app, node-app, docker-build
- **Folder organization**: Use folders by team/product → permissions cascade naturally
- **Configuration as Code (JCasC)**: jenkins.yaml in Git → Jenkins config is versioned, reproducible
- **Job DSL plugin**: Generate jobs programmatically from seed job → adding a new repo creates the Jenkins job automatically
- **Governance**: Require Jenkinsfiles to be reviewed in PR — pipeline code IS production code
- **Orphan job detection**: Weekly scan — jobs without active Git repos get auto-archived

---

### CATEGORY C: Kubernetes-Specific

---

**Q8. Your dynamic agents are pending in Kubernetes — builds queued but no agents spawning. Debug steps?**

**A:** Systematic debugging:
```bash
# Step 1: Check pending pods
kubectl get pods -n jenkins-agents
# If in Pending state, describe them:
kubectl describe pod <agent-pod-name> -n jenkins-agents

# Common errors:
# "Insufficient memory" → Node resource exhaustion → scale up node pool
# "0/3 nodes available: 3 Insufficient cpu" → Request too high vs node capacity
# "PodSecurityPolicy denied" → PSP/PSA blocking → adjust security context
# "ImagePullBackOff" → Agent image not pullable → check registry credentials
```
- **RBAC issue**: Jenkins SA doesn't have permission to create pods in jenkins-agents namespace → check rolebinding
- **Namespace issue**: Jenkins configured to spawn agents in wrong namespace
- **Resource quota exceeded**: Check `kubectl describe resourcequota -n jenkins-agents`
- **Image pull**: Agent image in private registry → ensure imagePullSecret is configured in pod template
- **Network**: Jenkins can't reach Kubernetes API → check NetworkPolicy allows egress to 443/6443

---

**Q9. How do you ensure builds are reproducible across agent pod restarts?**

**A:** Stateless agents by design:
- **Ephemeral agents**: Each build gets a fresh pod — no leftover state from previous builds
- **Dependencies via images**: Build tools, SDKs baked into agent Docker image — not installed at runtime
- **Caching strategy**:
  - Maven: Use PVC for `.m2/repository` mounted to agents (shared cache)
  - NPM: Cache node_modules in PVC or use Nexus proxy
  - Docker layers: Use BuildKit with layer caching via registry
- **Workspace**: `cleanWs()` at end of pipeline — even if reusing agents
- **Pin image versions**: `image: 'company/agent:1.2.3'` not `latest` — prevents drift
- **Test**: Run same pipeline 10 times — output should be identical if truly reproducible

---

### CATEGORY D: DR & HA

---

**Q10. Jenkins controller pod gets stuck in CrashLoopBackOff after a bad plugin install. How do you recover?**

**A:** This is one of the nastiest Jenkins scenarios:
```bash
# Step 1: Identify the bad plugin from logs
kubectl logs jenkins-0 -n jenkins --previous | grep -i "error\|exception\|failed"

# Step 2: You can't access UI — need to fix via filesystem
# Scale down Jenkins (stop the crashing pod)
kubectl scale statefulset jenkins --replicas=0 -n jenkins

# Step 3: Spin up a debug pod mounting the same PV
kubectl run jenkins-debug \
  --image=busybox \
  --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"jh","persistentVolumeClaim":{"claimName":"jenkins-pvc"}}],"containers":[{"name":"debug","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"mountPath":"/var/jenkins_home","name":"jh"}]}]}}' \
  -n jenkins

# Step 4: Remove the bad plugin
kubectl exec -it jenkins-debug -n jenkins -- \
  rm /var/jenkins_home/plugins/<bad-plugin>.jpi
kubectl exec -it jenkins-debug -n jenkins -- \
  rm /var/jenkins_home/plugins/<bad-plugin>.jpi.pinned 2>/dev/null || true

# Step 5: Also remove from disabled plugins if needed
kubectl exec -it jenkins-debug -n jenkins -- \
  rm /var/jenkins_home/plugins/<bad-plugin>.jpi.disabled 2>/dev/null || true

# Step 6: Restart Jenkins
kubectl delete pod jenkins-debug -n jenkins
kubectl scale statefulset jenkins --replicas=1 -n jenkins
kubectl logs -f jenkins-0 -n jenkins
```

---

**Q11. Walk me through your Jenkins DR test drill process.**

**A:** Quarterly drill process:
1. **Announce**: Notify teams — "Jenkins DR drill, staging environment only, 2-hour window"
2. **Snapshot current state**: Take Velero backup of prod Jenkins namespace
3. **Spin up DR cluster** (or use existing staging cluster)
4. **Restore**: `velero restore create drill-restore --from-backup <latest>`
5. **Validate checklist**:
   - Login works with admin credentials
   - All job folders visible (spot check 10 random jobs)
   - Run 3 test pipelines end-to-end
   - Check credential decryption (credentials should work — same master.key)
   - Verify agents spawn in DR cluster
   - Check Audit log continuity
6. **Measure RTO**: Time from "disaster declared" to "Jenkins fully operational"
7. **Document**: RTO achieved, any issues found, remediation
8. **Compare**: RTO target vs achieved — adjust runbooks if missed
9. **Teardown DR**: Clean up drill environment
10. **Post-mortem**: Share report with platform, security, management

---

**Q12. A Jenkins upgrade broke 50 pipelines due to a pipeline syntax change. How do you handle rollback and remediation at scale?**

**A:** Structured rollback + forward-fix approach:
- **Immediate**: Rollback Jenkins version → `kubectl rollout undo statefulset/jenkins -n jenkins`
- **Verify**: All 50 pipelines green again
- **Root cause**: Identify breaking change — check Jenkins LTS changelog, plugin release notes
- **Fix strategy**:
  - If shared library issue → fix once in shared library, all pipelines fixed
  - If Jenkinsfile syntax → use `grep -r "deprecated_syntax" */Jenkinsfile` across all repos
  - Use Jenkins Pipeline Linter (declarative validator) to pre-validate all Jenkinsfiles before next upgrade
- **Upgrade process improvement**:
  1. Upgrade **staging Jenkins first** — run all pipelines
  2. Identify failures in staging
  3. Fix in staging (shared library + Jenkinsfile PRs)
  4. Only then upgrade prod
- **Prevention**: Pipeline Linter as a gate in the Jenkins-itself CI pipeline (meta!)

---

### CATEGORY E: Security

---

**Q13. You found that a developer accidentally committed AWS credentials to a public GitHub repo. The credentials were used in a Jenkins pipeline. What do you do?**

**A:** Incident response protocol:
1. **Immediately rotate** the AWS credentials — assume compromised
2. **Revoke old credentials** in AWS IAM — don't just rotate, REVOKE
3. **Check CloudTrail** for unusual API activity with those credentials
4. **Remove from Git history**: `git filter-branch` or BFG Repo Cleaner — force push
5. **In Jenkins**: Update the credential in Jenkins credential store with new keys
6. **Post-incident**:
   - Enable **AWS Secrets Manager** or **Vault** — credentials never in Jenkins credential store as plaintext
   - Enable **GitHub secret scanning** to auto-detect future leaks
   - Add **pre-commit hooks** (`detect-secrets`, `git-secrets`) to developer workstations
   - Add **SAST scan** in pipeline that detects credential patterns
7. **Report**: Create security incident report — even if no breach found

---

**Q14. How do you prevent a rogue pipeline from accessing another team's credentials in Jenkins?**

**A:** Folder-based credential isolation:
- **Folder-scoped credentials**: Store team credentials in their Jenkins folder, not in global credentials store
- `Jenkins → TeamA-Folder → Credentials` — only pipelines inside TeamA-Folder can access these
- **Matrix authorization**: TeamA members have Job/Read+Build on TeamA folder, not on TeamB
- **Groovy sandbox**: Declarative pipelines run in sandbox — can't use arbitrary Java to read credential files
- **Audit trail**: Log every credential access — alert on cross-team access patterns
- **Network policies**: Even if a pipeline tries to reach another team's services, NetworkPolicy blocks it
- **Test it**: Run a pipeline in TeamA-Folder and try to access TeamB credentials by ID — it should fail with "No such credentials"

---

> ## MASTER REFERENCE: QUICK COMMANDS

```bash
# Health check
kubectl get pods -n jenkins
kubectl get pvc -n jenkins
kubectl top pod -n jenkins

# Logs
kubectl logs -f jenkins-0 -n jenkins
kubectl logs -f jenkins-0 -n jenkins --previous  # after restart

# Exec into Jenkins
kubectl exec -it jenkins-0 -n jenkins -- bash

# Force restart Jenkins (graceful)
kubectl rollout restart statefulset/jenkins -n jenkins

# Scale down (maintenance)
kubectl scale statefulset jenkins --replicas=0 -n jenkins

# Scale up
kubectl scale statefulset jenkins --replicas=1 -n jenkins

# Check agent pods
kubectl get pods -n jenkins-agents
kubectl describe pod <agent-pod> -n jenkins-agents

# Check events
kubectl get events -n jenkins --sort-by='.lastTimestamp'
kubectl get events -n jenkins-agents --sort-by='.lastTimestamp'

# Resource usage
kubectl top pod -n jenkins
kubectl top pod -n jenkins-agents

# Backup now (manual trigger)
kubectl create job --from=cronjob/jenkins-backup manual-backup-$(date +%Y%m%d) -n jenkins

# Check quota
kubectl describe resourcequota -n jenkins-agents
```
