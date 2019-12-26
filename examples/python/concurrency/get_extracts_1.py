#!/usr/bin/python
import pprint
import requests
import sys

def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    extracts = []
    for idx, page in enumerate(pages_list):
        extracts.append(get_extract(idx, page['title'], page['id']))
    return extracts

def get_extract(idx, title, id_):
    print("GETTING PAGE %s EXTRACT" % str(idx))
    content = requests.get('https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(title))
    data = content.json()
    return {'id': id_, 'title': title, 'extract': data['query']['pages'][str(id_)]['extract']}
    print("FINISHED PAGE %s EXTRACT" % str(idx))

def get_pages(limit=5):
    pages = requests.get('https://en.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&format=json&rnlimit='+str(limit))
    return pages.json()

if __name__ == "__main__":
    import time
    start = time.time()
    limit = 10
    if len(sys.argv) > 1:
        limit = sys.argv[1]
    if len(sys.argv) > 2:
        pprint.pprint(get_extract(0, sys.argv[1], sys.argv[2]))
    else:
        extracts = get_extracts(limit=limit)
        pprint.pprint(extracts)

    print("TOTAL TIME: ", time.time() - start)
