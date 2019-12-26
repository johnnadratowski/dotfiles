#!/usr/bin/python
import asyncio
import pprint
import requests
import sys

# Create an event loop to run all of the calls in parallel
LOOP = asyncio.get_event_loop()

# Create a coroutine to get all of the extracts
@asyncio.coroutine
def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    extracts = []
    tasks = []
    for idx, page in enumerate(pages_list):
        tasks.append(get_extract(idx, page['title'], page['id']))
    extracts = yield from asyncio.gather(*tasks)
    return extracts

# Create a coroutine to get a single extract
@asyncio.coroutine
def get_extract(idx, title, id_):
    print("RUNNING EVENT LOOP %s" % idx)
    print("GETTING PAGE %s EXTRACT" % str(idx))
    # Run the request in an executor, allowing it to run in parallel,
    # since requests lib doesn't suport asyncio
    future = LOOP.run_in_executor(None, requests.get, 'https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(title))
    # get the content of the future object when the async finally runs
    content = yield from future
    data = content.json()
    print("FINISHED PAGE %s EXTRACT" % str(idx))
    print("FINISHED EVENT LOOP %s" % idx)
    return {'id': id_, 'title': title, 'extract': data['query']['pages'][str(id_)]['extract']}

def get_pages(limit=5):
    pages = requests.get('https://en.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&format=json&rnlimit='+str(limit))
    return pages.json()

if __name__ == "__main__":
    import time
    start = time.time()
    limit = 10
    if len(sys.argv) > 1:
        limit = sys.argv[1]
    # Run the event loop until all tasks are complete
    extracts = LOOP.run_until_complete(get_extracts(limit=limit))
    pprint.pprint(extracts)

    print("TOTAL TIME: ", time.time() - start)
