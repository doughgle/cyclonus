#!/usr/bin/env bash

set -xv
set -euo pipefail

KIND_VERSION=${KIND_VERSION:-v0.23.0}
CNI=${CNI:-calico}
CLUSTER_NAME="netpol-$CNI"
RUN_FROM_SOURCE=${RUN_FROM_SOURCE:-true}
FROM_SOURCE_ARGS=${FROM_SOURCE_ARGS:-"generate --include conflict --job-timeout-seconds 2"}
INSTALL_KIND=${INSTALL_KIND:-true}
FORCE_RECREATE=${FORCE_RECREATE:-false}

# see https://github.com/actions/virtual-environments/blob/main/images/linux/Ubuntu2004-README.md
#   github includes a kind version, but it may not be the version we want
if [[ $INSTALL_KIND == true ]]; then
  curl -Lo ./kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-$(uname)-amd64"
  chmod +x "./kind"
  sudo mv kind /usr/local/bin
fi

kind version
which -a kind

# create kind cluster
pushd "$CNI"
  CLUSTER=$CLUSTER_NAME ./setup-kind.sh
popd

# preload agnhost image
docker pull registry.k8s.io/e2e-test-images/agnhost:2.43
kind load docker-image registry.k8s.io/e2e-test-images/agnhost:2.43 --name "$CLUSTER_NAME"

# make sure that the new kind cluster is the current kubectl context
kind get clusters
kind export kubeconfig --name "$CLUSTER_NAME"

# Verify we're using the correct context
CURRENT_CONTEXT=$(kubectl config current-context)
EXPECTED_CONTEXT="kind-$CLUSTER_NAME"
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo "Warning: Current kubectl context is $CURRENT_CONTEXT, expected $EXPECTED_CONTEXT"
  echo "Switching to the correct context"
  kubectl config use-context "$EXPECTED_CONTEXT"
fi

# get some debug info
kubectl get nodes
kubectl get pods -A

# run cyclonus
if [ "$RUN_FROM_SOURCE" == true ]; then
  # don't quote this -- we want word splitting here!
  go run ../../cmd/cyclonus/main.go $FROM_SOURCE_ARGS
else
  docker pull mfenwick100/cyclonus:latest
  kind load docker-image mfenwick100/cyclonus:latest --name "$CLUSTER_NAME"

  JOB_NAME=job.batch/cyclonus
  JOB_NS=netpol

  # Set up cyclonus namespace if it doesn't exist
  if ! kubectl get namespace "$JOB_NS" &> /dev/null; then
    echo "Creating namespace $JOB_NS"
    kubectl create namespace "$JOB_NS"
  else
    echo "Namespace $JOB_NS already exists"
  fi

  # Set up service account if it doesn't exist
  if ! kubectl get serviceaccount cyclonus -n "$JOB_NS" &> /dev/null; then
    echo "Creating service account cyclonus in namespace $JOB_NS"
    kubectl create serviceaccount cyclonus -n "$JOB_NS"
  else
    echo "Service account cyclonus already exists in namespace $JOB_NS"
  fi

  # Set up cluster role binding if it doesn't exist
  if ! kubectl get clusterrolebinding cyclonus &> /dev/null; then
    echo "Creating cluster role binding for cyclonus"
    kubectl create clusterrolebinding cyclonus --clusterrole=cluster-admin --serviceaccount="$JOB_NS":cyclonus
  else
    echo "Cluster role binding cyclonus already exists"
  fi

  # Delete any existing job before creating a new one
  if kubectl get job cyclonus -n "$JOB_NS" &> /dev/null; then
    echo "Deleting existing cyclonus job"
    kubectl delete job cyclonus -n "$JOB_NS" --wait=true
    
    # Wait for pods to be fully deleted using kubectl wait instead of a sleep loop
    echo "Waiting for job resources to be cleaned up..."
    kubectl wait --for=delete pod -l job-name=cyclonus -n "$JOB_NS" --timeout=60s || true
  fi

  pushd "$CNI"
    echo "Creating cyclonus job"
    kubectl create -f cyclonus-job.yaml -n "$JOB_NS"
  popd

  # Wait for the job to create a pod
  echo "Waiting for cyclonus job to create a pod..."
  kubectl wait --for=condition=complete=false job/cyclonus -n $JOB_NS --timeout=60s

  # Wait for the pod to be ready
  echo "Waiting for cyclonus pod to be ready..."
  kubectl wait --for=condition=ready pod -l job-name=cyclonus -n $JOB_NS --timeout=5m

  kubectl logs -f -n $JOB_NS $JOB_NAME
fi
