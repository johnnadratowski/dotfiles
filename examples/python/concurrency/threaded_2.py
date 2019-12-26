#!/usr/bin/python
import pprint
import requests
import sys
import threading

# Creaate synchronous locking mechanism
LOCK = threading.Lock()

# Create a thread class to get the extract
class ExtractThread(threading.Thread):
    """
        A thread class that will count a number, sleep and output that number
    """
    def __init__ (self, idx, page, extracts):
        self.idx = idx
        self.page = page
        self.extracts = extracts
        print("INIT THREAD %s" % self.idx)
        threading.Thread.__init__ (self)

    def run(self):
        print("RUNNING THREAD %s" % self.idx)
        print("GETTING PAGE %s EXTRACT" % self.idx)
        content = requests.get('https://en.wikipedia.org/w/api.php?format=json&action=query&prop=extracts&exintro=&explaintext=&titles='+str(self.page['title']))
        data = content.json()
        extract = {'title': self.page['title'], 'extract': data['query']['pages'][str(self.page['id'])]['extract']}
        self.append_extract(self.extracts, extract)
        print("FINISHED PAGE %s EXTRACT" % self.idx)
        print("FINISHED THREAD %s" % self.idx)

    def append_extract(self, extracts, extract):
        # Append extract to shared memory data structure, making sure we lock to synchronize
        try:
            LOCK.acquire()
            extracts.append(extract)
        finally:
            # ALWAYS put the lock release into a finally!
            LOCK.release()

def get_extracts(limit=5):
    pages = get_pages(limit=limit)
    pages_list = pages['query']['random']
    extracts = []
    threads = []
    for idx, page in enumerate(pages_list):
        # Create threads and run processes
        thread = ExtractThread(idx, page, extracts)
        thread.start()
        threads.append(thread)

    # Ensure all threads have finished
    for thread in threads:
        thread.join()

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
    extracts = get_extracts(limit=limit)
    pprint.pprint(extracts)

    print("TOTAL TIME: ", time.time() - start)
