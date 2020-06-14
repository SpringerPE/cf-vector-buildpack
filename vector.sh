#!/usr/bin/env bash
[ -z "$DEBUG" ] || set -x
# If debug is defined, enters in a debug mode for bash and vector
# will print out in the console the events processed as json. If
# debug starts with http, it will send the events there as json format
set -euo pipefail
shopt -s nullglob

# See bin/finalize to check predefined vars
DEBUG=${DEBUG:-0}
export ROOT="${ROOT:-/home/vcap}"
export APP_ROOT="${ROOT}/app"

export VECTOR=vector  # command
export VECTOR_DIR="${VECTOR_DIR:-$ROOT/vector}"
export VECTOR_DATADIR="${VECTOR_DATADIR:-$VECTOR_DIR/data}"
export VECTOR_OPTS=${VECTOR_OPTS:-"--quiet"}
export VECTOR_CONFIGDIR="${VECTOR_CONFIGDIR:-$VECTOR_DIR/config}"
export VECTOR_CONFIGFILE="${VECTOR_CONFIGFILE:-$VECTOR_CONFIGDIR/ee.toml}"
# Users can define their custom configuration in this folder
export VECTOR_CUSTOM_CONFIGDIR="${VECTOR_CUSTOM_CONFIGDIR:-$APP_ROOT/vector}"

### Google settings for PUBSUB (used by destination 'ee', see below)
export GCP_PUBSUB_TOPIC=${GCP_PUBSUB_TOPIC:-ee}
export GCP_PROJECT=${GCP_PROJECT-}
export GCP_API_KEY=${GCP_API_KEY-}
# Vector checkd this variable, we would need some way of getting this credentials
# automatically from a server and put the json in the file ${VECTOR_DATADIR}/credentials.json
export GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-${VECTOR_DATADIR}/credentials.json}

### Destinantion settings, first one just enables everything
export LOG_ENABLED=1
# Source (by default named 'src'), destination name (used 'ee' to avoid collisions with customizations) and
# input of the 'ee' default destination is 'src' but it can be any customization
export LOG_SRC="${LOG_SRC:-stdout}"
# Logs destination: ee (our default) or * (custom string). If custom, we try to find a service
# instance from a SB, if not found then we assume it is completely custom config
export LOG_DST="${LOG_DST-ee}"
export LOG_INPUT_DST="${LOG_INPUT_DST:-cf}"


###


get_binding_service() {
    local binding_name="${1}"
    jq --arg b "${binding_name}" '[.[][] | select(.binding_name == $b)]' <<<"${VCAP_SERVICES}"
}

services_has_tag() {
    local services="${1}"
    local tag="${2}"
    jq --arg t "${tag}" -e '.[].tags | contains([$t])' <<<"${services}" >/dev/null
}

get_gcs_service() {
    local name=${1:-"google-storage"}
    jq --arg n "${name}" '.[$n]' <<<"${VCAP_SERVICES}"
}


set_gcs_config() {
    local config="${1}"
    local services="${2}"
    local bucket=""

    for s in $(jq -r '.[] | .name' <<<"${services}")
    do
        # Gets the credentials from the SB
        jq -r --arg n "${s}" '.[] | select(.name == $n) | .credentials.PrivateKeyData' <<<"${services}" | base64 -d > "${VECTOR_DATADIR}/${s}-auth.json"
        bucket=$(jq -r -e --arg n "${s}" '.[][] | select(.name == $n) | .credentials.bucket_name' <<<"${services}")
        # Creates configuration
        jq --arg n "${s}" --arg b "${bucket}" --arg p "${VECTOR_DATADIR}" --arg i "${LOG_INPUT_DST}" -r '.[][] | select(.name == $n) |
"[sinks."+ .name +"]
type = \"gcp_cloud_storage\"
inputs = ["+ $i + "]
bucket = \"" + $b + "\"
compression = none
credentials_path = "+ $p +"/"+ .name +"-auth.json"
healthcheck = true
encoding.codec = \"ndjson\"
storage_class = \"REGIONAL\"
acl = \"authenticatedRead\"
# TODO, add tags from VCAP_APPLICATION
# metadata.Key1 = Value1
"' <<<"${services}" >> ${config}
         echo "* Defined GCS service ${s} as destination in bucket ${bucket}"
    done
}


generate_dst_config_from_vcap_services() {
    local config="${1}"
    local binding_name="${2}"

    local service=""
    local rc=0

    if [ -n "${binding_name}" ] && [ "${binding_name}" != "null" ]
    then
        service=$(get_binding_service "${binding_name}")
        if [ -n "${service}" ] && [ "${service}" != "null" ]
        then
            if services_has_tag "${service}" "gcp"
            then
                set_gcs_config "${config}" "${service}"
                rc=$?
            else
                echo ">> Error, bound service with name ${binding_name} not compatible because is not provided by GCP service broker" >&2
                return 1
            fi
        else
            echo ">> Error, cannot found bound service with name ${binding_name}!" >&2
            return 1
        fi
    else
        service=$(get_gcs_service)
        if [ -n "${service}" ] && [ "${service}" != "null" ]
        then
            set_gcs_config "${config}" "${service}"
            rc=$?
        else
            echo ">> Error,  GCS service not found!. Please bind a GCS service with name ${binding_name}! to this app" >&2
            return 1
        fi
    fi
    return $rc
}


generate_dst_configs_from_ee_defaults() {
    local config="${1}"

    echo "* Generating config for default destination ..."
    # Rest of the configuration for the default 'ee' output
    cat <<- EOF >> "${config}"
	[sinks.ee]
	inputs = ["${LOG_INPUT_DST}"]
	type = "gcp_pubsub"
	# using env var GOOGLE_APPLICATION_CREDENTIALS
	# credentials_path = "${VECTOR_DATADIR}/credentials.json"
	topic = "${GCP_PUBSUB_TOPIC}"
	healthcheck = true
	# Batch
	batch.max_size = 10485760 # optional, default, bytes
	batch.timeout_secs = 1    # optional, default, seconds
	# Buffer switch from memory to disk
	buffer.type = "disk" 
	buffer.when_full = "block"   # default is block, but maybe drop_newest?
	buffer.max_events = 500      # optional, default, events, relevant when type = "memory"
	# Max 100Mb of buffer
	buffer.max_size = 104900000  # required, bytes, required when type = "disk"
	# https://vector.dev/docs/reference/sinks/gcp_pubsub/#rate-limits
	request.rate_limit_duration_secs = 1    # optional, default, seconds
	request.rate_limit_num = 100            # optional, default
	request.retry_initial_backoff_secs = 1  # optional, default, seconds
	request.retry_max_duration_secs = 10    # optional, default, seconds
	request.timeout_secs = 60               # optional, default, seconds
	EOF
	if [ -z "${GCP_API_KEY}" ]
	then
        cat <<- EOF >> "${config}"
		api_key = "${GCP_API_KEY}"
		project = "${GCP_PROJECT}"
		EOF
    fi
}


generate_config() {
    local config="${1}"

    local service=""
    local rc=0

    # Warning there is a mix between tabs an spaces here! (see '<<-')
    echo "* Using env variables to generate configuration ..."
    cat <<- EOF > "${config}"
	#                                    __   __  __
	#                                    \ \ / / / /
	#                                     \ V / / /
	#                                      \_/  \/
	#                                    V E C T O R
	#                                   Configuration
	#
	# ------------------------------------------------------------------------------
	# Website: https://vector.dev
	# Docs: https://vector.dev/docs/
	# ------------------------------------------------------------------------------
	data_dir = "${VECTOR_DATADIR}"
	# Input data. Change me to a valid input source.
	[sources.src]
	EOF
    case "${LOG_SRC}" in
    stderr|stdout|stdall)
        cat <<- EOF >> "${config}"
		type = "stdin"
		max_length = 102400
		EOF
        ;;
    *)
        # It assumes input is a file (glob is possible)
        cat <<- EOF >> "${config}"
		type = "file"
		include = ["${LOG_SRC}"]
		start_at_beginning = true
		glob_minimum_cooldown = 10000   # milliseconds
		max_line_bytes = 102400         # optional, default, bytes
		EOF
        ;;
    esac
    # VCAP fields
    cat <<- EOF >> "${config}"
	[transforms.cf]
	type = "add_fields"
	inputs = ["src"]
	fields.cf.app = "app"
	fields.cf.app_index = 0
	fields.cf.api = "api"
	fields.cf.org = "org"
	fields.cf.space = "space"
	fields.cf.urls = "http://url.com"
	EOF
    if [ "${DEBUG}" != "0" ]
    then
        # Debug mode
        case "${DEBUG}" in
        http*)
            # HTTP debug
            cat <<- EOF >> "${config}"
			# Output data
			[sinks.debug]
			inputs = ["cf"]
			type = "http"
			compression = "none"
			healthcheck = false
			uri = "${DEBUG}"
			encoding.codec = "json"
			buffer.type = "disk" 
			buffer.when_full = "block"   # default is block, but maybe drop_newest?
			# Max 100Mb of buffer
			buffer.max_size = 104900000  # required, bytes, required when type = "disk"
			EOF
            ;;
        *)
            # Plain debug goes to console
            cat <<- EOF >> "${config}"
			# Output data
			[sinks.debug]
			inputs = ["cf"]
			type = "console"
			encoding.codec = "json"
			target = "stderr"
			EOF
            ;;
        esac
    fi
    # Rest of the configuration for the default 'ee' output or GCS SB
    case "${LOG_DST}" in
    "")
        echo "* No ${LOG_DST} defined!"
        rc=0
        ;;
    ee)
        generate_dst_configs_from_ee_defaults "${config}"
        rc=$?
        ;;
    *)
        # If destination is not default ('ee') we try to find a service from
        # GCS SB (a bucket)
        service=$(get_binding_service "${LOG_DST}")
        if [ -n "${service}" ] && [ "${service}" != "null" ] && [ ! -z "${DEBUG}" ]
        then
            echo "* Using custom ${LOG_DST} ... Logs DST config is up to you!"
        else
            generate_dst_config_from_vcap_services "${config}" "${LOG_DST}"
            rc=$?
        fi
        ;;
    esac
    return $rc
}


prepare_and_validate() {
    local rc=0

    mkdir -p ${VECTOR_DIR}
    mkdir -p ${VECTOR_DATADIR}
    mkdir -p ${VECTOR_CONFIGDIR}

    # TODO Download file GOOGLE_APPLICATION_CREDENTIALS from some kind
    # of SB or internal metadata service url (vault?, HTTP with certificates
    # injected in the container, ...)

    if [ -d "${VECTOR_CUSTOM_CONFIGDIR}" ]
    then
        # Copy custom configuration
        echo "* Custom vector configuration found in ${VECTOR_CUSTOM_CONFIGDIR}, copying it"
        cp -a ${VECTOR_CUSTOM_CONFIGDIR}/* ${VECTOR_CONFIGDIR}/
    fi
    # if configfile is empty, generate one based on the environment variables
    if [ ! -s "${VECTOR_CONFIGFILE}" ]
    then
        if ! generate_config "${VECTOR_CONFIGFILE}"
        then
            echo ">> Error generating vector configuration" >&2
            return 1
        fi
    fi
    # Validate config
    echo "* Validating vector configuration ..."
    if ! $VECTOR validate ${VECTOR_CONFIGDIR}/*.toml
    then
        echo ">> Error,  Vector configuration appears to be wrong!" >&2
        return 1
    fi
    return 0
}


# We will need 2 vector processes running in order to catch and tag stderr and stdout logs
# There is no way in vector to select stderr and stdout
# something like command > >(stdlog pipe)  2> >(stderr pipe)
redirect_all() {
    $VECTOR $VECTOR_OPTS --config ${VECTOR_CONFIGDIR}/*.toml
}


# Main program, setup the redirection
if [ "x${LOG_ENABLED}" == "x1" ]
then
    prepare_and_validate && exec &> >(tee >(redirect_all))
    sleep 1
fi

