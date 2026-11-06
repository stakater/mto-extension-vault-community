# Vendored vault-config-operator CRDs

The 7 VCO CRDs the charts render, used by `make crd-validate`, so the render
tests validate against the exact schema the lab and CI install, without a
cluster or a network call. There is no `Namespace` CRD: Vault Community
Edition has no namespaces, and the charts never render one.

Source: the `vault-config-operator` **v1.0.3** release chart
(`https://redhat-cop.github.io/vault-config-operator`), as vendored by the
Enterprise extension at `72f425c`.

Refresh with `make vco-crds-sync` (from the `VCO_VERSION` release chart) and
update the source line above.

A kind the charts render without a CRD here fails `crd-validate` ("no CRD for
…"), so adding a kind means adding its CRD.
