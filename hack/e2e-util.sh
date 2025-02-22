#!/bin/bash

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export LOG_LEVEL=${TEST_LOG_LEVEL:-2}
export CLEANUP_CLUSTER=${CLEANUP_CLUSTER:-"true"}
export MCAD_DEPLOYMENT_MODE=${MCAD_DEPLOYMENT_MODE:-"unified"}
export MCAD_MULTICLUSTER=${MCAD_MULTICLUSTER:-"false"}
export CLUSTER_CONTEXT="--name test"
export IMAGE_ECHOSERVER="quay.io/project-codeflare/echo-server:1.0"
export IMAGE_UBUNTU_LATEST="quay.io/quay/ubuntu:latest"
export IMAGE_UBI_LATEST="registry.access.redhat.com/ubi8/ubi:latest"
export IMAGE_BUSY_BOX_LATEST="quay.io/project-codeflare/busybox:latest"
export KIND_OPT=${KIND_OPT:=" --config ${ROOT_DIR}/hack/kind-config.yaml"}
export KA_BIN=_output/bin
export WAIT_TIME="20s"
export KUTTL_VERSION=0.15.0
DUMP_LOGS="true"

function update_test_host {

  local arch="$(go env GOARCH)"
  if [ -z $arch ]
  then
    echo "Unable to determine downloads architecture"
    exit 1
  fi
  echo "CPU architecture for downloads is: ${arch}"

  which curl >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "curl not installed, exiting."
    exit 1
  fi

  which kubectl >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
      sudo apt-get install -y --allow-unauthenticated kubectl
      [ $? -ne 0 ] && echo "Failed to install kubectl" && exit 1
      echo "kubectl was sucessfully installed."
  fi

  which kind >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    # Download kind binary (0.19.0)
    echo "Downloading and installing kind...."
    sudo curl -o /usr/local/bin/kind -L https://github.com/kubernetes-sigs/kind/releases/download/v0.19.0/kind-linux-${arch} && \
    sudo chmod +x /usr/local/bin/kind
    [ $? -ne 0 ] && echo "Failed to download kind" && exit 1
    echo "Kind was sucessfully installed."
  fi

  which helm >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    # Installing helm3
    echo "Downloading and installing helm..."
    curl -fsSL -o ${ROOT_DIR}/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 &&
      chmod 700 ${ROOT_DIR}/get_helm.sh && ${ROOT_DIR}/get_helm.sh
    [ $? -ne 0 ] && echo "Failed to download and install helm" && exit 1
    echo "Helm was sucessfully installed."
    rm -rf ${ROOT_DIR}/get_helm.sh
  fi

  kubectl kuttl version >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    if [[ "$arch" == "amd64" ]]
    then
      local kuttl_arch="x86_64"
    else
      local kuttl_arch=$arch
    fi
    # Download kuttl plugin
    echo "Downloading and installing kuttl...."
    sudo curl -sSLf --output /tmp/kubectl-kuttl https://github.com/kudobuilder/kuttl/releases/download/v${KUTTL_VERSION}/kubectl-kuttl_${KUTTL_VERSION}_linux_${kuttl_arch} && \
    sudo mv /tmp/kubectl-kuttl /usr/local/bin && \
    sudo chmod a+x /usr/local/bin/kubectl-kuttl
    [ $? -ne 0 ] && echo "Failed to download and install helm" && exit 1
    echo "Kuttl was sucessfully installed."
  fi
}

# check if pre-requizites are installed.
function check_prerequisites {
  echo "checking prerequisites"
  which kind >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "kind not installed, exiting."
    exit 1
  else
    echo -n "found kind, version: " && kind version
  fi

  which kubectl >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "kubectl not installed, exiting."
    exit 1
  else
    echo -n "found kubectl, " && kubectl version --client
  fi
  kubectl kuttl version >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "kuttl plugin for kubectl not installed, exiting."
    exit 1
  else
    echo -n "found kuttl plugin for kubectl, " && kubectl kuttl version
  fi

  which helm >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "helm not installed, exiting."
    exit 1
  else
    echo -n "found helm, " && helm version --short
  fi
}

function pull_images {
  docker pull ${IMAGE_ECHOSERVER}
  if [ $? -ne 0 ]
  then
    echo "Failed to pull ${IMAGE_ECHOSERVER}"
    exit 1
  fi

  docker pull ${IMAGE_UBUNTU_LATEST}
  if [ $? -ne 0 ]
  then
    echo "Failed to pull ${IMAGE_UBUNTU_LATEST}"
    exit 1
  fi

  docker pull ${IMAGE_UBI_LATEST}
  if [ $? -ne 0 ]
  then
    echo "Failed to pull ${IMAGE_UBI_LATEST}"
    exit 1
  fi

  docker pull ${IMAGE_BUSY_BOX_LATEST}
  if [ $? -ne 0 ]
  then
    echo "Failed to pull ${IMAGE_BUSY_BOX_LATEST}"
    exit 1
  fi

  if [[ "$MCAD_IMAGE_PULL_POLICY" = "Always" ]]
  then
    docker pull ${IMAGE_MCAD}
    if [ $? -ne 0 ]
    then
      echo "Failed to pull ${IMAGE_MCAD}"
      exit 1
    fi
    if [ $? -ne 0 ]
    then
      echo "Failed to pull ${IMAGE_MCAD}"
      exit 1
    fi
  fi
  docker images
}

function kind_up_cluster {
  echo "Running kind: [kind create cluster ${CLUSTER_CONTEXT} ${KIND_OPT}]"
  kind create cluster ${CLUSTER_CONTEXT} ${KIND_OPT} --wait ${WAIT_TIME}
  if [ $? -ne 0 ]
  then
    echo "Failed to start kind cluster"
    exit 1
  fi
  CLUSTER_STARTED="true"

  for image in ${IMAGE_ECHOSERVER} ${IMAGE_UBUNTU_LATEST} ${IMAGE_MCAD} ${IMAGE_UBI_LATEST} ${IMAGE_BUSY_BOX_LATEST}
  do
    kind load docker-image ${image} ${CLUSTER_CONTEXT}
    if [ $? -ne 0 ]
    then
      echo "Failed to load image ${image} in cluster"
      exit 1
    fi
  done
}

function configure_cluster {
  echo "Installing Podgroup CRD"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/scheduler-plugins/277b6bdec18f8a9e9ccd1bfeaf4b66495bfc6f92/config/crd/bases/scheduling.sigs.k8s.io_podgroups.yaml

  echo "Installing high-priority PriorityClass"
  kubectl apply -f $ROOT_DIR/hack/high-priority-class.yaml

  echo "Installing cert-manager"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml

  # Turn off master taints
  kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

  # This is meant to orchestrate initial cluster configuration such that accounting tests can be consistent
  echo "Orchestrate cluster..."
  echo "kubectl cordon test-worker"
  kubectl cordon test-worker
  a=$(kubectl -n kube-system get pods | grep coredns | cut -d' ' -f1)
  for b in $a
  do
    echo "kubectl -n kube-system delete pod $b"
    kubectl -n kube-system delete pod $b
  done
  echo "kubectl uncordon test-worker"
  kubectl uncordon test-worker

  # sleep to allow the pods to restart
  echo "Waiting for pod in the kube-system namespace to become ready"
  while [[ $(kubectl get pods -n kube-system -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | tr ' ' '\n' | sort -u) != "True" ]]
  do
    echo -n "." && sleep 1;
  done

  # sleep to ensure cert-manager is fully functional
  echo "Waiting for pod in the cert-manager namespace to become ready"
  while [[ $(kubectl get pods -n cert-manager -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | tr ' ' '\n' | sort -u) != "True" ]]
  do
    echo -n "." && sleep 1;
  done
}

function add_virtual_GPUs {
    # Patch nodes to provide GPUs resources without physical GPUs.
    # This is intended to allow testing of GPU specific features such as histograms.

    # Start communication with cluster
    kubectl proxy --port=0 > .port.dat 2>&1 &
    proxy_pid=$!

    echo "Starting background proxy connection (pid=${proxy_pid})..."
    echo "Waiting for proxy process to start."
    sleep 5

    kube_proxy_port=$(cat .port.dat | awk '{split($5, substrings, ":"); print substrings[2]}')
    curl -s 127.0.0.1:${kube_proxy_port} > /dev/null 2>&1

    if [[ ! $? -eq 0 ]]; then
        echo "Calling 'kubectl proxy' did not create a successful connection to the kubelet needed to patch the nodes. Exiting."
        kill -9 ${proxy_pid}
        exit 1
    else
        echo "Connected to the kubelet for patching the nodes. Using port ${kube_proxy_port}."
    fi

    rm .port.dat

    # Variables
    resource_name="nvidia.com~1gpu"
    resource_count="8"

    # Patch nodes
    for node_name in $(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
    do
        echo "- Patching node (add): ${node_name}"

        patching_status=$(curl -s --header "Content-Type: application/json-patch+json" \
                                --request PATCH \
                                --data '[{"op": "add", "path": "/status/capacity/'${resource_name}'", "value": "'${resource_count}'"}]' \
                                http://localhost:${kube_proxy_port}/api/v1/nodes/${node_name}/status | jq -r '.status')

        if [[ ${patching_status} == "Failure" ]]; then
            echo "Failed to patch node '${node_name}' with GPU resources"
            exit 1
        fi

        echo "Patching done!"
    done

    # Stop communication with cluster
    echo "Killing proxy (pid=${proxy_pid})..."
    kill -9 ${proxy_pid}

    # Run kuttl test to confirm GPUs were added correctly
    kuttl_test="${ROOT_DIR}/test/e2e-kuttl-extended-resources.yaml"
    echo "kubectl kuttl test --config ${kuttl_test}"
    kubectl kuttl test --config ${kuttl_test}
    if [ $? -ne 0 ]
    then
      echo "kuttl e2e test '${kuttl_test}' failure, exiting."
      exit 1
    fi
}

# clean up
function cleanup {
    echo "==========================>>>>> Cleaning up... <<<<<=========================="
    echo " "
    if [[ ${CLUSTER_STARTED} == "false" ]]
    then
      echo "Cluster was not started, nothing more to do."
      return
    fi

    if [[ ${DUMP_LOGS} == "true" ]]
    then

      echo "Custom Resource Definitions..."
      echo "kubectl get crds"
      kubectl get crds

      echo "---"
      echo "Get All AppWrappers..."
      kubectl get appwrappers --all-namespaces -o yaml

      echo "---"
      echo "Describe all AppWrappers..."
      kubectl describe appwrappers --all-namespaces

      echo "---"
      echo "'test' Pod list..."
      kubectl get pods -n test

      echo "---"
      echo "'test' Pod yaml..."
      kubectl get pods -n test -o yaml

      echo "---"
      echo "'test' Pod descriptions..."
      kubectl describe pods -n test

      echo "---"
      echo "'all' Namespaces  list..."
      kubectl get namespaces

      local mcad_dispatcher_pod=$(kubectl get pods -n mcad-system | grep mcad-controller | grep -v mcad-controller-runner | awk '{print $1}')
      local mcad_runner_pod=$(kubectl get pods -n mcad-system | grep mcad-controller-runner | awk '{print $1}')
      if [[ "$mcad_dispatcher_pod" != "" ]]
      then
        echo "===================================================================================="
        echo "==========================>>>>> MCAD Controller Logs <<<<<=========================="
        echo "===================================================================================="
        echo "kubectl logs ${mcad_dispatcher_pod} -n mcad-system"
        kubectl logs ${mcad_dispatcher_pod} -n mcad-system
      fi
      if [[ "$mcad_runner_pod" != "" ]]
      then
        echo "===================================================================================="
        echo "==========================>>>>> MCAD Runner Logs <<<<<=============================="
        echo "===================================================================================="
        echo "kubectl logs ${mcad_runner_pod} -n mcad-system"
        kubectl logs ${mcad_runner_pod} -n mcad-system
      fi
    fi

    rm -f kubeconfig

    if [[ $CLEANUP_CLUSTER == "true" ]]
    then
      kind delete cluster ${CLUSTER_CONTEXT}
    else
      echo "Cluster requested to stay up, not deleting cluster"
    fi
}

function install_mcad {
    local helm_args=" --install mcad-controller ${ROOT_DIR}/deployment/mcad-controller  --namespace mcad-system --create-namespace --wait"
    helm_args+=" --set deploymentMode=${MCAD_DEPLOYMENT_MODE} --set multicluster=${MCAD_MULTICLUSTER}"
    if [[ ${MCAD_DEPLOYMENT_MODE} == "kueue" ]]
    then
       helm_args+=" --set installKueueCRDs=true --set installMCADCRDs=false"
    else
       helm_args+=" --set installKueueCRDs=false --set installMCADCRDs=true"
    fi
    helm_args+=" --set loglevel=${LOG_LEVEL} --set resources.requests.cpu=500m --set resources.requests.memory=1024Mi"
    helm_args+=" --set resources.limits.cpu=500m --set resources.limits.memory=1024Mi"
    helm_args+=" --set configMap.name=mcad-controller-configmap --set configMap.podCreationTimeout='"120000"'"
    helm_args+=" --set configMap.quotaEnabled='"false"' --set coscheduler.rbac.apiGroup=scheduling.sigs.k8s.io"
    helm_args+=" --set coscheduler.rbac.resource=podgroups --set image.repository=$IMAGE_REPOSITORY_MCAD"
    helm_args+=" --set image.tag=$IMAGE_TAG_MCAD --set image.pullPolicy=$MCAD_IMAGE_PULL_POLICY"

    echo "helm upgrade $helm_args"
    helm upgrade $helm_args
    if [ $? -ne 0 ]
    then
      echo "Failed to deploy MCAD controller"
      exit 1
    fi
    echo "Filtered CRD inventory:"
    kubectl get crds | grep workload.codeflare.dev
    if [[ ${MCAD_DEPLOYMENT_MODE} == "kueue" ]]
    then
        kubectl get crds | grep kueue.x-k8s.io
    fi
}

function run_kuttl_test_suite {
  for kuttl_test in ${KUTTL_TEST_SUITES[@]}; do
    echo "kubectl kuttl test --config ${kuttl_test}"
    kubectl kuttl test --config ${kuttl_test}
    if [ $? -ne 0 ]
    then
      echo "kuttl e2e test '${kuttl_test}' failure, exiting."
      exit 1
    fi
  done
}
