#!/bin/bash

# Default parameter values
cluster=${1:-"localhost"}
namespace=${2:-"wac-hospital"}
installFlux=${3:-true}

# Assigning root directories
ProjectRoot="$(dirname "$0")/.."
echo "ScriptRoot is $(dirname "$0")"
echo "ProjectRoot is ${ProjectRoot}"

clusterRoot="${ProjectRoot}/clusters/${cluster}"

# Set error action preference
set -e

# Get current kubectl context
context=$(kubectl config current-context)

# Check if sops is installed
if ! command -v sops &>/dev/null; then
    echo "sops CLI must be installed, use 'choco install sops' to install it before continuing."
    exit -11
fi
sopsVersion=$(sops -v)

# Check if cluster folder exists
if [ ! -d "${clusterRoot}" ]; then
    echo "Cluster folder ${cluster} does not exist"
    exit -12
fi

# Display banner
banner="THIS IS A FAST DEPLOYMENT SCRIPT FOR DEVELOPERS!
---
The script shall be running only on fresh local cluster!
After initialization, it uses gitops controlled by installed flux cd controller.
To do some local fine tuning get familiar with flux, kustomize, and kubernetes

Verify that your context is corresponding to your local development cluster:

* Your kubectl context is ${context}.
* You are installing cluster ${cluster}.
* PowerShell version is ${ps_version}.
* Mozilla SOPS version is ${sopsVersion}.
* You got private SOPS key for development setup."
echo "${banner}"

read -p "Are you sure to continue? (y/n) " correct
if [ "${correct}" != "y" ]; then
    echo "Exiting script due to the user selection"
    exit -1
fi

# Function to read a password
read_password() {
    prompt=${1:-"Password"}
    defaultPassword=${2:-""}
    echo -n "${prompt} [${defaultPassword}]: "
    read -s password
    echo
    [ -z "${password}" ] && password=${defaultPassword}
    echo "${password}"
}

# Read SOPS AGE key
agekey=$(read_password "Enter master key of SOPS AGE (for developers)")

# Create namespace
echo "Creating namespace ${namespace}"
kubectl create namespace "${namespace}"
echo "Created namespace ${namespace}"

# Generate AGE key pair and create a secret for it
echo "Creating sops-age private secret in the namespace ${namespace}"
kubectl delete secret sops-age --namespace "${namespace}" 2>/dev/null
kubectl create secret generic sops-age --namespace "${namespace}" --from-literal=age.agekey="${agekey}"
echo "Created sops-age private secret in the namespace ${namespace}"

# Decrypt and create gitops-repo secret
patSecret="${clusterRoot}/secrets/params/repository-pat.env"
if [ ! -f "${patSecret}" ]; then
    patSecret="${clusterRoot}/../localhost/secrets/params/gitops-repo.env"
    if [ ! -f "${patSecret}" ]; then
        echo "gitops-repo secret not found in ${clusterRoot}/secrets/params/gitops-repo.env or ${clusterRoot}/../localhost/secrets/params/gitops-repo.env"
        exit -13
    fi
fi

oldKey=${SOPS_AGE_KEY}
export SOPS_AGE_KEY=${agekey}
envs=$(sops --decrypt ${patSecret})
if [ $? -ne 0 ]; then
    echo "Failed to decrypt gitops-repo secret"
    exit -14
fi

username=$(echo "${envs}" | grep '^username=' | cut -d '=' -f2)
password=$(echo "${envs}" | grep '^password=' | cut -d '=' -f2)
export SOPS_AGE_KEY="${oldKey}"
agekey=""

kubectl delete secret repository-pat --namespace ${namespace} 2>/dev/null
kubectl create secret generic repository-pat \
  --namespace ${namespace} \
  --from-literal username=${username} \
  --from-literal password=${password}

username=""
password=""
echo "Created gitops-repo secret in the namespace ${namespace}"

# Install Flux if requested
if [ "${installFlux}" = true ]; then
    echo "Deploying the Flux CD controller"
    kubectl apply -k ${ProjectRoot}/infrastructure/fluxcd --wait
    if [ $? -ne 0 ]; then
        echo "Failed to deploy fluxcd"
        exit -15
    fi
    echo "Flux CD controller deployed"
fi

# Deploy the cluster manifests
echo "Deploying the cluster manifests"
kubectl apply -k ${clusterRoot} --wait
echo "Bootstrapping process is done, check the status of the GitRepository and Kustomization resource in namespace ${namespace} for reconciliation updates"
