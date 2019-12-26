package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/kr/pretty"
)

func main() {
	start := time.Now()

	pages, err := getPages(5)
	if err != nil {
		log.Fatalf("An error occurred getting pages: %s", err)
	}

	pagesQuery := pages["query"].(map[string]interface{})
	pagesList := pagesQuery["random"].([]interface{})

	extractChan := make(chan interface{}, 5)
	for idx, pageInt := range pagesList {
		page := pageInt.(map[string]interface{})
		id := page["id"].(float64)
		title := page["title"].(string)
		idStr := strconv.FormatFloat(id, 'f', -1, 64)
		go getExtract(idx, idStr, title, extractChan)
	}

	extracts := make([]map[string]interface{}, 5)
	for idx := range extracts {
		select {
		case output := <-extractChan:
			switch out := output.(type) {
			case error:
				log.Fatalf("An error occurred getting extracts: %s", out)
			case map[string]interface{}:
				extracts[idx] = out
			}
		}
	}

	pretty.Log(extracts)
	elapsed := time.Since(start)
	log.Printf("Elapsed Time: %s\n", elapsed)
}

func getExtract(idx int, id string, title string, c chan interface{}) {
	fmt.Printf("Getting page %d extract\n", idx)
	resp, err := http.Get("https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles=" + strings.Replace(title, " ", "_", -1))
	if err != nil {
		c <- err
		return
	}

	var extractData map[string]interface{}
	err = json.NewDecoder(resp.Body).Decode(&extractData)
	if err != nil {
		c <- err
		return
	}

	extractQuery := extractData["query"].(map[string]interface{})
	extractPages := extractQuery["pages"].(map[string]interface{})
	extractPageID := extractPages[id].(map[string]interface{})
	extract := extractPageID["extract"].(string)

	c <- map[string]interface{}{
		"id":      id,
		"title":   title,
		"extract": extract,
	}
	fmt.Printf("Finished page %d extract\n", idx)
	return
}

func getPages(limit int) (map[string]interface{}, error) {
	resp, err := http.Get("https://en.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&format=json&rnlimit=" + strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}

	var pages map[string]interface{}
	err = json.NewDecoder(resp.Body).Decode(&pages)
	if err != nil {
		return nil, err
	}
	return pages, nil
}
