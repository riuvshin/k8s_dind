#!/bin/bash

set -e


up() {
    echo "[k8s] starting k8s dind cluster"
    docker run -d --privileged --shm-size 8G --name=k8s_dind -v /var/run/docker.sock:/var/run/docker.sock -v $K8S_STORAGE_PATH:/tmp -p 30000:30000 -p 8443:8443 -p 80:80 --rm riuvshin/minikube-dind:latest
    wait_k8s
    enable_ingress_addon
    install_helm
    get_che_helm_charts
    create_tiller_sa
    deploy_che_with_helm
}

stop() {
    docker rm -f k8s_dind >/dev/null 2>&1
    echo "[k8s] k8s dind cluster stopped"
}

is_booted() {
    k8s_dashboard_http_status=$(curl -s -o /dev/null -I -w "%{http_code}" "${IP}:30000")
    RET_VAL=1
    if [ "${k8s_dashboard_http_status}" == "200" ]; then
        RET_VAL=0
    fi
    return $RET_VAL
}

wait_k8s() {
    K8S_BOOT_TIMEOUT=300
    echo -n "[k8s] wait for k8s full boot"
    ELAPSED=0
    until is_booted; do
        if [ ${ELAPSED} -eq "${K8S_BOOT_TIMEOUT}" ];then
            echo -e "\n[k8s] k8s didn't started in $K8S_BOOT_TIMEOUT secs, exit"
            stop
            exit 1
        fi
        echo -n "."
        sleep 2
        ELAPSED=$((ELAPSED+1))
    done
    echo "Done!"
}

enable_ingress_addon() {
    echo -n "[k8s] enable ingress addon, "
    docker exec -i k8s_dind bash -c "./minikube addons enable ingress"
    #TODO replace with actuall check of ingress
    echo -n "[k8s] wait ingress available"
    for i in {1..30}; do
        echo -n "."
        sleep 1
    done
    echo "Done!"
}

che_server_is_booted() {
  PING_URL="che-che.${IP}.${DNS_PROVIDER}"
  HTTP_STATUS_CODE=$(curl -I -k "${PING_URL}/api/" -s -o /dev/null --write-out '%{http_code}')
  if [[ "${HTTP_STATUS_CODE}" = "200" ]] || [[ "${HTTP_STATUS_CODE}" = "302" ]]; then
    return 0
  else
    return 1
  fi
}

wait_until_server_is_booted() {
  SERVER_BOOT_TIMEOUT=500
  echo -n "[CHE] wait CHE pod booting..."
  ELAPSED=0
  until che_server_is_booted; do
    if [ ${ELAPSED} -eq "${SERVER_BOOT_TIMEOUT}" ]; then
        echo ""
        echo "[CHE] server didn't boot in $SERVER_BOOT_TIMEOUT sec, stopping..."
        stop
        exit 1
    fi
    echo -n "."
    sleep 1
    ELAPSED=$((ELAPSED+1))
  done
  echo "Done!"
  echo "[CHE] http://che-che.${IP}.${DNS_PROVIDER}"
}

detectIP() {
    docker run --rm --net host eclipse/che-ip:nightly
}

install_helm() {
    echo "[k8s] install helm"
    docker exec -i k8s_dind bash -c "curl -s -LO https://storage.googleapis.com/kubernetes-helm/helm-v2.9.0-linux-amd64.tar.gz >/dev/null && tar -zxvf helm-v2.9.0-linux-amd64.tar.gz >/dev/null && mv linux-amd64/helm /usr/local/bin/helm >/dev/null"
}

get_che_helm_charts() {
    echo "[k8s] get CHE helm charts"
    docker exec -i k8s_dind bash -c "apt-get -qq update &>/dev/null && apt-get -qq install git -y &>/dev/null"
    docker exec -i k8s_dind bash -c "cd /tmp/ && git clone --depth 1 https://github.com/eclipse/che.git che &>/dev/null"
}

create_tiller_sa() {
    echo "[k8s] create tiller SA"
    docker exec -i k8s_dind bash -c "kubectl create serviceaccount tiller --namespace kube-system && sleep 20 && kubectl apply -f /tmp/che/deploy/kubernetes/helm/che/tiller-rbac.yaml &>/dev/null && sleep 20 && helm init --service-account tiller &>/dev/null"
    #todo wait tiller pod
    sleep 60
}

deploy_che_with_helm() {
    echo "[k8s] deploying CHE, multiuser mode: ${CHE_MULTIUSER}"
    if [ "${CHE_MULTIUSER}" == "false" ];then
        docker exec -i k8s_dind bash -c "helm upgrade --install che --namespace che --set global.ingressDomain=${IP}.${DNS_PROVIDER} --set global.gitHubClientID=${CHE_OAUTH_GITHUB_CLIENTID} --set global.gitHubClientSecret=${CHE_OAUTH_GITHUB_CLIENTSECRET} /tmp/che/deploy/kubernetes/helm/che >/dev/null"
    else
        docker exec -i k8s_dind bash -c "kubectl create clusterrolebinding add-on-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:default"
        sleep 20
        docker exec -i k8s_dind bash -c "helm upgrade --install che --namespace che -f /tmp/che/deploy/kubernetes/helm/che/values/multi-user.yaml --set global.ingressDomain=${IP}.${DNS_PROVIDER} /tmp/che/deploy/kubernetes/helm/che"
    fi
    wait_until_server_is_booted
}

LOCAL_IP_ADDRESS=$(detectIP)
DNS_PROVIDER=${DNS_PROVIDER:-"nip.io"}
IP=${IP:-${LOCAL_IP_ADDRESS}}
CHE_MULTIUSER=${CHE_MULTIUSER:-"false"}
K8S_STORAGE_PATH=${K8S_STORAGE_PATH:-"~/k8s_dind_storage"}
$@
