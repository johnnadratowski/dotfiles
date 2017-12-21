package main

import (
	"os"
	"{{IMPORT_PATH}}/cmd"
	"github.com/urfave/cli"
)

func main() {
	cli.VersionPrinter = cmd.VersionCmd.Action.(func(c *cli.Context))

	app := cli.NewApp()
	app.Name = "{{PROJECT_NAME}}"
	app.Usage = "{{DESCRIPTION}}"
	app.Version = cmd.Version
	app.EnableBashCompletion = true
	app.Commands = []cli.Command{
		cmd.VersionCmd,
	}
	app.Run(os.Args)
}
