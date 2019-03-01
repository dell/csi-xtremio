# CSI Plugin for XtremIO
## Description
Deployment scripts for the CSI driver for Dell EMC XtremIO

The driver connects Dell EMC XtremIO storage to Kubernetes environment to provide persistent storage.

## Platform and Software Dependencies
### Relevant Dell Products
The driver has been tested with XtremIO X2 XIOS 6.2.0 and 6.2.1

### Operating Systems Supported
* CentOS 7.6 with Linux kernel 3.10+
* Ubuntu and other distributions can work but were not extensively tested

### Supported environments
The driver needs the following environment:
* FibreChannel
* Linux native multipath
* Docker 18.06 and above
* Kubernetes 1.13+
* Fully configured XtemIO X2 cluster

## Snapshot Support in Kubernetes
Snapshots have been recently added to Kubernetes and depending on used K8s version it can be required to enable them. It is accomplished by adding an option “--feature-gates=VolumeSnapshotDataSource=true” in
 **/etc/kubernetes/manifests/kube-apiserver.yaml**. Ensure that kube-apiserver pod is restarted after the configuration update.

## Installation Instructions
1. Firstly choose an authentication method for the plugin. A system administrator may choose any of the following deployment options for user account that will be utilized by CSI driver:
* use any of the existing default accounts, such as "admin".
* use a manually created account.
* let the installation script to create a specific new account. In this case the administrator will provide an "initial" user account with sufficient permission to create the new account.
2. One of the k8s nodes need to be chosen as `master` or `controller` - it needs to run **kubectl** as part of controller initialization, further such node will also be referred to as `controller`. All other nodes will be referenced as `nodes`. Clone this repository to the `controller`:
```bash
$ git clone https://github.com/dell/csi-xtremio-deploy.git
$ cd csi-xtremio-deploy && git checkout 1.0.0
```
3. Edit **csi.ini** file. Mandatory fields are `management_ip` - management address of XtremIO cluster, `csi_user` and `csi_password` - credentials used by the plugin to connect to the storage. `csi_user` and `csi_password` can be created in advance on step 1 or can be created by an installation script. If user creation is left to the script please provide `initial_user` and `initial_password` in the **csi.ini**, e.g. this can be credentials of the storage administrator. If nodes don't have direct access to the Internet, one can use local registry. In that case please populate local registry with the plugin image and sidecar containers and set `plugin_path` and `csi_.._path` variables. All parameters that can be changed in the file are described in section "**csi.ini** Parameters". Example below belongs to the case when administrator has credentials `admin/password123` and the plugin will use created by the installation script `csiuser/password456`:
```bash
management_ip=10.20.20.40
initial_username=admin
initial_password=password123
csi_username=csiuser
csi_password=password456
```
4. Copy the folder with all the files to all other nodes.
5. On `controller` node run:
```bash
$ ./install-csi-plugin.sh -c
```
6. On all other nodes run:
```bash
$ ./install-csi-plugin.sh -n
```

## Testing
The following describes creation of Persistent Volume Claim (PVC), snapshotting and restoration.
1. Create a file **pvc.yaml** with the content:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-pvc-demo
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: csi-xtremio-sc
```
2. Apply the file with `kubectl -f pvc.yaml` command:
```bash
$ kubectl create -f pvc.yaml
persistentvolumeclaim/csi-pvc-demo created
```
3. Check that PVC has been successful:
```bash
$ kubectl get pvc csi-pvc-demo
NAME          STATUS  VOLUME                                    CAPACITY  ACCESS MODES  STORAGECLASS    AGE
csi-pvc-demo  Bound   pvc-7caf0bf5-3b3d-11e9-8395-001e67bd0708  10Gi      RWO           csi-xtremio-sc  41s

```
4. Create a file **snapshot.yaml** with the content:
```yaml
apiVersion: snapshot.storage.k8s.io/v1alpha1
kind: VolumeSnapshot
metadata:
  name: csi-snapshot-demo
spec:
  snapshotClassName: csi-xtremio-xvc
  source:
    name: csi-pvc-demo
    kind: PersistentVolumeClaim
```
5. Apply the file with `kubectl -f snapshot.yaml` command:
```bash
$ kubectl create -f snapshot.yaml
volumesnapshot.snapshot.storage.k8s.io/csi-snapshot-demo created

```
6. Check that snapshot has been created from the volume:
```bash
$ kubectl get volumesnapshots csi-snapshot-demo
NAME               AGE
csi-snapshot-demo  38s
```
7. Create a file **restore.yaml** with the content:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-pvc-demo-restore
spec:
  storageClassName: csi-xtremio-sc
  dataSource:
    name: csi-snapshot-demo
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```
8. Apply the file with `kubectl -f restore.yaml` command:
```bash
$ kubectl create -f restore.yaml
persistentvolumeclaim/csi-pvc-demo-restore created

```
9. Check that restoration has been successful:
```bash
$ kubectl get pvc csi-pvc-demo-restore
NAME                  STATUS  VOLUME                                    CAPACITY  ACCESS MODES  STORAGECLASS    AGE
csi-pvc-demo-restore  Bound   pvc-c3b2d633-3b3f-11e9-8395-001e67bd0708  10Gi      RWO           csi-xtremio-sc  30s

$ kubectl get pv | grep csi-pvc-demo-restore
pvc-c3b2d633-3b3f-11e9-8395-001e67bd0708  10Gi  RWO  Delete  Bound  default/csi-pvc-demo-restore  csi-xtremio-sc 96s

```

## Upgrade
Running upgrade of plugin can be dangerous for existing k8s objects. It is recommended to run it with `-g` option which only generates YAML in **csi-tmp** folder. User is encouraged to check it, to correct and to run manually with help of **kubectl** command. The upgrade command only needs to be run on `controller`. E.g.
```bash
$ ./install-csi-plugin.sh -u -g
# check csi-tmp folder for instantiated YAMLs, correct if necessary
$ kubectl apply -f csi-tmp/plugin.yaml
```

## **csi.ini** Parameters
| Name | Explanation | Required | Default |
|--------|--------------|------------|---------|
| management_ip | Management IP of XMS managing XIO cluster/s | Yes |
| initial_username | Initial username to access and create new CSI user, if not exist. Shall be specified in case CSI user wasn't configured in advanced and script should create it. The user role needs to be Admin. |  No |
| initial_password | Initial password for the initial username | No |
| csi_username | CSI user account that will be used by the plugin in all REST call towards XIO System. This user can be created in advance by a user or by the script, in the latter case initial username and password with Tech role are required. | Yes |
| csi_password | CSI user password |  Yes |
| force | In case IG name was created manually a user should provide 'force' flag to allow such modification in XMS | | No
| verify | Perform connectivity verification | No | Yes
| plugin_path | | Yes | docker.io/dellemcstorage/csi-xtremio:v1.0.0
| csi_attacher_path | CSI attacher image | Yes | quay.io/k8scsi/csi-attacher:v1.0-canary
| csi_cluster_driver_registrar_path | CSI cluster driver registrar image | Yes | quay.io/k8scsi/csi-cluster-driver-registrar:v1.0-canary
| csi_node_driver_registrar_path | CSI node driver registrar image | Yes | quay.io/k8scsi/csi-node-driver-registrar:v1.0-canary
| csi_provisioner_path | CSI provisioner image | Yes | quay.io/k8scsi/csi-provisioner:v1.0-canary
| csi_snapshotter_path | CSI snapshotter image | Yes | quay.io/k8scsi/csi-snapshotter:v1.0-canary
| storage_class_name | Name of the storage class to be defined | Yes | csi-xtremio-sc
| list_of_clusters | Define the clusters' names that can be used for volumes provisioning. If provided, only the clusters in the list will be available for storage provisioning, otherwise all manged clusters will be available. | No |
| list_of_initiators | Define list of initiators per node that can be used for LUN mapping. If provided, only those initiators will be included in created IG, otherwise all will be included. | No |  
| csi_high_qos_policy | Bandwidth of High QoS policy profile | No | 15m
| csi_medium_qos_policy | Bandwidth of Medium QoS policy profile | No | 5m
| csi_low_qos_policy | Bandwidth of Low QoS policy profile | No | 1m


## Installation script parameters
Installation script **install-csi-plugin.sh** requires a number of options and a correctly filled **csi.ini** file. The script parameters:

| Name | Explanation |
|--------------|------------------|
|    `-c`    |      controller initialization, should run once only on one of k8s nodes. This option creates a user account, QoS policies, if necessary, and loads YAML definitions for the driver into k8s cluster. It also configures initiator group of this node in XMS 
|    `-n`    |      node initialization, should run on all other nodes. Configures initiator group of this node in XMS
|    `-x tarball`    |    load docker images from tarball. This optionally loads docker images from archive on this node, e.g. if Internet access is limited. Alternatively users can run own registry with all necessary images. In the latter case please check **csi.ini** file and correct paths to images.
|    `-u`    |    update plugin from new yaml files. With this flag installation script will update docker images and YAML definitions for the driver. **USE WITH CARE!** See explanation below in Upgrade section.
|    `-g`    |    only generate YAML definitions for k8s from template. Recommended with `-u`.
|    `-h`    |    print help message

