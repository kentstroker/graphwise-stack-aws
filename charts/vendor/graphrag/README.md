# GraphRAG Helm Chart

Welcome to the official Helm chart for GraphRAG by Graphwise! This Helm chart makes it easy to deploy and manage the
GraphRAG system on our Kubernetes cluster.

### Prerequisites

* Kubernetes v1.32+
* Helm v3.8+

For development and testing, you can use [kind](https://kind.sigs.k8s.io/) to create a local Kubernetes cluster.

## Install

Create a dedicated namespace where GraphRAG will be installed.

```shell
kubectl create namespace graphrag
```

### Dependencies

GraphRAG depends on the following services:

* Keycloak - Authentication and authorization in the Chatbot web application
* PostgreSQL - Database for n8n workflows

In case you are testing GraphRAG locally, you can follow the [development examples](examples/dev) for deploying a sample
Keycloak and PostgreSQL instances using their official Kubernetes operators.
Note that these examples are only for local testing and experimentation, **not** for production.

### Secrets

1. Registry credentials for pulling container images

    ```shell
    kubectl -n graphrag create secret docker-registry graphwise \
            --docker-server=maven.ontotext.com \
            --docker-username=<username> \
            --docker-password=<password>
    ```

2. Secret for the Conversation service database credentials

    ```shell
    kubectl -n graphrag create secret generic graphrag-conversation-database-credentials \
      --from-literal=spring.datasource.username='graphrag_conversation' \
      --from-literal=spring.datasource.password='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

3. Secret for the Conversation service Keycloak client

    ```shell
    kubectl -n graphrag create secret generic graphrag-conversation-keycloak-client \
      --from-literal=spring.security.oauth2.client.registration.keycloak.client-id='conversation-api-client' \
      --from-literal=spring.security.oauth2.client.registration.keycloak.client-secret='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
      --from-literal=spring.security.oauth2.client.registration.keycloak.scope='openid'
    ```

4. ConfigMap for the Components service vector database connection details

    ```shell
    kubectl -n graphrag create configmap graphrag-components-vector-database \
      --from-literal=VECTOR_STORE='opensearch' \
      --from-literal=OPENSEARCH_ENDPOINT='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
      --from-literal=VECTOR_INDEX='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
      --from-literal=VECTOR_FIELD_NAME='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

5. Secret for the Components service AWS credentials

    ```shell
    kubectl -n graphrag create secret generic graphrag-components-aws-credentials \
      --from-literal=AWS_REGION='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
      --from-literal=AWS_ACCESS_KEY_ID='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' \
      --from-literal=AWS_SECRET_ACCESS_KEY='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

6. Secret for the Workflows n8n database connection credentials

    ```shell
    kubectl -n graphrag create secret generic graphrag-n8n-database-credentials \
      --from-literal=DB_POSTGRESDB_USER='n8n' \
      --from-literal=DB_POSTGRESDB_PASSWORD='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

7. Secret for the Workflows n8n encryption key

    ```shell
    kubectl -n graphrag create secret generic graphrag-n8n-encryption \
      --from-literal=N8N_ENCRYPTION_KEY='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

8. Secret for the Workflows n8n license key

    ```shell
    kubectl -n graphrag create secret generic graphrag-n8n-license \
      --from-literal=N8N_LICENSE_ACTIVATION_KEY='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
    ```

You can use the [values.example.yaml](values.example.yaml) in addition to use the referenced secrets.

### Configuration

The GraphRAG Helm charts are designed to be customized and reconfigured in a myriad of ways:

* Providing additional environment variables to the subcharts via `extraEnv` and `extraEnvFrom`
* Configuring additional volumes and volume mounts to the subcharts via `extraVolumes` and `extraVolumeMounts`
* Providing additional init containers via `extraInitContainers`
* Disabling default resources like ingresses, services, persistence and providing your own
* Overriding the default values.yaml files
* And so on

Refer to the [values.yaml](values.yaml) file of each sub-chart for more details.

For simplicity, we have fixed the resource names, so they can be easily referenced across the default configurations.
You can override this by providing a different values.yaml file, but you must take care of service references.

Furthermore, we have configured the Ingress resources to use the `127.0.0.1.nip.io` domain name so for any non-test
deployment,
you need to override this.

### Deploy

Once you have prepared all required configurations and secrets, simply execute the following command:

```shell
helm --namespace graphrag upgrade --install --dependency-update -f values.example.yaml graphrag .
```

## Post-Install

### GraphRAG Workflows Provisioning

GraphRAG Workflows uses [n8n](https://n8n.io/) which can be provisioned and updated if needed, by executing SQL scripts
against its PostgreSQL database. For this, Graphwise provides the necessary initialization SQL scripts.

Once you have deployed GraphRAG and have been provided with an initialization SQL script, you can use the following
command to find the PostgreSQL leader and provision n8n:

```shell
CLUSTER_NAME="graphrag-postgres-n8n"
DATABASE_NAME="n8n"
PRIMARY_POD=$(kubectl -n graphrag get pod -l "cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')
kubectl -n graphrag exec -i $PRIMARY_POD -- psql -v ON_ERROR_STOP=1 -d $DATABASE_NAME < n8n_db_script_v.2.4.4.sql
```

Note: If your cluster and database are named differently, you might need to adjust the above script snippet accordingly.

### GraphRAG Workflows Dependencies

**Important**: These workflows might contain references and URLs to the GraphRAG services, so make sure they match the
actual service names in the cluster. You can check the service names by running:

```shell
kubectl -n graphrag get svc
```

### N8N Datatables

There might be additional steps for completing the N8N workflow integration, such as creating N8N datatables with API
keys. This varies by use case, so make sure to follow the documentation for your specific use case.

## Production

The GraphRAG Helm chart is designed to be used in a production environment but is not opinionated about the underlying
infrastructure. This means that you need to fine-tune the Helm chart values to match your specific environment and use
case. This includes:

* Storage classes and disk sizes
* Resource requests and limits
* Ingress controllers and annotations
* TLS certificates for SSL/TLS
* Network policies
* etc.

## Development

Checkout the dev example in [examples/dev/](examples/dev).

## Uninstall

To remove your GraphRAG deployment, run the following command:

```shell
helm --namespace graphrag uninstall graphrag
```

### Persistence

There might be leftover resources that need to be cleaned up manually, such as Persistent Volume Claims and their
associated Persistent
Volumes. This largely depends on your Kubernetes cluster, the persistence settings and related Helm overrides.

You can check for these resources by running:

```shell
kubectl -n graphrag get pvc,pv
```

It's up to you to decide whether to delete these resources or not.
