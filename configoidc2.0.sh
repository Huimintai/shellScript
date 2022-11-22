#!/usr/bin/env bash
#set -x

CA_CRT=""
SECRET_ID=""
SECRET_KEY=""
ENDPOINT=""
REGION=""
MASTER_ID=""
USER_NAME=""
ISSUER_URL=""
HOSTNAMES=""
HOSTNAMES=""
VIP=""

function getstr() {
  kubectl get cm oidc-config -n tke
  if [ $? -ne 0 ]; then
    echo "creating oidc-config configmap for persistent oidc value in tkeanywhere ..."
    kubectl create cm oidc-config -n tke --from-file=./oidc.json
  fi
  kubectl get cm oidc-config -n tke -ojson > oidccm.json
  str=`cat oidccm.json | python -c "import json; import sys; obj=json.load(sys.stdin); print json.dumps(obj['data']['oidc.json'])"`
  CA_CRT=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['ca.crt']")\"
  SECRET_ID=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['secret_id']")\"
  SECRET_KEY=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['secret_key']")\"
  ENDPOINT=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['endpoint']")\"
  REGION=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['region']")\"
  MASTER_ID=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['master_id']")\"
  USER_NAME=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['username']")\"
  ISSUER_URL=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['issuer_url']")\"
  HOSTNAMES="$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['hostnames']")
  VIP=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['vip']")\"
}



// kubectl create cm  持久化
CA_CRT=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['ca.crt']")\"
SECRET_ID=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['secret_id']")\"
SECRET_KEY=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['secret_key']")\"
ENDPOINT=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['endpoint']")\"
REGION=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['region']")\"
MASTER_ID=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['master_id']")\"
USER_NAME=$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['username']")
ISSUER_URL=\"$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['issuer_url']")\"
HOSTNAMES=$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print json.dumps(obj['hostnames'])")
HOSTNAMES=$(echo "$HOSTNAMES" | sed -e "s/^\[//" -e "s/\]$//")
VIP=$(cat oidc.json | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['vip']")

function backup() {
  api=$(kubectl -n tke get -o=name deployment | grep api)
  cm=$(kubectl -n tke get -o=name configmap | grep api)
  gw=$(kubectl -n tke get -o=name configmap | grep gateway)
  ds=$(kubectl -n tke get -o=name daemonset | grep gateway)
  r=("$api $cm $ds $gw")
  echo ======= backup current resources =======
  dir=/opt/oidcbackup
  mkdir -p ${dir}/deployment.apps ${dir}/daemonset.apps ${dir}/configmap
  for n in $r; do
    kubectl -n tke get -o=yaml $n >${dir}/$n.yaml
  done
}

function createcms() {
  # create oidc-ca configmap
  kubectl create cm oidc-ca -n tke --from-file=$CA_CRT
  # create cloudindustry-config configmap
  cat <<EOF | kubectl apply -f -
kind: ConfigMap
metadata:
  name: cloudindustry-config
  namespace: tke
apiVersion: v1
data:
  config: |
    {
        "secret_id": $SECRET_ID,
        "secret_key": $SECRET_KEY,
        "endpoint": $ENDPOINT,
        "region":$REGION,
        "master_id":$MASTER_ID
    }
EOF
}

function createOIDCAuthCMTmpFile() {
  content=$(
    cat <<EOF
\n
[authentication.oidc]\n
client_secret = $SECRET_KEY\n
client_id = $SECRET_ID\n
issuer_url = $ISSUER_URL\n
ca_file = "/app/certs/ca.crt"\n
username_prefix ="-"\n
username_claim = "name"\n
groups_claim = "groups"\n
tenantid_claim = "federated_claims"
EOF
  )
  echo -e $content >oidc_auth_tmp.txt
  sed -i 's/^/     /g' oidc_auth_tmp.txt
  sed -i '1d' oidc_auth_tmp.txt
  sed -i '1{x;p;x;}' oidc_auth_tmp.txt
}

function removeOIDCAuthCMTmpFile() {
  rm oidc_auth_tmp.txt
}

function modifyConfigMap() {
  echo ======= modify configmap $1 =======
  file=./$1-cm.yaml
  kubectl -n tke get cm $1 -o yaml >$file

  start=$(sed -n '/last-applied-configuration/=' $file)
  if [ "$start" != "" ]; then
    end=$(($start + 1))
    sed -i "$start, $end d" $file
  fi

  if [ "$1" = "tke-auth-api" ]; then
    line=$(sed -n '/authentication.oidc/=' $file)
    if [ "$line" = "" ]; then
      sed -i "/privileged_username/r oidc_auth_tmp.txt" $file
    fi
    line=$(sed -n '/init_tenant_type/=' $file)
    if [ "$line" = "" ]; then
      sed -i '/assets_path/a\    init_tenant_type = "cloudindustry"' $file
    fi
    line=$(sed -n '/init_tenant_id/=' $file)
    if [ "$line" = "" ]; then
      sed -i '/assets_path/a\    init_tenant_id = "default"' $file
    fi
    line=$(sed -n '/cloudindustry_config_file/=' $file)
    if [ "$line" = "" ]; then
      sed -i '/assets_path/a\    cloudindustry_config_file = "/app/cloudindustry/config"' $file
    fi

    line=$(sed -n '/init_client_id/=' $file)
    if [ "$line" != "" ]; then
      sed -i "${line}c \ \ \ \ init_client_id = ${SECRET_ID}" $file
    fi
    line=$(sed -n '/init_client_secret/=' $file)
    if [ "$line" != "" ]; then
      sed -i "${line}c \ \ \ \ init_client_secret = ${SECRET_KEY}" $file
    fi
  else
    sed -i '/external_issuer_url/d' $file

    sed -i '/client_secret/d' $file
    sed -i "/authentication.oidc/a\      client_secret = ${SECRET_KEY}" $file

    sed -i '/client_id/d' $file
    sed -i "/authentication.oidc/a\      client_id = ${SECRET_ID}" $file

    sed -i '/issuer_url/d' $file
    sed -i "/authentication.oidc/a\      issuer_url = ${ISSUER_URL}" $file
  fi

  sed -i '/resourceVersion/d' $file
  sed -i '/uid/d' $file
  kubectl apply -f $file
  rm $file
}

function createOIDCVolumeTmpFiles() {
  cat >>./oidc_volumeMounts_tmp.txt <<EOF
        - mountPath: /app/oidc
          name: oidc-ca-volume
        - mountPath: /app/cloudindustry
          name: cloudindustry-config-volume
EOF

  cat >>./oidc_volumes_tmp.txt <<EOF
      - configMap:
          defaultMode: 420
          name: oidc-ca
        name: oidc-ca-volume
      - configMap:
          defaultMode: 420
          name: cloudindustry-config
        name: cloudindustry-config-volume
EOF
}

function removeOIDCVolumeTmpFiles() {
  rm oidc_volumeMounts_tmp.txt
  rm oidc_volumes_tmp.txt
}
//值为空，不配置
function createOIDCHostAliasTmpFile() {
  file=oidc_hostAlias_tmp.txt
  rm -rf $file

  echo "      hostAliases:" >>$file
  echo "      - hostnames:" >>$file
  # shellcheck disable=SC2068
  for name in ${HOSTNAMES[@]}; do
    #    remove ','
    name=$(echo "$name" | sed -e "s/,$//")
    #    remove '"'
    name=$(echo "$name" | sed -e "s/^\"//" -e "s/\"$//")
    echo "****** ${name}"
    echo "        - ${name}" >>$file
  done
  echo "        ip: ${VIP}" >>$file
}

function rmOIDCHostAliasTmpFile() {
  rm oidc_hostAlias_tmp.txt
}

function modifyResource() {
  echo ======= modify $1 $2 =======
  file=./$2-$1.yaml

  kubectl -n tke annotate $1 $2 "oidc=true" key参照之前的annotation修改
  kubectl -n tke get $1 $2 -o yaml >$file

  start=$(sed -n '/last-applied-configuration/=' $file)
  if [ "$start" != "" ]; then
    end=$(($start + 1))
    sed -i "$start, $end d" $file
  fi
  //值为空不配置
  line=$(sed -n '/hostAliases/=' $file)
  if [ "$line" = "" ]; then
    sed -i "/dnsPolicy/r oidc_hostAlias_tmp.txt" $file
  fi

  line=$(sed -n '/oidc-ca-volume/=' $file)
  if [ "$line" = "" ]; then
    sed -i "/volumes/r oidc_volumes_tmp.txt" $file
    sed -i "/volumeMounts/r oidc_volumeMounts_tmp.txt" $file
  fi

  line=$(sed -n '/hostAliases/=' $file)
  if [ "$line" = "" ]; then
    sed -i "/dnsPolicy/r oidc_hostAlias_tmp.txt" $file
  fi

  kubectl apply -f $file
  rm $file
}
// 云上交付是否有对应的资源
function adduser() {
  kubectl get platforms.business.tkestack.io platform-default -oyaml > default.yaml
  sed -i "/- admin/a\  - ${USER_NAME}" default.yaml
  kubectl apply -f default.yaml
}

function configall() {
  createOIDCAuthCMTmpFile
  modifyConfigMap tke-gateway

  for cm in $(kubectl get cm -n tke -o=name | grep api | awk '{print $1}' | awk -F '/' '{print $2}'); do
    modifyConfigMap $cm
  done

  kubectl delete idp default
  removeOIDCAuthCMTmpFile

  createOIDCVolumeTmpFiles
  createOIDCHostAliasTmpFile
  for deploy in $(kubectl get deployment -n tke -o=name | grep api | awk '{print $1}' | awk -F '/' '{print $2}'); do
    modifyResource deploy $deploy
  done

  modifyResource daemonset tke-gateway
  removeOIDCVolumeTmpFiles
  rmOIDCHostAliasTmpFile
}

backup
createcms
configall
adduser

