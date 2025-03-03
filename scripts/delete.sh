#!/bin/bash
set -e

## Download & set permission to kubectl cli 
echo "########### Check & Install kubectl cli #############"
if hash kubectl 2>/dev/null; then
  echo "Kubectl CLI is installed"
else
    echo "Kubectl CLI is installing!"
    cd /tmp/
    curl -k -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl";
    chmod +x /tmp/kubectl;
    mkdir -p ~/.local/bin;
    cp /tmp/kubectl ~/.local/bin/kubectl;
fi

## Download & set permission to AWS cli 
echo "########### Check & Install AWS cli #############"
if hash aws 2>/dev/null; then
  echo "AWS CLI is installed"
else
  cd /tmp/
  echo "AWS CLI is installing!"
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" 
  unzip awscliv2.zip > /dev/null
  sudo sh ./aws/install
fi

## Download & set permission to jq 
echo "########### Check & Install jq #############"
if hash jq 2>/dev/null; then
  echo "jq is installed"
else
  cd /tmp/
  echo "jq is installing!"
  curl "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o "jq-linux-amd64" 
  chmod +x /tmp/jq-linux-amd64;
  mkdir -p ~/.local/bin;
  cp /tmp/jq-linux-amd64 ~/.local/bin/jq-linux-amd64;
fi

## Download & set permission to helm 
echo "########### Check & Install helm #############"
if hash helm 2>/dev/null; then
  echo "helm is installed"
else
  cd /tmp/
  echo "helm is installing!"
  curl "https://get.helm.sh/helm-v3.13.3-linux-amd64.tar.gz" -o "helm.tar.gz" 
  tar -zxvf helm.tar.gz;
  mkdir -p ~/.local/bin;
  cp /tmp/linux-amd64/helm ~/.local/bin/helm;
fi

CLUSTER_NAME=$1
REGION=$2

# Set the cluster kube config
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION


# Check if mutating webhook configurations are present
if kubectl get mutatingwebhookconfigurations | grep "kyverno-policy-mutating-webhook-cfg" \| "kyverno-resource-mutating-webhook-cfg" \| "kyverno-verify-mutating-webhook-cfg" \| "datadog-webhook" \| "linkerd-tap-injector-webhook-config" &> /dev/null; then
  kubectl delete mutatingwebhookconfigurations kyverno-policy-mutating-webhook-cfg kyverno-resource-mutating-webhook-cfg kyverno-verify-mutating-webhook-cfg datadog-webhook linkerd-tap-injector-webhook-config
  echo "Mutating webhook configurations deleted."
else
  echo "No mutating webhook configurations found."
fi

# Check if validating webhook configurations are present
if kubectl get validatingwebhookconfigurations | grep kyverno-policy-validating-webhook-cfg \| kyverno-resource-validating-webhook-cfg \| kyverno-cleanup-validating-webhook-cfg \| kyverno-exception-validating-webhook-cfg &> /dev/null; then
  kubectl delete validatingwebhookconfigurations kyverno-policy-validating-webhook-cfg kyverno-resource-validating-webhook-cfg kyverno-cleanup-validating-webhook-cfg kyverno-exception-validating-webhook-cfg
  echo "Validating webhook configurations deleted."
else
  echo "No validating webhook configurations found."
fi

#Delete all Helm charts
# Check if there are any Helm charts
if helm ls -a --all-namespaces | awk 'NR > 1' | grep -q '.'; then
  helm ls -a --all-namespaces | awk 'NR > 1 { print "-n "$2, $1 }' | xargs -L1 helm delete || true
else
  echo "No Helm charts found. Skipping deletion."
fi

# Get all namespaces excluding kube-system and default
namespaces=$(kubectl get namespaces -o=json | jq -r '.items[] | select(.metadata.name != "kube-system" and .metadata.name != "default" and .metadata.name != "kube-node-lease" and .metadata.name != "kube-public") | .metadata.name')

echo "Deleting namespaces"
kubectl delete namespace $namespaces --grace-period=0 --force &

# Set a timeout for namespace deletion (1 minute)
timeout=60
while [ $timeout -gt 0 ]; do
  sleep 1
  if kubectl get namespaces $namespaces &> /dev/null; then
    echo "Still deleting namespaces. Timeout in $timeout seconds."
    ((timeout--))
  else
    echo "Namespaces deleted successfully."
    break
  fi
done

# If the timeout is reached, print an error message
if [ $timeout -eq 0 ]; then
  echo "Timeout reached. Some namespaces may not have been deleted."
fi

# Get all namespaces in Terminating status
terminating_namespaces=$(kubectl get namespaces --field-selector='status.phase=Terminating' -o jsonpath='{.items[*].metadata.name}')

# Check if there are any namespaces in Terminating status
if [ -z "$terminating_namespaces" ]; then
  echo "No namespaces found in Terminating status."
else
  for namespace in $terminating_namespaces; do
    echo "Processing namespace: $namespace"
    
    # Save the JSON file
    kubectl get namespace $namespace -o json > tempfile.json

    # Remove the finalizers array block
    jq 'del(.spec.finalizers)' tempfile.json > tempfile_modified.json

    # Apply the changes
    kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f tempfile_modified.json
  done
fi
