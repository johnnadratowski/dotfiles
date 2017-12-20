package cmd

import (
	"fmt"

	"github.com/urfave/cli"
)

var (
	Version        string
	BuildTimestamp string
	GitHash        string
)

var VersionCmd cli.Command = cli.Command{
	Name:  "version",
	Usage: "Output version info",
	Action: func(c *cli.Context) {
		if Version == "" {
			fmt.Printf("Binary not built with version information.")
		} else {
			fmt.Printf("Version: %s\nBuild Timestamp: %s\nGit Hash: %s\n", Version, BuildTimestamp, GitHash)
		}
	},
}
