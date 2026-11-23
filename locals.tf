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
      # Bitnami stopped publishing versioned tags to the free registry: only
      # `latest` and digests are available, and bitnamilegacy tops out at
      # 17.6.0. Pin the digest so the deployment stays reproducible; it
      # currently resolves to PostgreSQL 18.7.0.
      image = {
        repository = "bitnami/postgresql"
        digest     = "sha256:2b159820ab3aee5655746887aae740402153ef937968370ff4e03461822b4ba9"
        debug      = var.debug
      }
      primary = {
        initdb = {
          scripts = {
            "init.sql" = <<-EOT
%{for db in local.databases~}
CREATE DATABASE ${db} OWNER ${local.credentials.username};
%{endfor~}
CREATE USER ${local.credentials.username}hive WITH PASSWORD '${local.credentials.password}';
CREATE DATABASE metastore OWNER ${local.credentials.username}hive;
GRANT ALL PRIVILEGES ON DATABASE metastore TO ${local.credentials.username}hive;
            EOT
          }
        }
        extraEnvVars = [
          # Bitnami defaults pg_hba to md5, which PostgreSQL 18 can no longer
          # verify at all, so the server must be told to use scram-sha-256.
          {
            name  = "POSTGRESQL_PGHBA_AUTH_METHOD"
            value = "scram-sha-256"
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
