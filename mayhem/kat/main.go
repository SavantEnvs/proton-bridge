// mayhem/kat/main.go — dynamically-linked known-answer probe for proton-bridge's
// message/MIME/RFC822 parser. `import "C"` (cgo) forces a DYNAMICALLY LINKED
// binary so the LD_PRELOAD sabotage shim used by the gate's anti-reward-hacking
// check can neuter it (a statically-linked Go binary would be immune, giving a
// false-green oracle — exactly the trap netnew §4 warns about with `go test`
// alone).
//
// It imports the build-time-staged internal package (created by mayhem/build.sh
// at _mayhem_harness/parser) and runs KATParse(), which parses a fixed RFC822
// message through the real parser.New decode path, then prints the parsed
// header/body fields in a fixed, greppable format for mayhem/test.sh to assert.
package main

// #include <stdint.h>
import "C"

import (
	"fmt"
	"os"

	parser "github.com/ProtonMail/proton-bridge/v3/_mayhem_harness/parser"
)

func main() {
	ctype, charset, subject, body, err := parser.KATParse()
	if err != nil {
		fmt.Fprintf(os.Stderr, "KAT error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_CTYPE=%s\n", ctype)
	fmt.Printf("KAT_CHARSET=%s\n", charset)
	fmt.Printf("KAT_SUBJECT=%s\n", subject)
	fmt.Printf("KAT_BODY=%s\n", body)
}
