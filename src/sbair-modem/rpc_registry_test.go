// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
)

type rpcACL struct {
	Read  rpcACLMethods `json:"read"`
	Write rpcACLMethods `json:"write"`
}

type rpcACLMethods struct {
	Ubus map[string][]string `json:"ubus"`
}

func TestRPCRegistryMatchesCheckedInACL(t *testing.T) {
	_, sourcePath, _, ok := runtimeCallerForRPCRegistryTest()
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	aclPath := filepath.Join(filepath.Dir(sourcePath), "..", "..", "root", "usr", "share", "rpcd", "acl.d", "luci-app-sbair-modem.json")
	raw, err := os.ReadFile(aclPath)
	if err != nil {
		t.Fatalf("read ACL: %v", err)
	}
	var document map[string]rpcACL
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatalf("decode ACL: %v", err)
	}
	acl, ok := document["luci-app-sbair-modem"]
	if !ok {
		t.Fatal("ACL object is missing")
	}
	read := make(map[string]bool)
	write := make(map[string]bool)
	for _, name := range acl.Read.Ubus["sbair"] {
		read[name] = true
	}
	for _, name := range acl.Write.Ubus["sbair"] {
		write[name] = true
	}
	for name, spec := range rpcRegistry {
		if spec.Access != rpcRead && spec.Access != rpcWrite {
			t.Errorf("%s has invalid access %q", name, spec.Access)
		}
		if spec.Access == rpcRead && !read[name] {
			t.Errorf("registry read method %q is absent from ACL read set", name)
		}
		if spec.Access == rpcWrite && !write[name] {
			t.Errorf("registry write method %q is absent from ACL write set", name)
		}
	}
	for name := range read {
		if spec, ok := rpcRegistry[name]; !ok || spec.Access != rpcRead {
			t.Errorf("ACL read method %q is absent or not read in registry", name)
		}
	}
	for name := range write {
		if spec, ok := rpcRegistry[name]; !ok || spec.Access != rpcWrite {
			t.Errorf("ACL write method %q is absent or not write in registry", name)
		}
	}
	for name := range read {
		if write[name] {
			t.Errorf("method %q appears in both ACL access sets", name)
		}
	}
}

// Kept as a tiny wrapper so the test's source lookup stays readable without
// importing runtime into production code.
func runtimeCallerForRPCRegistryTest() (uintptr, string, int, bool) {
	return runtime.Caller(0)
}

func TestRPCRegistryMethodsHaveDispatchCases(t *testing.T) {
	_, sourcePath, _, ok := runtimeCallerForRPCRegistryTest()
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	file, err := parser.ParseFile(token.NewFileSet(), filepath.Join(filepath.Dir(sourcePath), "rpcd.go"), nil, 0)
	if err != nil {
		t.Fatalf("parse rpcd.go: %v", err)
	}
	dispatch := make(map[string]bool)
	ast.Inspect(file, func(node ast.Node) bool {
		caseClause, ok := node.(*ast.CaseClause)
		if !ok {
			return true
		}
		for _, expr := range caseClause.List {
			literal, ok := expr.(*ast.BasicLit)
			if !ok || literal.Kind != token.STRING {
				continue
			}
			name, err := strconv.Unquote(literal.Value)
			if err == nil {
				dispatch[name] = true
			}
		}
		return true
	})
	for name := range rpcRegistry {
		if !dispatch[name] {
			t.Errorf("registry method %q has no rpcdCall dispatch case", name)
		}
	}
}
