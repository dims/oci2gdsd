package main

import (
	"context"
	"os"

	"github.com/dims/oci2gdsd/internal/app"
)

func main() {
	code := app.Run(context.Background(), os.Args[1:], os.Stdout, os.Stderr)
	os.Exit(code)
}
