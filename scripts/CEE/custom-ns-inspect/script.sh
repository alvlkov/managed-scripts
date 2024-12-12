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
TIMEOUT=60
TIMESTAMP=$(date +%s)
CURRENT_TIME=${TIMESTAMP}
ELAPSED_TIME=0
PODNAME="${NAMESPACE}-ns-inspect"
SECRET_NAME="ns-inspect-creds"
SFTP_FILENAME="inspect-ns-$NAMESPACE-$TIMESTAMP.tar.gz"
OUTPUTDIR="/tmp/inspect.namespace.$TIMESTAMP"
OUTPUTFILE="${OUTPUTDIR}/${SFTP_FILENAME}"
FTP_HOST="sftp.access.redhat.com"
SFTP_OPTIONS="-o BatchMode=no -o StrictHostKeyChecking=no -b"

# Function to collect inspect and create a tarball
create_tarball() {
  # collect namespace inspect
  oc adm inspect ns/$NAMESPACE --dest-dir "$OUTPUTDIR" || true
  # Compress the inspect directory
  cd "$OUTPUTDIR"
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
  privileged: false
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
      
      TIMESTAMP=$(date +%s)
      # Wait for the inspect file to exist
      while [ ! -f "/home/mustgather/$SFTP_FILENAME" ]; do
        sleep 1  # Wait for 1 second before checking again
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - TIMESTAMP))
        if [ "$ELAPSED_TIME" -ge "$TIMEOUT" ]; then
          echo "Timeout reached after $TIMEOUT seconds. File /home/mustgather/$SFTP_FILENAME does not exist. Exiting."
          exit 1
        fi
      done

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
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
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
  echo "Waiting for $PODNAME pod to start..."
  if [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Failed" ];
  then
    echo "The namespace inspect pod has failed. The logs are:"
    # Do not error if uploader pod is still in initialising state
    oc -n $NS logs "${PODNAME}" -c ns-inspect-uploader || true
    oc -n $NS delete secret "${SECRET_NAME}" >/dev/null 2>&1
    oc -n $NS delete pod "${PODNAME}" >/dev/null 2>&1
    exit 1
  fi
done

# copy the inspect tar file to pod
if [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ];
then
  if ! oc cp "$OUTPUTFILE" "$PODNAME":"/home/mustgather/$SFTP_FILENAME"; then
    echo "Error: Failed to copy $OUTPUTFILE to pod $PODNAME. Command output:"
    oc cp "$OUTPUTFILE" "$PODNAME":/home/mustgather  # Run again to show detailed output
    exit 1
  fi
fi
  
while [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Succeeded" ];
do
  if [ "$(oc -n ${NS} get pod "${PODNAME}" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Failed" ];
  then
    echo "The namespace inspect pod has failed. The logs are:"
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
}

clean(){
  # Cleanup the inspect directory
  if [ -d "$OUTPUTDIR" ]; then
    rm -rf "$OUTPUTDIR"
    echo "Cleanup: Removed inspect directory $OUTPUTDIR"
  fi
}

main(){
  create_tarball
  upload_tarball
  clean
}

main


