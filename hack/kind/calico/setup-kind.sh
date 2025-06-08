#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail
set -xv

CLUSTER=${CLUSTER:-netpol-calico}
FORCE_RECREATE=${FORCE_RECREATE:-false}

# Check if cluster already exists
if kind get clusters | grep -q "^$CLUSTER$"; then
  echo "Cluster $CLUSTER already exists"
  if [[ "$FORCE_RECREATE" == "true" ]]; then
    echo "FORCE_RECREATE is true, deleting existing cluster"
    kind delete cluster --name "$CLUSTER"
    
    # We can't use kubectl wait here since the cluster is being deleted
    # Instead, use a timeout approach with limited attempts
    echo "Waiting for cluster $CLUSTER to be deleted..."
    ATTEMPTS=30
    for ((i=1; i<=ATTEMPTS; i++)); do
      if ! kind get clusters | grep -q "^$CLUSTER$"; then
        echo "Cluster deleted after $i attempts"
        break
      fi
      if ((i == ATTEMPTS)); then
        echo "Warning: Cluster deletion took longer than expected"
      else
        echo -n "."
        # Use minimal delay - there's no event mechanism for cluster deletion
        sleep 0.2
      fi
    done
    echo ""
  else
    echo "Using existing cluster. Set FORCE_RECREATE=true to recreate it."
  fi
fi

# Only create if it doesn't exist now
if ! kind get clusters | grep -q "^$CLUSTER$"; then
  echo "Creating cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --config kind-config.yaml
fi

# Wait for cluster to be ready - more reliable than using sleep
kubectl wait --for=condition=Ready node --all --timeout=60s


kubectl get nodes
kubectl get all -A

kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
kubectl -n kube-system set env daemonset/calico-node FELIX_IGNORELOOSERPF=true
kubectl -n kube-system set env daemonset/calico-node FELIX_XDPENABLED=false

kubectl get nodes
kubectl get all -A

kubectl wait --for=condition=ready nodes --timeout=5m --all

kubectl get nodes
kubectl get all -A

kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system
