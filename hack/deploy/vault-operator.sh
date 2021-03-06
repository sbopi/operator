#!/bin/bash
set -eou pipefail

crds=(
  vaultservers
  vaultserverversions
)
apiServices=(v1alpha1.admission)

echo "checking kubeconfig context"
kubectl config current-context || {
  echo "Set a context (kubectl use-context <context>) out of the following:"
  echo
  kubectl config get-contexts
  exit 1
}
echo ""

# http://redsymbol.net/articles/bash-exit-traps/
function cleanup() {
  rm -rf $ONESSL ca.crt ca.key server.crt server.key
}
trap cleanup EXIT

# ref: https://github.com/appscodelabs/libbuild/blob/master/common/lib.sh#L55
inside_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
  inside_git=$?
  if [ "$inside_git" -ne 0 ]; then
    echo "Not inside a git repository"
    exit 1
  fi
}

detect_tag() {
  inside_git_repo

  # http://stackoverflow.com/a/1404862/3476121
  git_tag=$(git describe --exact-match --abbrev=0 2>/dev/null || echo '')

  commit_hash=$(git rev-parse --verify HEAD)
  git_branch=$(git rev-parse --abbrev-ref HEAD)
  commit_timestamp=$(git show -s --format=%ct)

  if [ "$git_tag" != '' ]; then
    TAG=$git_tag
    TAG_STRATEGY='git_tag'
  elif [ "$git_branch" != 'master' ] && [ "$git_branch" != 'HEAD' ] && [[ "$git_branch" != release-* ]]; then
    TAG=$git_branch
    TAG_STRATEGY='git_branch'
  else
    hash_ver=$(git describe --tags --always --dirty)
    TAG="${hash_ver}"
    TAG_STRATEGY='commit_hash'
  fi

  export TAG
  export TAG_STRATEGY
  export git_tag
  export git_branch
  export commit_hash
  export commit_timestamp
}

# https://stackoverflow.com/a/677212/244009
if [ -x "$(command -v onessl)" ]; then
  export ONESSL=onessl
else
  # ref: https://stackoverflow.com/a/27776822/244009
  case "$(uname -s)" in
    Darwin)
      curl -fsSL -o onessl https://github.com/kubepack/onessl/releases/download/0.7.0/onessl-darwin-amd64
      chmod +x onessl
      export ONESSL=./onessl
      ;;

    Linux)
      curl -fsSL -o onessl https://github.com/kubepack/onessl/releases/download/0.7.0/onessl-linux-amd64
      chmod +x onessl
      export ONESSL=./onessl
      ;;

    CYGWIN* | MINGW32* | MSYS*)
      curl -fsSL -o onessl.exe https://github.com/kubepack/onessl/releases/download/0.7.0/onessl-windows-amd64.exe
      chmod +x onessl.exe
      export ONESSL=./onessl.exe
      ;;
    *)
      echo 'other OS'
      ;;
  esac
fi

# ref: https://stackoverflow.com/a/7069755/244009
# ref: https://jonalmeida.com/posts/2013/05/26/different-ways-to-implement-flags-in-bash/
# ref: http://tldp.org/LDP/abs/html/comparison-ops.html

export VAULT_OPERATOR_NAMESPACE=kube-system
export VAULT_OPERATOR_SERVICE_ACCOUNT=vault-operator
export VAULT_OPERATOR_RUN_ON_MASTER=0
export VAULT_OPERATOR_ENABLE_VALIDATING_WEBHOOK=false
export VAULT_OPERATOR_ENABLE_MUTATING_WEBHOOK=false
export VAULT_OPERATOR_CATALOG=${VAULT_OPERATOR_CATALOG:-all}
export VAULT_OPERATOR_DOCKER_REGISTRY=kubevault
export VAULT_OPERATOR_IMAGE_TAG=canary
export VAULT_OPERATOR_IMAGE_PULL_SECRET=
export VAULT_OPERATOR_IMAGE_PULL_POLICY=IfNotPresent
export VAULT_OPERATOR_ENABLE_ANALYTICS=true
export VAULT_OPERATOR_UNINSTALL=0
export VAULT_OPERATOR_PURGE=0
export VAULT_OPERATOR_ENABLE_STATUS_SUBRESOURCE=false

export APPSCODE_ENV=${APPSCODE_ENV:-prod}
export SCRIPT_LOCATION="curl -fsSL https://raw.githubusercontent.com/kubevault/operator/master/"
if [ "$APPSCODE_ENV" = "dev" ]; then
  detect_tag
  export SCRIPT_LOCATION="cat "
  export VAULT_OPERATOR_IMAGE_TAG=$TAG
  export VAULT_OPERATOR_IMAGE_PULL_POLICY=Always
fi

KUBE_APISERVER_VERSION=$(kubectl version -o=json | $ONESSL jsonpath '{.serverVersion.gitVersion}')
$ONESSL semver --check='<1.9.0' $KUBE_APISERVER_VERSION || {
  export VAULT_OPERATOR_ENABLE_VALIDATING_WEBHOOK=true
  export VAULT_OPERATOR_ENABLE_MUTATING_WEBHOOK=false
}
$ONESSL semver --check='<1.11.0' $KUBE_APISERVER_VERSION || { export VAULT_OPERATOR_ENABLE_STATUS_SUBRESOURCE=true; }

show_help() {
  echo "vault-operator.sh - install Vault operator"
  echo " "
  echo "vault-operator.sh [options]"
  echo " "
  echo "options:"
  echo "-h, --help                         show brief help"
  echo "-n, --namespace=NAMESPACE          specify namespace (default: kube-system)"
  echo "    --docker-registry              docker registry used to pull Vault images (default: kubevault)"
  echo "    --image-pull-secret            name of secret used to pull Vault images"
  echo "    --run-on-master                run Vault operator on master"
  echo "    --enable-validating-webhook    enable/disable validating webhooks for Vault operator"
  echo "    --enable-mutating-webhook      enable/disable mutating webhooks for Vault operator"
  echo "    --enable-status-subresource    If enabled, uses status sub resource for crds"
  echo "    --enable-analytics             send usage events to Google Analytics (default: true)"
  echo "    --install-catalog              installs Vault server version catalog (default: all)"
  echo "    --uninstall                    uninstall Vault operator"
  echo "    --purge                        purges Vault operator crd objects and crds"
}

while test $# -gt 0; do
  case "$1" in
    -h | --help)
      show_help
      exit 0
      ;;
    -n)
      shift
      if test $# -gt 0; then
        export VAULT_OPERATOR_NAMESPACE=$1
      else
        echo "no namespace specified"
        exit 1
      fi
      shift
      ;;
    --namespace*)
      export VAULT_OPERATOR_NAMESPACE=$(echo $1 | sed -e 's/^[^=]*=//g')
      shift
      ;;
    --docker-registry*)
      export VAULT_OPERATOR_DOCKER_REGISTRY=$(echo $1 | sed -e 's/^[^=]*=//g')
      shift
      ;;
    --image-pull-secret*)
      secret=$(echo $1 | sed -e 's/^[^=]*=//g')
      export VAULT_OPERATOR_IMAGE_PULL_SECRET="name: '$secret'"
      shift
      ;;
    --enable-validating-webhook*)
      val=$(echo $1 | sed -e 's/^[^=]*=//g')
      if [ "$val" = "false" ]; then
        export VAULT_OPERATOR_ENABLE_VALIDATING_WEBHOOK=false
      fi
      shift
      ;;
    --enable-mutating-webhook*)
      val=$(echo $1 | sed -e 's/^[^=]*=//g')
      if [ "$val" = "false" ]; then
        export VAULT_OPERATOR_ENABLE_MUTATING_WEBHOOK=false
      fi
      shift
      ;;
    --enable-status-subresource*)
      val=$(echo $1 | sed -e 's/^[^=]*=//g')
      if [ "$val" = "false" ]; then
        export VAULT_OPERATOR_ENABLE_STATUS_SUBRESOURCE=false
      fi
      shift
      ;;
    --enable-analytics*)
      val=$(echo $1 | sed -e 's/^[^=]*=//g')
      if [ "$val" = "false" ]; then
        export VAULT_OPERATOR_ENABLE_ANALYTICS=false
      fi
      shift
      ;;
    --install-catalog*)
      shift
      val=$(echo $1 | sed -e 's/^[^=]*=//g')
      if [ "$val" = "false" ]; then
        export VAULT_OPERATOR_CATALOG=false
      fi
      ;;
    --run-on-master)
      export VAULT_OPERATOR_RUN_ON_MASTER=1
      shift
      ;;
    --uninstall)
      export VAULT_OPERATOR_UNINSTALL=1
      shift
      ;;
    --purge)
      export VAULT_OPERATOR_PURGE=1
      shift
      ;;
    *)
      echo "Error: unknown flag:" $1
      show_help
      exit 1
      ;;
  esac
done

if [ "$VAULT_OPERATOR_UNINSTALL" -eq 1 ]; then
  # delete webhooks and apiservices
  kubectl delete validatingwebhookconfiguration -l app=vault-operator || true
  kubectl delete mutatingwebhookconfiguration -l app=vault-operator || true
  kubectl delete apiservice -l app=vault-operator
  # delete Vault operator
  kubectl delete deployment -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE
  kubectl delete service -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE
  kubectl delete secret -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE
  # delete RBAC objects, if --rbac flag was used.
  kubectl delete serviceaccount -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE
  kubectl delete clusterrolebindings -l app=vault-operator
  kubectl delete clusterrole -l app=vault-operator
  kubectl delete rolebindings -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE
  kubectl delete role -l app=vault-operator --namespace $VAULT_OPERATOR_NAMESPACE

  echo "waiting for Vault operator pod to stop running"
  for (( ; ; )); do
    pods=($(kubectl get pods --namespace $VAULT_OPERATOR_NAMESPACE -l app=vault-operator -o jsonpath='{range .items[*]}{.metadata.name} {end}'))
    total=${#pods[*]}
    if [ $total -eq 0 ]; then
      break
    fi
    sleep 2
  done

  # https://github.com/kubernetes/kubernetes/issues/60538
  if [ "$VAULT_OPERATOR_PURGE" -eq 1 ]; then
    for crd in "${crds[@]}"; do
      pairs=($(kubectl get ${crd}.kubevault.com --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace} {end}' || true))
      total=${#pairs[*]}

      # save objects
      if [ $total -gt 0 ]; then
        echo "dumping ${crd} objects into ${crd}.yaml"
        kubectl get ${crd}.kubevault.com --all-namespaces -o yaml >${crd}.yaml
      fi

      for ((i = 0; i < $total; i++)); do
        name=${pairs[$i]}
        namespace="default"
        if [ ${#crd} -lt 8 ] || [ ${crd: -8} != "versions" ]; then
          namespace=${pairs[$i + 1]}
          i+=1
        fi
        # remove finalizers
        kubectl patch ${crd}.kubevault.com $name -n $namespace -p '{"metadata":{"finalizers":[]}}' --type=merge || true
        # delete crd object
        echo "deleting ${crd} $namespace/$name"
        kubectl delete ${crd}.kubevault.com $name -n $namespace --ignore-not-found=true
      done

      # delete crd
      kubectl delete crd ${crd}.kubevault.com --ignore-not-found=true
    done

    # delete user roles
    kubectl delete clusterroles kubevault:core:edit kubevault:core:view --ignore-not-found=true
  fi

  echo
  echo "Successfully uninstalled Vault operator!"
  exit 0
fi

echo "checking whether extended apiserver feature is enabled"
$ONESSL has-keys configmap --namespace=kube-system --keys=requestheader-client-ca-file extension-apiserver-authentication || {
  echo "Set --requestheader-client-ca-file flag on Kubernetes apiserver"
  exit 1
}
echo ""

export KUBE_CA=
export VAULT_OPERATOR_ENABLE_APISERVER=false
if [ "$VAULT_OPERATOR_ENABLE_VALIDATING_WEBHOOK" = true ] || [ "$VAULT_OPERATOR_ENABLE_MUTATING_WEBHOOK" = true ]; then
  $ONESSL get kube-ca >/dev/null 2>&1 || {
    echo "Admission webhooks can't be used when kube apiserver is accesible without verifying its TLS certificate (insecure-skip-tls-verify : true)."
    echo
    exit 1
  }
  export KUBE_CA=$($ONESSL get kube-ca | $ONESSL base64)
  export VAULT_OPERATOR_ENABLE_APISERVER=true
fi

env | sort | grep VAULT_OPERATOR*
echo ""

# create necessary TLS certificates:
# - a local CA key and cert
# - a webhook server key and cert signed by the local CA
$ONESSL create ca-cert
$ONESSL create server-cert server --domains=vault-operator.$VAULT_OPERATOR_NAMESPACE.svc
export SERVICE_SERVING_CERT_CA=$(cat ca.crt | $ONESSL base64)
export TLS_SERVING_CERT=$(cat server.crt | $ONESSL base64)
export TLS_SERVING_KEY=$(cat server.key | $ONESSL base64)

${SCRIPT_LOCATION}hack/deploy/operator.yaml | $ONESSL envsubst | kubectl apply -f -

${SCRIPT_LOCATION}hack/deploy/service-account.yaml | $ONESSL envsubst | kubectl apply -f -
${SCRIPT_LOCATION}hack/deploy/rbac-list.yaml | $ONESSL envsubst | kubectl auth reconcile -f -
${SCRIPT_LOCATION}hack/deploy/user-roles.yaml | $ONESSL envsubst | kubectl auth reconcile -f -

if [ "$VAULT_OPERATOR_RUN_ON_MASTER" -eq 1 ]; then
  kubectl patch deploy vault-operator -n $VAULT_OPERATOR_NAMESPACE \
    --patch="$(${SCRIPT_LOCATION}hack/deploy/run-on-master.yaml)"
fi

if [ "$VAULT_OPERATOR_ENABLE_VALIDATING_WEBHOOK" = true ]; then
  ${SCRIPT_LOCATION}hack/deploy/validating-webhook.yaml | $ONESSL envsubst | kubectl apply -f -
fi

if [ "$VAULT_OPERATOR_ENABLE_MUTATING_WEBHOOK" = true ]; then
  ${SCRIPT_LOCATION}hack/deploy/mutating-webhook.yaml | $ONESSL envsubst | kubectl apply -f -
fi

echo
echo "waiting until Vault operator deployment is ready"
$ONESSL wait-until-ready deployment vault-operator --namespace $VAULT_OPERATOR_NAMESPACE || {
  echo "Vault operator deployment failed to be ready"
  exit 1
}

if [ "$VAULT_OPERATOR_ENABLE_APISERVER" = true ]; then
  echo "waiting until Vault operator apiservice is available"
  for api in "${apiServices[@]}"; do
    $ONESSL wait-until-ready apiservice ${api}.kubevault.com || {
      echo "Vault operator apiservice $api failed to be ready"
      exit 1
    }
  done
fi

echo "waiting until Vault operator crds are ready"
for crd in "${crds[@]}"; do
  $ONESSL wait-until-ready crd ${crd}.kubevault.com || {
    echo "$crd crd failed to be ready"
    exit 1
  }
done

if [ "$VAULT_OPERATOR_CATALOG" = "all" ] || [ "$VAULT_OPERATOR_CATALOG" = "vaultserver" ]; then
  echo "installing Vault server catalog"
  ${SCRIPT_LOCATION}hack/deploy/catalog/vaultserver.yaml | $ONESSL envsubst | kubectl apply -f -
fi

echo
echo "Successfully installed Vault operator in $VAULT_OPERATOR_NAMESPACE namespace!"
