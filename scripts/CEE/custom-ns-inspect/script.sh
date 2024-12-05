#!/bin/bash

set -e
set -o nounset
set -o pipefail

### Check the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <namespace> <case_number>"
fi

# Define the project to gather information from
if [[ -z "${NAMESPACE:-}" ]]; then
    echo 'Variable NAMESPACE cannot be blank'
    exit 1
fi

# Define the project to gather information from
if [[ -z "${CASEID:-}" ]]; then
    echo 'Variable CASE_NUMBER cannot be blank'
    exit 1
fi

# shellcheck source=/dev/null
source /managed-scripts/lib/sftp_upload/lib.sh

# Define expected values
DUMP_DIR="/tmp/${NAMESPACE}"
TODAY=$(date -u +%Y%m%d)
TARBALL_NAME="${CASEID}_${TODAY}_${NAMESPACE}_dump.tar.gz"
TARBALL_PATH="${DUMP_DIR}/${TARBALL_NAME}"

# Function to check if the user is logged into OpenShift
check_login_status() {
  if ! oc whoami &>/dev/null; then
    echo "You are not logged into OpenShift. Please log in using 'oc login' and try again."
    exit 1
  fi
}


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

  if [ -f "$TARBALL_PATH" ]; then
    echo "Tarball $TARBALL_PATH already exists. Exiting."
    exit 0
  fi

  # Compress the dump directory
  # users can collect the data by running
  # kubectl -n openshift-backplane-managed-scripts logs <job-id> | tar xzf - 
  tar -czvf "$TARBALL_PATH" ./*

  echo "Compressed namespace inspect is saved as $TARBALL_PATH"

  return 0
}

# Function to upload the tarball to SFTP
upload_tarball() {
  cd "$DUMP_DIR"

  # Check if the tarball is in place
  if [ ! -f "$TARBALL_PATH" ]; then
    echo "Tarball is not found in $TARBALL_PATH"
    exit 1
  fi

  sftp_upload "$TARBALL_PATH" "$TARBALL_NAME"

  return 0
}

main(){
  # Calling functions to dump inspect, remove sensitive data, and create tarball
  check_login_status
  collect_inspect
  remove_sensitive_files
  create_tarball
  upload_tarball
}

main


