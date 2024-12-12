#!/bin/bash

set -e
set -o nounset
set -o pipefail

# Define the project to gather information from
if [[ -z "${NAMESPACE:-}" ]]; then
    echo 'Variable NAMESPACE cannot be blank'
    exit 1
fi

#VARS
NS="openshift-backplane-managed-scripts"
CURRENT_TIMESTAMP=$(date --utc +%Y%m%d_%H%M%SZ)
DUMP_DIR="/tmp/${NAMESPACE}"
PODNAME="${NAMESPACE}-ns-inspect"
SECRET_NAME="ns-inspect-creds"
SFTP_FILENAME="${CURRENT_TIMESTAMP}-ns-inspect.tar.gz"
OUTPUTFILE="${DUMP_DIR}/${SFTP_FILENAME}"
FTP_HOST="sftp.access.redhat.com"
SFTP_OPTIONS="-o BatchMode=no -o StrictHostKeyChecking=no -b"

# Function to collect resources and logs
collect_inspect() {
  # Resources to dump (excluding sensitive information)
  RESOURCES=(pods deployments services configmaps pvc routes serviceaccounts networkpolicies replicasets ingresses)

  # Create directory for storing output
  mkdir -p "$DUMP_DIR" || { echo "Failed to create directory $DUMP_DIR"; exit 1; }

  # Loop through each resource and dump it to a file
  for RESOURCE in "${RESOURCES[@]}"; do
    echo "Gathering $RESOURCE..."
    oc get "$RESOURCE" -n "$NAMESPACE" -o yaml > "$DUMP_DIR/${RESOURCE}.yaml"
  done

  # Additional useful information
  echo "Gathering namespace description..."
  oc describe namespace "$NAMESPACE" > "$DUMP_DIR/namespace_description.txt"

  echo "Gathering events..."
  oc get events -n "$NAMESPACE" -o yaml > "$DUMP_DIR/events.yaml"

  # Dump logs for each pod in the namespace
  PODS=$(oc get pods -n "$NAMESPACE" -o jsonpath="{.items[*].metadata.name}")
  for POD in $PODS; do
    CONTAINERS=$(oc get pod "$POD" -n "$NAMESPACE" -o jsonpath="{.spec.containers[*].name}")
    for CONTAINER in $CONTAINERS; do
      echo "Gathering logs for pod $POD, container $CONTAINER..."
      oc logs "$POD" -n "$NAMESPACE" -c "$CONTAINER" > "$DUMP_DIR/${POD}_${CONTAINER}_logs.txt"
    done
  done
}

# Function to remove files with Secrets and CERTIFICATE data
remove_sensitive_files() {
  cd "$DUMP_DIR"

  find . -type f -name "*.yaml" -print0 | while IFS= read -r -d '' file; do
    if [ "$(yq e '.kind == "Secret"' "${file}" 2> /dev/null)" = "true" ]; then
      echo "Removing ${file} because it contains a Secret"
      rm -f "${file}"
    elif [ "$(yq e '.kind == "SecretList"' "${file}" 2> /dev/null)" = "true" ]; then
      echo "Removing ${file} because it contains a SecretList"
      rm -f "${file}"
    elif [ "$(yq e 'select(.data[] | contains("CERTIFICATE")) | [.] | length > 0' "${file}" 2> /dev/null)" = "true" ]; then
      echo "Removing ${file} because it contains CERTIFICATE data"
      rm -f "${file}"
    elif [ "$(yq e 'select(.items[].data[] | contains("CERTIFICATE")) | [.] | length > 0' "${file}" 2> /dev/null)" = "true" ]; then
      echo "Removing ${file} because it contains CERTIFICATE data"
      rm -f "${file}"
    fi
  done

  return 0
}

# Function to compress the dump into a tarball
create_tarball() {
  cd "$DUMP_DIR"

  if [ -f "$OUTPUTFILE" ]; then
    echo "Tarball $OUTPUTFILE already exists. Exiting."
    exit 0
  fi

  # Compress the dump directory
  tar -czvf "$OUTPUTFILE" ./*

  echo "Compressed namespace inspect is saved as $OUTPUTFILE"

  return 0
}

upload_tarball(){
  # Smoke test to check that the secret exists before creating the pod
  oc -n $NS get secret "${SECRET_NAME}" 1>/dev/null

  echo "Starting tarball upload..."
  #Create the upload pod
  # shellcheck disable=SC1039
  oc create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PODNAME}
  namespace: ${NS}
spec:
  privileged: true
  restartPolicy: Never
  volumes:
  - name: ns-inspect-upload-volume
    emptyDir: {}
  containers:
  # Adapted from https://github.com/openshift/must-gather-operator/blob/7805956e1ded7741c66711215b51eaf4de775f5c/build/bin/upload
  - name: ns-inspect-uploader
    image: quay.io/app-sre/must-gather-operator
    image-pull-policy: Always
    command:
    - '/bin/bash'
    - '-c'
    - |-
      #!/bin/bash
      set -e
      
      sleep 10

      if [ -z "\${caseid}" ] || [ -z "\${username}" ] || [ -z "\${SSHPASS}" ];
      then
        echo "Error: Required Parameters have not been provided. Make sure the ${SECRET_NAME} secret exists in namespace openshift-backplane-managed-scripts. Exiting..."
        exit 1
      fi

      echo "Uploading '${SFTP_FILENAME}' to Red Hat Customer SFTP Server for case \${caseid}"

      REMOTE_FILENAME=\${caseid}_${SFTP_FILENAME}

      if [[ "\${internal_user}" == true ]]; then
        # internal users must upload to a different path on the sftp
        REMOTE_FILENAME="\${username}/\${REMOTE_FILENAME}"
      fi

      # upload file and detect any errors
      echo "Uploading ${SFTP_FILENAME}..."
      sshpass -e sftp ${SFTP_OPTIONS} - \${username}@${FTP_HOST} << EOF
          put /home/mustgather/${SFTP_FILENAME} \${REMOTE_FILENAME}
          bye
      EOF

      if [[ \$? == 0 ]];
      then
        echo "Successfully uploaded '${SFTP_FILENAME}' to Red Hat SFTP Server for case \${caseid}!"
      else
        echo "Error: Upload to Red Hat Customer SFTP Server failed. Make sure that you are not using the same SFTP token more than once."
        exit 1
      fi
    volumeMounts:
    # This directory needs to be used, as it has the correct user/group permissions set up in the must gather container.
    # See https://github.com/openshift/must-gather-operator/blob/7805956e1ded7741c66711215b51eaf4de775f5c/build/bin/user_setup
    - mountPath: /home/mustgather
      name: ns-inspect-upload-volume
    env:
    - name: username
      valueFrom:
        secretKeyRef:
          name: ${SECRET_NAME}
          key: username
    - name: SSHPASS
      valueFrom:
        secretKeyRef:
          name: ${SECRET_NAME}
          key: password
    - name: caseid
      valueFrom:
        secretKeyRef:
          name: ${SECRET_NAME}
          key: caseid
    - name: internal_user
      valueFrom:
        secretKeyRef:
          name: ${SECRET_NAME}
          key: internal
EOF

# wait until pod is running
while [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ];
do
  echo "waiting for $PODNAME pod to start..."
done

# copy the inspect tar file to pod
if [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ];
then
  echo "Copying $OUTPUTFILE to pod $PODNAME..."
  if ! oc cp "$OUTPUTFILE" "$PODNAME":"/home/mustgather/$SFTP_FILENAME"; then
    echo "Error: Failed to copy $OUTPUTFILE to pod $PODNAME. Command output:"
    oc cp "$OUTPUTFILE" "$PODNAME":/home/mustgather  # Run again to show detailed output
    exit 1
  fi
  echo "$OUTPUTFILE is successfully copied into $PODNAME pod."
fi
  
while [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Succeeded" ];
do
  echo "performing pod checks..."
  if [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Failed" ];
  then
    echo "The namespace inspect collector pod has failed. The logs are:"
    # Do not error if uploader pod is still in initialising state
    oc -n $NS logs "${PODNAME}" -c ns-inspect-uploader || true
    oc -n $NS delete secret "${SECRET_NAME}" >/dev/null 2>&1
    oc -n $NS delete pod "${PODNAME}" >/dev/null 2>&1
    exit 1
  fi
  sleep 30
done

oc -n $NS delete secret "${SECRET_NAME}" >/dev/null 2>&1
oc -n $NS logs "${PODNAME}" -c ns-inspect-uploader || true
oc -n $NS delete pod "${PODNAME}"  >/dev/null 2>&1

echo "ns inspect file successfully uploaded to case!"
}

cleanup () {
  echo "removing the original dump directory"
  # Cleanup the dump directory
  if [ -d "$DUMP_DIR" ]; then
    rm -rf "$DUMP_DIR"
    echo "Cleanup: Removed dump directory at $DUMP_DIR"
  fi
}

main(){
  collect_inspect
  remove_sensitive_files
  create_tarball
  upload_tarball
  cleanup
}

main


