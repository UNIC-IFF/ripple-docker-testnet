#!/bin/bash

OUTPUT_DIR_DEFAULT="./validators-config/"
VAL_NAME_PREFIX_DEFAULT="validator-"
CONFIG_TEMPLATE_DIR_DEFAULT="../templates/"

IPS_FILENAME="ips_fixed.lst"
VALIDATORS_MAP_FILENAME="validators-map.json"

CONTAINER_EXEC="docker exec -it rippled-tools"
VALIDATOR_TOOL="/rippled/bin/validator-keys"

OUTPUT_DIR=${OUTPUT_DIR:-${OUTPUT_DIR_DEFAULT}}
VAL_NAME_PREFIX=${VAL_NAME_PREFIX:-${VAL_NAME_PREFIX_DEFAULT}}
CONFIG_TEMPLATE_DIR=${TEMPLATES_DIR:-${CONFIG_TEMPLATE_DIR_DEFAULT}}

PEER_PORT=${PEER_PORT:-51235}

DOCKER_OUTPUT_DIR="./$(basename $OUTPUT_DIR)/"


function check_and_create_output_dirs(){
	if [[ ! -d $OUTPUT_DIR ]] ; then
		echo "Output director does not exist. Creating....";
		mkdir -p $OUTPUT_DIR
	fi;
}


function generate_validator_keys() {
	# Arguments
	val_id=$1
	out_keys="${DOCKER_OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-keys.json"
	out_token="${DOCKER_OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-token.txt"
# If VALIDATOR_TOOL uses a local installed validator-keys executable, then uncomment the following 2 lines
#	out_keys="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-keys.json"
#	out_token="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-token.txt"

	if [[ -e $out_keys ]]; then
		if [[ ! -e $out_token ]]; then
			cmd="${VALIDATOR_TOOL} create_token --keyfile ${out_keys} > ${out_token}"
			${CONTAINER_EXEC} sh -c "${cmd}"
		fi;
	else
		if [[ ! -d "${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}" ]]; then
			mkdir -p "${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}"
		fi;

		cmd="${VALIDATOR_TOOL} create_keys --keyfile ${out_keys}"
		${CONTAINER_EXEC} sh -c "${cmd}"
#		${cmd} # in case the validator_tool is installed in localhost (not in the container)

		cmd="${VALIDATOR_TOOL} create_token --keyfile ${out_keys} > ${out_token}"
		${CONTAINER_EXEC} sh -c "${cmd}"
#		${cmd}
	fi;

}

function generate_validator_configuration() {
	# Arguments
	val_id=$1
	# It is running in local machine, so no use of DOCKER_OUTPUT_DIR
	out_keys="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-keys.json"
	out_token="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-token.txt"
	out_cfg="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/rippled.cfg"
	out_validators="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validators.txt"

	# Read all validator keys and list them
	all_validator_keys=$(cat  ${OUTPUT_DIR}/${VALIDATORS_MAP_FILENAME} | jq '.[]' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\"//g')

	if [[ "$val_id" == "genesis" ]]; then
		#It's genesis node
		# replace  ips_fixed and validator token in cfg file
		sed -e "s#\${VALIDATOR_TOKEN}#$(tail -n 12 ${out_token} | sed -e ':a;N;$!ba;s/\n/\\n/g;s/\#/\\#/g')#" \
			-e "s#\${IPS_FIXED}#$(cat ${OUTPUT_DIR}/${IPS_FILENAME} | sed -e ':a;N;$!ba;s/\n/\\n/g')#" \
      -e "s#\${PEER_PORT}#${PEER_PORT}#g" \
			${CONFIG_TEMPLATE_DIR}/rippled_genesis_template.cfg > ${out_cfg}
		# put validator public key in validators.txt

		sed -e "s#\${VALIDATORS_PUBLIC_KEYS}#${all_validator_keys}#" \
			${CONFIG_TEMPLATE_DIR}/validators_txt_template.txt > ${out_validators}
	else
		#It's validator node
		# replace  validator key and validator token in cfg file
		sed -e "s#\${VALIDATOR_TOKEN}#$(tail -n 12 ${out_token} | sed -e ':a;N;$!ba;s/\n/\\n/g;s/\#/\\#/g')#" \
			-e "s#\${IPS_FIXED}#$(cat ${OUTPUT_DIR}/${IPS_FILENAME} | sed -e ':a;N;$!ba;s/\n/\\n/g')#" \
      -e "s#\${PEER_PORT}#${PEER_PORT}#g" \
			${CONFIG_TEMPLATE_DIR}/rippled_template.cfg > ${out_cfg}

    # put validator public key in validators.txt
		sed -e "s#\${VALIDATORS_PUBLIC_KEYS}#${all_validator_keys}#" \
			${CONFIG_TEMPLATE_DIR}/validators_txt_template.txt > ${out_validators}
	fi;
}


function check_tools_container()
{
	if [[ -z "$(docker container ls -q --filter=name=rippled-tools)" ]]; then
		# Container is not running
		echo "Starting rippled-tools container."
		echo $(dirname $(realpath ${OUTPUT_DIR}/))
		docker run -d -it --rm --name rippled-tools \
       			-v $(dirname $(realpath ${OUTPUT_DIR}/)):/rippled/config-generator \
       			--workdir /rippled/config-generator \
       			antiggl/rippled-runner /bin/bash
	else
		# Container is running
		echo "rippled-tools container is already running"
	fi;

	if [[ -z "$(docker container ls -q --filter=name=rippled-tools)" ]]; then
		# Container failed to start
		echo "FAIL: rippled-tools container failed to start."
		exit 2;
	fi;
}

function update_global_files()
{
	val_id=$1
	out_keys="${OUTPUT_DIR}/${VAL_NAME_PREFIX}${val_id}/validator-keys.json"

	# append ips in ips_fixed file
	echo "${VAL_NAME_PREFIX}${val_id}  ${PEER_PORT}" >> ${OUTPUT_DIR}/${IPS_FILENAME}

	# recreate the validators_map file
	cat ${OUTPUT_DIR}/${VALIDATORS_MAP_FILENAME} | jq ". + {\"${VAL_NAME_PREFIX}${val_id}\": $(cat ${out_keys} | jq '.public_key')}" > ${OUTPUT_DIR}/${VALIDATORS_MAP_FILENAME}

}

function generate_keys_and_configs()
{
	check_tools_container
	check_and_create_output_dirs

	#clean up
	#rm -f ${OUTPUT_DIR}/${IPS_FILENAME}
	echo "" > ${OUTPUT_DIR}/${IPS_FILENAME}
	#rm -f ${OUTPUT_DIR}/${VALIDATORS_MAP_FILENAME}
	echo {} > ${OUTPUT_DIR}/${VALIDATORS_MAP_FILENAME}
	VAL_NUM=$1

  echo "Generating keys for genesis"
	generate_validator_keys "genesis"
	update_global_files "genesis"
 
	echo "Generating keys for validators..."
	for ((i=0 ; i < ${VAL_NUM} ; i++)); do
		echo "    Generating keys for validator $i"
		generate_validator_keys $i
		update_global_files $i
	done

  # clean up: shutdown docker container used for tooling
	if [[ -n "$(docker container ls -q --filter=name=rippled-tools)" ]]; then
		# Container still running
		echo "Cleaning up rippled-tools container."
    docker container stop rippled-tools
	fi;

  echo "Generating configuration files for the genesis..."
	generate_validator_configuration "genesis"

	echo "Generating configuration files for the validators..."

	for ((i=0 ; i < ${VAL_NUM} ; i++)); do
		echo "    Generating configuration for validator $i"
		generate_validator_configuration $i
	done
}

#------------------------------------------------

USAGE="$0 <num of validators> "

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [[ -z "$1" ]]; then
		echo $USAGE
		exit 1;
	fi;
	VAL_NUM=$1

	generate_keys_and_configs $VAL_NUM

  echo "Finished!!!"

fi;


