# Architecture Decision Records (ADR)

## ADR-001: Infisical for Secrets Management

**Date:** 2025-10-19
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
Need centralized secrets management solution for Kubernetes cluster that:
- Supports multi-environment (dev/staging/prod)
- Provides audit logging
- Integrates with Kubernetes via External Secrets Operator
- Can be self-hosted for data sovereignty

### Decision
Use Infisical as the primary secrets management platform.

### Rationale
**Pros:**
- Self-hosted option available
- Native Kubernetes integration via ESO
- Good UI for secret management
- Supports multiple environments per project
- Machine Identity authentication
- Audit logging built-in
- Active development and community

**Cons:**
- Requires PostgreSQL and Redis infrastructure
- Learning curve for team
- Self-hosted means we manage updates

**Alternatives Considered:**
- **HashiCorp Vault:** More complex, heavyweight for our use case
- **Sealed Secrets:** No centralized UI, harder to manage at scale
- **SOPS:** File-based, no centralized management
- **AWS Secrets Manager:** Cloud-dependent, cost implications

### Consequences
- Need to maintain PostgreSQL and Redis for Infisical
- Must implement backup strategy for Infisical database
- Team needs training on Infisical workflows
- All new secrets should be added via Infisical

## ADR-002: cert-manager with Let's Encrypt for TLS

**Date:** 2025-10-22
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
Need automated TLS certificate management for all HTTPS endpoints in cluster.

### Decision
Use cert-manager with Let's Encrypt for automatic certificate issuance and renewal.

### Rationale
**Pros:**
- Industry standard for K8s certificate management
- Free certificates from Let's Encrypt
- Automatic renewal (30 days before expiration)
- Supports multiple challenge types (HTTP01, DNS01)
- Active CNCF project with strong community

**Cons:**
- Let's Encrypt rate limits (50 certs/domain/week)
- Requires DNS provider integration for DNS01
- Additional infrastructure component to maintain

**Alternatives Considered:**
- **Manual certificate management:** Not scalable, error-prone
- **Self-signed certificates:** Browser warnings, not production-ready
- **Commercial CA:** Additional costs, manual processes

### Implementation Details
- Use DNS01 challenge via Cloudflare for flexibility
- Store Cloudflare API token in Infisical
- Sync token to Kubernetes via External Secrets Operator
- Use staging issuer for testing to avoid rate limits

### Consequences
- Need Cloudflare API token with DNS edit permissions
- Must monitor certificate expiration as backup
- All HTTPS services should use cert-manager
- DNS01 challenges add 1-3 minute delay to cert issuance

## ADR-003: Traefik for Ingress Controller

**Date:** 2025-10 (prior to current session)
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
Need ingress controller for routing external traffic to services.

### Decision
Use Traefik as the ingress controller.

### Rationale
**Pros:**
- Native support for Kubernetes CRDs (IngressRoute)
- Built-in Let's Encrypt support
- Middleware support for authentication, rate limiting, etc.
- Good dashboard for monitoring
- HTTP/2 and HTTP/3 support
- Native support for TCP/UDP routing

**Cons:**
- CRD-based configuration not compatible with standard Ingress
- Different from nginx (more common choice)

**Alternatives Considered:**
- **nginx-ingress:** More common, but less feature-rich
- **HAProxy:** Good performance, but less k8s-native
- **Kong:** More complex, API gateway features we don't need

### Consequences
- Must use IngressRoute CRDs instead of standard Ingress
- Team needs to learn Traefik-specific configuration
- Easier TLS termination and middleware configuration

## ADR-004: DNS01 Challenge for TLS Certificates

**Date:** 2025-10-22
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
Need to choose between HTTP01 and DNS01 challenge for Let's Encrypt certificates.

### Decision
Use DNS01 challenge via Cloudflare for all certificates.

### Rationale
**Pros:**
- Works for services not exposed to internet
- Supports wildcard certificates
- No need to expose services on port 80 during challenge
- More flexible for internal services

**Cons:**
- Requires DNS provider integration
- Slightly slower (1-3 min for DNS propagation)
- Requires Cloudflare API token management

**HTTP01 Alternative:**
- Pros: Faster, simpler
- Cons: Requires HTTP exposure, no wildcards, only for publicly accessible services

### Implementation
- Store Cloudflare API token in Infisical
- Sync to cert-manager namespace via ExternalSecret
- Use single ClusterIssuer for all namespaces

### Consequences
- Need to manage Cloudflare API token securely
- Certificate issuance takes 1-3 minutes
- Can issue certificates for internal-only services

## ADR-005: External Secrets Operator for Secret Synchronization

**Date:** 2025-10-22
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
Need mechanism to sync secrets from Infisical to Kubernetes.

### Decision
Use External Secrets Operator (ESO) as the synchronization mechanism.

### Rationale
**Pros:**
- CNCF project, well-maintained
- Supports multiple secret backends (Infisical, Vault, AWS, etc.)
- Declarative configuration (ExternalSecret CRDs)
- Automatic sync with configurable interval
- ClusterSecretStore for sharing across namespaces

**Cons:**
- Additional component to maintain
- Adds complexity to secret management
- Sync delay (default 1 hour)

**Alternatives Considered:**
- **Infisical Kubernetes Operator:** Less mature, Infisical-specific
- **Manual sync scripts:** Not scalable, error-prone
- **Direct API calls:** No automatic updates, complex to implement

### Implementation
- Use ClusterSecretStore for cluster-wide configuration
- Per-namespace ExternalSecrets for secret mapping
- 1-hour sync interval (can be overridden)
- Machine Identity authentication to Infisical

### Consequences
- Secrets may be up to 1 hour out of sync
- Need to manage Machine Identity credentials
- Can force sync with annotation for immediate updates

## ADR-006: Machine Identity for ESO Authentication

**Date:** 2025-10-22
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
ESO needs to authenticate to Infisical. Multiple auth methods available.

### Decision
Use Infisical Machine Identity with Universal Auth.

### Rationale
**Pros:**
- Designed for machine-to-machine authentication
- Client ID + Client Secret pattern (familiar)
- Fine-grained access control (per-project permissions)
- Can be scoped to specific projects and environments
- Audit trail of access

**Cons:**
- Need to manage client credentials
- Initial setup more complex than service tokens

**Alternatives Considered:**
- **Service Tokens:** Legacy, being deprecated by Infisical
- **API Keys:** Less secure, broader permissions

### Implementation
- Machine Identity: `k8s-external-secrets`
- Role: Viewer (read-only)
- Scope: Project `traefik-certificates-bq-pt`, environment `prod`
- Credentials stored in `universal-auth-credentials` secret

### Consequences
- Need to backup Machine Identity credentials
- Must grant per-project access manually
- More secure than service tokens

## ADR-007: Internal HTTP for ClusterSecretStore

**Date:** 2025-10-22
**Status:** Accepted
**Deciders:** Infrastructure Team

### Context
ClusterSecretStore can connect to Infisical via internal HTTP or external HTTPS URL.

### Decision
Use internal cluster HTTP URL: `http://infisical.infisical.svc.cluster.local:8080`

### Rationale
**Pros:**
- No external network dependency
- Faster (no TLS overhead internally)
- No certificate validation issues
- More resilient to external network issues

**Cons:**
- Internal traffic not encrypted
- Relies on Kubernetes network security

**HTTPS Alternative:**
- Pros: End-to-end encryption
- Cons: External dependency, certificate validation complexity, slower

### Security Considerations
- Kubernetes network policy provides isolation
- Traffic stays within cluster network
- External access to Infisical uses HTTPS via Traefik

### Consequences
- ClusterSecretStore uses HTTP URL
- Must ensure Kubernetes network security
- External access always uses HTTPS

## Decision-Making Process

All architecture decisions should:
1. Be documented in this file
2. Include context, decision, rationale, and consequences
3. Consider at least 2 alternatives
4. Be reviewed after 6 months
5. Be updated if reversed or modified

---

**Last Updated:** 2025-10-22
**Next Review:** 2026-04-22
