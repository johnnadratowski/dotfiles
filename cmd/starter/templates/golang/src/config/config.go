package config

import (
	"fmt"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Config is a single configuration
type Config struct {
	Name        string
	Value       string
	Description string
	Required    bool
	Type        func(string) string
}

// Configs is a list of all configurations
type Configs []*Config

func (c Configs) get(key string) (*Config, bool) {
	for _, c := range configs {
		if strings.ToLower(c.Name) == strings.ToLower(key) {
			return c, true
		}
	}
	return &Config{}, false
}

var configs Configs

func envDefault(name string, def string) (x string, found bool) {
	x = os.Getenv(strings.ToUpper(name))
	found = x == ""
	if found {
		x = def
	}
	return
}

// IsTrue returns true if a config is truthy
func IsTrue(key string, def bool) (x bool) {
	key = strings.ToLower(key)
	conf, _ := configs.get(key)
	val := strings.ToLower(conf.Value)
	if val[0] == 'y' || val[0] == '1' || val[0] == 't' {
		x = true
	} else if val[0] == 'n' || val[0] == '0' || val[0] == 'f' {
		x = false
	} else {
		x = def
	}
	return
}

// Get Retrieves a configuration value
func Get(key string) string {
	conf, _ := configs.get(key)
	return conf.Value
}

// GetLower Retrieves a configuration value, but lowercases the string before returning
func GetLower(key string) string {
	conf, _ := configs.get(key)
	return strings.ToLower(conf.Value)
}

// GetDefault Retrieves a configuration value, if not found, return default
func GetDefault(key string, def string) string {
	conf, found := configs.get(key)
	if !found {
		return def
	}

	return conf.Value
}

// GetDefaultLower a configuration value, if not found return default,
// but lowercases the string before returning
func GetDefaultLower(key string, def string) string {
	return strings.ToLower(GetDefault(key, def))
}

// GetInt Retrieves an integer configuration value
func GetInt(key string) int {
	conf, _ := configs.get(key)
	val, err := strconv.Atoi(conf.Value)
	if err != nil {
		panic("Invalid format for integer config value: " + key)
	}
	return val
}

// GetInt64 Retrieves a 64 bit integer configuration value
func GetInt64(key string) int64 {
	conf, _ := configs.get(key)
	val, err := strconv.ParseInt(conf.Value, 10, 64)
	if err != nil {
		panic("Invalid format for integer config value: " + key)
	}
	return val
}

// GetFloat Retrieves a float configuration value
func GetFloat(key string) float64 {
	conf, _ := configs.get(key)
	val, err := strconv.ParseFloat(conf.Value, 64)
	if err != nil {
		panic("Invalid format for integer config value: " + key)
	}
	return val
}

// All Gets a copy of all of the configuration values
func All() (c Configs) {
	return configs
}

// Description gets a description of all the configs
func Description() string {
	lines := make([]string, len(configs))

	for i, conf := range configs {
		val := conf.Value
		req := ""
		if conf.Required {
			req = "REQUIRED: "
		}
		lines[i] = fmt.Sprintf(`%s="%s" # %s%s`, strings.ToUpper(conf.Name), val, req, conf.Description)
	}

	return strings.Join(lines, "\n")
}

// Log Logs the configuration of the application
func Log() {
	keys := []string{}
	for _, conf := range configs {
		keys = append(keys, conf.Name)
	}

	sort.Strings(keys)

	output := make([]string, len(keys))
	for idx, key := range keys {
		output[idx] = fmt.Sprintf("\t%s:    %s", key, Get(key))
	}

	log.Println("\n\nConfigurations:\n\n", strings.Join(output, "\n"), "\n\n")
}

// IsDevEnv returns true if the current environment is dev
func IsDevEnv() bool {
	return Get("env") == "dev"
}

// IsProdEnv returns true if the current environment is prod
func IsProdEnv() bool {
	return Get("env") == "prod"
}

// Initialize initilizes the config
func Initialize(c []Config) {
	if IsInitialized() {
		panic("Cannot initialize configuration twice")
	}
	configs = make(Configs, len(c))

	for i, cVal := range c {
		conf := &cVal

		if conf.Name == "" || conf.Description == "" {
			panic("Configurations must all define Name and Description")
		}

		val, found := envDefault(conf.Name, conf.Value)
		if !found && conf.Required {
			panic(fmt.Sprintf("Missing required configuration: %s", conf.Name))
		}

		if conf.Type != nil {
			val = conf.Type(val)
		}

		conf.Value = val

		configs[i] = conf
	}
}

// IsInitialized returns true if configs were initialized
func IsInitialized() bool {
	return len(configs) > 0
}
