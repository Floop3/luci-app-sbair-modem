// SPDX-License-Identifier: MIT
// Copyright (c) 2026 soralis0912

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// 時間のかかる処理の共通の足回り。

type jobState struct {
	State   string   `json:"state"` // running / done / error
	Step    string   `json:"step"`
	Message string   `json:"message,omitempty"`
	Started string   `json:"started,omitempty"`
	Target  int      `json:"target,omitempty"`  // simmap 用
	Mapping int      `json:"mapping,omitempty"` // simmap 用
	Stages  []string `json:"stages,omitempty"`  // download 用
}

type job struct {
	name  string // simmap / download
	state jobState
}

var jobExecutable = os.Executable

func jobPath(name string) string     { return filepath.Join(runtimeDir(), "jobs", name+".json") }
func jobLockPath(name string) string { return filepath.Join(runtimeDir(), "jobs", name+".lock") }

func newJob(name string) *job {
	return &job{name: name, state: jobState{
		State: "running", Step: "起動", Started: time.Now().Format(time.RFC3339),
	}}
}

func (j *job) write() error {
	b, err := json.Marshal(j.state)
	if err != nil {
		return err
	}
	return atomicWritePrivate(jobPath(j.name), b, 0600)
}

func (j *job) step(s string) {
	j.state.Step = s
	j.write()
}

func (j *job) fail(step, msg string) int {
	j.state.State, j.state.Step, j.state.Message = "error", step, msg
	j.write()
	return 1
}

func (j *job) done(step, msg string) int {
	j.state.State, j.state.Step, j.state.Message = "done", step, msg
	j.write()
	return 0
}

func readJob(name string) map[string]any {
	if info, err := os.Lstat(jobPath(name)); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular()) {
		return map[string]any{"state": "idle"}
	}
	b, err := os.ReadFile(jobPath(name))
	if err != nil {
		return map[string]any{"state": "idle"}
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return map[string]any{"state": "idle"}
	}
	return m
}

// startJob spawns a detached copy of this program to run the work.
//
// **rpcd kills the process group when the ubus call returns**, so the worker
// has to leave it (Setsid). Without that a switch would be cut off partway -
// and partway means the radio is off and the mapping may already have changed.
func startJob(name string, args ...string) map[string]any {
	if err := ensurePrivateDir(filepath.Join(runtimeDir(), "jobs")); err != nil {
		return map[string]any{"error": fmt.Sprintf("ジョブ実行領域を安全に準備できません: %v", err)}
	}
	// Wait for the short status/write/spawn critical section. Once the first
	// caller releases it, the second caller reads the durable running state and
	// returns the useful "already running" result instead of a misleading lock
	// error.
	lock, err := acquireRuntimeLock(jobLockPath(name), 5*time.Second)
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("ジョブを開始できません: %v", err)}
	}
	defer lock.close()

	if cur := readJob(name); cur["state"] == "running" {
		return map[string]any{"error": "すでに実行中です", "state": "running"}
	}
	self, err := jobExecutable()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("自分の場所が分かりません: %v", err)}
	}

	j := newJob(name)
	if err := j.write(); err != nil {
		return map[string]any{"error": fmt.Sprintf("ジョブ状態を保存できません: %v", err)}
	}

	argv := append([]string{"-d", *device, name + "-worker"}, args...)
	cmd := exec.Command(self, argv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Start(); err != nil {
		_ = j.fail("起動", err.Error())
		return map[string]any{"error": fmt.Sprintf("ワーカーを起動できません: %v", err)}
	}
	go func() { _ = cmd.Wait() }()

	return map[string]any{"result": "started"}
}
