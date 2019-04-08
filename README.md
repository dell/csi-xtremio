# CSI Plugin for XtremIO
## Description
This document discusses the deployment scripts for the CSI driver for Dell EMC XtremIO.

The CSI driver connects Dell EMC XtremIO storage to Kubernetes environment to provide persistent storage.

## Platform and Software Dependencies
### Relevant Dell Products
The CSI driver has been tested with XtremIO X1 / X2 XIOS 6.2.0 and 6.2.1.

### Operating Systems Supported
* RHEL 7.x or CentOS 7.x with Linux kernel 3.10+
* Ubuntu 18.04
* Other distributions may be supported, but were not extensively tested

### Supported Environments
The driver requires the following environment:
* FibreChannel or iSCSI (see Support of iSCSI section for additional installation notes)
* Linux native multipath
* Docker 18.06 and later
* Kubernetes 1.13+
* Fully-configured XtremIO X1 or X2 cluster (see Support of XtremIO X1 Clusters). A mix of X1 and X2 is not supported.

## Snapshot Support in Kubernetes
Snapshots were recently added to Kubernetes. Depending on the K8s version used, it may be necessary to enable them. Enablement is accomplished by adding an option "--feature-gates=VolumeSnapshotDataSource=true" in
 **/etc/kubernetes/manifests/kube-apiserver.yaml**. Make sure that kube-apiserver pod is restarted following the configuration update.

## Installation Instructions
1. Select an authentication method for the plugin. A system administrator may choose any of the following deployment options for the user account to be utilized by CSI driver:
* Use any of the existing default accounts, such as "admin".
* Use a manually-created account.
* Allow the installation script to create a specific new account. In this case, the administrator provides an "initial" user account with sufficient permission to create the new account.
2. One of the hosts must be designated to be the `master` or `controller`. It needs to run **kubectl** as part of controller initialization but is not required to be a Kubernetes node. From here on, this host will also be referred to as `controller`. All other hosts that run Kubernetes services will be referenced as `nodes`. Clone this repository to the `controller`:

```bash
$ git clone https://github.com/dell/csi-xtremio-deploy.git
$ cd csi-xtremio-deploy && git checkout 1.1.0
```
3. Edit **csi.ini** file. Mandatory fields are `management_ip` - management address of XtremIO cluster, `csi_user` and `csi_password` - credentials used by the plugin to connect to the storage. `csi_user` and `csi_password` can be created prior to performing step 1, or can be created by an installation script. If user creation is left to the script, provide `initial_user` and `initial_password` in the **csi.ini**. For example, the credentials of the storage administrator. If nodes do not have direct access to the Internet, the local registry can be used. In such cases, populate the local registry with the plugin image and sidecar containers, and set `plugin_path` and `csi_.._path` variables. All parameters that can be changed in the file are described in the section "**csi.ini** Parameters".
The below example presents the case when the storage administrator has the credentials `admin/password123` and the plugin used was created by the installation script `csiuser/password456`:
```bash
management_ip=10.20.20.40
initial_username=admin
initial_password=password123
csi_username=csiuser
csi_password=password456
```
4. Copy the folder with all the files to all nodes.
5. On `controller` host run the following command:
```bash
$ ./install-csi-plugin.sh -c
```
6. On all nodes, run the following command:
```bash
$ ./install-csi-plugin.sh -n
```
If `controller` is co-located with `node` the above command also needs to run on such host.

## Support of XtremIO X1 Clusters
X1 clusters don't support QoS. To successfully install the plugin it is required to clear values of `csi_high_qos_policy`, `csi_medium_qos_policy` and `csi_low_qos_policy` parameters in **csi.ini** file:
```bash
csi_high_qos_policy=
csi_medium_qos_policy=
csi_low_qos_policy=
```

## Support of iSCSI
iSCSI configuration requires the following to be supported by the CSI plugin:
- exactly one portal exists for each iSCSI target.
- portal IP address is reachable from all nodes
- CHAP is disabled

The following steps can be necessary to prepare nodes for further configuration (before running the plugin installation script):
1. Install iSCSI utils package on the Linux server:
```bash
$ yum install iscsi-initiator-utils -y
```
2. Edit the IQN name of the node in file **/etc/iscsi/initiatorname.iscsi** if needed:
```bash
$ cat /etc/iscsi/initiatorname.iscsi
InitiatorName=iqn.1994-05.com.redhat:c3699b430b9
```
3. Enable and restart the iSCSI service:
```bash
systemctl enable iscsid.service
systemctl restart iscsid.service
```

All of the iSCSI initiators must be known to XMS. To acomplish this for each node:
1. Create the new initiator group in XMS and add the IQN you’ve created earlier (see **/etc/iscsi/initiatorname.iscsi**)
2. Create file **/opt/emc/xio_ig_id** (replace `INITIATOR_GROUP_NAME` with a correct initiator group name):
```bash
$ cat /opt/emc/xio_ig_id
{"IgName":"INITIATOR_GROUP_NAME"}
```
After that you can proceed with general installation steps.

**Note**: There is no need to run the plugin installation script on `nodes`, iSCSI discovery and login processes are performed automatically during the first PV/PVC creation.

## Testing
The following example describes the creation of Persistent Volume Claim (PVC), snapshotting and restoration.
1. Create a file **pvc.yaml** with the following content:
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
2. Apply the following command to the `kubectl -f pvc.yaml` file:
```bash
$ kubectl create -f pvc.yaml
persistentvolumeclaim/csi-pvc-demo created
```
3. Check that PVC was successful, as follows:
```bash
$ kubectl get pvc csi-pvc-demo
NAME          STATUS  VOLUME                                    CAPACITY  ACCESS MODES  STORAGECLASS    AGE
csi-pvc-demo  Bound   pvc-7caf0bf5-3b3d-11e9-8395-001e67bd0708  10Gi      RWO           csi-xtremio-sc  41s

```
4. Create a file **snapshot.yaml** with the content, as follows:
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
5. Apply the following command to the `kubectl -f snapshot.yaml` file:
```bash
$ kubectl create -f snapshot.yaml
volumesnapshot.snapshot.storage.k8s.io/csi-snapshot-demo created

```
6. Check that snapshot has been created from the volume, as follows:
```bash
$ kubectl get volumesnapshots csi-snapshot-demo
NAME               AGE
csi-snapshot-demo  38s
```
7. Create a **restore.yaml** file with the following content:
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
8. Apply the following command to the `kubectl -f restore.yaml` file:
```bash
$ kubectl create -f restore.yaml
persistentvolumeclaim/csi-pvc-demo-restore created

```
9. Check that restoration was successful, as follows:
```bash
$ kubectl get pvc csi-pvc-demo-restore
NAME                  STATUS  VOLUME                                    CAPACITY  ACCESS MODES  STORAGECLASS    AGE
csi-pvc-demo-restore  Bound   pvc-c3b2d633-3b3f-11e9-8395-001e67bd0708  10Gi      RWO           csi-xtremio-sc  30s

$ kubectl get pv | grep csi-pvc-demo-restore
pvc-c3b2d633-3b3f-11e9-8395-001e67bd0708  10Gi  RWO  Delete  Bound  default/csi-pvc-demo-restore  csi-xtremio-sc 96s

```

## Upgrade
Running an upgrade of the plugin can be dangerous for existing k8s objects. It is recommended to run it with the `-g` option, which only generates YAML in the **csi-tmp** folder. The user is encouraged to check it, to correct it and to run it manually, with help of the **kubectl** command. The upgrade command only needs to be run on `controller`.
The following is an example:
```bash
$ ./install-csi-plugin.sh -u -g
# check csi-tmp folder for instantiated YAMLs, correct if necessary
$ kubectl apply -f csi-tmp/plugin.yaml
```

## **csi.ini** Parameters
| Name | Explanation | Required | Default |
|--------|--------------|------------|---------|
| management_ip | Management IP of XMS managing XIO cluster/s | Yes |
| initial_username | Initial username to access and create the new CSI user, if non existant. Shall be specified in case the CSI user was not configured in advanced and the script should create it. The user role must be Admin. |  No |
| initial_password | Initial password for the initial username | No |
| csi_username | The CSI user account to be used by the plugin in all REST calls to the XIO System. This user can be created in advance by a user or by the script. In the latter case, the initial username and password with Admin role are required. | Yes |
| csi_password | CSI user password |  Yes |
| force | In the event that the IG name was created manually, a user should provide the 'force' flag to allow such modification in the XMS. | | No
| verify | Perform connectivity verification | No | Yes
| plugin_path | | Yes | docker.io/dellemcstorage/csi-xtremio:v1.0.0
| csi_attacher_path | CSI attacher image | Yes | quay.io/k8scsi/csi-attacher:v1.0-canary
| csi_cluster_driver_registrar_path | CSI cluster driver registrar image | Yes | quay.io/k8scsi/csi-cluster-driver-registrar:v1.0-canary
| csi_node_driver_registrar_path | CSI node driver registrar image | Yes | quay.io/k8scsi/csi-node-driver-registrar:v1.0-canary
| csi_provisioner_path | CSI provisioner image | Yes | quay.io/k8scsi/csi-provisioner:v1.0-canary
| csi_snapshotter_path | CSI snapshotter image | Yes | quay.io/k8scsi/csi-snapshotter:v1.0-canary
| storage_class_name | Name of the storage class to be defined | Yes | csi-xtremio-sc
| list_of_clusters | Define the names of the clusters that can be used for volume provisioning. If provided, only the clusters in the list will be available for storage provisioning, otherwise all managed clusters become available. | No |
| list_of_initiators | Define list of initiators per node that can be used for LUN mapping. If provided, only those initiators will be included in created IG, otherwise all will be included. | No |  
| csi_high_qos_policy | Bandwidth of High QoS policy profile | No | 15m
| csi_medium_qos_policy | Bandwidth of Medium QoS policy profile | No | 5m
| csi_low_qos_policy | Bandwidth of Low QoS policy profile | No | 1m


## Installation Script Parameters
Installation script **install-csi-plugin.sh** requires a number of options and a correctly-filled **csi.ini** file. The script parameters are as follows:

| Name | Explanation |
|--------------|------------------|
|    `-c`    |      Controller initialization, should run once on a host connected to K8s cluster. This option creates a CSI user account, QoS policies, if necessary, and loads YAML definitions for the driver into k8s cluster. It can be one of k8s nodes.
|    `-n`    |      Node initialization, should run on all k8s nodes. Configures an Initiator Group of the node in the XMS.
|    `-x tarball`    |    Load docker images from tarball. This optionally loads the docker images from the archive on this node, for example, if Internet access is limited. Alternatively users can run their own registry with all the necessary images. In the latter case, check the **csi.ini** file and that there are correct paths to the images.
|    `-u`    |    Update the plugin from the new yaml files. With this flag, the installation script updates the docker images and YAML definitions for the driver. **USE WITH CARE!** See the explanation in the Upgrade section.
|    `-g`    |    Only generate YAML definitions for k8s from the template. Recommended with `-u`.
|    `-h`    |    Print help message

