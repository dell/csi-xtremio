#!/bin/bash
set -e

##### Constants

PROG=`basename $0`
DIR=$(dirname "$(readlink -f "$0")")
INI="${DIR}/csi.ini"
TMPDIR="${DIR}/csi-tmp"

DEFAULT_STORAGE_CLASS="csi_xtremio"

PLUGIN_TEMPLATE_YAML="${DIR}/template/plugin-template.yaml"
RESOURCES_TEMPLATE_YAML="${DIR}/template/resources-template.yaml"
SECRET_TEMPLATE_YAML="${DIR}/template/secret-template.yaml"

PLUGIN_YAML="${TMPDIR}/plugin.yaml"


##### Functions

function print_help() {
    echo "Help for $PROG"
    echo
    echo "Usage: $PROG options..."
    echo "Options:"
    echo "  -c           controller initialization"
    echo "  -n           node initialization"
    echo "  -x tarball   load docker images from tarball"
    echo "  -u           update plugin from new yaml files"
    echo "  -g           only generate yaml from template"
    echo "  -h           help"
    echo

    exit 0
}

function export_parameters() {
    echo "### reading parameters from $INI"

    while IFS= read -r line; do
      export $line
    done < $INI

    if [[ -z "$management_ip" ]]; then
      echo "management_ip - not set"
      exit 255
    else
      echo "management_ip="$management_ip
    fi
    if [[ -z "$csi_username" ]]; then
      echo "csi_username - not set"
      exit 255
    fi
    if [[ -z "$csi_password" ]]; then
      echo "csi_password - not set"
      exit 255
    fi

    if [[ -z "$storage_class_name" ]]; then
      export storage_class_name=$DEFAULT_STORAGE_CLASS
    fi
}

function run_installcsi() {
    echo "### installcsi"
    echo "prepare installcsi options"

    is_qos_needed=false

    csi_command="${DIR}/bin/installcsi -csi-user $csi_username -csi-password $csi_password -x $management_ip"

    if [[ "$is_controller" -eq 1 ]]; then
      csi_command="$csi_command -c"

      if [[ ! -z "$initial_username" ]]; then
        csi_command="$csi_command -u $initial_username"
      fi
      if [[ ! -z "$initial_password" ]]; then
        csi_command="$csi_command -p $initial_password"
      fi

      if [[ ! -z "$csi_high_qos_policy" || ! -z "$csi_medium_qos_policy" || ! -z "$csi_low_qos_policy" ]]; then
        prepare_qos_cmd
      fi

    fi

    if [[ ! -z "$list_of_clusters" ]]; then
      csi_command="$csi_command -s $list_of_clusters"
    fi
    if [[ ! -z "$list_of_initiators" ]]; then
      csi_command="$csi_command -i $list_of_initiators"
    fi
    if [[ $force == "Yes" || $force == "yes" ]]; then
      csi_command="$csi_command -f"
    fi
    if [[ $verify == "Yes" || $verify == "yes" ]]; then
      csi_command="$csi_command -v"
    fi

    echo "run installcsi command"
    $csi_command
    exitcode=$?

    if [[ $exitcode != 0 ]]; then
      echo "installcsi failed!"
      exit $exitcode
    fi

    if [ -f /opt/emc/xio_ig_id ]
    then
      cat /opt/emc/xio_ig_id
      echo
    else
      echo "installcsi failed! Not found xio_ig_id."
      exit 1
    fi

    if $is_qos_needed; then
      execute_qos_cmd
    fi

    echo "### installcsi - done"
}

function create_install_template() {
    sed -e '$a\\n---\n' $RESOURCES_TEMPLATE_YAML \
    | sed r - $PLUGIN_TEMPLATE_YAML > $PLUGIN_YAML
}

function crate_update_template() {
    cp $PLUGIN_TEMPLATE_YAML $PLUGIN_YAML
}

function create_plugin_yaml() {
    echo "### create plugin yaml file"

    sed -i "s/#MANAGEMENT_IP#/$management_ip/g" $PLUGIN_YAML
    sed -i "s/#CSI_USER#/$csi_username/g" $PLUGIN_YAML
    sed -i "s/#STORAGE_CLASS#/$storage_class_name/g" $PLUGIN_YAML
    sed -i "s/#CSI_PROVISIONER#/${csi_provisioner_path//\//\\/}/g" $PLUGIN_YAML
    sed -i "s/#CSI_ATTACHER#/${csi_attacher_path//\//\\/}/g" $PLUGIN_YAML
    sed -i "s/#CSI_SNAPSHOTTER#/${csi_snapshotter_path//\//\\/}/g" $PLUGIN_YAML
    sed -i "s/#CSI_CLUSTER_DRIVER#/${csi_cluster_driver_registrar_path//\//\\/}/g" $PLUGIN_YAML
    sed -i "s/#CSI_NODE_DRIVER#/${csi_node_driver_registrar_path//\//\\/}/g" $PLUGIN_YAML
    sed -i "s/#CSI_XTREMIO_DEBUG#/$csi_xtremio_debug/g" $PLUGIN_YAML
    sed -i "s/#CSI_PLUGIN#/${plugin_path//\//\\/}/g" $PLUGIN_YAML

    if [[ -z "$csi_qos_policy_id" ]]; then
      sed -i "/qos_policy_id: #QoS_POLICY#/d" $PLUGIN_YAML
    else
      sed -i "s/#QoS_POLICY#/\"${csi_qos_policy_id}\"/g" $PLUGIN_YAML
    fi

    echo "### plugin yaml file - done"
}

function create_k8s_secret() {
    echo "### create k8s secret"
    cat $SECRET_TEMPLATE_YAML | sed "s/#CSI_PASSWORD#/$csi_password/g" | kubectl create -f -
    exitcode=$?
    if [[ $exitcode != 0 ]]; then
      echo "creation of secret failed!"; exit $exitcode;
    fi
}

function create_k8s_objects() {
    echo "### create k8s objects"

    cd $TMPDIR

    kubectl create -f $PLUGIN_YAML
    exitcode=$?
    if [[ $exitcode != 0 ]]; then
      echo "plugin objects create failed!"; exit $exitcode;
    fi

    echo "### k8s objects - done"
    echo
    echo "Please run 'kubectl get pods --all-namespaces -l role=csi-xtremio --watch'"
    echo "to watch the installation progress on all nodes, press Ctrl+C for exit."
}

function remove_k8s_objects() {
    echo "### remove old k8s objects"

    kubectl -n kube-system delete statefulsets -l role=csi-xtremio &&
    kubectl -n kube-system delete daemonsets -l role=csi-xtremio
    exitcode=$?
    if [[ $exitcode != 0 ]]; then
      echo "remove objects old plugin failed!"; exit $exitcode;
    fi

    echo "### remove old k8s objects - done"
}

function prepare_qos_cmd() {
    csi_command_qos="$csi_command"
    is_qos_needed=true

    if [[ ! -z "$csi_high_qos_policy" && "${csi_high_qos_policy::-1}" -ne 0 ]]; then
      csi_command_qos="$csi_command_qos -q High,$csi_high_qos_policy"
    fi
    if [[ ! -z "$csi_medium_qos_policy" && "${csi_medium_qos_policy::-1}" -ne 0 ]]; then
      csi_command_qos="$csi_command_qos -q Medium,$csi_medium_qos_policy"
    fi
    if [[ ! -z "$csi_low_qos_policy" && "${csi_low_qos_policy::-1}" -ne 0 ]]; then
      csi_command_qos="$csi_command_qos -q Low,$csi_low_qos_policy"
    fi

    if [[ ! -z "$list_of_clusters" ]]; then
      csi_command_qos="$csi_command_qos -s $list_of_clusters"
    fi
}

function execute_qos_cmd() {
    echo "run installcsi qos command"
    $csi_command_qos
    exitcode=$?

    if [[ $exitcode != 0 ]]; then
    echo "qos setup failed!"
    fi
}

function check_kubectl() {
    which kubectl > /dev/null 2>&1
    exitcode=$?
    if [[ $exitcode != 0 ]]; then
      echo "not found kubectl"; exit 255;
    fi
}

function controller_initialization() {
    export_parameters

    is_controller=1
    run_installcsi

    create_install_template
    create_plugin_yaml

    if [[ $no_load -eq 0 ]]; then
      check_kubectl
      create_k8s_secret
      create_k8s_objects
    fi

    exit 0
}

function node_initialization() {
    export_parameters

    is_controller=0
    run_installcsi
    exit 0
}

function load_docker_images() {
    TARBALL=$(readlink -f "$TARBALL")

    echo "### load docker images from tarball '$TARBALL'"

    if [[ ! -f "$TARBALL" ]]; then
      echo "file '$TARBALL' does not exist"
      exit 1
    fi

    docker load < $TARBALL

    exitcode=$?
    if [[ $exitcode != 0 ]]; then
      echo "images load failed!"; exit $exitcode;
    fi

    echo "### load docker images - done"
    exit 0
}

function update_plugin() {
    echo "### update plugin from new yaml files"
    export_parameters
    crate_update_template
    create_plugin_yaml

    if [[ $no_load -eq 0 ]]; then
      check_kubectl
      remove_k8s_objects
      create_k8s_objects
    fi

    echo "### update plugin - done"
    exit 0
}

##### Main

mkdir -p $TMPDIR

if [ $# -eq 0 ]; then
    print_help
    exit 0
fi

controller=0
update=0
no_load=0

while getopts "cnx:ugh" opt;
do
    case $opt in
      c) controller=1
          ;;
      n) node_initialization
          ;;
      x) TARBALL=$OPTARG
         load_docker_images
          ;;
      u) update=1
          ;;
      g) no_load=1
          ;;
      h) print_help;
          ;;
      *) echo "Invalid option";
         echo "For help, run $PROG -h";
         exit 1
          ;;
    esac
done

if [[ $controller -eq 1 ]]; then
    controller_initialization
fi

if [[ $update -eq 1 ]]; then
    update_plugin
fi
