#!/bin/bash

validate_input() {
  local input="$1"
  # Check if input is empty, contains spaces, or special characters
  if [[ -z "$input" || "$input" =~ [^a-zA-Z0-9_-] ]]; then
    return 1 
  else
    return 0  
  fi
}
# Prompt the user for the cluster name
while true; do
  read -p "Enter the cluster name (alphanumeric, dashes, or underscores only): " cluster_name
  
  # Validate the input
  if validate_input "$cluster_name"; then
    break
  else
    echo "Invalid cluster name. Please use only alphanumeric characters, dashes, or underscores, and avoid spaces."
  fi
done

echo "Creating docker subnet 172.100.0.0/16 for testbed"
docker network create --subnet 172.100.0.0/16 testbed

echo "Using k3d to create cluster - disabling inbuilt loadbalancer and using testbed network"
k3d cluster create $cluster_name --k3s-arg "--disable=servicelb@server:0" --no-lb --wait --network testbed

kubectl config use-context k3d-$cluster_name

helm repo add metallb https://metallb.github.io/metallb
helm install metallb -n metallb --create-namespace metallb/metallb
echo "Waiting for metallb to deploy..."
sleep 5
kubectl wait -n metallb -l app.kubernetes.io/component=controller --for=condition=ready pod --timeout=120s

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ip-pool
  namespace: metallb
spec:
  addresses:
  - 172.100.150.0-172.100.150.20
EOF

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advertisement-l2
  namespace: metallb
spec:
  ipAddressPools:
  - ip-pool
EOF

# Add the ingress-nginx Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install the ingress-nginx Helm chart
helm install ingress-nginx -n ingress-nginx --create-namespace ingress-nginx/ingress-nginx

# Wait for the ingress-nginx controller pods to be ready
echo "Waiting for ingress-nginx controller pods to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=ingress-nginx \
  --timeout=90s

# Apply the app-load-balancer deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: app-load-balancer
  name: app-load-balancer
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-load-balancer
  template:
    metadata:
      labels:
        app: app-load-balancer
    spec:
      containers:
      - image: nginx
        name: nginx
        command:
          - sh
          - -c
          - "echo 'Hello, from app-load-balancer' > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"
EOF

# Wait for the app-load-balancer deployment to be ready
echo "Waiting for app-load-balancer deployment to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/app-load-balancer -n default

# Apply the app-load-balancer service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: app-load-balancer
  name: app-load-balancer
  namespace: default
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: app-load-balancer
  type: LoadBalancer
EOF

# Apply the app-ingress deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: app-ingress
  name: app-ingress
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-ingress
  template:
    metadata:
      labels:
        app: app-ingress
    spec:
      containers:
      - image: nginx
        name: nginx
        command:
          - sh
          - "-c"
          - "echo 'Hello, from app-ingress' > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"
EOF

# Wait for the app-ingress deployment to be ready
echo "Waiting for app-ingress deployment to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/app-ingress -n default

# Apply the app-ingress service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: app-ingress
  name: app-ingress
  namespace: default
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: app-ingress
  type: ClusterIP
EOF

# Wait for the app-ingress service to be ready
echo "Waiting for app-ingress service to be ready..."
kubectl wait --for=condition=available --timeout=60s service/app-ingress -n default

# Apply the ingress resource
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: app-ingress.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-ingress
            port:
              number: 80
EOF

INGRESS_LB_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Add $INGRESS_LB_IP to /etc/hosts"

echo "$INGRESS_LB_IP app-ingress.local" | sudo tee -a /etc/hosts
