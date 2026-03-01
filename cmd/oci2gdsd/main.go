package main

import (
	"context"
	"os"

	"github.com/dims/oci2gdsd/internal/cli"
)

func main() {
	code := cli.Run(context.Background(), os.Args[1:], os.Stdout, os.Stderr)
	os.Exit(code)
}
