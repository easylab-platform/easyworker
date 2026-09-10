//go:build !windows

package filesvc

// trimDevicePrefix: no device prefixes on unix.
func trimDevicePrefix(p string) string { return p }

// pathEqual: exact comparison on case-sensitive filesystems.
func pathEqual(a, b string) bool { return a == b }

// hasRootPrefix: p is strictly inside root.
func hasRootPrefix(p, root string) bool {
	return len(p) > len(root) && p[:len(root)] == root && p[len(root)] == '/'
}
