#!/usr/bin/env bash
# IMESH K8s/DevOps Assignment - full setup + verification script
# Run section by section (or as one script) on a fresh machine with
# docker, kubectl, helm, kind, cert-manager CLI (cmctl - optional) installed.
set -euo pipefail

### 1. CREATE CLUSTER (kind) #################################################
cat <<'EOF' > kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
kind create cluster --name imesh --config kind-config.yaml
kubectl cluster-info --context kind-imesh

### 2. INSTALL GATEWAY API CRDs + ENVOY GATEWAY ##############################
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.1.2 \
  -n envoy-gateway-system \
  --create-namespace

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

### 3. INSTALL CERT-MANAGER ###################################################
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true

kubectl wait --timeout=5m -n cert-manager deployment/cert-manager --for=condition=Available
kubectl wait --timeout=5m -n cert-manager deployment/cert-manager-webhook --for=condition=Available

### 4. ASSIGNMENT 3: CA, CLUSTERISSUER, TLS CERT #############################
kubectl apply -f manifests/certs/ca-and-issuer.yaml
kubectl apply -f manifests/certs/gateway-tls-certificate.yaml

kubectl get certificate -n cert-manager company-local-ca
kubectl get clusterissuer company-local-ca-issuer
kubectl get certificate -n default company-local-tls
kubectl get secret -n default company-local-tls

### 5. ASSIGNMENT 1: DEPLOY APPS #############################################
kubectl apply -f manifests/apps/nginx.yaml
kubectl apply -f manifests/apps/httpbin.yaml
kubectl apply -f manifests/apps/echoserver.yaml

kubectl rollout status deployment/nginx
kubectl rollout status deployment/httpbin
kubectl rollout status deployment/echoserver

kubectl get deploy,po,svc -l 'app in (nginx,httpbin,echoserver)'

### 6. ASSIGNMENT 2: GATEWAY + ROUTES ########################################
kubectl apply -f manifests/gateway/gateway.yaml
kubectl apply -f manifests/gateway/httproute-nginx.yaml
kubectl apply -f manifests/gateway/httproute-httpbin.yaml
kubectl apply -f manifests/gateway/httproute-echoserver.yaml
kubectl apply -f manifests/gateway/backend-traffic-policy.yaml

kubectl get gateway eg-gateway
kubectl get httproute
kubectl get backendtrafficpolicy

### 7. LOCAL DNS ##############################################################
# Add to /etc/hosts (Linux/Mac) or C:\Windows\System32\drivers\etc\hosts (Windows):
#   127.0.0.1  web.company.local api.company.local test.company.local
echo "127.0.0.1  web.company.local api.company.local test.company.local" | sudo tee -a /etc/hosts

### 8. VERIFICATION CURLS ####################################################
# --- Host-based + path-based routing, HTTP ---
curl -i http://web.company.local/
curl -i http://api.company.local/orders
curl -i http://test.company.local/

# --- URL rewrite + header injection check ---
# httpbin's /anything endpoint echoes back the request it received,
# so we can see the rewritten path and injected headers in the JSON response.
curl -s http://api.company.local/orders | jq '.headers, .url'

# --- Retry / timeout: hit a slow httpbin endpoint ---
curl -i --max-time 10 "http://api.company.local/orders/delay/3"

# --- Rate limiting: fire 15 requests, expect 429s after the 10th ---
for i in $(seq 1 15); do
  curl -s -o /dev/null -w "req $i -> %{http_code}\n" http://api.company.local/orders
done

# --- HTTPS / TLS ---
curl -i --cacert <(kubectl get secret company-local-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d) \
  https://api.company.local/orders

# Verify the cert from the command line:
openssl s_client -connect api.company.local:443 -servername api.company.local </dev/null 2>/dev/null | openssl x509 -noout -text
