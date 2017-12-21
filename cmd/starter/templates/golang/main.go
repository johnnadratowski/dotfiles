package main

import (
	"fmt"
	"os"
	"{{IMPORT_PATH}}/src/cmd"
	"{{IMPORT_PATH}}/src/config"
	"github.com/urfave/cli"
)

func init() {
	config.Initialize([]config.Config{
		config.Config{
			Name: "EXAMPLE",
			Value: "DefaultValue",
			Description: "Example Description",
			Required: false,
			Type: func (s string) string { return "Hi, " + s },
		},
	})
}

func main() {
	cli.VersionPrinter = cmd.VersionCmd.Action.(func(c *cli.Context))

	app := cli.NewApp()
	app.Name = "{{PROJECT_NAME}}"
	app.Usage = fmt.Sprintf(`{{DESCRIPTION}}

	# Configurations (ENV Vars - Should be in Uppercase)

	%s
	`, config.Description())
	app.Version = cmd.Version
	app.EnableBashCompletion = true
	app.Commands = []cli.Command{
		cmd.VersionCmd,
	}

	config.Log()
	app.Run(os.Args)
}
