locals {
  credentials = {
    username = "moderngitopsadmin"
    password = resource.random_password.password_secret.result
  }
  databases = concat(["airflow", "jupyterhub", "mlflow", "curated", "feature_store", "litellm"], var.databases)
  helm_values = [{
    postgresql = {
      volumePermissions = {
        enabled = true
        image = {
          repository = "bitnamilegacy/os-shell"
        }
      }
      metrics = {
        enabled = var.enable_service_monitor
        serviceMonitor = {
          enabled       = var.enable_service_monitor
          interval      = "10s"
          scrapeTimeout = "5s"
        }
        image = {
          repository = "bitnamilegacy/postgres-exporter"
        }
      }
      global = {
        security = {
          allowInsecureImages = true
        }
        postgresql = {
          auth = {
            username       = local.credentials.username
            database       = "keycloak"
            existingSecret = "postgresql-secrets"
            secretKeys = {
              adminPasswordKey       = "postgres-password"
              userPasswordKey        = "password"
              replicationPasswordKey = "replication-password"
            }
          }
        }
      }
      image = {
        repository = "bitnamilegacy/postgresql"
        debug      = var.debug
      }
      primary = {
        initdb = {
          scripts = {
            "init.sql" = <<-EOT
%{for db in local.databases~}
CREATE DATABASE ${db} OWNER ${local.credentials.username};
%{endfor~}
CREATE USER ${local.credentials.username}hive WITH PASSWORD 'md5${md5("${local.credentials.password}${local.credentials.username}hive")}';
CREATE DATABASE metastore OWNER ${local.credentials.username}hive;
GRANT ALL PRIVILEGES ON DATABASE metastore TO ${local.credentials.username}hive;
            EOT
          }
        }
        # The hive-metastore image ships a JDBC driver that predates
        # PostgreSQL 14's scram-sha-256 default and fails with
        # "The authentication type 10 is not supported". The md5 hash in
        # init.sql only takes effect when the server encrypts with md5.
        extraEnvVars = [
          {
            name  = "POSTGRESQL_PASSWORD_ENCRYPTION"
            value = "md5"
          },
          # The chart runs initdb scripts as POSTGRES_INITSCRIPTS_USERNAME,
          # which defaults to the application user. That role is created with
          # CREATEDB but not CREATEROLE, so "CREATE USER ...hive" failed and
          # the script aborted before creating the metastore database.
          {
            name  = "POSTGRES_INITSCRIPTS_USERNAME"
            value = "postgres"
          },
          {
            name  = "POSTGRES_INITSCRIPTS_PASSWORD"
            value = "${local.credentials.password}"
          }
        ]
        service = {
          type = "ClusterIP"
        }
        persistence = {
          size = "${var.persistence_size}Gi"
        }
        resources = {
          requests = { for k, v in var.resources.requests : k => v if v != null }
          limits   = { for k, v in var.resources.limits : k => v if v != null }
        }
        # Istio ambient mode tunnels mesh traffic between pods over HBONE on
        # port 15008. NetworkPolicy is enforced on the host (outside the pod),
        # so a policy restricting ingress to only the app port (5432) blocks
        # the HBONE-encapsulated connection before it ever reaches the pod.
        # See: https://istio.io/latest/docs/ambient/usage/networkpolicy/
        networkPolicy = {
          extraIngress = [
            {
              ports = [
                { port = 15008, protocol = "TCP" }
              ]
            }
          ]
        }
      }
    }
  }]
}
