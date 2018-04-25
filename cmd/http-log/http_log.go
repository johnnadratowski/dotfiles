//usr/bin/env go run $0 $@; exit $?
package main

import (
	"encoding/json"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"time"
)

type Response struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

func main() {

	cnt := 0
	logger := log.New(os.Stdout, "", log.LstdFlags)
	logger.Println("Server is starting...")

	server := &http.Server{
		Addr: os.Getenv("ADDR"),
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			params := r.URL.Query()
			respData := params.Get("_server_response")
			params.Del("_server_response")
			resp := Response{Status: 200}
			if len(respData) > 0 {
				err := json.Unmarshal([]byte(respData), &resp)
				if err != nil {
					log.Println(":: ERROR: Error occurred parsing server response param " + respData)
					return
				}
			}

			body, err := ioutil.ReadAll(r.Body)
			if err != nil {
				log.Println("Error reading body: " + err.Error())
				return
			}

			logger.Printf(
				":: REQUEST[%d]:\n\n[%s] %s\n\nParams:\n\t%#v\n\n"+
					"Headers:\n\t%#v\n\nBody:\n\t%s\n\nResponse:\n\t%#v",
				cnt, r.Method, r.URL.Path, params, r.Header, body, resp)

			if len(resp.Headers) > 0 {
				for k, v := range resp.Headers {
					w.Header().Add(k, v)
				}
			}
			w.WriteHeader(resp.Status)
			if len(resp.Body) > 0 {
				w.Write([]byte(resp.Body))
			}

			cnt++
		}),
		ErrorLog:     logger,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
		IdleTimeout:  2 * time.Second,
	}

	logger.Println("Server is ready to handle requests at", os.Getenv("ADDR"))
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("Could not listen on %s: %v\n", os.Getenv("ADDR"), err)
	}
}
