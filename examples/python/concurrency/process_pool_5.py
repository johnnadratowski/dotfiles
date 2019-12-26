#!/usr/bin/python
import pprint
import requests
import sys
from multiprocessing import Pool

def get_extract(idx, title, id):
    print("RUNNING PROCESS %s" % idx)
    print("GETTING PAGE %s EXTRACT" % idx)
    content = requests.get('https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(title))
    data = content.json()
    extract = {'title': title, 'extract': data['query']['pages'][str(id)]['extract']}
    print("FINISHED PAGE %s EXTRACT" % idx)
    print("FINISHED PROCESS %s" % idx)
    return extract

def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    print("CREATING POOL")
    # Create a pool of processes to pick up stuff
    pool = Pool(limit)
    print("POOL CREATED")
    extracts = []
    for idx, page in enumerate(pages_list):
        args = (idx, page['title'], page['id'])
        # Apply the function asynchronously to the pool - NON BLOCKING
        extracts.append(pool.apply_async(get_extract, args))

    pool.close()
    pool.join()

    return extracts

def get_pages(limit=5):
    pages = requests.get('https://en.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&format=json&rnlimit='+str(limit))
    return pages.json()

if __name__ == "__main__":
    import time
    start = time.time()
    try:
        limit = 10
        if len(sys.argv) > 1:
            limit = sys.argv[1]
        extracts = get_extracts(limit=limit)
        all_extracts = []
        for extract in extracts:
            # Consume extracts from pool AsyncResult
            all_extracts.append(extract.get())
        pprint.pprint(all_extracts)
    except:
        import traceback
        traceback.print_exc()

    print("TOTAL TIME: ", time.time() - start)
