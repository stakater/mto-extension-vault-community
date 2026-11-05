// Offline runner for the bootstrap chart's ValidatingAdmissionPolicies.
//
// The admission policies (charts/mto-extension-vault-community-bootstrap/
// templates/50-admission.yaml) are the wall between tenants that Vault
// Community does not have, and their CEL used to run only on a live cluster:
// a change that broke a rule passed `make verify`. This runs the rendered
// policies and bindings through k8s.io/apiserver's own ValidatingAdmissionPolicy
// plugin — the code the API server runs: match constraints, match conditions,
// variables, validations, the param binding — against the cases that
// hack/lab/admission-cases.sh emits with EMIT=<dir>, so the live script and
// this runner read one list of cases.
//
// A case file holds a header and one object, or two for an UPDATE (the new
// object, then the old one):
//
//	# want: admit | refuse
//	# policy: <the policy that must refuse>   (refuse only)
//	# what: <description>
//	# as: <username>           (optional; default a person, "kubernetes-admin")
//	---
//	<object>
//
// Each policy runs on its own, so the result does not depend on the order in
// which the API server reports denials (it reports the first). An "admit"
// case passes when no policy refuses; a "refuse" case when the named policy
// refuses by one of its validations — not because it failed to compile,
// configure or evaluate, or ran out of cost budget — and no other policy
// refuses, so the live run reports the same policy.
//
// Before any case, every expression of every policy is compiled as a
// Kubernetes 1.30 API server compiles a new policy (environment
// NewExpressions at its compatibility version, 1.29): an expression that a
// newer CEL library accepts but 1.30 refuses fails here.
//
// Usage: go run ./hack/admission-eval -cases N <rendered-bootstrap.yaml> <cases-dir>
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/version"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/apiserver/pkg/admission"
	"k8s.io/apiserver/pkg/admission/plugin/cel"
	"k8s.io/apiserver/pkg/admission/plugin/policy/generic"
	"k8s.io/apiserver/pkg/admission/plugin/policy/matching"
	"k8s.io/apiserver/pkg/admission/plugin/policy/validating"
	"k8s.io/apiserver/pkg/admission/plugin/webhook/matchconditions"
	"k8s.io/apiserver/pkg/authentication/user"
	"k8s.io/apiserver/pkg/authorization/authorizer"
	"k8s.io/apiserver/pkg/cel/environment"
	"k8s.io/client-go/kubernetes"
	"k8s.io/klog/v2"
)

const group = "redhatcop.redhat.io"

// oldestAPIServer is the compatibility version of the oldest API server the
// chart supports (Kubernetes 1.30, K2): it validates a new policy's CEL at
// n-1.
var oldestAPIServer = version.MajorMinor(1, 29)

type testContext = generic.PolicyTestContext[*admissionregistrationv1.ValidatingAdmissionPolicy, *admissionregistrationv1.ValidatingAdmissionPolicyBinding, validating.Validator]

type quietLogger struct{}

func (quietLogger) Helper()             {}
func (quietLogger) Logf(string, ...any) {}

// compile is validating.compilePolicy (k8s.io/apiserver v0.36.3,
// pkg/admission/plugin/policy/validating/plugin.go), which is unexported.
// Every piece it calls is exported; keep the two in step on a bump.
func compile(policy *admissionregistrationv1.ValidatingAdmissionPolicy) validating.Validator {
	hasParam := policy.Spec.ParamKind != nil
	optionalVars := cel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: true}
	expressionOptionalVars := cel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: false}
	failurePolicy := policy.Spec.FailurePolicy
	envTemplate := environment.MustBaseEnvSet(environment.DefaultCompatibilityVersion())
	filterCompiler, err := cel.NewCompositedCompiler(envTemplate)
	if err != nil {
		return validating.NewValidator(nil, nil, nil, nil, failurePolicy, err)
	}
	vars := make([]cel.NamedExpressionAccessor, len(policy.Spec.Variables))
	for i, v := range policy.Spec.Variables {
		vars[i] = &validating.Variable{Name: v.Name, Expression: v.Expression}
	}
	filterCompiler.CompileAndStoreVariables(vars, optionalVars, environment.StoredExpressions)

	var matcher matchconditions.Matcher
	if mc := policy.Spec.MatchConditions; len(mc) > 0 {
		acc := make([]cel.ExpressionAccessor, len(mc))
		for i := range mc {
			acc[i] = (*matchconditions.MatchCondition)(&mc[i])
		}
		matcher = matchconditions.NewMatcher(filterCompiler.CompileCondition(acc, optionalVars, environment.StoredExpressions), failurePolicy, "policy", "validate", policy.Name)
	}
	validations := make([]cel.ExpressionAccessor, len(policy.Spec.Validations))
	messages := make([]cel.ExpressionAccessor, len(policy.Spec.Validations))
	for i, v := range policy.Spec.Validations {
		validations[i] = &validating.ValidationCondition{Expression: v.Expression, Message: v.Message, Reason: v.Reason}
		if v.MessageExpression != "" {
			messages[i] = &validating.MessageExpressionCondition{MessageExpression: v.MessageExpression}
		}
	}
	audits := make([]cel.ExpressionAccessor, len(policy.Spec.AuditAnnotations))
	for i, a := range policy.Spec.AuditAnnotations {
		audits[i] = &validating.AuditAnnotationCondition{Key: a.Key, ValueExpression: a.ValueExpression}
	}
	return validating.NewValidator(
		filterCompiler.CompileCondition(validations, optionalVars, environment.StoredExpressions),
		matcher,
		filterCompiler.CompileCondition(audits, optionalVars, environment.StoredExpressions),
		filterCompiler.CompileCondition(messages, expressionOptionalVars, environment.StoredExpressions),
		failurePolicy,
		nil,
	)
}

// compileErrors compiles every expression of a policy in the NewExpressions
// environment of the oldest supported API server. NewValidator takes a nil
// error, so a validator's CompileError says nothing: the errors are on each
// compiled expression.
func compileErrors(policy *admissionregistrationv1.ValidatingAdmissionPolicy) []string {
	mode := environment.NewExpressions
	c, err := cel.NewCompositedCompiler(environment.MustBaseEnvSet(oldestAPIServer))
	if err != nil {
		return []string{err.Error()}
	}
	hasParam := policy.Spec.ParamKind != nil
	opts := cel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: true}
	var out []string
	for _, v := range policy.Spec.Variables {
		if r := c.CompileAndStoreVariable(&validating.Variable{Name: v.Name, Expression: v.Expression}, opts, mode); r.Error != nil {
			out = append(out, fmt.Sprintf("variable %s: %v", v.Name, r.Error))
		}
	}
	var exprs []cel.ExpressionAccessor
	for i := range policy.Spec.MatchConditions {
		exprs = append(exprs, (*matchconditions.MatchCondition)(&policy.Spec.MatchConditions[i]))
	}
	for _, v := range policy.Spec.Validations {
		exprs = append(exprs, &validating.ValidationCondition{Expression: v.Expression})
	}
	for _, e := range c.CompileCondition(exprs, opts, mode).CompilationErrors() {
		out = append(out, e.Error())
	}
	var msgs []cel.ExpressionAccessor
	for _, v := range policy.Spec.Validations {
		if v.MessageExpression != "" {
			msgs = append(msgs, &validating.MessageExpressionCondition{MessageExpression: v.MessageExpression})
		}
	}
	msgOpts := cel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: false}
	for _, e := range c.CompileCondition(msgs, msgOpts, mode).CompilationErrors() {
		out = append(out, "messageExpression: "+e.Error())
	}
	return out
}

type testCase struct {
	file, want, policy, what, as string
	obj, old                     *unstructured.Unstructured
}

func main() {
	// The informers log their sync at info level; the result lines are the output.
	klog.LogToStderr(false)
	klog.SetOutput(io.Discard)
	wantCases := flag.Int("cases", -1, "fail unless exactly N cases are found")
	flag.Parse()
	if flag.NArg() != 2 || *wantCases < 0 {
		fmt.Println("usage: admission-eval -cases N <rendered-bootstrap.yaml> <cases-dir>")
		os.Exit(2)
	}
	policies, bindings, err := loadPolicies(flag.Arg(0))
	if err != nil {
		fmt.Println("FAIL  infra —", err)
		os.Exit(1)
	}
	if len(policies) == 0 {
		fmt.Println("FAIL  infra — no ValidatingAdmissionPolicy in", flag.Arg(0))
		os.Exit(1)
	}
	compileFailed := false
	for _, p := range policies {
		for _, e := range compileErrors(p) {
			compileFailed = true
			fmt.Printf("FAIL  compile: %s (Kubernetes 1.30): %s\n", p.Name, e)
		}
	}
	if compileFailed {
		os.Exit(1)
	}
	configNS := policies[0].Spec.MatchConstraints.NamespaceSelector.MatchLabels["kubernetes.io/metadata.name"]
	if configNS == "" {
		fmt.Println("FAIL  infra — the first policy names no namespace in its namespaceSelector")
		os.Exit(1)
	}
	cases, err := loadCases(flag.Arg(1), configNS)
	if err != nil {
		fmt.Println("FAIL  infra —", err)
		os.Exit(1)
	}
	if len(cases) != *wantCases {
		fmt.Printf("FAIL  infra — %d cases in %s, want exactly %d: a case was lost or added without the count\n", len(cases), flag.Arg(1), *wantCases)
		os.Exit(1)
	}

	// One test context per policy, each with only that policy and its binding.
	contexts := map[string]*testContext{}
	var names []string
	for _, p := range policies {
		var bs []*admissionregistrationv1.ValidatingAdmissionPolicyBinding
		for _, b := range bindings {
			if b.Spec.PolicyName == p.Name {
				bs = append(bs, b)
			}
		}
		if len(bs) != 1 {
			fmt.Printf("FAIL  infra — policy %s has %d bindings, want 1\n", p.Name, len(bs))
			os.Exit(1)
		}
		tc, cancel, err := newContext(configNS, p, bs[0])
		if err != nil {
			fmt.Printf("FAIL  infra — policy %s: %v\n", p.Name, err)
			os.Exit(1)
		}
		defer cancel()
		contexts[p.Name] = tc
		names = append(names, p.Name)
	}
	sort.Strings(names)
	for _, c := range cases {
		if c.want == "refuse" && contexts[c.policy] == nil {
			fmt.Printf("FAIL  infra — %s names policy %q, which is not rendered\n", c.file, c.policy)
			os.Exit(1)
		}
	}

	scheme := runtime.NewScheme()
	verbose := os.Getenv("VERBOSE") != ""
	failed := 0
	for _, c := range cases {
		denials := map[string]error{}
		for _, n := range names {
			if err := dispatch(contexts[n], scheme, c); err != nil {
				denials[n] = err
			}
		}
		var others []string
		for _, n := range names {
			if denials[n] != nil && n != c.policy {
				others = append(others, fmt.Sprintf("%s: %v", n, denials[n]))
			}
		}
		switch {
		case c.want == "admit" && len(denials) == 0:
			fmt.Printf("PASS  admit:  %s\n", c.what)
		case c.want == "refuse" && refusedByPolicy(denials[c.policy]) && len(others) == 0:
			if verbose {
				fmt.Printf("PASS  refuse: %s — %v\n", c.what, denials[c.policy])
			} else {
				fmt.Printf("PASS  refuse: %s\n", c.what)
			}
		case c.want == "admit":
			failed++
			fmt.Printf("FAIL  admit: %s (%s): %s\n", c.what, c.file, strings.Join(others, "; "))
		default:
			failed++
			fmt.Printf("FAIL  refuse: %s (%s): by %s: %v; by others: [%s]\n", c.what, c.file, c.policy, denials[c.policy], strings.Join(others, "; "))
		}
	}
	fmt.Printf("== offline result: %d cases, %d failed\n", len(cases), failed)
	if failed > 0 {
		os.Exit(1)
	}
}

// newContext loads one policy and its binding into k8s.io/apiserver's policy
// test context: the real plugin, with fake clients holding the config
// namespace and its kube-root-ca.crt (the cluster policy's param).
func newContext(configNS string, p *admissionregistrationv1.ValidatingAdmissionPolicy, b *admissionregistrationv1.ValidatingAdmissionPolicyBinding) (*testContext, func(), error) {
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: configNS, Labels: map[string]string{"kubernetes.io/metadata.name": configNS}}}
	rootCA := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "kube-root-ca.crt", Namespace: configNS}, Data: map[string]string{"ca.crt": "-----BEGIN CERTIFICATE-----\nthe cluster CA\n-----END CERTIFICATE-----\n"}}
	tc, cancel, err := generic.NewPolicyTestContext[*admissionregistrationv1.ValidatingAdmissionPolicy, *admissionregistrationv1.ValidatingAdmissionPolicyBinding, validating.Validator](
		quietLogger{},
		validating.NewValidatingAdmissionPolicyAccessor,
		validating.NewValidatingAdmissionPolicyBindingAccessor,
		compile,
		func(a authorizer.Authorizer, m *matching.Matcher, _ kubernetes.Interface) generic.Dispatcher[validating.PolicyHook] {
			return validating.NewDispatcher(a, generic.NewPolicyMatcher(m))
		},
		[]runtime.Object{ns, rootCA},
		// The fake REST mapper knows ConfigMaps; the namespace lookup needs
		// Namespaces too.
		[]meta.RESTMapping{{
			Resource:         corev1.SchemeGroupVersion.WithResource("namespaces"),
			GroupVersionKind: corev1.SchemeGroupVersion.WithKind("Namespace"),
			Scope:            meta.RESTScopeRoot,
		}},
	)
	if err != nil {
		return nil, nil, err
	}
	if err := tc.Start(); err != nil {
		cancel()
		return nil, nil, err
	}
	if err := tc.UpdateAndWait(p, b); err != nil {
		cancel()
		return nil, nil, err
	}
	if got := len(tc.Source.Hooks()); got != 1 {
		cancel()
		return nil, nil, fmt.Errorf("%d policies bound, want 1", got)
	}
	return tc, cancel, nil
}

func dispatch(tc *testContext, scheme *runtime.Scheme, c testCase) error {
	gvk := c.obj.GroupVersionKind()
	gvr := schema.GroupVersionResource{Group: gvk.Group, Version: gvk.Version, Resource: plural(gvk.Kind)}
	op := admission.Create
	var old runtime.Object
	if c.old != nil {
		op = admission.Update
		old = c.old
	}
	attrs := admission.NewAttributesRecord(c.obj, old, gvk, c.obj.GetNamespace(), c.obj.GetName(), gvr, "", op, nil, false, &user.DefaultInfo{Name: c.as})
	ctx, cancel := context.WithTimeout(tc, 10*time.Second)
	defer cancel()
	return tc.Plugin.Dispatch(ctx, attrs, admission.NewObjectInterfacesFromScheme(scheme))
}

// defaultPolicy sets what the API server's defaulting sets on a stored
// ValidatingAdmissionPolicy (k8s.io/kubernetes pkg/apis/admissionregistration/
// v1/defaults.go), which the plugin then relies on: empty selectors, the
// Equivalent match policy, scope "*" on every rule.
func defaultPolicy(p *admissionregistrationv1.ValidatingAdmissionPolicy) {
	if p.Spec.FailurePolicy == nil {
		f := admissionregistrationv1.Fail
		p.Spec.FailurePolicy = &f
	}
	mc := p.Spec.MatchConstraints
	if mc == nil {
		return
	}
	if mc.NamespaceSelector == nil {
		mc.NamespaceSelector = &metav1.LabelSelector{}
	}
	if mc.ObjectSelector == nil {
		mc.ObjectSelector = &metav1.LabelSelector{}
	}
	if mc.MatchPolicy == nil {
		e := admissionregistrationv1.Equivalent
		mc.MatchPolicy = &e
	}
	for _, rules := range [][]admissionregistrationv1.NamedRuleWithOperations{mc.ResourceRules, mc.ExcludeResourceRules} {
		for i := range rules {
			if rules[i].Scope == nil {
				all := admissionregistrationv1.AllScopes
				rules[i].Scope = &all
			}
		}
	}
}

// refusedByPolicy is a refusal a policy's validation gave. A policy that
// failed to configure, compile or evaluate also refuses (failure policy
// Fail), and that must never read as a rule doing its work.
func refusedByPolicy(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	if !strings.Contains(s, "ValidatingAdmissionPolicy") || !strings.Contains(s, "denied request") {
		return false
	}
	for _, bad := range []string{"failed to configure", "resulted in error", "compil", "no such key", "evaluation", "cost", "budget"} {
		if strings.Contains(s, bad) {
			return false
		}
	}
	return true
}

// plural is the lower-case plural every VCO kind uses (Policy -> policies).
func plural(kind string) string {
	k := strings.ToLower(kind)
	if strings.HasSuffix(k, "y") {
		return strings.TrimSuffix(k, "y") + "ies"
	}
	return k + "s"
}

func decodeDocs(r io.Reader) ([]*unstructured.Unstructured, error) {
	dec := utilyaml.NewYAMLOrJSONDecoder(r, 4096)
	var out []*unstructured.Unstructured
	for {
		var m map[string]any
		if err := dec.Decode(&m); err != nil {
			if errors.Is(err, io.EOF) {
				return out, nil
			}
			return nil, err
		}
		if len(m) == 0 {
			continue
		}
		out = append(out, &unstructured.Unstructured{Object: m})
	}
}

func loadPolicies(path string) ([]*admissionregistrationv1.ValidatingAdmissionPolicy, []*admissionregistrationv1.ValidatingAdmissionPolicyBinding, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	docs, err := decodeDocs(f)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", path, err)
	}
	var ps []*admissionregistrationv1.ValidatingAdmissionPolicy
	var bs []*admissionregistrationv1.ValidatingAdmissionPolicyBinding
	for _, d := range docs {
		switch d.GetKind() {
		case "ValidatingAdmissionPolicy":
			p := &admissionregistrationv1.ValidatingAdmissionPolicy{}
			if err := runtime.DefaultUnstructuredConverter.FromUnstructuredWithValidation(d.Object, p, true); err != nil {
				return nil, nil, fmt.Errorf("policy %s: %w", d.GetName(), err)
			}
			// No TypeMeta: the test context files a typed policy under its own
			// fake kind, and only when the object names no kind itself.
			p.TypeMeta = metav1.TypeMeta{}
			defaultPolicy(p)
			ps = append(ps, p)
		case "ValidatingAdmissionPolicyBinding":
			b := &admissionregistrationv1.ValidatingAdmissionPolicyBinding{}
			if err := runtime.DefaultUnstructuredConverter.FromUnstructuredWithValidation(d.Object, b, true); err != nil {
				return nil, nil, fmt.Errorf("binding %s: %w", d.GetName(), err)
			}
			b.TypeMeta = metav1.TypeMeta{}
			bs = append(bs, b)
		}
	}
	return ps, bs, nil
}

func loadCases(dir, configNS string) ([]testCase, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var out []testCase
	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		c := testCase{file: filepath.Base(file), as: "kubernetes-admin"}
		sc := bufio.NewScanner(bytes.NewReader(raw))
		for sc.Scan() {
			line := sc.Text()
			for _, h := range []struct {
				prefix string
				dst    *string
			}{{"# want: ", &c.want}, {"# policy: ", &c.policy}, {"# what: ", &c.what}, {"# as: ", &c.as}} {
				if strings.HasPrefix(line, h.prefix) {
					*h.dst = strings.TrimSpace(strings.TrimPrefix(line, h.prefix))
				}
			}
		}
		if c.want != "admit" && c.want != "refuse" {
			return nil, fmt.Errorf("%s: want is %q, not admit or refuse", file, c.want)
		}
		if (c.want == "refuse") != (c.policy != "") {
			return nil, fmt.Errorf("%s: a refusal names its policy, an admission none (want %q, policy %q)", file, c.want, c.policy)
		}
		docs, err := decodeDocs(bytes.NewReader(raw))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", file, err)
		}
		if len(docs) < 1 || len(docs) > 2 {
			return nil, fmt.Errorf("%s: %d objects, want 1 (CREATE) or 2 (UPDATE: new, old)", file, len(docs))
		}
		for _, d := range docs {
			if d.GetNamespace() == "" {
				d.SetNamespace(configNS)
			}
			if d.GroupVersionKind().Group != group {
				return nil, fmt.Errorf("%s: %s is not a %s object", file, d.GroupVersionKind(), group)
			}
		}
		c.obj = docs[0]
		if len(docs) == 2 {
			c.old = docs[1]
		}
		out = append(out, c)
	}
	return out, nil
}
