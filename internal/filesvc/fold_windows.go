//go:build windows

package filesvc

import "strings"

// trimDevicePrefix drops the extended-length device prefix Windows APIs (and
// EvalSymlinks) may return: \\?\C:\... and \\.\C:\...
func trimDevicePrefix(p string) string {
	if strings.HasPrefix(p, `\\?\`) || strings.HasPrefix(p, `\\.\`) {
		return p[4:]
	}
	return p
}

// pathEqual: Windows filesystems are case-insensitive by default.
func pathEqual(a, b string) bool { return strings.EqualFold(a, b) }

// hasRootPrefix: p is strictly inside root (case-insensitive).
func hasRootPrefix(p, root string) bool {
	return strings.HasPrefix(strings.ToLower(p), strings.ToLower(root+`\`))
}
