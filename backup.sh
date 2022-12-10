#!/bin/bash
#
# Version:  0.6.2 (2022-12-08)
# Author:   Mischa Schindowski <mschindowski@gmail.com>
# License:  MIT, see LICENSE
#
# Usage:
#
# ./backup.sh command [host] [options]
#
# OPTIONS
#
# command and host:
#
# command:
#
# backup    do backup of a specific host
# rotate    rotate backups
# list      list avaiable backups per host with age (useful for monitoring)
# check     check access for the configuration
#
# host:     host to backup, mandatory when command = backup
#
# options:
#
# -c, --config-json <file>
#     Location of the configuration JSON file
#
# -s, --secret-json <file>
#     Location of the secret JSON file with credentials
#
# -v, --verbose
#     Verbose output, default off
#
# -h, --help
#     Display help.

# global configuration (or set by -c and -s)
# CONFIG_JSON="$HOME/backup-sh-config.json"
# SECRET_JSON="$HOME/.env.backup-sh.json"

# Where to put lock files, make sure user has write permissions
RUN_DIR="/var/run/backup-sh"

# dateformat of backup files
#
# for rotating the daily, weekly, monthly and yearly backups the format
# should not be changed
#
# format: <filename>.<dateformat>.<extension>
# example:
#
# demo-database.2022-11-05-135622-w38.sql.gz
NOW=`date +%Y-%m-%d-%H%M%S-w%V`

# Periods to keep
readonly -a PERIODS=(daily weekly monthly yearly)

# How many backups to keep for each period
readonly -A PERIOD_KEEPS=([daily]=14 [weekly]=5 [monthly]=13 [yearly]=4)

# Times of periods in seconds
readonly -A PERIOD_TIMES=([daily]=86400 [weekly]=604800 [monthly]=2419200 [yearly]=31536000)

# Patterns of the filenames to check against existance
# First can be omitted, because a period is not tested against itself, only the next
readonly -A PERIOD_PATTERS=([weekly]=+%Y-%m-??-??????-w%V [monthly]=+%Y-%m-??-??????-w?? [yearly]=+%Y-??-??-??????-w??)

# start to parse with getopt and display help if needed

# Display help
display_help() {
  echo -e "\nUsage:
  backup.sh [options] [command]
  backup.sh [optoins] backup <host>
  backup.sh [options] rotate
  backup.sh [options] list

Backup or rotate databases and files to a specific folder.

Commands:
  backup <host>       backup database and files of a given host
  rotate              rotate all backup files (daily, weekly, monthly, yearly)
  list                list avaiable backups per host with age (useful for monitoring)
  check               check access for the configuration

Options:
  -c, --config-json   configuration of hosts, files, databases to backup
  -s, --secret-json   credentials for database dumps
  -v, --verbose       print output
  -n, --no-log        do not log anything to syslog or stdout
  -h, --help          display this
  "
}

# Define and read options
#
# Implemented right at the beginning to only allow available commands.
SHORT_OPTS=v,h,c:,s:,n,
LONG_OPTS=verbose,help,config-json:,secret-json:,no-log,_completion

set +e
OPTS=$(getopt -a -n backup.sh -o $SHORT_OPTS -l $LONG_OPTS -- "$@")
if [ $? -ne 0 ]; then
  display_help
  exit 1
fi
set -e

# Logs messages to syslog with logger
#
# When -v is given, it prints it to stdout.
log() {
  local args=""

  if [[ "$NO_LOG" == "true" ]]; then
    return 0
  fi

  MSG=`echo $1`

  if [[ "${VERBOSE}" == true ]]; then
    args="-s"
  fi

  logger $args -p local0.notice -t `basename $0` -- $MSG
}

# Checks if the process is already running
#
# Check is differentiating between command and host if backup is running.
check_is_running() {
  if [[ "${COMMAND}" == "backup" ]]; then
    flockfile="${COMMAND}-${HOST}.lock"
  else
    flockfile="${COMMAND}.lock"
  fi

  if { set -C; 2>/dev/null >${RUN_DIR}/${flockfile}; }; then
    trap "rm ${RUN_DIR}/${flockfile}" EXIT
  else
    log "Command (${COMMAND}) already running"
    exit 0
  fi
}

# Find values in JSON files
#
# @param file       JSON file
# @param filter     Filter as 'jq' is defining it
# @param raw        String "raw" adds -r to jq
# @param operator   Operater for jq including pipe '| <operator>'
# @return           Output of jq
json_value() {
  local file=$1
  local filter=$2
  local args=""
  local operator=""

  if [[ "${3}" == "raw" ]]; then
    args="-r"
  fi

  if [[ "${4}" != "" ]]; then
    operator="| ${4}"
  fi

  v=$(jq $args ''"${filter} ${operator}"'' ${file})

  if [[ "${v}" == "null" ]]; then
    log "config: Value for ${filter} not found"
    exit 1
  fi

  echo $v
}

# Find a value in the config.json
# @see json_value() for details
#
# @param filter
# @param raw
# @param operator
# @return           Output of jq
config_value() {
  json_value $CONFIG_JSON "${1}" "${2}" "${3}"
}

# Find a value in the .env.json
# @see json_value() for details
#
# @param filter
# @param raw
# @param operator
# @return           Output of jq
secret_value() {
  json_value $SECRET_JSON "${1}" "${2}" "${3}"
}

# Ensures the given directory exists
#
# @param dir    Directory to create
ensure_dir() {
  if [[ "${1}" == "" ]]; then
    log "Can not ensure empty dir"
    exit 1
  fi

  [ -d $1 ] || mkdir -p $1
}

# Ensures the main backup directory exists
ensure_backup_dir() {
  ensure_dir $BACKUP_DIR
}

# Ensure the pariod dirs in the diven directory
#
# @param dir    Directory to create
ensure_period_dirs() {
  if [[ "${1}" == "" ]]; then
    log "Can not ensure empty dir"
    exit 1
  fi

  for period in "${PERIODS[@]}"; do
    [ -d "${1}/${period}" ] || mkdir -p "${1}/${period}"
  done
}

# Backup the given host
#
# Host is defined by command line argument and stored in $HOST.
backup_command() {
  ensure_backup_dir

  host=$HOST
  first_period=${PERIODS[0]}
  hostname=$(config_value ".hosts[\"${host}\"].hostname" raw)

  # backup directories
  if [[ `jq ".hosts[\"${host}\"] | has(\"files\")" $CONFIG_JSON` == "true" ]]; then
    file_backups=$(config_value ".hosts[\"${host}\"].files" raw 'keys | .[]')
    for file_backup in $file_backups; do
      ssh_user=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].ssh_user" raw)
      dir="${BACKUP_DIR}/${host}/files/${file_backup}/${first_period}"
      backup_dirs=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].directories" raw '.[]')
      base_dir=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].base_dir" raw)
      file="${file_backup}.${NOW}.tar.gz"

      ensure_dir $dir

      log "Backing up: files ${file_backup} at host ${host}"

      # NOTE: tar returns 0 on success, 1 if files differ: this can happen,
      #   when files are changed during read.
      #
      # To not end the backup, ignore the file-changed error (still returns 1)
      # and exit only on other tar errors
      set +e
      ssh ${ssh_user}@${hostname} "tar --warning=no-file-changed -cz -C ${base_dir} ${backup_dirs}" > ${dir}/${file}
      if [ "$?" != "1" ] && [ "$?" != "0" ]; then
        exit $?
      fi
      set -e

      log "Backup succeded: files ${file_backup} at host ${host}"
    done
  fi
  # /backup directories

  # backup databases
  if [[ `jq ".hosts[\"${host}\"] | has(\"databases\")" $CONFIG_JSON` == "true" ]]; then
    databases=$(config_value ".hosts[\"${host}\"].databases" raw 'keys | .[]')
    for db in $databases; do
      ssh_user=$(config_value ".hosts[\"${host}\"].databases[\"${db}\"].ssh_user" raw)
      dbuser=$(secret_value ".[\"${host}\"].databases[\"${db}\"].user" raw)
      dbpass=$(secret_value ".[\"${host}\"].databases[\"${db}\"].password" raw)
      file="${db}.${NOW}.sql.gz"
      dir="${BACKUP_DIR}/${host}/databases/${db}/${first_period}"

      if [[ `jq ".hosts[\"${host}\"].databases[\"${db}\"] | has(\"extra_opts\")" $CONFIG_JSON` == "true" ]]; then
        extra_opts=$(config_value ".hosts[\"${host}\"].databases[\"${db}\"].extra_opts" raw)
      else
        extra_opts=""
      fi

      ensure_dir $dir

      log "Backing up: database ${db} at host ${host}"

      # Save mysql password to use mysqldump without password with defaults-file
      echo -e "[client_backup]\npassword=$dbpass" | ssh ${ssh_user}@${hostname} "cat > ~/.my-backup.cnf && chmod 600 ~/.my-backup.cnf"

      # Backup the given database with mysqldump, write errors to .my-backup.err:
      # This file should be empty on success.
      ssh ${ssh_user}@${hostname} "mysqldump --defaults-file=~/.my-backup.cnf --defaults-group-suffix=_backup -q ${extra_opts} -u ${dbuser} -h localhost $db 2>~/.my-backup.err | gzip -9" > ${dir}/${file}
      errors=$(ssh ${ssh_user}@${hostname} "cat ~/.my-backup.err")

      # If mysqldump did not succeed:
      # * log error
      # * delete defaults-file on remote host
      # * delete created backup-file (an empty .gz file)
      # * exit
      if [[ $errors != "" ]]; then
        log "Remote error: $errors"

        # cleanup secrets
        ssh ${ssh_user}@${hostname} "rm ~/.my-backup.cnf"

        # remove created backup (will be empty)
        [ -f "${dir}/${file}" ] && rm "${dir}/${file}"

        exit 1
      else
        log "Backup succeded: database ${db} at host ${host}"
      fi

      # Remove defaults-file on remote host
      ssh ${ssh_user}@${hostname} "rm ~/.my-backup.cnf"
    done
  fi
  # /backup databases
}

# Rotate all the backup files
rotate_command() {
  # Construct a list of directories where to rotate
  dirs=()
  hosts=$(config_value ".hosts" raw 'keys | .[]')
  for host in $hosts; do
    # skip hosts without a dir, no backup made so far
    if [ ! -d "${BACKUP_DIR}/${host}" ]; then
      continue
    fi

    # check database dirs (databases)
    if [[ `jq ".hosts[\"${host}\"] | has(\"databases\")" $CONFIG_JSON` != "true" ]]; then
      continue
    fi
    databases=$(config_value ".hosts[\"${host}\"].databases" raw 'keys | .[]')
    for db in $databases; do
      # skip databases without a dir, no backup made so far
      if [ ! -d "${BACKUP_DIR}/${host}/databases/${db}" ]; then
        continue
      fi

      dirs+=("${BACKUP_DIR}/${host}/databases/${db}")
    done

    # check dirs for file backup (files)
    if [[ `jq ".hosts[\"${host}\"] | has(\"files\")" $CONFIG_JSON` != "true" ]]; then
      continue
    fi
    file_backups=$(config_value ".hosts[\"${host}\"].files" raw 'keys | .[]')
    for file_backup in $file_backups; do
      # skip file backups without a dir, no backup made so far
      if [ ! -d "${BACKUP_DIR}/${host}/files/${file_backup}" ]; then
        continue
      fi

      dirs+=("${BACKUP_DIR}/${host}/files/${file_backup}")
    done
  done

  # loop over existing directories to rotate
  for dir in "${dirs[@]}"; do
    # create the period dirs
    ensure_period_dirs $dir

    # loop over names of periods (daily, weekly, ...)
    i_p=1
    for period in "${PERIODS[@]}"; do
      max_age=$((${PERIOD_KEEPS[$period]} * ${PERIOD_TIMES[$period]}))
      next_period=${PERIODS[$i_p]}

      # loop over files in the period dirs
      for file in `ls -Art "${dir}/${period}"`; do
        ts=`date +%s -r "${dir}/${period}/$file"`
        age=$(($(date +%s) - $ts))

        if [[ $age -gt $max_age ]]; then
          if [[ "${next_period}" != "" ]]; then
            pattern=$(date -d @$ts ${PERIOD_PATTERS[$next_period]})

            # check if a file is in the next period
            if ! compgen -G "${dir}/${next_period}/*.$pattern.*" > /dev/null; then
              mv ${dir}/${period}/$file ${dir}/${next_period}/
            else
              rm ${dir}/${period}/$file
            fi
          else
            rm ${dir}/${period}/$file
          fi
        fi
      done
      let i_p=i_p+1
    done
  done
}

# Runs the list command
#
# Lists the most recent backup made by each host. Age is displayed as seconds
# since creation. Can be used to monitor the backups (e.g. with Nagios).
list_command() {
  last_backups=()
  first_period=${PERIODS[0]}
  hosts=$(config_value ".hosts" raw 'keys | .[]')
  for host in $hosts; do
    # skip hosts without a dir, no backup made so far
    if [ ! -d "${BACKUP_DIR}/${host}" ]; then
      last_backups+=("${host}:-:-:-")
      continue
    fi

    # check database dirs (databases)
    # skip, if no databases are defined
    if [[ `jq ".hosts[\"${host}\"] | has(\"databases\")" $CONFIG_JSON` != "true" ]]; then
      continue
    fi
    databases=$(config_value ".hosts[\"${host}\"].databases" raw 'keys | .[]')
    for db in $databases; do
      dir="${BACKUP_DIR}/${host}/databases/${db}"

      # skip databases without a dir, no backup made so far
      if [ ! -d "${dir}" ]; then
        last_backups+=("${host}:databases:${db}:-")
        continue
      fi

      latest_backup=$(ls -Art ${dir}/${first_period} | tail -n1)
      # no backup in dir, skip
      if [[ "${latest_backup}" == "" ]]; then
        last_backups+=("${host}:databases:${db}:-")
        continue
      fi

      ts=$(date +%s -r ${dir}/${first_period}/${latest_backup})
      age=$(($(date +%s) - $ts))

      last_backups+=("${host}:databases:${db}:${age}")
    done

    # check dirs for file backup (files)
    # skip, if no files are defined
    if [[ `jq ".hosts[\"${host}\"] | has(\"files\")" $CONFIG_JSON` != "true" ]]; then
      continue
    fi

    file_backups=$(config_value ".hosts[\"${host}\"].files" raw 'keys | .[]')
    for file_backup in $file_backups; do
      dir="${BACKUP_DIR}/${host}/files/${file_backup}"

      # skip file backups without a dir, no backup made so far
      if [ ! -d "${dir}" ]; then
        last_backups+=("${host}:files:${file_backup}:-")
        continue
      fi

      latest_backup=$(ls -Art ${dir}/${first_period} | tail -n1)
      # no backup in dir, skip
      if [[ "${latest_backup}" == "" ]]; then
        last_backups+=("${host}:files:${file_backup}:-")
        continue
      fi

      ts=$(date +%s -r ${dir}/${first_period}/${latest_backup})
      age=$(($(date +%s) - $ts))

      last_backups+=("${host}:files:${file_backup}:${age}")
    done
  done

  printf "%s\n" "${last_backups[@]}"
}

# Runs the check command
#
# Checks if the access to the hosts and databases works, and if the
# directories in the files exists.
check_command() {
  set +e
  hosts=$(config_value ".hosts" raw 'keys | .[]')
  for host in $hosts; do
    echo "Checking ${host}..."
    hostname=$(config_value ".hosts[\"${host}\"].hostname" raw)

    if [[ "${hostname}" == "" ]]; then
      echo "[!!] hostname not defined for ${host}"
      continue
    fi

    if [[ `jq ".hosts[\"${host}\"] | has(\"files\")" $CONFIG_JSON` == "true" ]]; then
      file_backups=$(config_value ".hosts[\"${host}\"].files" raw 'keys | .[]')
      for file_backup in $file_backups; do
        ssh_user=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].ssh_user" raw)
        ret=$(ssh ${ssh_user}@${hostname} "exit" 2>&1)
        if [[ $? == 0 ]]; then
          echo "[OK] files: ${file_backup} => SSH access okay"
        else
          echo "[!!] files: ${file_backup} => SSH error: ${ret}"
          continue
        fi
        base_dir=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].base_dir" raw)

        ret=$(ssh ${ssh_user}@${hostname} "ls ${base_dir}" 2>&1)
        if [[ $? == 0 ]]; then
          echo "[OK] files: ${file_backup} => base_dir found"
        else
          echo "[!!] files: ${file_backup} => base_dir error: ${ret}"
          continue
        fi

        dirs=()
        directories=$(config_value ".hosts[\"${host}\"].files[\"${file_backup}\"].directories" raw '.[]')
        for directory in $directories; do
          dirs+="${base_dir}/${directory} "
        done

        ret=$(ssh ${ssh_user}@${hostname} "ls $dirs" 2>&1)
        if [[ $? == 0 ]]; then
          echo "[OK] files: ${file_backup} => directories found"
        else
          echo "[!!] files: ${file_backup} => directories error: ${ret}"
          continue
        fi
      done
    fi

    if [[ `jq ".hosts[\"${host}\"] | has(\"databases\")" $CONFIG_JSON` == "true" ]]; then
      databases=$(config_value ".hosts[\"${host}\"].databases" raw 'keys | .[]')
      for db in $databases; do
        ssh_user=$(config_value ".hosts[\"${host}\"].databases[\"${db}\"].ssh_user" raw)
        dbuser=$(secret_value ".[\"${host}\"].databases[\"${db}\"].user" raw)
        dbpass=$(secret_value ".[\"${host}\"].databases[\"${db}\"].password" raw)

        if [[ "${dbuser}" == "" ]]; then
          echo "[!!] databases: ${db} => dbuser not defined for ${host} and ${db}"
          continue
        fi

        if [[ "${dbpass}" == "" ]]; then
          echo "[!!] databases: ${db} => dbpass not defined for ${host} and ${db}"
          continue
        fi

        if [[ `jq ".hosts[\"${host}\"].databases[\"${db}\"] | has(\"extra_opts\")" $CONFIG_JSON` == "true" ]]; then
          extra_opts=$(config_value ".hosts[\"${host}\"].databases[\"${db}\"].extra_opts" raw)
        else
          extra_opts=""
        fi

        # Save mysql password to use mysqldump without password with defaults-file
        echo -e "[client_backup]\npassword=$dbpass" | ssh ${ssh_user}@${hostname} "cat > ~/.my-backup.cnf && chmod 600 ~/.my-backup.cnf"

        # Backup the given database with mysqldump with --no-data
        ret=$(ssh ${ssh_user}@${hostname} "mysqldump --defaults-file=~/.my-backup.cnf --defaults-group-suffix=_backup --no-data -q ${extra_opts} -u ${dbuser} -h localhost $db > /dev/null")
        if [[ $? == 0 ]]; then
          echo "[OK] databases: ${db} => test-dump OK"
        else
          echo "[!!] databases: ${db} => MySQL error: ${ret}"
          continue
        fi

        # Remove defaults-file on remote host
        ssh ${ssh_user}@${hostname} "rm ~/.my-backup.cnf"
      done
    fi
  done
}

# Runs the given command
#
# @param command    Command: backup, rotate, ...
run_command() {
  if [[ "${1}" == "" ]]; then
    log "Can not run empty command"
    exit 1
  fi

  case "$1" in
    'backup')
      backup_command
      ;;
    'rotate')
      rotate_command
      ;;
    'list')
      list_command
      ;;
    'check')
      check_command
      ;;
  esac
}

# Parse given options and set global variables
parse_opts() {

  # defaults:
  VERBOSE=false

  # verify getopts, set:
  # * VERBOSE
  #
  # display help
  eval set -- "$OPTS"
  while true; do
    case "$1" in
      '-v'|'--verbose')
        VERBOSE=true
        shift
        continue
        ;;
      '-h'|'--help')
        display_help
        exit 0
        ;;
      '-c'|'--config-json')
        CONFIG_JSON=$2
        shift 2
        continue
        ;;
      '-s'|'--secret-json')
        SECRET_JSON=$2
        shift 2
        continue
        ;;
      '-n'|'--no-log')
        NO_LOG=true
        shift
        continue
        ;;
      '--_completion')
        _completion
        exit 0
        ;;
      '--')
        shift
        break;
        ;;
      *)
        echo "Unexpected option: $1"
        display_help
        exit 1
        ;;
    esac
  done

  # remaining args, check for command
  ARGC=$#

  if [ $ARGC -lt 1 ]; then
    echo "Command missing (backup, rotate)"
    display_help
    exit 1
  fi

  COMMAND=$1
  case "$COMMAND" in
    'backup')
      if [ $ARGC -lt 2 ]; then
        echo "Host for backup command missing"
        display_help
        exit 1
      fi

      HOST=$2
      ;;
    'rotate')
      # no further check, run
      ;;
    'list')
      # no further check, run
      ;;
    'check')
      # no further check, run
      ;;
    *)
      echo "Unknown command: $COMMAND"
      display_help
      exit 1
      ;;
  esac
}

# Checks if the configuration is available and assigns important variables.
#
# Checks for the following files:
# * config.json set by argument -c as variable $CONFIG_JSON
# * .env.json (database secrets and other passwords) set by argument -s as
#   variable $SECRET_JSON
#
# Assigns the following variables:
# * BACKUP_DIR    main backup directory
check_config() {
  if [ ! -d "${RUN_DIR}" ]; then
    log "Run dir does not exist: $RUN_DIR"
    exit 1
  fi

  if [ ! -w "${RUN_DIR}" ]; then
    log "Can not write to directory: $RUN_DIR"
    exit 1
  fi

  if [ ! -f "${CONFIG_JSON}" ]; then
    log "config.json not found at: $CONFIG_JSON"
    exit 1
  fi

  if [ ! -f "${SECRET_JSON}" ]; then
    log ".env.json not found at: $SECRET_JSON"
    exit 1
  fi

  if [[ "${COMMAND}" == "backup" ]]; then
    if [[ `jq '.hosts | has("'$HOST'")' $CONFIG_JSON` != "true" ]]; then
      log "Host not found in config.json: ${HOST}"
      exit 1
    fi
  fi

  if [[ `jq '. | has("BACKUP_DIR")' $CONFIG_JSON` != "true" ]]; then
    echo "backup_dir not defined"
  fi
  BACKUP_DIR=$(config_value ".BACKUP_DIR" raw)
}

# Run main application
main() {
  parse_opts

  starttime=$(date +%Y%m%d%H%M.%S)

  log "Command (${COMMAND}) started at `date`"

  check_config
  check_is_running

  run_command ${COMMAND}

  log "Command (${COMMAND}) completed at `date`"
}

# Very simple completion
#
# Will be executed if this script is executed by:
# ./backup.sh --_completion
#
# OPTIMIZE: long options could be implemented
_completion() {
  echo -e "-c\tLocation of the config JSON"
  echo -e "-s\tLocation of the secret JSON"
  echo -e "-v\tVerbose output"
  echo -e "-h\tShow help"
  echo -e "rotate\tRotate files"
  echo -e "backup\tBackup host (backup <host>)"
  echo -e "list\tList available backups"
  echo -e "check\tCheck access and directories"
}

main
