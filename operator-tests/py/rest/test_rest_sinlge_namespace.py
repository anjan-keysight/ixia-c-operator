import pytest
import utils


def test_rest_single_namespace(ixia_c_release):
    """
    Config Map will be fetched via REST call from Ixia-C Release
    Deploy dut kne topology,
    - namespace - 1: ixia-c-rest
    Delete dut kne topology,
    - namespace - 1: ixia-c-rest
    Validate,
    - total pods count
    - overall pods status
    - total service count
    - individual pod status
    - individual service status
    - operator pod health
    """
    namespace1 = 'ixia-c-rest'
    namespace1_config = 'rest_ixia_c_namespace.txt'
    expected_svcs = [
        'ixia-c-service',
        'gnmi-service',
        'grpc-service',
        'service-arista1',
        'service-arista2',
        'service-ixia-c-port1',
        'service-ixia-c-port2',
        'service-ixia-c-port3'
    ]

    expected_pods = [
        'ixia-c',
        'arista1',
        'arista2',
        'ixia-c-port1',
        'ixia-c-port2',
        'ixia-c-port3'
    ]

    utils.generate_rest_config_from_temaplate(
        namespace1_config,
        ixia_c_release
    )
    try:
        op_rscount = utils.get_operator_restart_count()
        print("[Namespace:{}]Deploying KNE topology".format(
            namespace1
        ))
        utils.create_kne_config(namespace1_config, namespace1)
        utils.ixia_c_pods_ok(namespace1, expected_pods)
        utils.ixia_c_services_ok(namespace1, expected_svcs)
        op_rscount = utils.ixia_c_operator_ok(op_rscount)

        arista_pods = [
            'arista1',
            'arista2'
        ]
        utils.arista_sshable_ok(arista_pods, namespace1)

        print("[Namespace:{}]Checking E2E tests running fine or not ...".format(
            namespace1
        ))
        utils.ixia_c_e2e_test_ok(namespace1, None, 'sanity', 90)

        print("[Namespace:{}]Deleting KNE topology".format(
            namespace1
        ))
        utils.delete_kne_config(namespace1_config, namespace1)
        utils.ixia_c_pods_ok(namespace1, [])
        utils.ixia_c_services_ok(namespace1, [])
        op_rscount = utils.ixia_c_operator_ok(op_rscount)

    finally:
        utils.delete_kne_config(namespace1_config, namespace1)
        utils.ixia_c_pods_ok(namespace1, [])
        utils.ixia_c_services_ok(namespace1, [])
        utils.delete_config(namespace1_config)
