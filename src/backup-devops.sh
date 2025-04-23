#!/usr/bin/env bash

# strict mode configuration
set -uo pipefail

# enable extended pathname expansion (e.g. $ ls !(*.jpg|*.gif))
shopt -s extglob

################################################################################
### variables and defaults
################################################################################
VERBOSE_MODE=false;
DRY_RUN=false;
COMPRESS=true
PROJECT_WIKI=false;

# required options
PAT=""
BACKUP_ROOT_PATH=""
ORGANIZATION=""
RETENTION_DAYS=""

BACKUP_SUCCESS=true;

################################################################################
### FUNCTIONS
################################################################################

# check if command is available
function installed {
  command -v "${1}" >/dev/null 2>&1
}

# die and exit with code 1
function die {
  >&2 printf '%s %s\n' "Fatal: " "${@}"
  exit 1
}

# die and exit with code 1 + usage
function die_and_usage {
  >&2 printf '%s %s\n' "Fatal: " "${@}"
  usage
  exit 1
}

# usage function
function usage {
  usage="$(basename "$0") [-h] -p PAT -d backup-dir -o organization -r retention [-v] [-x] [-w] [-n]
where:
    -h  show this help text
    -p  personal access token (PAT) for Azure DevOps [REQUIRED]
    -d  backup directory path: the directory where to store the backup archive [REQUIRED]
    -o  Azure DevOps organization URL (e.g. https://dev.azure.com/organization) [REQUIRED]
    -r  retention days for backup files: how many days to keep the backup files [REQUIRED]
        A value of zero is accepted and keeps only the last daily backup
    -v  verbose mode [default is false]
    -x  dry run mode (no actual backup, only simulation) [default is false]
    -w  backup project wiki [default is false]
    -n  do not compress backup folder [default is true]"
  printf '%s\n' "${usage}"
}

# function to delete partial backup directory if some operation fails in the middle
function delete_partial_backup {
  if [[ "${DRY_RUN}" == "false" ]]; then
    if [ -n "${BACKUP_DIRECTORY}" -a "${BACKUP_DIRECTORY}" != "/" ]; then
      echo "=== Deleting partial backup directory [${BACKUP_DIRECTORY}]"
      rm -rf "${BACKUP_DIRECTORY}"
    else
      echo "=== Skip deleting partial backup directory due to invalid backup directory (${BACKUP_DIRECTORY})"
    fi
  else
    echo "=== Simulate deleting partial backup directory [${BACKUP_DIRECTORY}]"
  fi
}


################################################################################
### MAIN
################################################################################

# min bash 4 version
[[ "${BASH_VERSINFO[0]}" -lt 4 ]] && die "Bash >=4 required"

# check for required commands
deps=(jq base64 git az tar)
for dep in "${deps[@]}"; do
  installed "${dep}" || die "Missing '${dep}'"
done

# parse options
while getopts ':p:d:o:r:vxwhn' option; do
  case "$option" in
    p) PAT=$OPTARG
       ;;
    d) BACKUP_ROOT_PATH=$OPTARG
       ;;
    o) ORGANIZATION=$OPTARG
       ;;
    r) RETENTION_DAYS=$OPTARG
       ;;
    v) VERBOSE_MODE=true
       ;;
    x) DRY_RUN=true
       ;;
    w) PROJECT_WIKI=true
       ;;
    n) COMPRESS=false
       ;;
    h) usage
       exit 0
       ;;
    :) printf 'missing argument for -%s\n' "$OPTARG" >&2
       usage
       exit 1
       ;;
   \?) printf 'illegal option: -%s\n' "$OPTARG" >&2
       usage
       exit 1
       ;;
  esac
done
shift $((OPTIND - 1))

# deal with required options
# die if PAT is empty
[[ -z "${PAT}" ]] && die_and_usage "PAT is required (-p option)"
# die if directory argument is empty
[[ -z "${BACKUP_ROOT_PATH}" ]] && die_and_usage "Backup directory is required (-d option)"
# die if organization argument is empty
[[ -z "${ORGANIZATION}" ]] && die_and_usage "Organization URL is required (-o option)"
# die if retention argument is empty
[[ -z "${RETENTION_DAYS}" ]] && die_and_usage "Retention days is required (-r option)"
# die if retention argument is not a number
[[ ! "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] && die_and_usage "Retention days must be a number"
# die if retention argument is less than 0
[[ "${RETENTION_DAYS}" -lt 0 ]] && die_and_usage "Retention days must be greater or equal to 0"
# die if retention argument is greater than 365
[[ "${RETENTION_DAYS}" -gt 365 ]] && die_and_usage "Retention days must be less than or equal to 365"
# die if directory does not exist
[[ ! -d "${BACKUP_ROOT_PATH}" ]] && die "Backup directory does not exist"
# die if directory is not writable
[[ ! -w "${BACKUP_ROOT_PATH}" ]] && die "Backup directory is not writable"
# die if directory is not a directory
[[ ! -d "${BACKUP_ROOT_PATH}" ]] && die "Backup directory is not a directory"
# die if directory is root (/)
[[ "${BACKUP_ROOT_PATH}" == "/" ]] && die "Backup directory should not be root dir /"

echo "=== Azure DevOps Repository Backup Script ==="

# Initialize POSITIONAL array
POSITIONAL=()

set -- "${POSITIONAL[@]}" # restore positional parameters

echo "=== Script parameters"
#echo "PAT               = ${PAT}"
echo "ORGANIZATION_URL  = ${ORGANIZATION}"
echo "BACKUP_ROOT_PATH  = ${BACKUP_ROOT_PATH}"
echo "RETENTION_DAYS    = ${RETENTION_DAYS}"
echo "DRY_RUN           = ${DRY_RUN}"
echo "PROJECT_WIKI      = ${PROJECT_WIKI}"
echo "VERBOSE_MODE      = ${VERBOSE_MODE}"
echo "COMPRESS          = ${COMPRESS}"

#Store script start time
start_time=$(date +%s)

# git tuning
git config --global http.postBuffer 524288000
git config --global core.compression 0
git config --global http.version HTTP/1.1
if [[ "${VERBOSE_MODE}" == "true" ]]; then
  echo "=== Show git config (git config --list):"
  git config --list --show-scope
fi


#Install the Devops extension
echo "=== Install DevOps Extension"
az extension add --name 'azure-devops'

#Set this environment variable with a PAT will 'auto login' when using 'az devops' commands
echo "=== Set AZURE_DEVOPS_EXT_PAT env variable"
export AZURE_DEVOPS_EXT_PAT=${PAT} 
#Store PAT in Base64
B64_PAT=$(printf "%s"":${PAT}" | base64 -w 0)

echo "=== Get project list"
ProjectList=$(az devops project list --organization ${ORGANIZATION} --query 'value[]')

[[ -z $ProjectList ]] && die "ERROR: empty project list, wrong azure cli parameters?"

#Create backup folder with current time as name
BACKUP_FOLDER=$(date +"%Y%m%d%H%M")
BACKUP_DIRECTORY="${BACKUP_ROOT_PATH}/${BACKUP_FOLDER}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== Simulate Backup folder creation [${BACKUP_DIRECTORY}]"
else
  mkdir -p "${BACKUP_DIRECTORY}"
  if [[ $? -ne 0 ]]; then
    die "=== Backup folder creation failed [${BACKUP_DIRECTORY}]"
  else
    echo "=== Backup folder created [${BACKUP_DIRECTORY}]"
  fi
fi

# Show project list
PROJECT_COUNTER=0
for project in $(echo "${ProjectList}" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${project} | base64 -d | jq -r ${1}
  }
  echo "==> Found project [${PROJECT_COUNTER}] [$(_jq '.name')]"
  ((PROJECT_COUNTER++))
done

#Initialize counters
PROJECT_COUNTER=0
REPO_COUNTER=0

# start process projects
for project in $(echo "${ProjectList}" | jq -r '.[] | @base64'); do

  WIKI_COUNTER=0

  _jq() {
    echo ${project} | base64 -d | jq -r ${1}
  }
  echo "==> Backup project [${PROJECT_COUNTER}] [$(_jq '.name')] [$(_jq '.id')]"

  #Get current project name and normalize it to create folder
  CURRENT_PROJECT_NAME=$(_jq '.name')
  CURRENT_WIKI_PROJECT_NAME=$(echo $CURRENT_PROJECT_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/-/g')    
  CURRENT_PROJECT_NAME=$(echo $CURRENT_PROJECT_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/_/g')
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "=== Simulate Backup folder created [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
  else
    mkdir -p "${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}"
    if [[ $? -ne 0 ]]; then
      die "=== Backup folder creation failed [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
    else
      echo "=== Backup folder created [${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}]"
    fi
  fi
  
  #Get Repository list for current project id.
  REPO_LIST_CMD="az repos list --organization ${ORGANIZATION} --project $(_jq '.id')"
  REPO_LIST=$($REPO_LIST_CMD)
  # echo ${REPO_LIST}

  for repo in $(echo "${REPO_LIST}" | jq -r '.[] | @base64'); do
    _jqR() {
        echo ${repo} | base64 -d | jq -r ${1}           
    }
    
    # There must always be at least one repository per Team Project.
    if [[ ${WIKI_COUNTER} -eq 0 ]]; then
      CURRENT_BASE_WIKI_URL=$(_jqR '.webUrl')  
      ((WIKI_COUNTER++))        
    fi

    echo "====> Backup repo [${REPO_COUNTER}][$(_jqR '.name')] [$(_jqR '.id')] [$(_jqR '.webUrl')]"
            
    #Get current repo name and normalize it to create folder
    CURRENT_REPO_NAME=$(_jqR '.name')
    CURRENT_REPO_NAME=$(echo $CURRENT_REPO_NAME | sed -e 's/[^A-Za-z0-9._\(\)-]/_/g')
    CURRENT_REPO_DIRECTORY="${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}/repo/${CURRENT_REPO_NAME}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "Simulate git clone ${CURRENT_REPO_NAME}"
    else
        # check if repo is disabled and skip it
        # disabled repos cannot be accessed
        if [[ "$(_jqR '.isDisabled')" == "false" ]]; then
          # Use Base64 PAT in header to authenticate on Git Repository
          git -c http.extraHeader="Authorization: Basic ${B64_PAT}" clone $(_jqR '.webUrl') ${CURRENT_REPO_DIRECTORY}
          if [ $? -ne 0 ]; then
            echo "====> Backup failed for repo [${CURRENT_REPO_NAME}]"
            delete_partial_backup
            die "=== Backup failed for repo [${CURRENT_REPO_NAME}], exiting"
          fi
        else
          echo "====> Skipping disabled repo: [${CURRENT_REPO_NAME}]"
        fi
    fi        
    ((REPO_COUNTER++))
  done

  if [[ "${PROJECT_WIKI}" == "true" ]]; then
      CURRENT_WIKI_DIRECTORY="${BACKUP_DIRECTORY}/${CURRENT_PROJECT_NAME}/wiki/${CURRENT_WIKI_PROJECT_NAME}"             
      CURRENT_BASE_WIKI_URL=$(echo $CURRENT_BASE_WIKI_URL | sed -E 's/(https:\/\/dev.azure.com\/.+\/_git\/)(.+)$/\1/g')
      CURRENT_WIKI_URL="${CURRENT_BASE_WIKI_URL}${CURRENT_WIKI_PROJECT_NAME}.wiki"
      if [[ "${DRY_RUN}" == "true" ]]; then
          echo "Simulate WIKI git clone ${CURRENT_WIKI_PROJECT_NAME}"
      else
        echo "====> Backup Wiki repo ${CURRENT_WIKI_URL}"            
        git -c http.extraHeader="Authorization: Basic ${B64_PAT}" clone ${CURRENT_WIKI_URL} ${CURRENT_WIKI_DIRECTORY}
        if [ $? -ne 0 ]; then
          # if wiki fails give only a warning and continue (maybe is not defined)
          echo "====> WARNING: backup failed for repo [${CURRENT_WIKI_URL}]"
          echo "====> WARNING: wiki not defined?"
        fi
      fi
  fi
  ((PROJECT_COUNTER++))
done

# if DRYRUN true skip useless steps
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "=== Skip compress and retention in DRYRUN mode ==="
  echo "=== Backup completed ==="
  exit 0
fi

if [[ "${VERBOSE_MODE}" == "true" ]]; then
  echo "=== Backup structure ==="
  find ${BACKUP_DIRECTORY} -maxdepth 2 -ls
fi

backup_size_uncompressed=$(du -hs ${BACKUP_DIRECTORY})

echo "=== Backup completed ==="
echo  "Projects : ${PROJECT_COUNTER}"
echo  "Repositories : ${REPO_COUNTER}"

cd ${BACKUP_ROOT_PATH}

if [[ "$COMPRESS" == "true" ]]; then
  echo "=== Compress folder"
  tar czf ${BACKUP_FOLDER}.tar.gz --checkpoint=50000 --checkpoint-action=echo="#%u: %T" ${BACKUP_FOLDER}
  if [[ $? -lt 2 ]]; then
    backup_size_compressed=$(du -hs ${BACKUP_FOLDER}.tar.gz)
    echo "Size : ${backup_size_uncompressed} (uncompressed) - ${backup_size_compressed} (compressed)"
    echo "=== Remove raw data in folder"
    rm -rf ${BACKUP_FOLDER}
  else
    BACKUP_SUCCESS=false
    echo "=== ERROR: tar command exited with fatal error!"
    rm -rf ${BACKUP_FOLDER}
    rm -f ${BACKUP_FOLDER}.tar.gz
  fi
else
  echo "Size : ${backup_size_uncompressed} (uncompressed)"
fi

# apply retention policy according to options
if [[ "${BACKUP_SUCCESS}" == "true" ]]; then
  if [[ "${COMPRESS}" == "true" ]]; then
    # doublecheck for BACKUP_ROOT_PATH
    if [ -n "${BACKUP_ROOT_PATH}" -a "${BACKUP_ROOT_PATH}" != "/" ]; then
      echo "=== Apply retention policy (${RETENTION_DAYS} days):"
      echo "=== i'm going to delete following files:"
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type f -regextype posix-extended -regex ".*/[0-9]{12}\\.tar\\.gz$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type f -regextype posix-extended -regex ".*/[0-9]{12}\\.tar\\.gz$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -delete
      echo "=== Done."
    else
      echo "=== Skip deletion due to invalid backup directory (${BACKUP_ROOT_PATH})"
    fi
  else
    # doublecheck for BACKUP_ROOT_PATH
    if [ -n "${BACKUP_ROOT_PATH}" -a "${BACKUP_ROOT_PATH}" != "/" ]; then
      echo "=== Apply retention policy (${RETENTION_DAYS} days):"
      echo "=== i'm going to delete following backup directories:"
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type d -regextype posix-extended -regex ".*/[0-9]{12}$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print
      find ${BACKUP_ROOT_PATH} -mindepth 1 -maxdepth 1 \
        -type d -regextype posix-extended -regex ".*/[0-9]{12}$" \
        -daystart -mtime +${RETENTION_DAYS} \
        -print0 | xargs -0 -r -- rm -rf
      echo "=== Done."
    else
      echo "=== Skip deletion due to invalid backup directory (${BACKUP_ROOT_PATH})"
    fi
  fi
  # calculate and print elapsed time since start
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))
  eval "echo Elapsed time : $(date -ud "@$elapsed" +'$((%s/3600/24)) days %H hr %M min %S sec')"
else
  die "=== Backup failed, retention policy not applied, exiting"
fi
