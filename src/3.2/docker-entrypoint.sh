#!/bin/bash -eu

cmd="$1"

# We intentionally chown /data to root in Dockerfile so we can detect
# if no volume is mounted
if [[ "$(stat -c %u /data)" != "0" ]]; then
  # /data is a volume, is the same uid/gid for neo4j user
  user_uid="$(stat -c %u /data)"
  user_gid="$(stat -c %g /data)"
elif [ -d /conf ] && [[ "${cmd}" == "dump-config" ]]; then
  # A configuration volume has been mounted and we are dumping config
  user_uid="$(stat -c %u /conf)"
  user_gid="$(stat -c %g /conf)"
fi


# Only add group if it does not already exist which can happen
#   1. if the docker container is restarted
#   2. if the mounted directory has group "nobody" for example which is a default group
# And only add with specific GID if mounted directory
if [[ "${user_gid:-0}" = 0 ]]; then
  if ! getent group neo4j >/dev/null; then
    addgroup -S neo4j
  fi
  user_gid=$(getent group neo4j | awk -F ':' '{ print $3 }')
# Check if a group with that gid already exists, and if so don't add a neo4j group
elif ! getent group | awk -F ':' '{ print $3 }' | grep -q "${user_gid}"; then
  addgroup -S -g "${user_gid}" neo4j
fi

group_name=$(getent group "${user_gid}" | awk -F ':' '{ print $1 }')
readonly group_name

# Only add user if it does not already exist
if [[ "${user_uid:-0}" = 0 ]]; then
  if ! getent passwd neo4j >/dev/null; then
    adduser -S -H -h /var/lib/neo4j -G "${group_name}" neo4j
  fi
  user_uid=$(getent passwd neo4j | awk -F ':' '{ print $3 }')
elif ! getent passwd | awk -F ':' '{ print $3 }' | grep -q "${user_uid}"; then
  adduser -S -u "${user_uid}" -H -h /var/lib/neo4j -G "${group_name}" neo4j
fi

user_name=$(getent passwd "${user_uid}" | awk -F ':' '{ print $1 }')
readonly user_name

# Need to chown the home directory - but a user might have mounted a
# volume here. So take care not to chown volumes (stuff not owned by
# root due to our intentional chowning to root in the Dockerfile)
if [[ "$(stat -c %u /var/lib/neo4j)" = "0" ]]; then
  # Non-recursive chown for the base directory
  chown "${user_name}:${group_name}" /var/lib/neo4j
fi

while IFS= read -r -d '' dir
do
  if [[ "$(stat -c %u "${dir}")" = "0" ]]; then
    # Using mindepth 1 to avoid the base directory here so recursive is OK
    chown -R "${user_name}:${group_name}" "${dir}"
  fi
done <   <(find /var/lib/neo4j -type d -mindepth 1 -maxdepth 1 -print0)

# Data dir is chowned later

if [ "${cmd}" == "dump-config" ]; then
  if [ -d /conf ]; then
    # Run with neo4j user so we write files with correct permissions
    su-exec "${user_name}" cp --recursive conf/* /conf
    exit 0
  else
    echo >&2 "You must provide a /conf volume"
    exit 1
  fi
fi

# Env variable naming convention:
# - prefix NEO4J_
# - double underscore char '__' instead of single underscore '_' char in the setting name
# - underscore char '_' instead of dot '.' char in the setting name
# Example:
# NEO4J_dbms_tx__log_rotation_retention__policy env variable to set
#       dbms.tx_log.rotation.retention_policy setting

# Backward compatibility - map old hardcoded env variables into new naming convention (if they aren't set already)
# Set some to default values if unset
: ${NEO4J_dbms_tx__log_rotation_retention__policy:=${NEO4J_dbms_txLog_rotation_retentionPolicy:-"100M size"}}
: ${NEO4J_wrapper_java_additional:=${NEO4J_UDC_SOURCE:-"-Dneo4j.ext.udc.source=docker"}}
: ${NEO4J_dbms_memory_heap_initial__size:=${NEO4J_dbms_memory_heap_maxSize:-"512M"}}
: ${NEO4J_dbms_memory_heap_max__size:=${NEO4J_dbms_memory_heap_maxSize:-"512M"}}
: ${NEO4J_dbms_unmanaged__extension__classes:=${NEO4J_dbms_unmanagedExtensionClasses:-}}
: ${NEO4J_dbms_allow__format__migration:=${NEO4J_dbms_allowFormatMigration:-}}
: ${NEO4J_dbms_connectors_default__advertised__address:=${NEO4J_dbms_connectors_defaultAdvertisedAddress:-}}
: ${NEO4J_ha_server__id:=${NEO4J_ha_serverId:-}}
: ${NEO4J_ha_initial__hosts:=${NEO4J_ha_initialHosts:-}}
: ${NEO4J_causal__clustering_expected__core__cluster__size:=${NEO4J_causalClustering_expectedCoreClusterSize:-}}
: ${NEO4J_causal__clustering_initial__discovery__members:=${NEO4J_causalClustering_initialDiscoveryMembers:-}}
: ${NEO4J_causal__clustering_discovery__listen__address:=${NEO4J_causalClustering_discoveryListenAddress:-"0.0.0.0:5000"}}
: ${NEO4J_causal__clustering_discovery__advertised__address:=${NEO4J_causalClustering_discoveryAdvertisedAddress:-"$(hostname):5000"}}
: ${NEO4J_causal__clustering_transaction__listen__address:=${NEO4J_causalClustering_transactionListenAddress:-"0.0.0.0:6000"}}
: ${NEO4J_causal__clustering_transaction__advertised__address:=${NEO4J_causalClustering_transactionAdvertisedAddress:-"$(hostname):6000"}}
: ${NEO4J_causal__clustering_raft__listen__address:=${NEO4J_causalClustering_raftListenAddress:-"0.0.0.0:7000"}}
: ${NEO4J_causal__clustering_raft__advertised__address:=${NEO4J_causalClustering_raftAdvertisedAddress:-"$(hostname):7000"}}

: ${NEO4J_dbms_connectors_default__listen__address:="0.0.0.0"}
: ${NEO4J_dbms_connector_http_listen__address:="0.0.0.0:7474"}
: ${NEO4J_dbms_connector_https_listen__address:="0.0.0.0:7473"}
: ${NEO4J_dbms_connector_bolt_listen__address:="0.0.0.0:7687"}
: ${NEO4J_ha_host_coordination:="$(hostname):5001"}
: ${NEO4J_ha_host_data:="$(hostname):6001"}

# unset old hardcoded unsupported env variables
unset NEO4J_dbms_txLog_rotation_retentionPolicy NEO4J_UDC_SOURCE \
    NEO4J_dbms_memory_heap_maxSize NEO4J_dbms_memory_heap_maxSize \
    NEO4J_dbms_unmanagedExtensionClasses NEO4J_dbms_allowFormatMigration \
    NEO4J_dbms_connectors_defaultAdvertisedAddress NEO4J_ha_serverId \
    NEO4J_ha_initialHosts NEO4J_causalClustering_expectedCoreClusterSize \
    NEO4J_causalClustering_initialDiscoveryMembers \
    NEO4J_causalClustering_discoveryListenAddress \
    NEO4J_causalClustering_discoveryAdvertisedAddress \
    NEO4J_causalClustering_transactionListenAddress \
    NEO4J_causalClustering_transactionAdvertisedAddress \
    NEO4J_causalClustering_raftListenAddress \
    NEO4J_causalClustering_raftAdvertisedAddress

if [ -d /conf ]; then
    find /conf -type f -exec cp {} conf \;
fi

if [ -d /ssl ]; then
    NEO4J_dbms_directories_certificates="/ssl"
fi

if [ -d /plugins ]; then
    NEO4J_dbms_directories_plugins="/plugins"
fi

if [ -d /logs ]; then
    NEO4J_dbms_directories_logs="/logs"
fi

if [ -d /import ]; then
    NEO4J_dbms_directories_import="/import"
fi

if [ -d /metrics ]; then
    NEO4J_dbms_directories_metrics="/metrics"
fi

# set the neo4j initial password only if you run the database server
if [ "${cmd}" == "neo4j" ]; then
    if [ "${NEO4J_AUTH:-}" == "none" ]; then
        NEO4J_dbms_security_auth__enabled=false
    elif [[ "${NEO4J_AUTH:-}" == neo4j/* ]]; then
        password="${NEO4J_AUTH#neo4j/}"
        if [ "${password}" == "neo4j" ]; then
            echo >&2 "Invalid value for password. It cannot be 'neo4j', which is the default."
            exit 1
        fi
        # Will exit with error if users already exist (and print a message explaining that)
        bin/neo4j-admin set-initial-password "${password}" || true
    elif [ -n "${NEO4J_AUTH:-}" ]; then
        echo >&2 "Invalid value for NEO4J_AUTH: '${NEO4J_AUTH}'"
        exit 1
    fi
fi

# list env variables with prefix NEO4J_ and create settings from them
unset NEO4J_AUTH NEO4J_SHA256 NEO4J_TARBALL
for i in $( set | grep ^NEO4J_ | awk -F'=' '{print $1}' | sort -rn ); do
    setting=$(echo ${i} | sed 's|^NEO4J_||' | sed 's|_|.|g' | sed 's|\.\.|_|g')
    value=$(echo ${!i})
    if [[ -n ${value} ]]; then
        if grep -q -F "${setting}=" conf/neo4j.conf; then
            # Remove any lines containing the setting already
            sed --in-place "/${setting}=.*/d" conf/neo4j.conf
        fi
        # Then always append setting to file
        echo "${setting}=${value}" >> conf/neo4j.conf
    fi
done

# Chown the data dir now that (maybe) an initial password has been
# set (this is a file in the data dir)
if [[ "$(stat -c %u /data)" = "0" ]]; then
  chown -R "${user_name}:${group_name}" /data
fi

[ -f "${EXTENSION_SCRIPT:-}" ] && . ${EXTENSION_SCRIPT}

# Use su-exec to drop privileges to neo4j user
if [ "${cmd}" == "neo4j" ]; then
    su-exec "${user_name}" neo4j console
else
    su-exec "${user_name}" "$@"
fi
