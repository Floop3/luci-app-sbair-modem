// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

// Small, shared primitives for files which are written by rpcd workers.  The
// backend is normally started as root on OpenWrt; keeping the owner check tied
// to the current uid also makes the same checks usable by unprivileged host
// fixtures without weakening the root production path.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const defaultRuntimeDir = "/var/run/sbair"

var (
	ErrLockUnavailable = errors.New("sbair runtime lock unavailable")
	ErrLockBusy        = errors.New("sbair runtime lock busy")
)

func runtimeDir() string {
	if value := os.Getenv("SBAIR_RUNTIME_DIR"); value != "" {
		return filepath.Clean(value)
	}
	return defaultRuntimeDir
}

func fileOwnerUID(info os.FileInfo) (uint32, bool) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return st.Uid, true
}

// ensurePrivateDir creates or tightens a runtime directory and rejects a
// symlink/non-directory replacement.  On the real device this process is root,
// therefore requiring the current uid to own the directory is equivalent to
// requiring root ownership there.
func ensurePrivateDir(path string) error {
	path = filepath.Clean(path)
	if err := os.MkdirAll(path, 0700); err != nil {
		return fmt.Errorf("create private directory %s: %w", path, err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("stat private directory %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("private directory %s is not a directory", path)
	}
	if err := os.Chmod(path, 0700); err != nil {
		return fmt.Errorf("tighten private directory %s: %w", path, err)
	}
	info, err = os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("private directory %s changed while opening", path)
	}
	if info.Mode().Perm() != 0700 {
		return fmt.Errorf("private directory %s has mode %04o", path, info.Mode().Perm())
	}
	uid, ok := fileOwnerUID(info)
	if ok && int(uid) != os.Getuid() {
		return fmt.Errorf("private directory %s is owned by uid %d", path, uid)
	}
	return nil
}

func ensureRuntimeDir() error {
	return ensurePrivateDir(runtimeDir())
}

func secureRuntimePath(path string, mode os.FileMode) (*os.File, error) {
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("runtime file %s is not a regular file", path)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat runtime file %s: %w", path, err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return nil, fmt.Errorf("open runtime file %s: %w", path, err)
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("stat runtime file %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, fmt.Errorf("runtime file %s is not a regular file", path)
	}
	if uid, ok := fileOwnerUID(info); ok && int(uid) != os.Getuid() {
		_ = f.Close()
		return nil, fmt.Errorf("runtime file %s is owned by uid %d", path, uid)
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return nil, fmt.Errorf("chmod runtime file %s: %w", path, err)
	}
	info, err = f.Stat()
	if err != nil || info.Mode().Perm() != mode.Perm() {
		_ = f.Close()
		if err != nil {
			return nil, fmt.Errorf("restat runtime file %s: %w", path, err)
		}
		return nil, fmt.Errorf("runtime file %s has mode %04o", path, info.Mode().Perm())
	}
	return f, nil
}

// secureExistingRuntimeFile tightens an already-created runtime sidecar
// without creating a new one. O_NOFOLLOW is applied to the file descriptor,
// so a replacement race cannot turn chmod into a write through a symlink.
func secureExistingRuntimeFile(path string, mode os.FileMode) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("runtime file %s is not a regular file", path)
	}
	f, err := os.OpenFile(path, os.O_RDWR|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err = f.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("runtime file %s is not a regular file", path)
	}
	if uid, ok := fileOwnerUID(info); ok && int(uid) != os.Getuid() {
		return fmt.Errorf("runtime file %s is owned by uid %d", path, uid)
	}
	if err := f.Chmod(mode); err != nil {
		return err
	}
	info, err = f.Stat()
	if err != nil {
		return err
	}
	if info.Mode().Perm() != mode.Perm() {
		return fmt.Errorf("runtime file %s has mode %04o", path, info.Mode().Perm())
	}
	return nil
}

// atomicWritePrivate writes a complete file in the already-private directory
// and replaces the final name without ever following it.
func atomicWritePrivate(path string, data []byte, mode os.FileMode) error {
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".sbair-tmp-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	// Rename replaces a symlink at path; it does not follow the symlink.  This
	// is the property needed for predictable runtime names.
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	cleanup = false
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("runtime file %s is not a regular file after replace", path)
	}
	if info.Mode().Perm() != mode.Perm() {
		return fmt.Errorf("runtime file %s has mode %04o after replace", path, info.Mode().Perm())
	}
	return nil
}

type runtimeLock struct {
	file *os.File
}

func acquireRuntimeLock(path string, timeout time.Duration) (*runtimeLock, error) {
	f, err := secureRuntimePath(path, 0600)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrLockUnavailable, err)
	}
	deadline := time.Now().Add(timeout)
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &runtimeLock{file: f}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			_ = f.Close()
			return nil, fmt.Errorf("%w: flock %s: %v", ErrLockUnavailable, path, err)
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("%w: flock timeout %s", ErrLockBusy, path)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (l *runtimeLock) close() error {
	if l == nil || l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}
