#!/usr/bin/env bash

OPTIONAL_FLAGS=""

[[ "${DRY_RUN}" == "true" ]] && OPTIONAL_FLAGS="$OPTIONAL_FLAGS -x"
[[ "${WIKI}" == "true" ]] && OPTIONAL_FLAGS="$OPTIONAL_FLAGS -w"
[[ "${VERBOSE}" == "true" ]] && OPTIONAL_FLAGS="$OPTIONAL_FLAGS -v"
[[ "${NOCOMPRESS}" == "true" ]] && OPTIONAL_FLAGS="$OPTIONAL_FLAGS -n"

echo "INFO: running script ./backup-devops.sh -p $DEVOPS_PAT -o $DEVOPS_ORG_URL -d /data -r $RETENTION_DAYS  $OPTIONAL_FLAGS"
./backup-devops.sh -p $DEVOPS_PAT -o $DEVOPS_ORG_URL -d /data -r $RETENTION_DAYS  $OPTIONAL_FLAGS
