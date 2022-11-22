#!/usr/bin/env bash
#set -x

function setConfigEnvs() {
  kubectl get cm oidc-config -n tke

  if [ $? -ne 0 ]; then
    echo "creating oidc-config configmap for persistent oidc value in tke anywhere ..."
    sed -i s/[[:space:]]//g oidc_cfg # 删除所有空格
    kubectl create cm oidc-config -n tke --from-file=./oidc_cfg
  else
    kubectl get cm oidc-config -n tke -ojson | python -c "import json; import sys; obj=json.load(sys.stdin); print obj['data']['oidc_cfg']" >oidc_cfg
  fi

  . oidc_cfg

  # ca_crt
  # secret_id
  # secret_key
  # endpoint
  # region
  # master_id
  # username
  # issuer_url
  # hostnames
  # vip
}

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
  #  TODO: oidc-ca 是否先删后创
  kubectl get cm oidc-ca -n tke
  if [ $? -ne 0 ]; then
    echo "creating oidc-ca configmap ..."
    kubectl create cm oidc-ca -n tke --from-file=$ca_crt
  fi
  # create cloudindustry-config configmap
  # TODO：判断 cloudindustry-config 是否已经存在
  cat <<EOF | kubectl apply -f -
kind: ConfigMap
metadata:
  name: cloudindustry-config
  namespace: tke
apiVersion: v1
data:
  config: |
    {
        "secret_id": $secret_id,
        "secret_key": $secret_key,
        "endpoint": $endpoint,
        "region":$region,
        "master_id":$master_id
    }
EOF
}

function createOIDCAuthCMTmpFile() {
  content=$(
    cat <<EOF
\n
[authentication.oidc]\n
client_secret = $secret_key\n
client_id = $secret_id\n
issuer_url = $issuer_url\n
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
      sed -i "${line}c \ \ \ \ init_client_id = ${secret_id}" $file
    fi
    line=$(sed -n '/init_client_secret/=' $file)
    if [ "$line" != "" ]; then
      sed -i "${line}c \ \ \ \ init_client_secret = ${secret_key}" $file
    fi
  else
    sed -i '/external_issuer_url/d' $file

    sed -i '/client_secret/d' $file
    sed -i "/authentication.oidc/a\      client_secret = ${secret_key}" $file

    sed -i '/client_id/d' $file
    sed -i "/authentication.oidc/a\      client_id = ${secret_id}" $file

    sed -i '/issuer_url/d' $file
    sed -i "/authentication.oidc/a\      issuer_url = ${issuer_url}" $file
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

function createOIDCHostAliasTmpFile() {
  if [ "$hostnames" != "" ] && [ "$vip" != "" ]; then
    file=oidc_hostAlias_tmp.txt
    rm -rf $file
    echo "      hostAliases:" >>$file
    echo "      - hostnames:" >>$file
    arr=(${hostnames//,/ })
    for name in "${arr[@]}"; do
      #    remove ','
      name=$(echo "$name" | sed -e "s/,$//")
      #    remove '"'
      name=$(echo "$name" | sed -e "s/^\"//" -e "s/\"$//")
      echo "****** ${name}"
      echo "        - ${name}" >>$file
    done
    echo "        ip: ${vip}" >>$file
  fi
}

function rmOIDCHostAliasTmpFile() {
  rm -f oidc_hostAlias_tmp.txt
}

function modifyResource() {
  echo ======= modify $1 $2 =======
  file=./$2-$1.yaml

  kubectl -n tke annotate $1 $2 tkeanywhere/oidc="true" --overwrite=true
  kubectl -n tke get $1 $2 -o yaml >$file

  start=$(sed -n '/last-applied-configuration/=' $file)
  if [ "$start" != "" ]; then
    end=$(($start + 1))
    sed -i "$start, $end d" $file
  fi

  line=$(sed -n '/hostAliases/=' $file)
  if [ "$line" = "" ] && [ "$hostnames" != "" ] && [ "$vip" != "" ]; then
    sed -i "/dnsPolicy/r oidc_hostAlias_tmp.txt" $file
  fi

  line=$(sed -n '/oidc-ca-volume/=' $file)
  if [ "$line" = "" ]; then
    sed -i "/volumes/r oidc_volumes_tmp.txt" $file
    sed -i "/volumeMounts/r oidc_volumeMounts_tmp.txt" $file
  fi

  kubectl apply -f $file
  rm $file
}
# 云上交付是否有对应的资源
function adduser() {
  kubectl get platforms.business.tkestack.io platform-default -oyaml >default.yaml
  sed -i "/- admin/a\  - ${username}" default.yaml
  kubectl apply -f default.yaml
}

function configAll() {
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

setConfigEnvs
backup
createcms
configAll
adduser

#function getstr() {
#  kubectl get cm oidc-config -n tke
#  if [ $? -ne 0 ]; then
#    echo "creating oidc-config configmap for persistent oidc value in tkeanywhere ..."
#    kubectl create cm oidc-config -n tke --from-file=./oidc.json
#  fi
#  kubectl get cm oidc-config -n tke -ojson >oidccm.json
#  str=$(cat oidccm.json | python -c "import json; import sys; obj=json.load(sys.stdin); print json.dumps(obj['data']['oidc.json'])")
#  ca_crt=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['ca.crt']")\"
#  secret_id=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['secret_id']")\"
#  secret_key=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['secret_key']")\"
#  endpoint=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['endpoint']")\"
#  region=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['region']")\"
#  master_id=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['master_id']")\"
#  username=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['username']")\"
#  issuer_url=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['issuer_url']")\"
#  hostnames=$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['hostnames']")
#  hostnames=$(echo "$hostnames" | sed -e "s/^\[//" -e "s/\]$//")
#  vip=\"$(echo $str | python -c "import json; import ast; import sys; obj=json.load(sys.stdin); s=ast.literal_eval(obj); print s['vip']")\"
#}

