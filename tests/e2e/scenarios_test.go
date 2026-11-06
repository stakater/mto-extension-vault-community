package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

// The fixture: three tenants in Vault's one namespace.
//
//	e2e-alpha  e2e-alpha-dev    SA web     kv editor, exports to e2e-beta
//	                            SA viewer  kv viewer
//	                            SA admin   kv admin
//	                            SA auditor kv audit-read
//	                            SA temp    kv editor, its access is removed mid-run
//	                            SA lower   kv editor, lowered to viewer mid-run
//	           e2e-alpha-tools  SA web     no annotation: web's name in another namespace
//	                            SA sub     kv editor, subscribes to e2e-alpha-dev
//	                            SA nosub   kv editor, no subscription
//	           e2e-alpha-reuse  SA app     kv editor; the namespace is deleted and
//	                                       created again under e2e-beta
//	e2e-beta   e2e-beta-dev     SA reader  kv viewer, imports from e2e-alpha
//	e2e        e2e-core         SA core    kv admin, exports to e2e-beta; "e2e" is a prefix of
//	                                       "e2e-alpha" and "e2e-beta" (AC-ISO-3)
//
// Names are short on purpose: the child TemplateInstance name is
// mto-extension-vault-community-<tenant>[.eso], capped at 63 characters.
const (
	alpha   = "e2e-alpha"
	beta    = "e2e-beta"
	prefixT = "e2e"
	alphaNS = "e2e-alpha-dev"
	toolsNS = "e2e-alpha-tools"
	reuseNS = "e2e-alpha-reuse"
	betaNS  = "e2e-beta-dev"
	coreNS  = "e2e-core"
)

// The number of cases of hack/lab/admission-cases.sh (CASES in
// hack/admission-offline.sh), and the ones that run offline only, by
// description: their old object (a spec out of scope, or no spec) can't be
// created while admission is on, or the lab installs no CRD of their kind.
const admissionCases = 109

var admissionOfflineCases = []string{
	"a spec with a connection put back during a deletion",
	"a finalizer removed during a deletion, the spec unchanged",
	"a finalizer removed during a deletion of a CR without a spec",
	"a cluster-scoped redhatcop.redhat.io object of another operator",
	"a cluster-scoped object of another operator, written by Template Operator",
}

// e2eTenants are every tenant the suite creates, for the preflight's cleanup.
var e2eTenants = []string{alpha, beta, prefixT}

// roleName mirrors the tenant chart's vault.roleName: kv.<tenant>.<ns>.<sa>.
func roleName(tenant, ns, sa string) string { return "kv." + tenant + "." + ns + "." + sa }

// appPath is an app's own KV prefix inside its tenant's mount: <env>/<ns>/<app>.
func appPath(ns, app, leaf string) string { return env + "/" + ns + "/" + app + "/" + leaf }

// sharedPath is a namespace's intra-tenant write area: <env>/_shared/from-<ns>.
func sharedPath(ns, leaf string) string { return env + "/_shared/from-" + ns + "/" + leaf }

// TestE2E is one ordered scenario against one install. Each step depends on the
// state the previous one left, so the steps are subtests of one test and a
// failure stops the run.
func TestE2E(t *testing.T) {
	step := func(name string, f func(t *testing.T)) {
		t.Helper()
		if !t.Run(name, f) {
			t.FailNow()
		}
	}

	step("preflight", func(t *testing.T) {
		// This extension is for Community Edition: a tenant is a path prefix in
		// Vault's one namespace. On Enterprise the same charts would work, but
		// prove nothing about the edition they are for, and the Enterprise
		// extension is the one to use there. Asked of the SERVER, not the CLI
		// binary in the pod.
		var st struct{ Version string }
		if err := json.Unmarshal([]byte(vaultRoot(t, "status", "-format=json")), &st); err != nil || st.Version == "" {
			t.Fatalf("cannot read the Vault server's version: %q, err %v", st.Version, err)
		}
		if strings.Contains(st.Version, "+ent") {
			t.Fatalf("the Vault server is Enterprise (%s) — this suite tests the Community Edition extension; use mto-extension-vault-enterprise there", st.Version)
		}
		// Every run starts from the customer's starting point: no install, no
		// fixture tenants.
		if releaseExists(t) || get(t, gvrTemplateInstance, configNS, parentName) != nil {
			uninstall(t)
		}
		deleteTenant(t, alpha, alphaNS, toolsNS, reuseNS)
		deleteTenant(t, beta, betaNS, reuseNS)
		deleteTenant(t, prefixT, coreNS)
		deleteTenant(t, "e2e-plat", "e2e-plat-dev")
		// Vault state a failed run left behind would make the root checks below
		// pass without this run creating anything. The lab Vault is dev mode, so
		// root may remove it.
		for _, tn := range append(slices.Clone(e2eTenants), sharedName) {
			if slices.Contains(vaultKeys(t, "secrets", "list", "-format=json"), kvMount(tn)+"/") {
				vaultRoot(t, "secrets", "disable", kvMount(tn))
			}
			if slices.Contains(vaultKeys(t, "auth", "list", "-format=json"), k8sAuthMount(tn)+"/") {
				vaultRoot(t, "auth", "disable", k8sAuthMount(tn))
			}
		}
		// SSO needs the lab's Dex and Keycloak. Checked here, so a lab without
		// them fails in one clear line instead of at the SSO step.
		if got := dexIssuerFromVault(t); got != dexIssuer {
			t.Fatalf("Dex names its issuer %q, want %q: tokens would not validate", got, dexIssuer)
		}
		// The SSO roles allow the CLI callback and each tenant's UI callback
		// (helmInstall). Dex must too, or it refuses the login with
		// "Unregistered redirect_uri"; it has no wildcard, so one per tenant.
		dexRedirects := dexClientRedirects(t)
		for _, want := range []string{cliCallback, uiCallbackFor(alpha), uiCallbackFor(beta)} {
			if !slices.Contains(dexRedirects, want) {
				t.Fatalf("Dex client %s does not allow the redirect URI %s (it allows %v)", dexClient, want, dexRedirects)
			}
		}
		for _, u := range []string{"alice", "bob", "carol", "dave", "erin"} {
			testUserPassword(t, u)
		}
		// The health step's platform mounts.
		if slices.Contains(vaultKeys(t, "secrets", "list", "-format=json"), "e2e-plat/") {
			vaultRoot(t, "secrets", "disable", "e2e-plat")
		}
		if slices.Contains(vaultKeys(t, "auth", "list", "-format=json"), "e2e-plat/") {
			vaultRoot(t, "auth", "disable", "e2e-plat")
		}
		// VCO's own login must be the one make lab-vault-bootstrap wrote.
		if a := vaultKeys(t, "auth", "list", "-format=json"); !slices.Contains(a, vcoLoginMount+"/") {
			t.Fatalf("VCO's login mount %s/ is missing: %v — run make lab-vault-bootstrap", vcoLoginMount, a)
		}
	})

	// The teardown runs even when a step fails: t.Cleanup, not the last step.
	// A failed run otherwise left its install and fixtures behind for the next.
	// The one exception is E2E_KEEP_ON_FAILURE (set by make e2e-kind): its
	// e2e-diagnostics runs after go test exits, and a teardown first would
	// leave it nothing to dump. The next run's preflight removes that state.
	//
	// One cleanup per job, not one for all: they run in reverse order of
	// registration, and a t.Fatalf inside one ends only that one, so a failed
	// uninstall does not skip the tenant deletion.
	if os.Getenv("E2E_KEEP") == "" {
		keep := func() bool { return t.Failed() && os.Getenv("E2E_KEEP_ON_FAILURE") != "" }
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, prefixT, coreNS)
			}
		})
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, beta, betaNS, reuseNS)
			}
		})
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, alpha, alphaNS, toolsNS, reuseNS)
			}
		})
		t.Cleanup(func() {
			if keep() {
				t.Log("the run failed and E2E_KEEP_ON_FAILURE is set: leaving the install and fixtures for diagnostics")
				return
			}
			uninstall(t)
		})
	}

	step("install", func(t *testing.T) {
		createTenant(t, alpha, alphaNS, toolsNS, reuseNS)
		createTenant(t, beta, betaNS)
		createTenant(t, prefixT, coreNS)
		createServiceAccount(t, alphaNS, "web", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "role":             "editor",
			annPrefix + "kv-export-tenant": beta,
		})
		for sa, role := range map[string]string{"viewer": "viewer", "admin": "admin", "auditor": "audit-read", "temp": "editor", "lower": "editor"} {
			createServiceAccount(t, alphaNS, sa, map[string]string{annPrefix + "kv": "true", annPrefix + "role": role})
		}
		// Named like web, in another namespace, with no annotation: a role binds
		// a ServiceAccount name AND a namespace, and the login refusals below
		// change one of the two at a time.
		createServiceAccount(t, toolsNS, "web", nil)
		// An editor: a read-only subscription must hold even for a role that can
		// write its own prefixes — with viewer the refusals could not fail.
		createServiceAccount(t, toolsNS, "sub", map[string]string{
			annPrefix + "kv":              "true",
			annPrefix + "role":            "editor",
			annPrefix + "kv-subscribe-ns": alphaNS,
		})
		createServiceAccount(t, toolsNS, "nosub", map[string]string{annPrefix + "kv": "true", annPrefix + "role": "editor"})
		createServiceAccount(t, reuseNS, "app", map[string]string{annPrefix + "kv": "true", annPrefix + "role": "editor"})
		createServiceAccount(t, betaNS, "reader", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "role":             "viewer",
			annPrefix + "kv-import-tenant": alpha,
		})
		createServiceAccount(t, coreNS, "core", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "role":             "admin",
			annPrefix + "kv-export-tenant": beta,
		})
		copyOIDCClientSecret(t)
		helmInstall(t)
		waitTIReady(t, parentName)
		for _, tn := range e2eTenants {
			waitTIReady(t, tiPrefix+tn)
			waitTIReady(t, tiPrefix+tn+".eso")
		}
	})

	step("render: one kv mount and one auth mount per tenant", func(t *testing.T) {
		waitVCO(t, "secretenginemounts", sharedName+"-kv")
		for _, tn := range e2eTenants {
			for _, o := range []struct{ kind, name string }{
				{"secretenginemounts", tn + "-kv"},
				{"authenginemounts", tn + "-kubernetes"},
				{"kubernetesauthengineconfigs", tn + "-kubernetes-config"},
			} {
				waitVCO(t, o.kind, o.name)
			}
		}
		for _, r := range []string{roleName(alpha, alphaNS, "web"), roleName(alpha, alphaNS, "viewer"),
			roleName(alpha, alphaNS, "admin"), roleName(alpha, alphaNS, "auditor"), roleName(alpha, reuseNS, "app"),
			roleName(alpha, alphaNS, "temp"), roleName(alpha, alphaNS, "lower"),
			roleName(alpha, toolsNS, "sub"), roleName(alpha, toolsNS, "nosub"),
			roleName(beta, betaNS, "reader"), roleName(prefixT, coreNS, "core")} {
			waitVCO(t, "policies", r)
			waitVCO(t, "kubernetesauthengineroles", r)
		}
		// VCO deletes an object in Vault only through its finalizer, which it
		// adds after the first successful reconcile. A CR without it is deleted
		// at once and nothing happens in Vault. VCO's own update refused every
		// mount this way until the charts set config.listingVisibility.
		deletable := map[string]string{"secretenginemounts": "SecretEngineMount",
			"authenginemounts": "AuthEngineMount", "policies": "Policy",
			"kubernetesauthengineroles": "KubernetesAuthEngineRole"}
		waitFor(t, "VCO's finalizer on every CR it deletes", func() string {
			var missing []string
			seen := 0
			for res, kind := range deletable {
				l, err := dyn.Resource(vcoGVR(res)).Namespace(configNS).List(ctx, metav1.ListOptions{})
				if err != nil {
					return err.Error()
				}
				for _, o := range l.Items {
					if tn := o.GetLabels()[tenantLabel]; !slices.Contains(e2eTenants, tn) && o.GetName() != sharedName+"-kv" {
						continue
					}
					seen++
					if !slices.Contains(o.GetFinalizers(), "controller-"+strings.ToLower(kind)) {
						missing = append(missing, res+"/"+o.GetName())
					}
				}
			}
			slices.Sort(missing)
			switch {
			case seen == 0:
				return "no CR of the e2e tenants found"
			case len(missing) > 0:
				return "no VCO finalizer on " + strings.Join(missing, ", ")
			}
			return ""
		})
		// Inspected as root: each tenant has its own kv mount and its own
		// workload auth mount, at its own prefix. No shared auth mount: share
		// roles live on the tenant's own mount (ADR-0007).
		mounts := vaultKeys(t, "secrets", "list", "-format=json")
		auths := vaultKeys(t, "auth", "list", "-format=json")
		if !slices.Contains(mounts, kvMount(sharedName)+"/") {
			t.Errorf("no shared mount %s/: %v", kvMount(sharedName), mounts)
		}
		for _, tn := range e2eTenants {
			if !slices.Contains(mounts, kvMount(tn)+"/") {
				t.Errorf("tenant %s has no %s/ mount: %v", tn, kvMount(tn), mounts)
			}
			if !slices.Contains(auths, k8sAuthMount(tn)+"/") {
				t.Errorf("tenant %s has no %s/ auth mount: %v", tn, k8sAuthMount(tn), auths)
			}
		}
		if slices.Contains(auths, k8sAuthMount(sharedName)+"/") {
			t.Errorf("a shared auth mount %s/ exists: share roles belong on each tenant's mount", k8sAuthMount(sharedName))
		}
		// Each role is on its own tenant's mount, and nowhere else.
		roles := jsonList(t, vaultRoot(t, "list", "-format=json", "auth/"+k8sAuthMount(alpha)+"/role"))
		if slices.Contains(roles, roleName(beta, betaNS, "reader")) {
			t.Errorf("e2e-beta's role is on e2e-alpha's mount: %v", roles)
		}
	})

	step("vco: the tenant mounts stay clean across drift reconciles", func(t *testing.T) {
		// VCO re-reconciles every object each drift period. A mount that fails
		// its SECOND reconcile builds per-object back-off, and a later delete
		// then waits for it. Watching across two periods catches that directly.
		//
		// The hold proves something only while VCO really reconciles in the
		// window: with drift off, or at another period, it passes on nothing.
		venv := deploymentEnv(t, vcoNS, vcoDeploy)
		if want := strconv.Itoa(int(vcoSync.Seconds())); venv["ENABLE_DRIFT_DETECTION"] != "true" || venv["SYNC_PERIOD_SECONDS"] != want {
			t.Fatalf("VCO drift is not on at the period this step waits for: ENABLE_DRIFT_DETECTION=%q SYNC_PERIOD_SECONDS=%q, want \"true\" and %q",
				venv["ENABLE_DRIFT_DETECTION"], venv["SYNC_PERIOD_SECONDS"], want)
		}
		type obj struct{ kind, name string }
		var objs []obj
		for _, tn := range []string{alpha, beta} {
			objs = append(objs, obj{"secretenginemounts", tn + "-kv"}, obj{"authenginemounts", tn + "-kubernetes"})
		}
		// VCO never clears ReconcileFailed, so a failure from before the window
		// (a login race just after install) stays on the object. Only a NEW
		// message fails the hold.
		before := map[obj]string{}
		for _, o := range objs {
			cr := get(t, vcoGVR(o.kind), configNS, o.name)
			if cr == nil {
				t.Fatalf("%s/%s absent", o.kind, o.name)
			}
			_, before[o] = condition(cr, "ReconcileFailed")
			if before[o] != "" {
				t.Logf("%s/%s carries an earlier failure, ignored unless it changes: %s", o.kind, o.name, before[o])
			}
		}
		holdFor(t, 2*vcoSync+15*time.Second, "tenant mount CRs across two drift reconciles", func() string {
			for _, o := range objs {
				cr := get(t, vcoGVR(o.kind), configNS, o.name)
				if cr == nil {
					return o.kind + "/" + o.name + " absent"
				}
				if _, msg := condition(cr, "ReconcileFailed"); msg != before[o] {
					return o.kind + "/" + o.name + " failed a reconcile: " + msg
				}
			}
			return ""
		})
	})

	var webToken string
	step("kv: a workload reads and writes its own secrets", func(t *testing.T) {
		var policies []string
		webToken, policies = vaultLogin(t, alpha, roleName(alpha, alphaNS, "web"), saToken(t, alphaNS, "web"))
		if !slices.Contains(policies, roleName(alpha, alphaNS, "web")) {
			t.Fatalf("login gave policies %v, want %s", policies, roleName(alpha, alphaNS, "web"))
		}
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password=v1"); err != nil {
			t.Fatalf("editor could not write its own secret: %v", err)
		}
		got, err := kvGet(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password")
		if err != nil || got != "v1" {
			t.Fatalf("read own secret: got %q, err %v; want v1", got, err)
		}
		// The token the role hands out: a service token (revocable), with the
		// chart's default ttl of 3600 s at most.
		out, err := vaultRun(t, webToken, "token", "lookup", "-format=json")
		if err != nil {
			t.Fatalf("look up the workload token: %v", err)
		}
		var tok struct {
			Data struct {
				Type string `json:"type"`
				TTL  int    `json:"ttl"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(out), &tok); err != nil || tok.Data.Type != "service" || tok.Data.TTL <= 0 || tok.Data.TTL > 3600 {
			t.Errorf("workload token: type %q, ttl %d s (err %v); want a service token with 0 < ttl <= 3600", tok.Data.Type, tok.Data.TTL, err)
		}
	})

	step("kv: isolation between apps, roles and tenants", func(t *testing.T) {
		// Seeded as root, so a refusal below is about the caller, not a missing secret.
		vaultRoot(t, "kv", "put", "-mount="+kvMount(alpha), appPath(alphaNS, "viewer", "cfg"), "mode=ro")
		vaultRoot(t, "kv", "put", "-mount="+kvMount(beta), appPath(betaNS, "reader", "cfg"), "mode=beta")

		if _, err := kvGet(t, webToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode"); !refused(err) {
			t.Errorf("web read a sibling app's secret in its own namespace; err: %v", err)
		}
		// AC-ISO-2: another tenant's mount, at the path its own app can read.
		if _, err := kvGet(t, webToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); !refused(err) {
			t.Errorf("an e2e-alpha token read e2e-beta's mount; err: %v", err)
		}
		// AC-ISO-5: the beta role works for its own ServiceAccount at its own
		// mount, and refuses alpha's.
		readerToken, pols, err := vaultTryLogin(t, beta, roleName(beta, betaNS, "reader"), saToken(t, betaNS, "reader"))
		if err != nil || !slices.Contains(pols, roleName(beta, betaNS, "reader")) {
			t.Fatalf("e2e-beta's own ServiceAccount could not log in to its role: policies %v, err %v", pols, err)
		}
		if got, err := kvGet(t, readerToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
			t.Errorf("e2e-beta's reader could not read its own secret (the allow for the refusal above): got %q, err %v", got, err)
		}
		if _, _, err := vaultTryLogin(t, beta, roleName(beta, betaNS, "reader"), saToken(t, alphaNS, "web")); !refused(err) {
			t.Errorf("e2e-alpha's ServiceAccount was not refused by an e2e-beta role; err: %v", err)
		}
		// The refusal above changes both the name and the namespace, so it fails
		// only if BOTH bindings are dropped. These change one each; web's own
		// login to the same role is the matching allow.
		webRole := roleName(alpha, alphaNS, "web")
		if _, _, err := vaultTryLogin(t, alpha, webRole, saToken(t, alphaNS, "viewer")); !refused(err) {
			t.Errorf("another ServiceAccount in web's namespace was not refused by web's role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, alpha, webRole, saToken(t, toolsNS, "web")); !refused(err) {
			t.Errorf("a ServiceAccount named web in another namespace was not refused by web's role; err: %v", err)
		}

		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if got, err := kvGet(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode"); err != nil || got != "ro" {
			t.Errorf("viewer could not read its own secret: got %q, err %v", got, err)
		}
		if err := kvPut(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode=rw"); !refused(err) {
			t.Errorf("viewer role wrote a secret; err: %v", err)
		}
	})

	step("kv: a prefix tenant can't reach its longer neighbour", func(t *testing.T) {
		// AC-ISO-3. Tenant e2e is a string prefix of e2e-alpha and e2e-beta. Its
		// admin writes its own mount (the allow) and is refused on theirs, where
		// the same paths exist and their own apps read them.
		coreToken, _ := vaultLogin(t, prefixT, roleName(prefixT, coreNS, "core"), saToken(t, coreNS, "core"))
		if err := kvPut(t, coreToken, prefixT, appPath(coreNS, "core", "x"), "v=1"); err != nil {
			t.Fatalf("the prefix tenant's admin could not write its own mount: %v", err)
		}
		if _, err := kvGet(t, coreToken, alpha, appPath(alphaNS, "web", "db"), "password"); !refused(err) {
			t.Errorf("tenant e2e read e2e-alpha's secret; err: %v", err)
		}
		if err := kvPut(t, coreToken, alpha, appPath(alphaNS, "web", "db"), "password=stolen"); !refused(err) {
			t.Errorf("tenant e2e wrote e2e-alpha's secret; err: %v", err)
		}
		if _, err := kvGet(t, coreToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); !refused(err) {
			t.Errorf("tenant e2e read e2e-beta's secret; err: %v", err)
		}
	})

	step("kv: versions, patch and deletes follow the role", func(t *testing.T) {
		// KV v2 keeps every version of a secret. What each role may do with them:
		//   editor  write, read an old version, patch; no soft delete
		//   viewer  read; no patch
		//   admin   soft delete, then undelete
		p := appPath(alphaNS, "web", "versions")
		for _, v := range []string{"v=1", "v=2"} {
			if err := kvPut(t, webToken, alpha, p, v); err != nil {
				t.Fatalf("editor could not write %s: %v", v, err)
			}
		}
		if got, err := kv(t, webToken, alpha, "get", "-version=1", "-field=v", p); err != nil || strings.TrimSpace(got) != "1" {
			t.Errorf("editor could not read version 1: got %q, err %v", got, err)
		}
		// patch changes one field and keeps the others, in one request.
		if _, err := kv(t, webToken, alpha, "patch", p, "extra=x"); err != nil {
			t.Fatalf("editor could not patch its own secret: %v", err)
		}
		if got, err := kvGet(t, webToken, alpha, p, "v"); err != nil || got != "2" {
			t.Errorf("patch lost a field: v=%q, err %v", got, err)
		}
		// A soft delete needs the delete capability, which only admin has. The
		// admin's own delete below is the matching allow for the same call.
		if _, err := kv(t, webToken, alpha, "delete", p); !refused(err) {
			t.Errorf("editor soft-deleted a secret; err: %v", err)
		}
		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if _, err := kv(t, viewerToken, alpha, "patch", appPath(alphaNS, "viewer", "cfg"), "mode=patched"); !refused(err) {
			t.Errorf("viewer patched a secret; err: %v", err)
		}

		adminToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "admin"), saToken(t, alphaNS, "admin"))
		ap := appPath(alphaNS, "admin", "soft")
		if err := kvPut(t, adminToken, alpha, ap, "v=1"); err != nil {
			t.Fatalf("admin could not write: %v", err)
		}
		if _, err := kv(t, adminToken, alpha, "delete", ap); err != nil {
			t.Fatalf("admin could not soft-delete its own secret: %v", err)
		}
		if got, err := kvGet(t, adminToken, alpha, ap, "v"); err == nil && got == "1" {
			t.Errorf("a soft-deleted secret still reads %q", got)
		}
		if _, err := kv(t, adminToken, alpha, "undelete", "-versions=1", ap); err != nil {
			t.Fatalf("admin could not undelete: %v", err)
		}
		if got, err := kvGet(t, adminToken, alpha, ap, "v"); err != nil || got != "1" {
			t.Errorf("the undeleted secret reads %q, err %v; want 1", got, err)
		}
	})

	step("kv: an app sees only its own prefix, not the other apps of its namespace", func(t *testing.T) {
		// viewer/cfg exists (seeded as root above), so a refusal is about the caller.
		out, err := kv(t, webToken, alpha, "list", "-format=json", env+"/"+alphaNS+"/web/")
		if err != nil || !strings.Contains(out, "db") {
			t.Fatalf("web could not list its own prefix: %q, err %v", out, err)
		}
		// Listing the namespace level would name every other app in it.
		if _, err := kv(t, webToken, alpha, "list", env+"/"+alphaNS+"/"); !refused(err) {
			t.Errorf("web listed the apps of its namespace; err: %v", err)
		}
		if _, err := kv(t, webToken, alpha, "metadata", "get", appPath(alphaNS, "viewer", "cfg")); !refused(err) {
			t.Errorf("web read another app's secret metadata; err: %v", err)
		}
	})

	step("vco: an out-of-band change in Vault is reverted", func(t *testing.T) {
		// Root plays an out-of-band admin who widens the viewer's policy in Vault.
		// It asserts nothing; every check runs as the viewer.
		role := roleName(alpha, alphaNS, "viewer")
		p := appPath(alphaNS, "viewer", "cfg")
		widened := policyRules(t, role) + "\npath \"" + kvMount(alpha) + "/data/" + env + "/" + alphaNS + "/viewer/*\" { capabilities = [\"create\", \"update\"] }\n"
		viewerToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "viewer"))
		// The change took effect: without it, the revert below would prove
		// nothing. VCO's drift reconcile can revert the widening between the
		// write and the check (every sync period), so the widening is applied
		// again until one write lands.
		waitFor(t, "the widened policy takes effect", func() string {
			vaultRoot(t, "write", "sys/policy/"+role, "policy="+widened)
			if err := kvPut(t, viewerToken, alpha, p, "mode=tampered"); err != nil {
				return err.Error()
			}
			return ""
		})
		// VCO's drift detection rewrites the policy from its CR within a sync period.
		waitFor(t, "VCO reverts the widened policy", func() string {
			err := kvPut(t, viewerToken, alpha, p, "mode=still-writable")
			switch {
			case err == nil:
				return "the viewer can still write"
			case !refused(err):
				return err.Error()
			}
			return ""
		})
		vaultRoot(t, "kv", "put", "-mount="+kvMount(alpha), p, "mode=ro")
	})

	step("vco: a role cannot move to another tenant's mount", func(t *testing.T) {
		// Two layers refuse to put web's role on e2e-beta's auth mount: the
		// scope admission policy (a role lives on its own tenant's mount), and
		// VCO's webhook, which refuses any change of spec.path because the
		// object would stay behind at the old path (V11). The admission policy
		// answers first when it is installed.
		name := roleName(alpha, alphaNS, "web")
		move := []byte(`{"spec":{"path":"` + k8sAuthMount(beta) + `"}}`)
		_, err := dyn.Resource(vcoGVR("kubernetesauthengineroles")).Namespace(configNS).Patch(ctx, name, types.MergePatchType, move, metav1.PatchOptions{})
		switch {
		case err == nil:
			t.Errorf("web's role moved to e2e-beta's mount")
		case strings.Contains(err.Error(), "vco-scope"):
			t.Logf("refused by the scope admission policy")
		case strings.Contains(err.Error(), "cannot be updated"):
			t.Logf("refused by VCO's webhook")
		default:
			t.Errorf("moving a role to another tenant's mount was refused for an unexpected reason: %v", err)
		}
		// The matching allow: an update that keeps the path passes the same webhook.
		keep := []byte(`{"metadata":{"annotations":{"e2e.stakater.com/touched":"true"}}}`)
		if _, err := dyn.Resource(vcoGVR("kubernetesauthengineroles")).Namespace(configNS).Patch(ctx, name, types.MergePatchType, keep, metav1.PatchOptions{}); err != nil {
			t.Errorf("an update that keeps the path was refused: %v", err)
		}
	})

	step("roles: admin can destroy versions, audit-read can only list", func(t *testing.T) {
		adminToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "admin"), saToken(t, alphaNS, "admin"))
		p := appPath(alphaNS, "admin", "key")
		if err := kvPut(t, adminToken, alpha, p, "v=1"); err != nil {
			t.Fatalf("admin could not write: %v", err)
		}
		if _, err := kv(t, adminToken, alpha, "destroy", "-versions=1", p); err != nil {
			t.Errorf("admin could not destroy a version of its own secret: %v", err)
		}
		// An editor cannot destroy history.
		if _, err := kv(t, webToken, alpha, "destroy", "-versions=1", appPath(alphaNS, "web", "db")); !refused(err) {
			t.Errorf("editor destroyed a secret version; err: %v", err)
		}

		vaultRoot(t, "kv", "put", "-mount="+kvMount(alpha), appPath(alphaNS, "auditor", "item"), "v=1")
		auditToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "auditor"), saToken(t, alphaNS, "auditor"))
		out, err := kv(t, auditToken, alpha, "list", "-format=json", env+"/"+alphaNS+"/auditor/")
		if err != nil || !strings.Contains(out, "item") {
			t.Errorf("audit-read could not list its own prefix: %q, err %v", out, err)
		}
		if _, err := kvGet(t, auditToken, alpha, appPath(alphaNS, "auditor", "item"), "v"); !refused(err) {
			t.Errorf("audit-read read secret data; err: %v", err)
		}
	})

	step("sso: Keycloak users log in through Dex with their group's role", func(t *testing.T) {
		// Keycloak holds the users and groups, Dex fronts it through Keycloak's
		// "dex" client, and each tenant's auth/<tenant>/oidc/sso roles bind one
		// group each (<tenant>-<role>s). The test users (make lab-keycloak):
		//   alice e2e-alpha-editors   bob e2e-alpha-viewers   carol e2e-beta-admins
		for _, tn := range []string{alpha, beta} {
			waitVCO(t, "authenginemounts", tn+"-oidc")
			waitVCO(t, "jwtoidcauthengineconfigs", tn+"-oidc-config")
			for _, role := range []string{"admin", "editor", "viewer", "audit-read"} {
				waitVCO(t, "jwtoidcauthengineroles", ssoRole(tn, role))
			}
		}
		c := newSSOClient(t)
		note := env + "/sso/note"

		// The group gives the role: alice's editor login writes.
		aliceToken, pols, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice"))
		if err != nil || !slices.Contains(pols, ssoRole(alpha, "editor")) {
			t.Fatalf("alice (e2e-alpha-editors) could not log in as editor: policies %v, err %v", pols, err)
		}
		if err := kvPut(t, aliceToken, alpha, note, "by=alice"); err != nil {
			t.Fatalf("the SSO editor could not write in its tenant: %v", err)
		}
		// bob's viewer login reads what alice wrote, and cannot write it:
		// alice's write above, same path, is the matching allow.
		bobToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "viewer"), "bob", testUserPassword(t, "bob"))
		if err != nil {
			t.Fatalf("bob (e2e-alpha-viewers) could not log in as viewer: %v", err)
		}
		if got, err := kvGet(t, bobToken, alpha, note, "by"); err != nil || got != "alice" {
			t.Errorf("the SSO viewer could not read in its tenant: got %q, err %v", got, err)
		}
		if err := kvPut(t, bobToken, alpha, note, "by=bob"); !refused(err) {
			t.Errorf("the SSO viewer wrote a secret; err: %v", err)
		}
		// A group gives only its own role: bob cannot take the editor role.
		if _, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "bob", testUserPassword(t, "bob")); !claimRefused(err) {
			t.Errorf("bob (e2e-alpha-viewers) was not refused the editor role for the group; err: %v", err)
		}

		// AC-ISO-6. Tenants: carol (e2e-beta-admins) logs in at e2e-beta's mount,
		// and alice cannot.
		carolToken, _, err := oidcLogin(t, c, beta, ssoRole(beta, "admin"), "carol", testUserPassword(t, "carol"))
		if err != nil {
			t.Fatalf("carol (e2e-beta-admins) could not log in to e2e-beta: %v", err)
		}
		if _, _, err := oidcLogin(t, c, beta, ssoRole(beta, "editor"), "alice", testUserPassword(t, "alice")); !claimRefused(err) {
			t.Errorf("alice (e2e-alpha-editors) was not refused an e2e-beta role for the group; err: %v", err)
		}
		// And alice's e2e-alpha token does not reach e2e-beta's mount, which carol reads.
		if err := kvPut(t, carolToken, beta, note, "by=carol"); err != nil {
			t.Fatalf("the SSO admin could not write in its tenant: %v", err)
		}
		if _, err := kvGet(t, aliceToken, beta, note, "by"); !refused(err) {
			t.Errorf("an e2e-alpha SSO token read e2e-beta's secret; err: %v", err)
		}
	})

	step("sso: audit-read lists and reads nothing, only admin destroys history", func(t *testing.T) {
		// dave (e2e-alpha-audit-reads) and erin (e2e-alpha-admins), on the note
		// alice wrote in the step above.
		c := newSSOClient(t)
		note := env + "/sso/note"
		daveToken, pols, err := oidcLogin(t, c, alpha, ssoRole(alpha, "audit-read"), "dave", testUserPassword(t, "dave"))
		if err != nil || !slices.Contains(pols, ssoRole(alpha, "audit-read")) {
			t.Fatalf("dave (e2e-alpha-audit-reads) could not log in as audit-read: policies %v, err %v", pols, err)
		}
		out, err := kv(t, daveToken, alpha, "list", "-format=json", env+"/sso/")
		if err != nil || !strings.Contains(out, "note") {
			t.Errorf("audit-read could not list the tenant's secrets: %q, err %v", out, err)
		}
		erinToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "admin"), "erin", testUserPassword(t, "erin"))
		if err != nil {
			t.Fatalf("erin (e2e-alpha-admins) could not log in as admin: %v", err)
		}
		// erin's read is the matching allow for dave's refusal.
		if got, err := kvGet(t, erinToken, alpha, note, "by"); err != nil || got != "alice" {
			t.Fatalf("the SSO admin could not read the note: got %q, err %v", got, err)
		}
		if _, err := kvGet(t, daveToken, alpha, note, "by"); !refused(err) {
			t.Errorf("audit-read read secret data; err: %v", err)
		}
		// Destroying a version: the editor is refused, then the admin does it.
		aliceToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice"))
		if err != nil {
			t.Fatalf("alice could not log in again: %v", err)
		}
		if _, err := kv(t, aliceToken, alpha, "destroy", "-versions=1", note); !refused(err) {
			t.Errorf("the SSO editor destroyed a version; err: %v", err)
		}
		if _, err := kv(t, erinToken, alpha, "destroy", "-versions=1", note); err != nil {
			t.Errorf("the SSO admin could not destroy a version: %v", err)
		}
		// AC-ISO-9: the admin role administers secrets, never Vault. Every call
		// below is one VCO's own policy makes; the admin's destroy above is the
		// allow in the same tenant.
		for _, c := range []struct {
			what string
			args []string
		}{
			{"write a policy", []string{"write", "sys/policy/" + roleName(alpha, alphaNS, "erin"), `policy=path "` + kvMount(alpha) + `/*" { capabilities = ["read"] }`}},
			{"rewrite its own SSO policy", []string{"write", "sys/policy/" + ssoRole(alpha, "admin"), `policy=path "*" { capabilities = ["sudo"] }`}},
			{"mount a secrets engine", []string{"secrets", "enable", "-path=" + alpha + "/kv2", "kv"}},
			{"tune its tenant's mount", []string{"write", kvMount(alpha) + "/config", "max_versions=1"}},
			{"write a workload role", []string{"write", "auth/" + k8sAuthMount(alpha) + "/role/" + roleName(alpha, alphaNS, "erin"), "bound_service_account_names=*", "bound_service_account_namespaces=*"}},
			{"write an SSO role", []string{"write", "auth/" + ssoMount(alpha) + "/role/" + ssoRole(alpha, "erin"), "user_claim=sub"}},
			{"read the identity store", []string{"list", "identity/entity/id"}},
		} {
			if _, err := vaultRun(t, erinToken, c.args...); !refused(err) {
				t.Errorf("the SSO admin could %s; err: %v", c.what, err)
			}
		}
	})

	step("sso: a person removed from the group can't log in again", func(t *testing.T) {
		// AC-ACC-6. Removed from e2e-alpha-editors in Keycloak, alice's next
		// editor login is refused for the group; added back, it works again.
		// A token issued before stays valid to its TTL (design §7), so only new
		// logins are checked.
		c := newSSOClient(t)
		keycloakGroup(t, "remove", "alice", "e2e-alpha-editors")
		t.Cleanup(func() { keycloakGroup(t, "add", "alice", "e2e-alpha-editors") })
		// alice was in that one group only, so her new ID token has no groups
		// claim at all: groupRefused accepts that reason as well.
		if _, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice")); !groupRefused(err) {
			t.Errorf("alice, removed from e2e-alpha-editors, was not refused the editor role; err: %v", err)
		}
		keycloakGroup(t, "add", "alice", "e2e-alpha-editors")
		if _, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice")); err != nil {
			t.Errorf("alice, added back to e2e-alpha-editors, could not log in (the matching allow): %v", err)
		}
	})

	step("vco: the production policy can't widen VCO or delete data", func(t *testing.T) {
		// AC-ISO-7, AC-LIFE-4. The production policy (charts/examples), loaded
		// under a check name, in a token that holds only it. Each refusal has
		// its allow: the same kind of call inside the policy's bounds.
		raw, err := os.ReadFile("../../charts/examples/vco-admin-policy.hcl")
		if err != nil {
			t.Fatal(err)
		}
		const pol, scratch = "e2e-vco-production", "e2e-vco"
		vaultRoot(t, "write", "sys/policy/"+pol, "policy="+string(raw))
		t.Cleanup(func() {
			// Vault answers success for a mount or policy that is already
			// gone, so any error here is real: left behind, it would make the
			// next run's checks pass on this run's state.
			for _, args := range [][]string{
				{"secrets", "disable", kvMount(scratch)},
				{"auth", "disable", k8sAuthMount(scratch)},
				{"delete", "sys/policy/kv." + scratch + ".ns.sa"},
				{"delete", "sys/policy/" + pol},
			} {
				if _, err := vaultRun(t, vaultRootToken, args...); err != nil {
					t.Errorf("cleanup: vault %s: %v", strings.Join(args, " "), err)
				}
			}
		})
		tok := strings.TrimSpace(vaultRoot(t, "token", "create", "-policy="+pol, "-no-default-policy", "-ttl=10m", "-field=token"))
		inScope := `path "` + kvMount(scratch) + `/data/dev/ns/sa/*" { capabilities = ["read"] }`
		cases := []struct {
			what  string
			allow bool
			args  []string
		}{
			{"write a kv.* policy", true, []string{"write", "sys/policy/kv." + scratch + ".ns.sa", "policy=" + inScope}},
			{"rewrite its own policy", false, []string{"write", "sys/policy/vco-admin", "policy=" + inScope}},
			{"rewrite the default policy", false, []string{"write", "sys/policy/default", "policy=" + inScope}},
			{"write a policy outside the families", false, []string{"write", "sys/policy/platform-x", "policy=" + inScope}},
			{"mount a transit engine at a tenant's kv place", false, []string{"secrets", "enable", "-path=" + kvMount(scratch), "transit"}},
			{"mount a kv engine at a tenant's kv place", true, []string{"secrets", "enable", "-path=" + kvMount(scratch), "-version=2", "kv"}},
			{"disable a tenant's kv mount", false, []string{"secrets", "disable", kvMount(scratch)}},
			{"mount userpass at a tenant's workload auth place", false, []string{"auth", "enable", "-path=" + k8sAuthMount(scratch), "userpass"}},
			{"mount kubernetes at a tenant's workload auth place", true, []string{"auth", "enable", "-path=" + k8sAuthMount(scratch), "kubernetes"}},
			{"write a role on its own login mount", false, []string{"write", "auth/" + vcoLoginMount + "/role/kv." + scratch + ".ns.sa", "bound_service_account_names=sa", "bound_service_account_namespaces=ns", "policies=kv." + scratch + ".ns.sa"}},
			{"rewrite its own login role", false, []string{"write", "auth/" + vcoLoginMount + "/role/" + vcoLogin, "bound_service_account_names=*", "bound_service_account_namespaces=*"}},
			{"disable a tenant's workload auth mount", true, []string{"auth", "disable", k8sAuthMount(scratch)}},
		}
		for _, c := range cases {
			_, err := vaultRun(t, tok, c.args...)
			switch {
			case c.allow && err != nil:
				t.Errorf("the production policy refused VCO to %s (the matching allow): %v", c.what, err)
			case !c.allow && !refused(err):
				t.Errorf("the production policy let VCO %s; err: %v", c.what, err)
			}
		}
	})

	step("admission: out-of-scope VCO CRs are refused at the API server", func(t *testing.T) {
		// AC-ISO-11. The same cases make admission-test runs: server-side dry
		// runs in the config namespace, each refusal by the one rule it names.
		// An update case creates its old object for real (and VCO deletes it
		// in Vault afterwards), so the run is longer than one command.
		cctx, cancel := context.WithTimeout(context.Background(), 4*cmdTimeout)
		defer cancel()
		cmd := exec.CommandContext(cctx, "bash", "../../hack/lab/admission-cases.sh")
		// The origin cases write as Template Operator: the identity the
		// install's templateOperator.* names (the chart's default unless
		// E2E_TOV2_SA overrides it, helmInstall).
		tovUser := tov2SA
		if tovUser == "" {
			tovUser = "system:serviceaccount:stakater-template-operator:template-operator-template-operator-v2"
		}
		cmd.Env = append(os.Environ(), "CONTEXT="+kubeContext, "CONFIG_NS="+configNS, "KUBECTL="+kubectlBin(),
			"ISSUER="+dexIssuer, "TOV_USER="+tovUser)
		raw, err := cmd.CombinedOutput()
		out := string(raw)
		if err != nil {
			t.Fatalf("admission cases: %v\n%s", err, out)
		}
		// The split is pinned: a case that silently became offline only (or
		// a live one lost) changes the result line, and each offline-only
		// case is named. hack/admission-offline.sh pins the total.
		offline := len(admissionOfflineCases)
		want := fmt.Sprintf("== result: %d cases, 0 failed, %d offline only", admissionCases, offline)
		if !strings.Contains(out, want) || strings.Contains(out, "FAIL ") {
			t.Fatalf("admission cases: want %q\n%s", want, out)
		}
		if got := strings.Count(out, "PASS "); got != admissionCases-offline {
			t.Fatalf("admission cases: %d passed live, want %d\n%s", got, admissionCases-offline, out)
		}
		var skipped []string
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, "SKIP  offline only (") {
				skipped = append(skipped, l[strings.Index(l, "): ")+3:])
			}
		}
		slices.Sort(skipped)
		wantSkipped := slices.Clone(admissionOfflineCases)
		slices.Sort(wantSkipped)
		if !slices.Equal(skipped, wantSkipped) {
			t.Fatalf("admission cases: offline only %q, want %q\n%s", skipped, wantSkipped, out)
		}
		t.Logf("%d admission cases passed live, %d offline only", admissionCases-offline, offline)
	})

	step("admission: a tenant's Template can't make Template Operator write into the config namespace", func(t *testing.T) {
		// AC-ISO-12 (T2, Q18b). A Template's targetNamespaces gates where its
		// TemplateInstance lives, not where the objects it renders go, and
		// Template Operator applies them with its own rights — which include
		// writing VCO CRs in the config namespace. The origin policy refuses a
		// VCO CR whose TemplateInstance is anywhere else. The matching allow is
		// every Policy the extension's own TemplateInstances rendered above.
		deputy := roleName(alpha, alphaNS, "deputy")
		manifest := fmt.Sprintf(`apiVersion: templates.v2.stakater.com/v2alpha1
kind: Template
metadata: { name: deputy, namespace: %[1]s }
spec:
  targetNamespaces: { explicit: { allow: { literal: [%[1]s] } } }
  gotemplate: |
    apiVersion: redhatcop.redhat.io/v1alpha1
    kind: Policy
    metadata: { name: %[2]s, namespace: %[3]s }
    spec:
      authentication: { path: kubernetes, role: vco-admin, serviceAccount: { name: vco-admin } }
      name: %[2]s
      policy: |
        path "%[4]s/data/dev/%[1]s/deputy/*" { capabilities = ["read"] }
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata: { name: deputy, namespace: %[1]s }
spec:
  templateRef: { name: deputy, namespace: %[1]s }
`, alphaNS, deputy, configNS, kvMount(alpha))
		applyManifest(t, manifest)
		t.Cleanup(func() {
			run(t, kubectlBin(), "--context", kubeContext, "-n", alphaNS, "delete", "templateinstances.templates.v2.stakater.com", "deputy", "--ignore-not-found", "--wait=true")
			run(t, kubectlBin(), "--context", kubeContext, "-n", alphaNS, "delete", "templates.templates.v2.stakater.com", "deputy", "--ignore-not-found")
		})
		waitFor(t, "the deputy TemplateInstance reports the admission refusal", func() string {
			o := get(t, gvrTemplateInstance, alphaNS, "deputy")
			if o == nil {
				return "absent"
			}
			if _, msg := condition(o, "Applied"); !strings.Contains(msg, "vco-origin") {
				return "Applied: " + msg
			}
			return ""
		})
		holdFor(t, 10*time.Second, "no Policy written for the tenant Template", func() string {
			if get(t, vcoGVR("policies"), configNS, deputy) != nil {
				return "Policy " + deputy + " exists in " + configNS
			}
			return ""
		})
	})

	step("configmap: vault-config-<sa> describes a working login", func(t *testing.T) {
		cm := configMapData(t, alphaNS, "vault-config-web")
		if cm == nil {
			t.Fatal("ConfigMap vault-config-web is missing")
		}
		want := map[string]string{
			"VAULT_ADDR":        vaultServer,
			"VAULT_NAMESPACE":   "",
			"VAULT_K8S_MOUNT":   k8sAuthMount(alpha),
			"VAULT_K8S_ROLE":    roleName(alpha, alphaNS, "web"),
			"VAULT_KV_APP_PATH": kvMount(alpha) + "/data/" + env + "/" + alphaNS + "/web/",
		}
		for k, v := range want {
			if got, ok := cm[k]; !ok || got != v {
				t.Errorf("%s = %q (present %v), want %q", k, got, ok, v)
			}
		}
		// The values themselves must work: log in with exactly what the
		// ConfigMap says, and read the app's secret at the path it names.
		token, _, err := vaultTryLoginAt(t, cm["VAULT_K8S_MOUNT"], cm["VAULT_K8S_ROLE"], saToken(t, alphaNS, "web"))
		if err != nil {
			t.Fatalf("login with the ConfigMap's values failed: %v", err)
		}
		out, err := vaultRun(t, token, "read", "-format=json", cm["VAULT_KV_APP_PATH"]+"db")
		if err != nil || !strings.Contains(out, "password") {
			t.Errorf("read at the ConfigMap's path %sdb: %q, err %v", cm["VAULT_KV_APP_PATH"], out, err)
		}
		if idx := configMapData(t, alphaNS, "vault-apps"); !strings.Contains(idx["web"], want["VAULT_KV_APP_PATH"]) {
			t.Errorf("vault-apps index has no entry for web with its path: %q", idx["web"])
		}
	})

	step("template-operator: a deleted ConfigMap comes back", func(t *testing.T) {
		// sync.mode=revert (the bootstrap default): template-operator-v2 puts back
		// what it rendered. Deleting the workload's environment is that kind of drift.
		before := configMapData(t, alphaNS, "vault-config-web")
		if before == nil {
			t.Fatal("ConfigMap vault-config-web is missing")
		}
		if err := kube.CoreV1().ConfigMaps(alphaNS).Delete(ctx, "vault-config-web", metav1.DeleteOptions{}); err != nil {
			t.Fatalf("delete ConfigMap vault-config-web: %v", err)
		}
		waitFor(t, "template-operator-v2 restores vault-config-web", func() string {
			got := configMapData(t, alphaNS, "vault-config-web")
			if got == nil {
				return "absent"
			}
			if got["VAULT_K8S_ROLE"] != before["VAULT_K8S_ROLE"] || got["VAULT_KV_APP_PATH"] != before["VAULT_KV_APP_PATH"] {
				return fmt.Sprintf("restored with other values: %v", got)
			}
			return ""
		})
	})

	step("eso: a Deployment gets its secret from Vault", func(t *testing.T) {
		// AC-DEL-1. The SecretStore reads the tenant's mount e2e-alpha/kv as web,
		// and the ExternalSecret's key is relative to it.
		createDeployment(t, alphaNS, "web", "web", map[string]string{
			annPrefix + "kv-secret.db": "db#password",
			// Reloader restarts the Deployment when this Secret changes (C.10).
			"secret.reloader.stakater.com/reload": "web-db",
		}, []corev1.EnvVar{secretEnv("PASSWORD", "web-db", "password")})
		waitFor(t, "ExternalSecret web-db synced", func() string {
			if v := secretValue(t, alphaNS, "web-db", "password"); v != "v1" {
				o := get(t, gvrExternalSecret, alphaNS, "web-db")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret password=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
		waitFor(t, "the web pod sees PASSWORD=v1", func() string {
			p := runningPod(t, alphaNS, "web")
			if p == "" {
				return "no single ready pod"
			}
			if v, err := podEnv(t, alphaNS, p, "PASSWORD"); err != nil {
				return err.Error()
			} else if v != "v1" {
				return "PASSWORD=" + v
			}
			return ""
		})
	})

	step("reloader: a rotated secret reaches a new pod", func(t *testing.T) {
		// AC-DEL-2.
		before := runningPod(t, alphaNS, "web")
		if before == "" {
			t.Fatal("no running web pod to compare against")
		}
		// Rotated as the WORKLOAD, through its own grant.
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password=v2"); err != nil {
			t.Fatalf("rotate: %v", err)
		}
		waitFor(t, "ESO refreshes Secret web-db to v2", func() string {
			if v := secretValue(t, alphaNS, "web-db", "password"); v != "v2" {
				return "password=" + v
			}
			return ""
		})
		// An env var is read once at container start, so only a NEW pod can see
		// v2: seeing it proves Reloader rolled the Deployment.
		waitFor(t, "Reloader rolls web and the new pod sees PASSWORD=v2", func() string {
			p := runningPod(t, alphaNS, "web")
			if p == "" || p == before {
				return "pod not replaced yet (current: " + p + ")"
			}
			if v, err := podEnv(t, alphaNS, p, "PASSWORD"); err != nil {
				return err.Error()
			} else if v != "v2" {
				return "new pod " + p + " has PASSWORD=" + v
			}
			return ""
		})
	})

	step("eso: a whole secret becomes one Kubernetes Secret", func(t *testing.T) {
		// kv-secret.<name>: <leaf> with no #key copies every key of the leaf.
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "cfg"), "host=db.internal", "port=5432"); err != nil {
			t.Fatalf("editor could not write the leaf: %v", err)
		}
		createDeployment(t, alphaNS, "cfg-reader", "web", map[string]string{annPrefix + "kv-secret.cfg": "cfg"}, nil)
		waitFor(t, "Secret web-cfg holds every key of the leaf", func() string {
			host, port := secretValue(t, alphaNS, "web-cfg", "host"), secretValue(t, alphaNS, "web-cfg", "port")
			if host != "db.internal" || port != "5432" {
				return fmt.Sprintf("host=%q port=%q", host, port)
			}
			return ""
		})
		deleteDeployment(t, alphaNS, "cfg-reader")
	})

	step("intra-tenant: apps in one namespace share through _shared/", func(t *testing.T) {
		// AC-SHR-1. web (editor) writes its namespace's shared area; viewer, in
		// the same namespace, reads it without any annotation — and cannot write it.
		if err := kvPut(t, webToken, alpha, sharedPath(alphaNS, "common"), "url=https://db.internal"); err != nil {
			t.Fatalf("editor could not write its namespace's _shared/: %v", err)
		}
		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if got, err := kvGet(t, viewerToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Fatalf("an app in the same namespace could not read _shared/: got %q, err %v", got, err)
		}
		if err := kvPut(t, viewerToken, alpha, sharedPath(alphaNS, "common"), "url=tampered"); !refused(err) {
			t.Errorf("viewer role wrote to _shared/; err: %v", err)
		}
	})

	step("intra-tenant: another namespace subscribes with kv-subscribe-ns", func(t *testing.T) {
		// AC-SHR-2.
		subToken, _ := vaultLogin(t, alpha, roleName(alpha, toolsNS, "sub"), saToken(t, toolsNS, "sub"))
		if got, err := kvGet(t, subToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Fatalf("subscriber could not read the producer's _shared/: got %q, err %v", got, err)
		}
		// A subscription is read-only on the producer's prefix, on the metadata
		// path too: KV v2 metadata update sets max_versions, which destroys
		// versions. sub is an editor, and its role grants that update on its own
		// prefixes, so the refusal fails if the subscription grant is widened to
		// the role's caps. The producer's update on the same path shows the call
		// itself works.
		if err := kvPut(t, subToken, alpha, sharedPath(alphaNS, "common"), "url=tampered"); !refused(err) {
			t.Errorf("subscriber wrote to the producer's _shared/; err: %v", err)
		}
		if err := kvMetadataPut(t, webToken, alpha, sharedPath(alphaNS, "common"), "-max-versions=5"); err != nil {
			t.Fatalf("the producer could not update its own _shared/ metadata: %v", err)
		}
		if err := kvMetadataPut(t, subToken, alpha, sharedPath(alphaNS, "common"), "-max-versions=1"); !refused(err) {
			t.Errorf("subscriber updated the producer's secret metadata; err: %v", err)
		}
		// Same tenant, no annotation: no grant. An editor role does not help.
		nosubToken, _ := vaultLogin(t, alpha, roleName(alpha, toolsNS, "nosub"), saToken(t, toolsNS, "nosub"))
		if _, err := kvGet(t, nosubToken, alpha, sharedPath(alphaNS, "common"), "url"); !refused(err) {
			t.Errorf("an unsubscribed app read another namespace's _shared/; err: %v", err)
		}
		// The value survived every refused write above.
		if got, err := kvGet(t, webToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Errorf("_shared/ value changed: got %q, err %v", got, err)
		}

		createDeployment(t, toolsNS, "sub", "sub", map[string]string{
			annPrefix + "kv-subscribe.common": alphaNS + "/common#url",
		}, []corev1.EnvVar{secretEnv("DB_URL", "sub-common", "url")})
		waitFor(t, "ExternalSecret sub-common synced", func() string {
			if v := secretValue(t, toolsNS, "sub-common", "url"); v != "https://db.internal" {
				o := get(t, gvrExternalSecret, toolsNS, "sub-common")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret url=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
		waitFor(t, "the sub pod sees DB_URL", func() string {
			p := runningPod(t, toolsNS, "sub")
			if p == "" {
				return "no single ready pod"
			}
			if v, err := podEnv(t, toolsNS, p, "DB_URL"); err != nil {
				return err.Error()
			} else if v != "https://db.internal" {
				return "DB_URL=" + v
			}
			return ""
		})
	})

	step("share: e2e-alpha exports, e2e-beta imports through ESO", func(t *testing.T) {
		// AC-SHR-3. The share lives in shared/kv, in neither tenant's mount; each
		// share role lives on its OWN tenant's auth mount (ADR-0007), so a share
		// login uses the VAULT_K8S_MOUNT the app already has.
		outRole := "share." + alpha + "." + alphaNS + ".web.out." + beta
		inRole := "share." + beta + "." + betaNS + ".reader.in." + alpha
		sharePath := env + "/from-" + alpha + "/to-" + beta + "/handoff"
		waitVCO(t, "kubernetesauthengineroles", outRole)
		waitVCO(t, "kubernetesauthengineroles", inRole)

		cm := configMapData(t, alphaNS, "vault-config-web")
		peer := strings.ToUpper(strings.ReplaceAll(beta, "-", "_"))
		if cm["VAULT_OUT_"+peer+"_ROLE"] != outRole || cm["VAULT_OUT_"+peer+"_NAMESPACE"] != "" ||
			cm["VAULT_OUT_"+peer+"_PATH"] != kvMount(sharedName)+"/data/"+env+"/from-"+alpha+"/to-"+beta+"/" {
			t.Fatalf("web's ConfigMap does not describe its share: %v", cm)
		}
		// Logged in exactly as the ConfigMap says: VAULT_K8S_MOUNT, the share role.
		outToken, _, err := vaultTryLoginAt(t, cm["VAULT_K8S_MOUNT"], cm["VAULT_OUT_"+peer+"_ROLE"], saToken(t, alphaNS, "web"))
		if err != nil {
			t.Fatalf("web could not log in with its share role at VAULT_K8S_MOUNT: %v", err)
		}
		if err := kvPut(t, outToken, sharedName, sharePath, "token=t1"); err != nil {
			t.Fatalf("exporter could not write the share: %v", err)
		}
		inToken, _ := vaultLogin(t, beta, inRole, saToken(t, betaNS, "reader"))
		if got, err := kvGet(t, inToken, sharedName, sharePath, "token"); err != nil || got != "t1" {
			t.Fatalf("importer read the share: got %q, err %v", got, err)
		}
		if err := kvPut(t, inToken, sharedName, sharePath, "token=tampered"); !refused(err) {
			t.Errorf("importer wrote to a share it may only read; err: %v", err)
		}
		// A share role binds one tenant's ServiceAccount: the other tenant's
		// ServiceAccount is refused by it, in both directions.
		if _, _, err := vaultTryLogin(t, alpha, outRole, saToken(t, betaNS, "reader")); !refused(err) {
			t.Errorf("e2e-beta's ServiceAccount was not refused by e2e-alpha's share-out role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, beta, inRole, saToken(t, alphaNS, "web")); !refused(err) {
			t.Errorf("e2e-alpha's ServiceAccount was not refused by e2e-beta's share-in role; err: %v", err)
		}
		// One binding changed at a time, as for the own-tenant role: the same
		// tenant's other ServiceAccount (no export annotation), and a
		// ServiceAccount named web in another namespace.
		if _, _, err := vaultTryLogin(t, alpha, outRole, saToken(t, alphaNS, "viewer")); !refused(err) {
			t.Errorf("a ServiceAccount without kv-export-tenant was not refused by web's share-out role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, alpha, outRole, saToken(t, toolsNS, "web")); !refused(err) {
			t.Errorf("a ServiceAccount named web in another namespace was not refused by web's share-out role; err: %v", err)
		}
		// The reverse direction was never granted. Seeded as root, so the
		// refusal is about the caller, not a path with nothing at it.
		reversePath := env + "/from-" + beta + "/to-" + alpha + "/x"
		vaultRoot(t, "kv", "put", "-mount="+kvMount(sharedName), reversePath, "token=r1")
		if _, err := kvGet(t, outToken, sharedName, reversePath, "token"); !refused(err) {
			t.Errorf("exporter read the reverse share path; err: %v", err)
		}
		// The prefix tenant e2e exports to e2e-beta too: its folder is
		// from-e2e/, never from-e2e-alpha/, which web wrote above.
		coreOut := "share." + prefixT + "." + coreNS + ".core.out." + beta
		waitVCO(t, "kubernetesauthengineroles", coreOut)
		coreToken, _ := vaultLogin(t, prefixT, coreOut, saToken(t, coreNS, "core"))
		if err := kvPut(t, coreToken, sharedName, env+"/from-"+prefixT+"/to-"+beta+"/x", "token=c1"); err != nil {
			t.Fatalf("the prefix tenant could not write its own share: %v", err)
		}
		if err := kvPut(t, coreToken, sharedName, sharePath, "token=forged"); !refused(err) {
			t.Errorf("the prefix tenant e2e wrote e2e-alpha's share; err: %v", err)
		}

		createDeployment(t, betaNS, "reader", "reader", map[string]string{
			annPrefix + "kv-import.handoff": alpha + "/handoff#token",
		}, []corev1.EnvVar{secretEnv("HANDOFF", "reader-handoff", "token")})
		waitFor(t, "ExternalSecret reader-handoff synced", func() string {
			if v := secretValue(t, betaNS, "reader-handoff", "token"); v != "t1" {
				o := get(t, gvrExternalSecret, betaNS, "reader-handoff")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret token=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
	})

	step("isolation: a namespace name reused by another tenant gets nothing", func(t *testing.T) {
		// AC-ISO-10 (Q13). Kubernetes does not reserve a namespace name for a
		// tenant (K1). e2e-alpha's app in e2e-alpha-reuse logs in (the allow);
		// then the namespace is deleted and created again, with the same name,
		// under e2e-beta, with a ServiceAccount of the same name. That
		// ServiceAccount must not log in to e2e-alpha's role WHILE THE ROLE
		// STILL EXISTS: the chart drops the role once the namespace leaves
		// e2e-alpha, and a refusal then ("invalid role name") proves only that
		// it is gone. So the suite writes the same role spec as its own CR,
		// under its own object name, as a stuck or late re-render would leave
		// it, and asserts that VCO binds it to no namespace (each role binds the
		// namespace by name AND tenant label) and that the login gets a 403.
		// Relabelled for e2e-alpha, the same token logs in to the same role:
		// the label alone made the difference.
		appRole := roleName(alpha, reuseNS, "app")
		roleGVR := vcoGVR("kubernetesauthengineroles")
		rolePath := "auth/" + k8sAuthMount(alpha) + "/role/" + appRole
		if _, _, err := vaultTryLogin(t, alpha, appRole, saToken(t, reuseNS, "app")); err != nil {
			t.Fatalf("e2e-alpha's app could not log in before the namespace moved: %v", err)
		}
		rendered := get(t, roleGVR, configNS, appRole)
		if rendered == nil {
			t.Fatalf("e2e-alpha's role CR %s is absent before the namespace moved", appRole)
		}
		spec, _, _ := unstructured.NestedMap(rendered.Object, "spec")
		deleteTenantNamespace(t, reuseNS)
		waitFor(t, "the chart's role CR "+appRole+" gone with the namespace", func() string {
			if get(t, roleGVR, configNS, appRole) != nil {
				return "still present"
			}
			return ""
		})
		const held = "e2e-iso10-held-role"
		heldRole := &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": "redhatcop.redhat.io/v1alpha1",
			"kind":       "KubernetesAuthEngineRole",
			"metadata":   map[string]any{"name": held, "namespace": configNS},
			"spec":       spec,
		}}
		// e2e-beta's namespace of the same name first: VCO's first look at
		// the held role then finds a namespace of that name with another
		// tenant's label, not no namespace at all.
		createTenant(t, beta, reuseNS)
		createServiceAccount(t, reuseNS, "app", map[string]string{annPrefix + "kv": "true", annPrefix + "role": "editor"})
		if _, err := dyn.Resource(roleGVR).Namespace(configNS).Create(ctx, heldRole, metav1.CreateOptions{}); err != nil {
			t.Fatalf("write e2e-alpha's role spec as the suite's own CR (it passes admission like the chart's): %v", err)
		}
		t.Cleanup(func() {
			deleteIfExists(t, roleGVR, configNS, held)
			waitFor(t, "the held role CR gone", func() string {
				if get(t, roleGVR, configNS, held) != nil {
					return "still present"
				}
				return ""
			})
		})
		waitVCO(t, "kubernetesauthengineroles", held)
		// The role is in Vault, and VCO bound it to no namespace: the selector
		// names the namespace by name AND e2e-alpha's label, and the namespace
		// of that name is e2e-beta's now.
		boundTo := func() ([]string, string) {
			out, err := vaultRun(t, vaultRootToken, "read", "-format=json", rolePath)
			if err != nil {
				return nil, "e2e-alpha's role is not in Vault: " + err.Error()
			}
			var r struct {
				Data struct {
					Namespaces []string `json:"bound_service_account_namespaces"`
				} `json:"data"`
			}
			if err := json.Unmarshal([]byte(out), &r); err != nil {
				return nil, "cannot read the role: " + err.Error()
			}
			return r.Data.Namespaces, ""
		}
		waitFor(t, "VCO binds e2e-alpha's role to no namespace", func() string {
			ns, bad := boundTo()
			if bad != "" {
				return bad
			}
			// VCO writes __no_namespace__ when the selector matches none
			// (baseline V10); a field missing or renamed decodes to nil and
			// must not read as "unbound".
			if !slices.Equal(ns, []string{"__no_namespace__"}) {
				return fmt.Sprintf("bound to %v, want [__no_namespace__]", ns)
			}
			return ""
		})
		// e2e-beta's own role for the new namespace works, at e2e-beta's mount.
		waitVCO(t, "kubernetesauthengineroles", roleName(beta, reuseNS, "app"))
		waitFor(t, "e2e-beta's app logs in at its own mount", func() string {
			if _, _, err := vaultTryLogin(t, beta, roleName(beta, reuseNS, "app"), saToken(t, reuseNS, "app")); err != nil {
				return err.Error()
			}
			return ""
		})
		jwt := saToken(t, reuseNS, "app")
		if _, _, err := vaultTryLogin(t, alpha, appRole, jwt); err == nil {
			t.Fatalf("a ServiceAccount in a namespace now owned by e2e-beta logged in to e2e-alpha's role %s", appRole)
		} else if !refused(err) {
			t.Fatalf("the login was refused, but not with a 403 — the role must exist and refuse the namespace: %v", err)
		}
		// Hold across a drift period: the refusal must last, with the role
		// still in Vault, not be a moment before VCO re-resolves the selector.
		holdFor(t, vcoSync+10*time.Second, "e2e-alpha's role stays closed to the reused namespace", func() string {
			if _, bad := boundTo(); bad != "" {
				return bad
			}
			_, _, err := vaultTryLogin(t, alpha, appRole, jwt)
			switch {
			case err == nil:
				return "the login succeeded"
			case !refused(err):
				return "refused, but not with a 403: " + err.Error()
			}
			return ""
		})
		// The matching allow: the namespace labelled for e2e-alpha again, the
		// same token logs in to the same role. Then back to e2e-beta, which the
		// lifecycle step below expects.
		setNamespaceTenant := func(tenant string) {
			patch := fmt.Sprintf(`{"metadata":{"labels":{%q:%q}}}`, tenantLabel, tenant)
			if _, err := kube.CoreV1().Namespaces().Patch(ctx, reuseNS, types.MergePatchType, []byte(patch), metav1.PatchOptions{}); err != nil {
				t.Fatalf("label %s for %s: %v", reuseNS, tenant, err)
			}
		}
		setNamespaceTenant(alpha)
		waitFor(t, "the same token logs in to e2e-alpha's role once the namespace is e2e-alpha's", func() string {
			if _, _, err := vaultTryLogin(t, alpha, appRole, jwt); err != nil {
				return err.Error()
			}
			return ""
		})
		setNamespaceTenant(beta)
		waitFor(t, "e2e-alpha's role closed again", func() string {
			if _, _, err := vaultTryLogin(t, alpha, appRole, jwt); err == nil || !refused(err) {
				return fmt.Sprintf("login: %v", err)
			}
			return ""
		})
		waitVCO(t, "kubernetesauthengineroles", roleName(beta, reuseNS, "app"))
	})

	step("health: a mount collision surfaces on its own tenant only", func(t *testing.T) {
		// AC-OPS-1, AC-OPS-2. The platform has mounts at e2e-plat/ and
		// auth/e2e-plat/ that parent.reservedPaths does not list. A tenant named
		// e2e-plat then collides: Vault refuses its kv mount and its auth mount
		// (a mount can't nest under another, N3, N7). The errors reach that
		// tenant's outputs — on the parent for the kv mount, on its child TI for
		// the auth mount and its roles — and no other tenant's.
		const plat, platNS = "e2e-plat", "e2e-plat-dev"
		vaultRoot(t, "secrets", "enable", "-path="+plat, "kv")
		vaultRoot(t, "auth", "enable", "-path="+plat, "userpass")
		t.Cleanup(func() {
			deleteTenant(t, plat, platNS)
			vaultRun(t, vaultRootToken, "secrets", "disable", plat)
			vaultRun(t, vaultRootToken, "auth", "disable", plat)
		})
		createTenant(t, plat, platNS)
		createServiceAccount(t, platNS, "app", map[string]string{annPrefix + "kv": "true", annPrefix + "role": "editor"})
		out := func(ti, field, key string) string {
			o := get(t, gvrTemplateInstance, configNS, ti)
			if o == nil {
				return ""
			}
			v, _, _ := unstructured.NestedString(o.Object, "status", "outputs", field, key)
			return v
		}
		waitFor(t, "the parent reports e2e-plat's kv mount error", func() string {
			if v := out(parentName, "enginesLastError", plat+"-kv"); !strings.Contains(v, "in use") {
				return "enginesLastError[" + plat + "-kv] = " + v
			}
			return ""
		})
		waitFor(t, "e2e-plat's child TI reports its auth mount and role errors", func() string {
			if v := out(tiPrefix+plat, "authMountsLastError", plat+"-kubernetes"); !strings.Contains(v, "in use") {
				return "authMountsLastError[" + plat + "-kubernetes] = " + v
			}
			if v := out(tiPrefix+plat, "k8sAuthRolesLastError", roleName(plat, platNS, "app")); v == "" || v == "[]" {
				return "k8sAuthRolesLastError = " + v
			}
			return ""
		})
		// No other tenant is affected: their entries carry no error, and a
		// workload of e2e-alpha still logs in and reads.
		for _, k := range []string{alpha + "-kv", prefixT + "-kv", sharedName + "-kv"} {
			if v := out(parentName, "enginesLastError", k); v != "[]" {
				t.Errorf("enginesLastError[%s] = %q, want no error", k, v)
			}
		}
		if v := out(tiPrefix+alpha, "authMountsLastError", alpha+"-kubernetes"); v != "[]" {
			t.Errorf("e2e-alpha's authMountsLastError = %q, want no error", v)
		}
		tok, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "web"), saToken(t, alphaNS, "web"))
		if _, err := kvGet(t, tok, alpha, appPath(alphaNS, "web", "db"), "password"); err != nil {
			t.Errorf("e2e-alpha's web could not read during e2e-plat's collision: %v", err)
		}
	})

	step("role change: lowering editor to viewer takes write away", func(t *testing.T) {
		// AC-ACC-5.
		role := roleName(alpha, alphaNS, "lower")
		leaf := appPath(alphaNS, "lower", "k")
		// The write before the change is the matching allow for the refusals
		// after it: same token, same path.
		lowerToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "lower"))
		if err := kvPut(t, lowerToken, alpha, leaf, "v=1"); err != nil {
			t.Fatalf("editor could not write its own secret before the role change: %v", err)
		}
		setServiceAccountAnnotations(t, alphaNS, "lower", map[string]string{annPrefix + "kv": "true", annPrefix + "role": "viewer"})
		// The role is not part of the policy name, so VCO rewrites the same
		// policy in place. Inspected as root: wait for the viewer version.
		waitFor(t, "Vault holds the viewer policy for lower", func() string {
			out, err := vaultRun(t, vaultRootToken, "policy", "read", role)
			if err != nil {
				return err.Error()
			}
			if strings.Contains(out, `"create"`) {
				return "the policy still grants create"
			}
			return ""
		})
		// Vault resolves a token's policies by name on every request, so the
		// token issued at editor follows the new role at once.
		if err := kvPut(t, lowerToken, alpha, leaf, "v=2"); !refused(err) {
			t.Errorf("a token issued at editor still wrote after the role was lowered; err: %v", err)
		}
		if got, err := kvGet(t, lowerToken, alpha, leaf, "v"); err != nil || got != "1" {
			t.Errorf("viewer could not read its own secret after the role change: got %q, err %v", got, err)
		}
		newToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "lower"))
		if err := kvPut(t, newToken, alpha, leaf, "v=3"); !refused(err) {
			t.Errorf("a new login after the role change wrote a secret; err: %v", err)
		}
	})

	step("removal: dropping the annotation revokes the access", func(t *testing.T) {
		// AC-LIFE-3.
		role := roleName(alpha, alphaNS, "temp")
		// A token issued BEFORE the removal, and a write with it: the matching
		// allow for the refusal after it.
		tempToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "temp"))
		leaf := appPath(alphaNS, "temp", "k")
		if err := kvPut(t, tempToken, alpha, leaf, "v=1"); err != nil {
			t.Fatalf("temp could not write its own secret before removal: %v", err)
		}
		setServiceAccountAnnotations(t, alphaNS, "temp", nil)
		for _, k := range []string{"policies", "kubernetesauthengineroles"} {
			waitFor(t, k+"/"+role+" gone", func() string {
				if get(t, vcoGVR(k), configNS, role) != nil {
					return "still present"
				}
				return ""
			})
		}
		waitFor(t, "the Vault role and policy are deleted", func() string {
			if msg := vaultGone(t, "read", "auth/"+k8sAuthMount(alpha)+"/role/"+role); msg != "" {
				return "role: " + msg
			}
			if msg := vaultGone(t, "policy", "read", role); msg != "" {
				return "policy: " + msg
			}
			return ""
		})
		// Vault resolves a token's policies by name on every request, so the
		// token issued before the removal loses its access with the policy.
		if _, err := kvGet(t, tempToken, alpha, leaf, "v"); !refused(err) {
			t.Errorf("a token issued before the removal still read temp's secret; err: %v", err)
		}
		// A new login fails because the role is gone, not for another reason.
		if _, _, err := vaultTryLogin(t, alpha, role, saToken(t, alphaNS, "temp")); err == nil || !strings.Contains(err.Error(), "invalid role name") {
			t.Errorf("login after removal: want Vault's \"invalid role name\", got %v", err)
		}
		if configMapData(t, alphaNS, "vault-config-temp") != nil {
			t.Errorf("ConfigMap vault-config-temp survived the removal")
		}
	})

	step("lifetime: a tenant keeps its data without a labelled namespace, and its tokens are revoked", func(t *testing.T) {
		// AC-LIFE-2, AC-LIFE-5. The workload render exists only while a tenant
		// has a labelled namespace; its kv mount is the parent's, so it must
		// outlive it. Deleting e2e-beta's last namespaces must remove its child
		// TemplateInstances and nothing that holds data — and, on Community
		// Edition, disable its auth mount, which revokes every token issued
		// through it (A6, ADR-0007).
		readerRole := roleName(beta, betaNS, "reader")
		// A token issued before, and a read with it: the allow for the
		// revocation below.
		readerToken, _ := vaultLogin(t, beta, readerRole, saToken(t, betaNS, "reader"))
		if got, err := kvGet(t, readerToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
			t.Fatalf("reader could not read its secret before its namespaces went: got %q, err %v", got, err)
		}
		// What the workload render wrote: the grants, not the data.
		grants := []struct{ kind, name string }{
			{"authenginemounts", beta + "-kubernetes"},
			{"kubernetesauthengineconfigs", beta + "-kubernetes-config"},
			{"policies", readerRole},
			{"kubernetesauthengineroles", readerRole},
		}
		// e2e-beta's labelled namespaces: its own, and the one it took over in
		// the reused-name step.
		deleteTenantNamespace(t, betaNS)
		deleteTenantNamespace(t, reuseNS)
		for _, ti := range []string{tiPrefix + beta, tiPrefix + beta + ".eso"} {
			waitFor(t, "TemplateInstance "+ti+" gone", func() string {
				if get(t, gvrTemplateInstance, configNS, ti) != nil {
					return "still present"
				}
				return ""
			})
		}
		for _, o := range grants {
			waitFor(t, o.kind+"/"+o.name+" gone with the workload render", func() string {
				if get(t, vcoGVR(o.kind), configNS, o.name) != nil {
					return "still present"
				}
				return ""
			})
		}
		waitFor(t, "e2e-beta's auth mount disabled", func() string {
			if slices.Contains(vaultKeys(t, "auth", "list", "-format=json"), k8sAuthMount(beta)+"/") {
				return "still mounted"
			}
			return ""
		})
		// The token issued before is revoked with its mount, at once — not at
		// its TTL, as a role deletion on a shared mount would leave it.
		if _, err := kvGet(t, readerToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); !refused(err) {
			t.Errorf("a token issued through e2e-beta's auth mount still read after the mount was disabled; err: %v", err)
		}
		// Held across a VCO drift period, not read once: a deletion is
		// asynchronous (t-op-v2 prunes, then VCO deletes in Vault).
		holdFor(t, vcoSync+15*time.Second, "e2e-beta's Vault data without a labelled namespace", func() string {
			if obj := get(t, vcoGVR("secretenginemounts"), configNS, beta+"-kv"); obj == nil || obj.GetDeletionTimestamp() != nil {
				return "secretenginemounts/" + beta + "-kv was removed with the tenant's last namespace"
			}
			if got, err := kvGet(t, vaultRootToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
				return fmt.Sprintf("the secret did not survive: got %q, err %v", got, err)
			}
			return ""
		})
		// A labelled namespace brings the workload render back, and the grants
		// find the data that stayed — what a reused tenant name adopts.
		createTenant(t, beta, betaNS)
		waitTIReady(t, tiPrefix+beta)
		waitTIReady(t, tiPrefix+beta+".eso")
		createServiceAccount(t, betaNS, "reader", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "role":             "viewer",
			annPrefix + "kv-import-tenant": alpha,
		})
		for _, o := range grants {
			waitVCO(t, o.kind, o.name)
		}
		var newToken string
		waitFor(t, "reader logs in again at e2e-beta's mount", func() string {
			tok, _, err := vaultTryLogin(t, beta, readerRole, saToken(t, betaNS, "reader"))
			if err != nil {
				return err.Error()
			}
			newToken = tok
			return ""
		})
		if got, err := kvGet(t, newToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
			t.Fatalf("the workload could not read its surviving secret after its namespace came back: got %q, err %v", got, err)
		}
	})

	step("offboarding: deleting a Tenant keeps its Vault data under the production VCO policy", func(t *testing.T) {
		// AC-LIFE-4. The lab's VCO login policy allows the kv delete, so the
		// teardown can clean up. The production one refuses it: that refusal is
		// what keeps a tenant's secrets when its Tenant CR goes. Root swaps it in
		// for this step only.
		prod, err := os.ReadFile("../../charts/examples/vco-admin-policy.hcl")
		if err != nil {
			t.Fatalf("read the production VCO policy: %v", err)
		}
		lab := policyRules(t, vcoLogin)
		t.Cleanup(func() { vaultRoot(t, "write", "sys/policy/"+vcoLogin, "policy="+lab) })
		vaultRoot(t, "write", "sys/policy/"+vcoLogin, "policy="+string(prod))

		// The data that must stay: e2e-beta's own secret, and both shares with
		// e2e-alpha, which live in shared/kv. Inspected as root: e2e-beta's
		// workloads lose their logins with the Tenant.
		handoff := env + "/from-" + alpha + "/to-" + beta + "/handoff"
		reverse := env + "/from-" + beta + "/to-" + alpha + "/x"
		data := func() string {
			if got, err := kvGet(t, vaultRootToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
				return fmt.Sprintf("e2e-beta's secret: got %q, err %v", got, err)
			}
			if got, err := kvGet(t, vaultRootToken, sharedName, handoff, "token"); err != nil || got != "t1" {
				return fmt.Sprintf("the share to e2e-beta: got %q, err %v", got, err)
			}
			if got, err := kvGet(t, vaultRootToken, sharedName, reverse, "token"); err != nil || got != "r1" {
				return fmt.Sprintf("the share from e2e-beta: got %q, err %v", got, err)
			}
			return ""
		}
		if msg := data(); msg != "" {
			t.Fatalf("before the deletion: %s", msg)
		}

		// MTO deletes a Tenant together with its namespaces.
		deleteTenant(t, beta, betaNS)

		// The grants go, under the production policy too: every e2e-beta CR
		// except the kv mount, and e2e-alpha's share role to the tenant that is
		// gone.
		waitFor(t, "every e2e-beta CR gone except its kv mount", func() string {
			objs := tenantVCOObjects(t, beta)
			if len(objs) != 1 || objs[0] != "secretenginemounts/"+beta+"-kv" {
				return fmt.Sprintf("left: %v", objs)
			}
			return ""
		})
		outRole := "share." + alpha + "." + alphaNS + ".web.out." + beta
		for _, k := range []string{"policies", "kubernetesauthengineroles"} {
			waitFor(t, k+"/"+outRole+" gone with its peer", func() string {
				if get(t, vcoGVR(k), configNS, outRole) != nil {
					return "still present"
				}
				return ""
			})
		}
		if msg := vaultGone(t, "policy", "read", outRole); msg != "" {
			t.Errorf("e2e-alpha's share policy to e2e-beta is still in Vault: %s", msg)
		}

		// VCO tries to delete the mount, Vault refuses, and VCO's finalizer
		// holds the CR. Held across a drift period.
		holdFor(t, vcoSync+15*time.Second, "e2e-beta's data after its Tenant was deleted", func() string {
			switch obj := get(t, vcoGVR("secretenginemounts"), configNS, beta+"-kv"); {
			case obj == nil:
				return "secretenginemounts/" + beta + "-kv was deleted"
			case obj.GetDeletionTimestamp() == nil:
				return "secretenginemounts/" + beta + "-kv is not being deleted: the Tenant's deletion did not reach it"
			}
			return data()
		})

		// The refusal is the policy's: VCO's own login reads the mount, and is
		// refused its disable. Under the lab policy the disable would pass.
		vcoToken, _, err := vaultTryLoginAt(t, vcoLoginMount, vcoLogin, saToken(t, configNS, vcoLogin))
		if err != nil {
			t.Fatalf("log in as VCO: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, "read", "sys/mounts/"+kvMount(beta)); err != nil {
			t.Fatalf("VCO could not read e2e-beta's kv mount: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, "secrets", "disable", kvMount(beta)); !refused(err) {
			t.Errorf("VCO's login disabled e2e-beta's kv mount; err: %v", err)
		}

		// The documented purge (charts/README.md → Deletion): with the mount CR
		// already Terminating, a Vault admin disables the mount, then removes the
		// finalizer. Never the other way round: a live CR makes VCO re-create
		// the mount, empty (V12).
		vaultRoot(t, "secrets", "disable", kvMount(beta))
		removeFinalizers(t, vcoGVR("secretenginemounts"), configNS, beta+"-kv")
		waitFor(t, "secretenginemounts/"+beta+"-kv gone", func() string {
			if get(t, vcoGVR("secretenginemounts"), configNS, beta+"-kv") != nil {
				return "still present"
			}
			return ""
		})
		holdFor(t, vcoSync+10*time.Second, "the purged mount stays gone", func() string {
			if slices.Contains(vaultKeys(t, "secrets", "list", "-format=json"), kvMount(beta)+"/") {
				return kvMount(beta) + " is mounted again"
			}
			return ""
		})
	})

	step("teardown: the documented uninstall order", func(t *testing.T) {
		if os.Getenv("E2E_KEEP") != "" {
			t.Skip("E2E_KEEP is set")
		}
		uninstall(t)
		if releaseExists(t) {
			t.Fatal("the bootstrap release still exists after the uninstall")
		}
	})
}
