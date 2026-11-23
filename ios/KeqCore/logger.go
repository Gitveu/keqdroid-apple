package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	logMaxBytes      = 512 * 1024
	logKeepTailBytes = 256 * 1024
)

const (
	lvlDebug = 0
	lvlInfo  = 1
	lvlWarn  = 2
	lvlError = 3
	lvlNone  = 4
)

func parseLogLevel(s string) int {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return lvlDebug
	case "info":
		return lvlInfo
	case "warning", "warn":
		return lvlWarn
	case "error":
		return lvlError
	case "none", "silent":
		return lvlNone
	default:
		return lvlWarn
	}
}

// isServerDialFailure mirrors CoreDialFailures.isServerDialFailure in Dart
// and is_server_dial_failure in Android forkexec.c so auto-select watchdog
// reacts identically on iOS.
func isServerDialFailure(line string) bool {
	if strings.Contains(line, "failed to find an available destination") {
		return true
	}
	if idx := strings.Index(line, "splithttp: "); idx >= 0 {
		what := line[idx+len("splithttp: "):]
		if strings.HasPrefix(what, "failed to create") {
			return false
		}
		return strings.HasPrefix(what, "failed to ") ||
			strings.HasPrefix(what, "unexpected status ")
	}
	if idx := strings.Index(line, "[TCP] dial "); idx >= 0 {
		if !strings.Contains(line, " error: ") {
			return false
		}
		target := line[idx+len("[TCP] dial "):]
		return !strings.HasPrefix(target, "DIRECT") && !strings.HasPrefix(target, "REJECT")
	}
	if strings.Contains(line, "open connection to ") && strings.Contains(line, " using outbound/") {
		return !strings.Contains(line, "outbound/direct[") &&
			!strings.Contains(line, "outbound/block[")
	}
	return false
}

type coreLogWriter struct {
	mu        sync.Mutex
	path      string
	threshold int
	file      *os.File
	written   int64
	dialFails atomic.Int64
}

func newCoreLogWriter(path, level string) *coreLogWriter {
	w := &coreLogWriter{
		path:      path,
		threshold: parseLogLevel(level),
	}
	if path != "" {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err == nil {
			w.file = f
		}
	}
	return w
}

func (w *coreLogWriter) WriteLine(severity int, line string) {
	if isServerDialFailure(line) {
		w.dialFails.Add(1)
	}
	if severity < w.threshold {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return
	}
	ts := time.Now().Format("2006/01/02 15:04:05")
	out := fmt.Sprintf("%s %s\n", ts, strings.TrimRight(line, "\r\n"))
	n, err := w.file.WriteString(out)
	if err != nil {
		return
	}
	w.written += int64(n)
	if w.written > logMaxBytes {
		w.trimLocked()
	}
}

func (w *coreLogWriter) trimLocked() {
	if w.file == nil || w.path == "" {
		return
	}
	_ = w.file.Close()
	w.file = nil
	data, err := os.ReadFile(w.path)
	if err == nil && len(data) > logKeepTailBytes {
		tail := data[len(data)-logKeepTailBytes:]
		if nl := strings.IndexByte(string(tail), '\n'); nl >= 0 && nl+1 < len(tail) {
			tail = tail[nl+1:]
		}
		_ = os.WriteFile(w.path, tail, 0644)
		w.written = int64(len(tail))
	} else {
		w.written = int64(len(data))
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		w.file = f
	}
}

func (w *coreLogWriter) DialFailures() int64 {
	if w == nil {
		return 0
	}
	return w.dialFails.Load()
}

func (w *coreLogWriter) Close() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file != nil {
		_ = w.file.Close()
		w.file = nil
	}
}
