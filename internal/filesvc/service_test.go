package filesvc

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadWriteList(t *testing.T) {
	s := New(t.TempDir())

	if err := s.Write("a/b.txt", []byte("content")); err != nil {
		t.Fatal(err)
	}
	data, err := s.Read("a/b.txt")
	if err != nil || string(data) != "content" {
		t.Fatalf("read = %q err=%v", data, err)
	}

	// parent dirs auto-created on write
	if _, err := os.Stat(filepath.Join(s.Root(), "a")); err != nil {
		t.Fatal(err)
	}

	isDir, entries, err := s.List("a")
	if err != nil || !isDir || len(entries) != 1 || entries[0].Path != "a/b.txt" {
		t.Fatalf("list dir: %v %v err=%v", isDir, entries, err)
	}

	isDir, entries, err = s.List("a/b.txt")
	if err != nil || isDir || len(entries) != 1 {
		t.Fatalf("list file: %v %v err=%v", isDir, entries, err)
	}
}

func TestContainment(t *testing.T) {
	s := New(t.TempDir())

	if _, err := s.Read("../../etc/passwd"); err == nil {
		t.Error("traversal read must fail")
	}
	if err := s.Write("/tmp/escape.txt", []byte("x")); err == nil {
		t.Error("absolute escape write must fail")
	}
	// symlink escape
	outside := t.TempDir()
	link := filepath.Join(s.Root(), "link")
	if err := os.Symlink(outside, link); err == nil {
		if _, err := s.Read("link/whatever"); err == nil {
			t.Error("symlink escape must fail")
		}
	}
}
