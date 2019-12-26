#!/usr/bin/python
import pprint
import requests
import sys
from multiprocessing import Process, Pipe

def get_extract(conn, idx, title, id):
    print("RUNNING PROCESS %s" % idx)
    print("GETTING PAGE %s EXTRACT" % idx)
    content = requests.get('https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(title))
    data = content.json()
    extract = {'title': title, 'extract': data['query']['pages'][str(id)]['extract']}
    print("FINISHED PAGE %s EXTRACT" % idx)
    conn.send(extract)
    conn.close()
    print("FINISHED PROCESS %s" % idx)

def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    procs = []
    pipes = []
    for idx, page in enumerate(pages_list):
        # Create pipe for sending data back/forth from process
        recv, send = Pipe()
        # Send pipe to child process to communicate
        proc = Process(target=get_extract, args=(send, idx, page['title'], page['id']))
        # Start process
        proc.start()
        procs.append(proc)
        pipes.append(recv)

    # Get all of the data from all of the pipes. NOTE: recv is blocking!
    extracts = []
    for pipe in pipes:
        extracts.append(pipe.recv())

    # Ensure processes finish
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
    except:
        import traceback
        traceback.print_exc()
    pprint.pprint(extracts)

    print("TOTAL TIME: ", time.time() - start)
