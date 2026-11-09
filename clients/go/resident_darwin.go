package glass

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// residentBytes is the process's resident set, in the units ps reports.
func residentBytes() (uint64, bool) {
	out, err := exec.Command("/bin/ps", "-o", "rss=", "-p", strconv.Itoa(os.Getpid())).Output()
	if err != nil {
		return 0, false
	}
	kb, err := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0, false
	}
	return kb * 1024, true
}
