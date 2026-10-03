# Diagrams

C4 views (context → container → component) and the main flows. Mermaid; render
in GitHub or any Mermaid viewer.

## C4 — Context

```mermaid
flowchart TB
  PT([Platform team<br/>defines tenants])
  AT([Application team<br/>annotates workloads])
  SEC([Security and audit<br/>verifies isolation])
  subgraph SYS[Vault Community extension for the Multi-Tenant Operator]
    EXT[Derives each tenant's mount,<br/>policies and login roles, checked in scope]
  end
  MTO[Multi-Tenant Operator<br/>Tenant, namespaces, labels]
  VCO[vault-config-operator<br/>writes Vault configuration]
  V[Vault Community Edition<br/>one root namespace, enforces policies]
  ESO[External Secrets Operator<br/>Vault in, Kubernetes Secret out]
  IDP[Identity provider<br/>groups tenant-tier]
  PT -->|Tenant| MTO
  MTO -->|Tenant, namespaces| EXT
  AT -->|ServiceAccount and Deployment annotations| EXT
  EXT -->|VCO CRs| VCO
  VCO -->|mounts, policies, roles| V
  ESO -->|logs in as the workload| V
  IDP -->|group membership| V
  SEC -->|audit log, policies| V
```

## C4 — Container

```mermaid
flowchart LR
  subgraph Cluster[OpenShift / Kubernetes cluster]
    MTO[Multi-Tenant Operator]
    subgraph TOP[Template Operator v2]
      PTI[Parent TemplateInstance<br/>per Tenant: SecretEngineMount tenant/kv]
      CTI[Child TemplateInstances<br/>core and eso slice per tenant]
    end
    BOOT[[mto-extension-vault-community-bootstrap<br/>Helm, installed once]]
    VCO[vault-config-operator<br/>login role vco-admin, name-bounded policy]
    NS[Tenant namespaces<br/>vault-config-sa ConfigMaps, SecretStores,<br/>ExternalSecrets, Secrets]
    ESO[External Secrets Operator]
    REL[Reloader Enterprise]
  end
  subgraph V[Vault Community Edition, root namespace]
    KVA[(team-a/kv)]
    KVB[(team-b/kv)]
    KVS[(shared/kv)]
    K8S[auth/kubernetes/workloads<br/>roles kv.tenant.ns.sa]
    OIDC[auth/oidc/sso<br/>roles sso.tenant.tier]
    POL[policies kv.* share.* sso.*]
  end
  IDP[Identity provider]
  BOOT --> PTI
  MTO -->|Tenant list| PTI
  PTI -->|emits| CTI
  PTI -->|SecretEngineMount| VCO
  CTI -->|Policy, roles| VCO
  CTI -->|ConfigMaps, ESO objects| NS
  VCO --> KVA & KVB & KVS & K8S & OIDC & POL
  ESO -->|login as workload| K8S
  ESO -->|read| KVA
  ESO --> NS
  REL -->|rolling restart| NS
  IDP --> OIDC
```

## C4 — Component (per-tenant chart)

```mermaid
flowchart TB
  subgraph Chart[mto-extension-vault-community, rendered per tenant]
    IN[/Inputs: tenant, namespaces by selector,<br/>annotated ServiceAccounts and Deployments/]
    SCOPE[_helpers.tpl<br/>scope check: every path inside tenant/kv<br/>or its named shares; name families]
    SA[04-sa-own-tenant<br/>Policy + KubernetesAuthEngineRole per SA]
    SH[04-sa-share-in / -out<br/>share policies and roles on shared/kv]
    SSO[06-oidc / 07-sso-policies<br/>roles and policies per tier]
    CM[vault-config-sa, vault-apps<br/>VAULT_NAMESPACE empty]
    ES[05-externalsecrets<br/>slice eso]
  end
  IN --> SCOPE --> SA & SH & SSO
  IN --> CM & ES
```

## Onboard, deliver, rotate

```mermaid
sequenceDiagram
  participant PT as Platform team
  participant AT as Application team
  participant EXT as Extension (Template Operator)
  participant VCO as vault-config-operator
  participant V as Vault Community
  participant ESO as External Secrets Operator
  participant R as Reloader Enterprise
  participant P as Pods
  PT->>EXT: Tenant team-a
  EXT->>VCO: SecretEngineMount team-a/kv
  VCO->>V: mount team-a/kv
  AT->>EXT: annotate ServiceAccount web, Deployment
  EXT->>EXT: scope check: every path under team-a/kv/
  EXT->>VCO: Policy and role kv.team-a.team-a-api.web
  VCO->>V: policy, Kubernetes auth role
  EXT->>ESO: SecretStore web-vault, ExternalSecret web-db-creds
  AT->>V: sign in (OIDC, sso.team-a.editor), write postgres
  ESO->>V: log in as web, read team-a/kv/data/dev/team-a-api/web/postgres
  ESO->>P: Secret web-db-creds
  AT->>V: write a new version
  ESO->>V: next refresh reads it
  R->>P: rolling restart, new value live
```

## Offboard

```mermaid
sequenceDiagram
  participant PT as Platform team
  participant EXT as Extension (Template Operator)
  participant VCO as vault-config-operator
  participant V as Vault Community
  participant VA as Vault admin
  PT->>EXT: delete Tenant team-a
  EXT->>VCO: remove Policies, roles, share roles
  VCO->>V: delete policies and roles: access revoked
  EXT->>VCO: remove SecretEngineMount team-a/kv
  VCO--xV: disable mount: denied by VCO's policy
  Note over VCO,V: CR stays Terminating, secrets stay
  VA->>V: later, deliberate: vault secrets disable team-a/kv
  VA->>VCO: remove the CR's finalizer
```

## The leak this design closes

```mermaid
flowchart LR
  subgraph Bad[A policy written by hand]
    W[path kv/data/team*] --> L1[team-a's app reads<br/>kv/data/team-ab/...]
    T[one policy per tenant] --> L2[every app in team-a<br/>reads every other app]
  end
  subgraph Good[Rendered and checked]
    R[team-a/kv/data/dev/team-a-api/web/*] --> C{scope check:<br/>under team-a/kv/,<br/>segment closed by /}
    C -->|passes| OK[Policy written by VCO]
    C -->|fails| X[render fails, nothing written]
  end
```
