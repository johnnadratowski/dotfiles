#!/usr/bin/python
import pprint
import requests
import sys
from multiprocessing import Process, Queue

def get_extract(extracts, idx, title, id):
    print("RUNNING PROCESS %s" % idx)
    print("GETTING PAGE %s EXTRACT" % idx)
    content = requests.get('https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(title))
    data = content.json()
    extract = {'title': title, 'extract': data['query']['pages'][str(id)]['extract']}
    print("FINISHED PAGE %s EXTRACT" % idx)
    extracts.put(extract)
    print("FINISHED PROCESS %s" % idx)

def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    procs = []
    # Create a shared memory queue to pass data from process. NOTE: Queue is thread-safe
    extracts = Queue(limit)
    for idx, page in enumerate(pages_list):
        # Create process passing queue
        proc = Process(target=get_extract, args=(extracts, idx, page['title'], page['id']))
        # Start process
        proc.start()
        procs.append(proc)

    for proc in procs:
        proc.join()

    return extracts

def get_pages(limit=5):
    pages = requests.get('https://en.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&format=json&rnlimit='+str(limit))
    return pages.json()

if __name__ == "__main__":
    import time
    start = time.time()
    limit = 10
    if len(sys.argv) > 1:
        limit = sys.argv[1]
    try:
        extracts = get_extracts(limit=limit)
        all_extracts = []
        # Consume all data from queue for output
        while not extracts.empty():
            all_extracts.append(extracts.get())
        pprint.pprint(all_extracts)
    except:
        import traceback
        traceback.print_exc()

    print("TOTAL TIME: ", time.time() - start)
