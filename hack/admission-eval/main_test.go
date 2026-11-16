package main

// The offline runner's own rules (C.21): each one, removed, makes a test here
// fail (hack/mutation_tests.py, suite "go").

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
)

const pol = "mto-extension-vault-community-vco-scope"

var names = []string{"mto-extension-vault-community-vco-kinds", pol}

func denial(p, msg string) error {
	return errors.New(`policies.redhatcop.redhat.io "x" is forbidden: ValidatingAdmissionPolicy '` + p +
		`' with binding '` + p + `' denied request: ` + msg)
}

func refuseCase() testCase {
	return testCase{file: "001.yaml", want: "refuse", policy: pol, message: "an SSO role binds only", what: "a case"}
}

func TestAdmitWithNoDenialPasses(t *testing.T) {
	if line, ok := verdict(testCase{want: "admit", what: "a case"}, map[string]error{}, names); !ok {
		t.Fatal(line)
	}
}

func TestAdmitWithADenialFails(t *testing.T) {
	line, ok := verdict(testCase{want: "admit", what: "a case"}, map[string]error{pol: denial(pol, "no")}, names)
	if ok || !strings.Contains(line, "refused by "+pol) {
		t.Fatal(line)
	}
}

func TestRefusedByTheRulePasses(t *testing.T) {
	if line, ok := verdict(refuseCase(), map[string]error{pol: denial(pol, "an SSO role binds only its own policy")}, names); !ok {
		t.Fatal(line)
	}
}

func TestAdmittedFails(t *testing.T) {
	line, ok := verdict(refuseCase(), map[string]error{}, names)
	if ok || !strings.Contains(line, "admitted by") {
		t.Fatal(line)
	}
}

func TestEvaluationErrorIsNoRefusal(t *testing.T) {
	d := denial(pol, "expression '!has(object.spec.connection)' resulted in error: no such key: spec")
	c := refuseCase()
	c.message = "no such key"
	line, ok := verdict(c, map[string]error{pol: d}, names)
	if ok || !strings.Contains(line, "on an evaluation error") {
		t.Fatal(line)
	}
}

func TestRefusedByAnotherRuleFails(t *testing.T) {
	line, ok := verdict(refuseCase(), map[string]error{pol: denial(pol, "a policy has no spec.type")}, names)
	if ok || !strings.Contains(line, "by another rule") {
		t.Fatal(line)
	}
}

func TestAlsoRefusedByAnotherPolicyFails(t *testing.T) {
	kinds := names[0]
	line, ok := verdict(refuseCase(), map[string]error{
		pol:   denial(pol, "an SSO role binds only its own policy"),
		kinds: denial(kinds, "a VCO CR in the config namespace has a spec"),
	}, names)
	if ok || !strings.Contains(line, "also refused by "+kinds) {
		t.Fatal(line)
	}
}

func TestEachErrorWordIsNoRefusal(t *testing.T) {
	for _, w := range []string{"failed to configure", "resulted in error", "compil", "no such key", "evaluation", "cost", "budget"} {
		if refusedByPolicy(denial(pol, "x "+w+" y")) {
			t.Errorf("a denial holding %q read as a rule's refusal", w)
		}
	}
	if !refusedByPolicy(denial(pol, "a policy has no spec.type")) {
		t.Error("a rule's refusal did not read as one")
	}
}

func TestAResultIsOneLine(t *testing.T) {
	d := denial(pol, "expression 'a &&\n  b' resulted in error: no such key")
	c := refuseCase()
	line, _ := verdict(c, map[string]error{pol: d}, names)
	if strings.Contains(line, "\n") || !strings.Contains(line, "resulted in error") {
		t.Fatalf("the result must be one line with the whole error: %q", line)
	}
	admit, _ := verdict(testCase{want: "admit", what: "a case"}, map[string]error{pol: d}, names)
	if strings.Contains(admit, "\n") || !strings.Contains(admit, "resulted in error") {
		t.Fatalf("an admit result must be one line with the whole error: %q", admit)
	}
}

func TestCountMismatchFails(t *testing.T) {
	if countError(76, 77, "d") == "" || countError(78, 77, "d") == "" {
		t.Fatal("a case count other than the pinned one must fail")
	}
	if e := countError(77, 77, "d"); e != "" {
		t.Fatal(e)
	}
}

func TestTooNewExpressionFailsToCompile(t *testing.T) {
	p := func(expr string) *admissionregistrationv1.ValidatingAdmissionPolicy {
		return &admissionregistrationv1.ValidatingAdmissionPolicy{Spec: admissionregistrationv1.ValidatingAdmissionPolicySpec{
			Validations: []admissionregistrationv1.Validation{{Expression: expr}},
		}}
	}
	if errs := compileErrors(p("true")); len(errs) != 0 {
		t.Fatalf("a plain expression must compile: %v", errs)
	}
	if errs := compileErrors(p("ip('10.0.0.1') != ip('10.0.0.2')")); len(errs) == 0 {
		t.Fatal("ip() is newer than the CEL of Kubernetes 1.30 and must not compile")
	}
}

func writeCase(t *testing.T, dir, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

const obj = "---\napiVersion: redhatcop.redhat.io/v1alpha1\nkind: Policy\nmetadata: { name: x }\n"

func TestARefusalWithoutAMessageIsRefused(t *testing.T) {
	dir := t.TempDir()
	writeCase(t, dir, "001.yaml", "# want: refuse\n# policy: "+pol+"\n# what: x\n"+obj)
	if _, err := loadCases(dir, "vault-config"); err == nil {
		t.Fatal("a refusal without its rule's message must not load")
	}
}

func TestAClusterScopedCaseKeepsNoNamespace(t *testing.T) {
	dir := t.TempDir()
	writeCase(t, dir, "001.yaml", "# want: admit\n# what: x\n# scope: cluster\n"+obj)
	writeCase(t, dir, "002.yaml", "# want: admit\n# what: y\n"+obj)
	cases, err := loadCases(dir, "vault-config")
	if err != nil {
		t.Fatal(err)
	}
	if ns := cases[0].obj.GetNamespace(); ns != "" {
		t.Fatalf("a cluster-scoped case got namespace %q", ns)
	}
	if ns := cases[1].obj.GetNamespace(); ns != "vault-config" {
		t.Fatalf("a namespaced case got namespace %q, want the config namespace", ns)
	}
}
