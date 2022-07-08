#!/bin/bash
#
# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not installed. Aborting."; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "oc cli is not installed. Aborting."; exit 1; }

export MY_GIT_FORK_REMOTE="qe"
export MY_GITHUB_ORG=${GITHUB_E2E_ORGANIZATION:-"redhat-appstudio-qe"}
export MY_GITHUB_TOKEN="${GITHUB_TOKEN}"
export TEST_BRANCH_ID=$(date +%s)
export ROOT_E2E="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/..
export WORKSPACE=${WORKSPACE:-${ROOT_E2E}}
export E2E_APPLICATIONS_NAMESPACE=${E2E_APPLICATIONS_NAMESPACE:-appstudio-e2e-test}
export SHARED_SECRET_NAMESPACE="build-templates"

# Environment variable used to override the default "protected" image repository in HAS
# https://github.com/redhat-appstudio/application-service/blob/6b9d21b8f835263b2e92f1e9343a1453caa2e561/gitops/generate_build.go#L50
# Users are allowed to push images to this repo only in case the image contains a tag that consists of "<USER'S_NAMESPACE_NAME>-<CUSTOM-TAG>"
# For example: "quay.io/redhat-appstudio-qe/test-images-protected:appstudio-e2e-test-mytag123"
export HAS_DEFAULT_IMAGE_REPOSITORY="quay.io/${QUAY_E2E_ORGANIZATION:-redhat-appstudio-qe}/test-images-protected"

# Path to install openshift-ci tools
export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

function installCITools() {
    curl -H "Authorization: token $GITHUB_TOKEN" -LO https://github.com/mikefarah/yq/releases/download/v4.20.2/yq_linux_amd64 && \
    chmod +x ./yq_linux_amd64 && \
    mv ./yq_linux_amd64 /tmp/bin/yq && \
    yq --version
}

# Download gitops repository to install AppStudio in e2e mode.
function cloneInfraDeployments() {
    git clone https://$GITHUB_TOKEN@github.com/redhat-appstudio/infra-deployments.git "$WORKSPACE"/tmp/infra-deployments
}

# Add a custom remote for infra-deployments repository.
function addQERemoteForkAndInstallAppstudio() {
    cd "$WORKSPACE"/tmp/infra-deployments
    git remote add "${MY_GIT_FORK_REMOTE}" https://github.com/"${MY_GITHUB_ORG}"/infra-deployments.git

    # Start AppStudio installation
    /bin/bash hack/bootstrap-cluster.sh preview
    cd "$WORKSPACE"
}

# Add a custom remote for infra-deployments repository.
function initializeSPIVault() {
   curl https://raw.githubusercontent.com/redhat-appstudio/e2e-tests/main/scripts/spi-e2e-setup.sh | bash -s
}

# Secrets used by pipelines to push component containers to quay.io
function createApplicationServiceSecrets() {
    echo -e "[INFO] Creating application-service related secrets in $SHARED_SECRET_NAMESPACE namespace"

    echo "$QUAY_TOKEN" | base64 --decode > docker.config
    kubectl create secret docker-registry redhat-appstudio-user-workload -n $SHARED_SECRET_NAMESPACE --from-file=.dockerconfigjson=docker.config || true
    rm docker.config
}

# Setup Sandbox Operator
function setupSandboxOperator() {
    cd "$WORKSPACE"/tmp/infra-deployments
    /bin/bash hack/sandbox-development-mode.sh
    cd "$WORKSPACE"
}

# Setup MultiClusterEngine Operator
function setupMCEOperator() {
    oc create namespace open-cluster-management
    oc project open-cluster-management
    echo "---
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: open-cluster-management
    spec:
      targetNamespaces:
        - open-cluster-management
    " | oc apply -f - 

    echo "---
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: acm-operator-subscription
    spec:
      sourceNamespace: openshift-marketplace
      source: redhat-operators
      channel: release-2.5
      installPlanApproval: Automatic
      name: advanced-cluster-management
    " | oc apply -f - 

    echo "Waiting 30 seconds before creating the MultiClusterHub..."
    sleep 30 
    while $(oc get subs -n open-cluster-management -o=jsonpath='{.items[0].status.conditions[?(@.type=="CatalogSourcesUnhealthy")].status}') != 'False' ; do
        echo '.'
        sleep 10
    done
    
    echo "---
    apiVersion: operator.open-cluster-management.io/v1
    kind: MultiClusterHub
    metadata:
      name: multiclusterhub
    spec: {}
    " | oc apply -f - 

    echo "Waiting for MCE to be ready..."

    # TBD: need write a proper check to check for multiclusterengines crd availability or next command will fail
    sleep 300

    oc project default

}

# create the secret needed to onboard a managed hub cluster
function onboardManagedHubCluster() {
    # ensure that, on the managed hub, the multiclusterengine CR has the managedserviceaccount-preview enabled
    oc patch multiclusterengine multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"managedserviceaccount-preview","enabled":true}]}}}'
    echo "multiclusterengine CR patched to enable managedserviceaccount-preview"

    # get the kubeconfig of the managed hub cluster and 
    # create the secret in the appstudio cluster using the managed hub cluster kubeconfig 
    # NOTE: this script deploys MCE and AppStudio on the same cluster
    oc create secret generic hub-kubeconfig --from-file=kubeconfig=$KUBECONFIG -n cluster-reg-config
    echo "created secret hub-kubeconfig from kubeconfig file"
}

function startClusterRegistrationController() {

    # create the hub config on the AppStudio cluster
    echo "---
    apiVersion: singapore.open-cluster-management.io/v1alpha1
    kind: HubConfig
    metadata:
      name: multiclusterhub
      namespace: cluster-reg-config
    spec:
      kubeConfigSecretRef:
        name: hub-kubeconfig
    " | oc create -f -

    # create the clusterregistrar on the AppStudio cluster  
    echo "---
    apiVersion: singapore.open-cluster-management.io/v1alpha1
    kind: ClusterRegistrar
    metadata:
      name: cluster-reg
    spec:
    " | oc create -f -
    
    # verify pods are running
}

function setupManagedCluster(){
    BASE_DOMAIN=$( oc get ingresses.config/cluster -o jsonpath={.spec.domain} )
    
    # create the managed cluster namespace  
    oc create namespace managed-cluster

    # create the load balancer to expose vcluster's pod
    echo "---
    apiVersion: v1
    kind: Service
    metadata:
      name: vcluster-loadbalancer
      namespace: managed-cluster
    spec:
      selector:
        app: vcluster
        release: vcluster
      ports:
        - name: https
          port: 443
          targetPort: 8443
          protocol: TCP
      type: LoadBalancer
    " | oc create -f -

    # create the clusterregistrar on the AppStudio cluster  
    echo "---
    apiVersion: route.openshift.io/v1
    kind: Route
    apiVersion: route.openshift.io/v1
    metadata:
      name: vcluster
      namespace: managed-cluster
    spec:
      host: vcluster.$BASE_DOMAIN
      to:
        kind: Service
        name: vcluster-loadbalancer
        weight: 100
      port:
        targetPort: https
      tls:
        termination: passthrough
        insecureEdgeTerminationPolicy: Redirect
      wildcardPolicy: None
    " | oc create -f -

    # create the clusterregistrar on the AppStudio cluster  
    echo "---
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: vcluster
      namespace: openshift-gitops
    spec:
      destination:
        namespace: managed-cluster
        server: https://kubernetes.default.svc
      project: default
      source:
        chart: vcluster
        repoURL: https://charts.loft.sh
        targetRevision: 0.10.2
        helm:  
          values: |
            syncer:
              extraArgs:
                - --tls-san=vcluster.$BASE_DOMAIN
                - --out-kube-config-server=https://vcluster.$BASE_DOMAIN
          syncPolicy:
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true" | oc create -f -

}

while [[ $# -gt 0 ]]
do
    case "$1" in
        install)
            installCITools
            cloneInfraDeployments
            addQERemoteForkAndInstallAppstudio
            createApplicationServiceSecrets
            initializeSPIVault
            setupSandboxOperator
            setupMCEOperator
            onboardManagedHubCluster
            startClusterRegistrationController
            setupManagedCluster
            ;;
        *)
            ;;
    esac
    shift
done
