#!/bin/sh

export PATH=$PATH:/usr/local/go/bin/

GO_VERSION=1.16.5

# Avoid warnings for non-interactive apt-get install
export DEBIAN_FRONTEND=noninteractive


IXIA_C_OPERATOR_IMAGE=ixia-c-operator
GO_TARGZ=""

IXIA_C_CONTROLLER=0.0.1-2662
IXIA_C_PROTOCOL_ENGINE=""
IXIA_C_TRAFFIC_ENGINE=""
IXIA_C_GRPC_SERVER=""
IXIA_C_GNMI_SERVER=""
ARISTA_CEOS_VERSION=4.26.1F
IXIA_C_TEST_CLIENT=""

GCP_DOCKER_REPO=us-central1-docker.pkg.dev/kt-nts-athena-dev/keysight

LOCK_STATUS_FILE=sanity_lock_status.txt
LOCK_FILE=sanity_lock

SANITY_REPORTS=./reports
SANITY_LOGS=./logs
SANITY_STATUS=FAIL

START_TIME="$(date -u +%s)"
TOTAL_TIME=3600
APPROX_SANITY_TIME=1200

TESTBED_CICD_DIR=operator_cicd

art=./art
release=./release

# get installers based on host architecture
if [ "$(arch)" = "aarch64" ] || [ "$(arch)" = "arm64" ]
then
    echo "Host architecture is ARM64"
    GO_TARGZ=go${GO_VERSION}.linux-arm64.tar.gz
elif [ "$(arch)" = "x86_64" ]
then
    echo "Host architecture is x86_64"
    GO_TARGZ=go${GO_VERSION}.linux-amd64.tar.gz
else
    echo "Host architecture $(arch) is not supported"
    exit 1
fi


install_deps() {
	# Dependencies required by this project
    echo "Installing Dependencies ..."
    apt-get update \
	&& apt-get -y install --no-install-recommends apt-utils dialog 2>&1 \
    && apt-get -y install curl git openssh-server vim unzip tar make bash wget sshpass build-essential \
    && get_go \
    && get_go_deps
}

get_go() {
    echo "Installing Go ..."
    # install golang per https://golang.org/doc/install#tarball
    curl -kL https://dl.google.com/go/${GO_TARGZ} | tar -C /usr/local/ -xzf -
}

get_go_deps() {
    # download all dependencies mentioned in go.mod
    echo "Dowloading go mod dependencies ..."
    go mod download
}

get_version() {
    version=$(head ./version | cut -d' ' -f1)
    echo ${version}
}

echo_version() {
    version=$(head ./version | cut -d' ' -f1)
    echo "gRPC version : ${version}"
}

get_local_build() {
    # Generating local build using Makefile
    echo "Generating local build ..."
    make build
}

get_docker_build() {
    # Generating docker build using Makefile
    echo "Generating docker build ..."
    export VERSION=$(get_version)
    export IMAGE_TAG_BASE=${IXIA_C_OPERATOR_IMAGE}
    make docker-build
    docker rmi -f $(docker images | grep '<none>') 2> /dev/null || true
}

gen_ixia_c_op_dep_yaml() {
    # Generating ixia-c-operator deployment yaml using Makefile
    img=${1}
    echo "Generating ixia-c-operator deployment yaml ..."
    export VERSION=$(get_version)
    export IMAGE_TAG_BASE=${img}
    make yaml
}

cicd_publish() {
    version=$(get_version)
    img="${IXIA_C_OPERATOR_IMAGE}:${version}"
    if cicd_dockerhub_image_exists ${img}; then
        echo "${img} already exists..."
    else
        echo "${img} does not exist..."
        cicd_push_dockerhub_image ${img}
        cicd_verify_dockerhub_images ${img}
    fi
    cicd_gen_release_art
}

cicd_gen_release_art() {
    mkdir -p ${release}
    rm -rf ./ixiatg-operator.yaml
    rm -rf ${release}/*.yaml
    gen_ixia_c_op_dep_yaml "${DOCKERHUB_REPO}/${IXIA_C_OPERATOR_IMAGE}"
    mv ./ixiatg-operator.yaml ${release}/
     echo "Files in ./release: $(ls -lht ${release})"
}

gen_operator_artifacts() {
    echo "Generating ixia-c-operator offline artifacts ..."
    art=${1}
    version=$(get_version)
    rm -rf ${art}/*.yaml
    rm -rf ${art}/*.tar.gz
    mv ./ixiatg-operator.yaml ${art}/
    docker save ${IXIA_C_OPERATOR_IMAGE}:${version} | gzip > ${art}/ixia-c-operator.tar.gz
}

cicd_get_versions_yaml() {
    echo "Downloading versions.yaml for Ixia-C ${IXIA_C_CONTROLLER}..."
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/builds/${IXIA_C_CONTROLLER}/versions.yaml"
}

cicd_get_component_versions() {
    cicd_get_versions_yaml
    echo "Getting Coponents versions from versions.yaml..."
    cat versions.yaml
    echo ""
    IXIA_C_PROTOCOL_ENGINE=$(cat versions.yaml | grep "ixia-c-protocol-engie: " | sed -n 's/^\ixia-c-protocol-engie: //p' | tr -d '[:space:]')
    echo "Ixia-C protocol engine version : ${IXIA_C_PROTOCOL_ENGINE}"
    IXIA_C_TRAFFIC_ENGINE=$(cat versions.yaml | grep "ixia-c-traffic-engine: " | sed -n 's/^\ixia-c-traffic-engine: //p' | tr -d '[:space:]')
    echo "Ixia-C traffic engine version : ${IXIA_C_TRAFFIC_ENGINE}"
    IXIA_C_GRPC_SERVER=$(cat versions.yaml | grep "ixia-c-grpc-server: " | sed -n 's/^\ixia-c-grpc-server: //p' | tr -d '[:space:]')
    echo "Ixia-C gRPC server version : ${IXIA_C_GRPC_SERVER}"
    IXIA_C_GNMI_SERVER=$(cat versions.yaml | grep "ixia-c-gnmi-server: " | sed -n 's/^\ixia-c-gnmi-server: //p' | tr -d '[:space:]')
    echo "Ixia-C gnmi server version : ${IXIA_C_GNMI_SERVER}"
    echo "Arista ceos version : ${ARISTA_CEOS_VERSION}"
    rm -rf versions.yaml
}

cicd_gen_local_ixia_c_artifacts() {
    ixia_c_art=./ixia_c_art
    mkdir -p ${ixia_c_art}

    cicd_get_component_versions

    echo "Downloading ixia-c-controller:${IXIA_C_CONTROLLER}"
    docker rmi -f $(docker images | grep 'ixia-c-controller') 2> /dev/null || true
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/builds/${IXIA_C_CONTROLLER}/ixia-c-controller.tar.gz" \
    && docker load -i ixia-c-controller.tar.gz \
    && rm -rf ixia-c-controller.tar.gz \
    && docker tag ixia-c-controller:${IXIA_C_CONTROLLER} ${GCP_DOCKER_REPO}/ixia-c-controller:${IXIA_C_CONTROLLER} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-controller:${IXIA_C_CONTROLLER} | gzip > ${ixia_c_art}/ixia-c-controller.tar.gz

    echo "Downloading ixia-c-test-client"
    docker rmi -f $(docker images | grep 'ixia-c-test-client') 2> /dev/null || true
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/builds/${IXIA_C_CONTROLLER}/ixia-c-test-client.tar.gz" \
    && docker load -i ixia-c-test-client.tar.gz \
    && rm -rf ixia-c-test-client.tar.gz
    IXIA_C_TEST_CLIENT=$(docker images "ixia-c-test-client:*" --format '{{.Tag}}')
    echo "ixia-c-test-client version is ${IXIA_C_TEST_CLIENT}"
    docker tag ixia-c-test-client:${IXIA_C_TEST_CLIENT} ${GCP_DOCKER_REPO}/ixia-c-test-client:${IXIA_C_TEST_CLIENT} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-test-client:${IXIA_C_TEST_CLIENT} | gzip > ${ixia_c_art}/ixia-c-test-client.tar.gz

    echo "Downloading ixia-c-traffic-engine:${IXIA_C_TRAFFIC_ENGINE}"
    docker rmi -f $(docker images | grep 'ixia-c-traffic-engine') 2> /dev/null || true
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/builds/${IXIA_C_CONTROLLER}/ixia-c-traffic-engine.tar.gz" \
    && docker load -i ixia-c-traffic-engine.tar.gz \
    && rm -rf ixia-c-traffic-engine.tar.gz \
    && docker tag ixia-c-traffic-engine:${IXIA_C_TRAFFIC_ENGINE} ${GCP_DOCKER_REPO}/ixia-c-traffic-engine:${IXIA_C_TRAFFIC_ENGINE} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-traffic-engine:${IXIA_C_TRAFFIC_ENGINE} | gzip > ${ixia_c_art}/ixia-c-traffic-engine.tar.gz

    echo "Downloading ixia-c-protocol-engine:${IXIA_C_PROTOCOL_ENGINE}"
    docker rmi -f $(docker images | grep 'ixia-c-protocol-engine') 2> /dev/null || true
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/builds/${IXIA_C_CONTROLLER}/ixia-c-protocol-engine.tar.gz" \
    && docker load -i ixia-c-protocol-engine.tar.gz \
    && rm -rf ixia-c-protocol-engine.tar.gz \
    && docker tag ixia-c-protocol-engine:${IXIA_C_PROTOCOL_ENGINE} ${GCP_DOCKER_REPO}/ixia-c-protocol-engine:${IXIA_C_PROTOCOL_ENGINE} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-protocol-engine:${IXIA_C_PROTOCOL_ENGINE} | gzip > ${ixia_c_art}/ixia-c-protocol-engine.tar.gz

    echo "Downloading ixia-c-grpc-server:${IXIA_C_GRPC_SERVER}"
    docker rmi -f $(docker images | grep 'ixiacom/ixia-c-grpc-server') 2> /dev/null || true
    docker pull ixiacom/ixia-c-grpc-server:${IXIA_C_GRPC_SERVER} \
    && docker tag ixiacom/ixia-c-grpc-server:${IXIA_C_GRPC_SERVER} ${GCP_DOCKER_REPO}/ixia-c-grpc-server:${IXIA_C_GRPC_SERVER} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-grpc-server:${IXIA_C_GRPC_SERVER} | gzip > ${ixia_c_art}/ixia-c-grpc-server.tar.gz

    echo "Downloading ixia-c-gnmi-server:${IXIA_C_GNMI_SERVER}"
    docker rmi -f $(docker images | grep 'ixiacom/ixia-c-gnmi-server') 2> /dev/null || true
    docker pull ixiacom/ixia-c-gnmi-server:${IXIA_C_GNMI_SERVER} \
    && docker tag ixiacom/ixia-c-gnmi-server:${IXIA_C_GNMI_SERVER} ${GCP_DOCKER_REPO}/ixia-c-gnmi-server:${IXIA_C_GNMI_SERVER} \
    && docker save ${GCP_DOCKER_REPO}/ixia-c-gnmi-server:${IXIA_C_GNMI_SERVER} | gzip > ${ixia_c_art}/ixia-c-gnmi-server.tar.gz

    echo "Downloading arista-ceos:${ARISTA_CEOS_VERSION}"
    cd ${ixia_c_art}
    curl -kLO "https://${IXIA_C_ARTIFACTORY}/external/ceos/${ARISTA_CEOS_VERSION}/cEOS64-lab-${ARISTA_CEOS_VERSION}.tar"
    cd ..

    echo "Files in ./ixia_c_art: $(ls -lht ${ixia_c_art})"
}

cicd_exec_on_testbed() {
    cmd=${1}
    sshpass -p ${TESTBED_PASSWORD} ssh -o StrictHostKeyChecking=no  ${TESTBED_USERNAME}@${TESTBED} "${cmd}"
}

cicd_create_lock_status_file() {
    echo "creating lock status file: ${LOCK_STATUS_FILE}"
    touch ${LOCK_STATUS_FILE}
    echo "lock status file: ${LOCK_STATUS_FILE} created"
}

cicd_create_folder_in_testbed() {
    echo "creating cicd folder in testbed: ${TESTBED_CICD_DIR}"
    cicd_exec_on_testbed "mkdir ${TESTBED_CICD_DIR}"
    echo "creating cicd folder: ${TESTBED_CICD_DIR}"
}

cicd_lock_testbed() {
    echo "Locking testbed for sanity"
    cicd_create_folder_in_testbed
    cicd_create_lock_status_file
    echo "Locked testbed for sanity"
}

cicd_check_for_timeout() {
    echo "Checking for timeout in CICD Pipeline"
    END_TIME="$(date -u +%s)"
    ELAPSED="$(($END_TIME-$START_TIME))"
    echo "Time Elapsed: ${ELAPSED} seconds"
    echo "Timeout Given For Pipeline: ${TOTAL_TIME} seconds"
    REM_TIME="$(($TOTAL_TIME-$ELAPSED))"
    echo "Remaining time for pipeline : ${REM_TIME} seconds"
    echo "Estimated Time required to run sanity ${APPROX_SANITY_TIME} seconds"
    if [ ${REM_TIME} -lt ${APPROX_SANITY_TIME} ]
    then
        echo "Pipeline may expire during running tests in testbed, please retry the pipeline sometimes later"
        exit 1
    fi
    echo "Pipeline won't expire during running tests in testbed"

}

cicd_wait_for_testbed_to_unlock() {
    local_lock_status=$(ls ${LOCK_STATUS_FILE} 2> /dev/null)
    if [ ${local_lock_status} ]
    then
        echo "Local lock status file forund, so testbed is already locked by this process"
    else
        while :
        do
            status=$(cicd_exec_on_testbed "ls -d ${TESTBED_CICD_DIR} 2> /dev/null")
            if  [ ${status} ]
            then
                echo "Testbed is locked due to another sanity is still running....."
                echo "Retry after 1 minute"
                sleep 1m
            else
                echo "Testbed is already unlocked"
                cicd_check_for_timeout
                cicd_lock_testbed
                break
            fi
        done 
    fi  
}

cicd_copy_file_to_testbed() {
    for var in "$@"
    do
        echo "pushing ${var} to testbed"
        sshpass -p ${TESTBED_PASSWORD} scp -o StrictHostKeyChecking=no ${var} ${TESTBED_USERNAME}@${TESTBED}:./${TESTBED_CICD_DIR}/
        echo "${var} pushed to testbed"
    done
}

cicd_push_artifacts_to_testbed() {
    art=${1}
    cicd_copy_file_to_testbed ./art/*
    cicd_copy_file_to_testbed ./ixia_c_art/*
    cicd_copy_file_to_testbed ./tests_art/*
}

cicd_run_sanity_in_testbed() {
    version=${1}
    echo "sanity run in testbed: starting"
    sanity_run_cmd="python3 operator_cicd.py --test -build ${version} -mark sanity -ixia_c_release ${IXIA_C_CONTROLLER}"
    cicd_exec_on_testbed "cd ./${TESTBED_CICD_DIR} && sudo ${sanity_run_cmd}"
    echo "sanity run in testbed: done"
}

cicd_copy_results_from_testbed() {
    for var in "$@"
    do
        echo "pulling ${var} from testbed"
        sshpass -p ${TESTBED_PASSWORD} scp -o StrictHostKeyChecking=no -r ${TESTBED_USERNAME}@${TESTBED}:/home/${TESTBED_USERNAME}/${TESTBED_CICD_DIR}/${var} ${SANITY_REPORTS}/
        echo "${var} pulled from testbed"
    done
}

cicd_pull_results_from_testbed() {
    version=${1}
    mkdir -p ${SANITY_REPORTS}
    cicd_copy_results_from_testbed reports-*.html sanity-summary-${version}.csv
}

cicd_cleanup_in_testbed() {
    echo "clean up in testbed: starting"
    cicd_exec_on_testbed "cd ${TESTBED_CICD_DIR} && sudo python3 operator_cicd.py --clean"
    cicd_exec_on_testbed "cd ${TESTBED_CICD_DIR} && sudo rm operator_cicd.py"
    echo "clean up in testbed: done"
}

cicd_check_sanity_status() {
    version=${1}
    echo "checking santy status"
    cat ${SANITY_REPORTS}/sanity-summary-${version}.csv
    sanity_pass=$(grep All ${SANITY_REPORTS}/sanity-summary-${version}.csv | grep -Eo '[0-9]{1,4}')
    echo "Sanity pass rate : ${sanity_pass}"
    sanity_pass_rate=$(echo "${sanity_pass}" | tr -d $'\r' | bc -l)
    if [ ${sanity_pass_rate} -ge ${EXPECTED_SANITY_PASS_RATE} ]
    then
        SANITY_STATUS=PASS
    fi
    echo "Sanity Status : ${SANITY_STATUS}"
    echo "Sanity expected pass rate : ${EXPECTED_SANITY_PASS_RATE}"
    if [ ${SANITY_STATUS} = PASS ]
    then
        echo "sanity : pass"
    else 
        echo "sanity: fail"
        exit 1
    fi
}

cicd_run_sanity() {
    art=${1}
    version=${2}
    cicd_push_artifacts_to_testbed ${art}
    cicd_run_sanity_in_testbed ${version}
    cicd_pull_results_from_testbed ${version}
    cicd_cleanup_in_testbed

    echo "Reports in ${SANITY_REPORTS}: $(ls -lht ${SANITY_REPORTS})"
    cicd_check_sanity_status ${version}
}

cicd_install_deps() {
    echo "Installing CICD deps"
    apk update \
    && apk add curl git openssh vim unzip tar make bash wget sshpass ssh-askpass \
    && apk add --no-cache libc6-compat \
    && apk add build-base

    echo "Installing go in alpine ..."
    wget https://dl.google.com/go/${GO_TARGZ} \
    && tar -C /usr/local -xzf ${GO_TARGZ}
    export PATH=$PATH:/usr/local/go/bin
    go version

    echo "Installing go mod dependencies in alpine ..."
    go mod download
}

cicd_gen_tests_artifacts() {
    echo "Generating Ixia-C-Operator test artifacts ..."
    tests_art=./tests_art
    mkdir -p ${tests_art}
    tar -zcvf ${tests_art}/operator-tests.tar.gz ./operator-tests
    cp ./operator-tests/helper/* ${tests_art}/

    cat ${tests_art}/template-ixia-configmap.yaml | \
        sed "s/IXIA_C_CONTROLLER_VERSION/${IXIA_C_CONTROLLER}/g" | \
        sed "s/IXIA_C_GNMI_SERVER_VERSION/${IXIA_C_GNMI_SERVER}/g" | \
        sed "s/IXIA_C_GRPC_SERVER_VERSION/${IXIA_C_GRPC_SERVER}/g" | \
        sed "s/IXIA_C_TRAFFIC_ENGINE_VERSION/${IXIA_C_TRAFFIC_ENGINE}/g" | \
        sed "s/IXIA_C_PROTOCOL_ENGINE_VERSION/${IXIA_C_PROTOCOL_ENGINE}/g" | \
        tee ${tests_art}/ixia-configmap.yaml > /dev/null

    cat ${tests_art}/template-ixia-c-test-client.yaml | \
        sed "s/IXIA_C_TEST_CLIENT/${IXIA_C_TEST_CLIENT}/g" | \
        tee ${tests_art}/ixia-c-test-client.yaml > /dev/null

    rm -rf template-*.yaml
    echo "Files in ./tests_art: $(ls -lht ${tests_art})"
}

cicd_build() {
    mkdir -p ${art}
    install_deps \
    && gen_ixia_c_op_dep_yaml ${IXIA_C_OPERATOR_IMAGE} \
    && get_docker_build \
    && gen_operator_artifacts ${art}
    version=$(get_version)
    echo "Build Version: $version"
    echo "Files in ./art: $(ls -lht ${art})"
}

cicd_dockerhub_image_exists() {
    img=${1}
    if DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect ${DOCKERHUB_REPO}/${img} >/dev/null; then
        return 0
    else
        return 1
    fi
}

cicd_push_dockerhub_image() {
    img=${1}
    docker tag ${img} ${DOCKERHUB_REPO}/${img}
    docker login -p ${DOCKERHUB_KEY} -u ${DOCKERHUB_USER} \
    && docker push "${DOCKERHUB_REPO}/${img}" \
    && docker logout ${DOCKERHUB_USER} \
    && echo "${img} pushed in Docker Hub" \
    && docker rmi "${DOCKERHUB_REPO}/${img}" > /dev/null 2>&1 || true
}

cicd_verify_dockerhub_images() {
    for var in "$@"
    do
        img=${var}
        dockerhub_image=${DOCKERHUB_REPO}/${img}
        echo "pulling ${dockerhub_image} from Docker Hub"
        docker pull $dockerhub_image
        if docker image inspect ${dockerhub_image} >/dev/null 2>&1; then
            echo "${dockerhub_image} pulled successfully from Docker Hub"
            docker rmi $dockerhub_image > /dev/null 2>&1 || true
        else
            echo "${dockerhub_image} not found locally!!!"
            docker rmi $dockerhub_image > /dev/null 2>&1 || true
            exit 1
        fi
    done
}

cicd_test() {
    cicd_gen_local_ixia_c_artifacts \
    && cicd_gen_tests_artifacts

    version=$(get_version)
    cicd_wait_for_testbed_to_unlock \
    && cicd_run_sanity ${art} ${version}
}


remove_cicd_folder_from_testbed(){
    lock_status=$(ls ${LOCK_STATUS_FILE} 2> /dev/null)
    if [ ${lock_status} ]
    then
        status=$(cicd_exec_on_testbed "ls -d ${TESTBED_CICD_DIR} 2> /dev/null")
        if  [ ${status} ]
        then
            cicd_exec_on_testbed "sudo rm -rf ${TESTBED_CICD_DIR}" 
            echo "${TESTBED_CICD_DIR}: deleted from testbed"
        else
            echo "${TESTBED_CICD_DIR}: not found in testbed"
        fi
    fi
}

remove_testbed_lock_status() {
    echo "removing testbed lock status file"
    lock_status=$(ls ${LOCK_STATUS_FILE} 2> /dev/null)
    if [ ${lock_status} ]
    then 
        rm ${LOCK_STATUS_FILE}
        echo "testbed lock status file removed"
    fi
}

unlock_testbed(){
    echo "unlocking testbed..."
    docker rmi -f ${IXIA_C_OPERATOR_IMAGE}:${version} 2> /dev/null || true
    remove_cicd_folder_from_testbed
    remove_testbed_lock_status
    echo "testbed unlocked"
}

case $1 in
    deps   )
        install_deps
        ;;
    local   )
        get_local_build
        ;;
    docker   )
        get_docker_build
        ;;
    yaml   )
        gen_ixia_c_op_dep_yaml ${IXIA_C_OPERATOR_IMAGE}
        ;;
    cicd_build   )
        cicd_build
        ;;
    cicd_test   )
        cicd_test
        ;;
    cicd_publish    )
        cicd_publish
        ;;
    version   )
        echo_version
        ;;
    unlock  )
        unlock_testbed
        ;;
	*		)
        $1 || echo "usage: $0 [deps|local|docker|yaml|version]"
		;;
esac
