# Homelab Configurations with FlagOps

This is my personal homelab and self hosted infrastructure using another project of mine [FlagOps](https://github.com/graytonio/flagops). This allows me to control different pieces and configurations across environments using feature flags similar to runtime applications.

## Dependencies

These are tools/servies that need to be setup in advanced before this repository can be used correctly.

- [ArgoCD Autopilot](https://argocd-autopilot.readthedocs.io/en/stable/)
- [FlagOps](https://github.com/graytonio/flagops)
- [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)
- [Cloudflare DNS](https://www.cloudflare.com/application-services/products/dns/)
- [Grafana Cloud](https://grafana.com/products/cloud/)

Details on required setup in the bootstrapping section

## Structure

- **bootstrap/**: Contains the essentials manifests to install ArgoCD as a self managed deployment. This allows argocd to manage itself and then pull in the other manifests in this repository. This section is used primarily by ArgoCD Autopilot during bootstrapping and for any version upgrades needed down the line.

- **projects/**: Contains "environment" definitions such as production and staging. Each environment is intended to be deployed to a dedicated set of machines with the bootstrapping existing on a "management" cluster. In my setup the production system and the management cluster are the same but this is not required. They create an Argo Project and an ApplicationSet which typically will dynamically pickup definitions from the apps/ directory.

- **apps/**: Contains individual application definitions through helm charts. Typically a chart will contain its dependency which will be some external dependency and a values file to configure it. In some circumstances additional templates will be added to make running the apps easier. By defauly all projects receive all configured apps in the apps folder.

## Applications

### Infrastructure

These applications are infrastructure components used to support other applications. They typically provide services like DNS, storage, and secrets management.

- [External DNS](https://github.com/kubernetes-sigs/external-dns) - Syncs ingress dns records with cloudflare and internal adguard
- [External Secrets](https://external-secrets.io/latest/) - Syncs secrets from aws secrets manager to k8s secret objects
- [MetalLB](https://metallb.io/) - Provides a baremetal loadbalancer implementation
- [Longhorn](https://longhorn.io/) - Exposes node storage as dynamic storage class
- [Traefik](https://github.com/traefik/traefik) - Reverse proxy and service discovery
- [Prometheus Agent](https://grafana.com/docs/agent/latest/operator/) - Forwarding metrics and logs to grafana cloud
- [Gotify](https://gotify.net/) - Notification services

### User Apps

These are the forward facing applications that provide services to users

- [Homepage](https://gethomepage.dev/) - Provides a portal to see all available services
- [Radarr](https://radarr.video/) - Movie media management system
- [Sonarr](https://sonarr.tv/) - TV Show media management system
- [Overseerr](https://overseerr.dev/) - Media request system
- [HomeAssistant](https://www.home-assistant.io/) - Self hosted home automation platform
- [Discord File Sync Bot](https://github.com/graytonio/discord-file-sync) - Bot for syncing markdown files to discord embeds

## Bootstrapping

In order to take this repository and go to a fully functioning deployment you need to have the following setup before hand.

TODO