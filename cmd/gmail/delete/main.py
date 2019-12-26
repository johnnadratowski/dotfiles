#!/usr/bin/env python3
# Trash Gmail Messages

import argparse
import logging
import json
import os
import sys
import time

from apiclient import discovery
import httplib2
import oauth2client
from oauth2client import client
from oauth2client import tools


# FROM AUTH SCOPES: https://developers.google.com/gmail/api/auth/scopes
SCOPES = 'https://mail.google.com/'
CLIENT_SECRET_FILE = 'client_secret.json'
APPLICATION_NAME = 'Gmail Delete Messages'
USER_ID = 'me'
HOME_DIR = os.path.expanduser('~')
CRED_DIR = os.path.join(HOME_DIR, '.credentials')
CRED_FILE = os.path.join(CRED_DIR, 'gmail-delete-messages.json')


def get_creds():
    """Gets valid user credentials from storage.
    If nothing has been stored, or if the stored credentials are invalid,
    the OAuth2 flow is completed to obtain the new credentials.
    """
    if not os.path.exists(CRED_DIR):
        os.makedirs(CRED_DIR)

    store = oauth2client.file.Storage(CRED_FILE)
    credentials = store.get()
    if credentials and not credentials.invalid:
        return credentials

    flow = client.flow_from_clientsecrets(CLIENT_SECRET_FILE, SCOPES)
    flow.user_agent = APPLICATION_NAME
    credentials = tools.run_flow(flow, store)

    logging.info(f'Storing credentials to ${CRED_FILE}')

    sys.exit(1)


def execute(req):
    """Executes the given request"""
    retry = 0
    def run():
        nonlocal retry
        try:
            return req.execute()
        except:
            logging.exception(f"An error occurred making API call. Retry {retry} of 50")
            time.sleep(2)
            retry += 1
            return None

    ret = None
    while retry < 50 and ret is None:
        ret = run()

    return ret

def print_messages(messages):
    """Hard delete messages"""
    print(f'A total of {len(messages)} in this block')
    for msg in messages:
        print(json.dumps(msg, indent=4, sort_keys=True))


def delete_messages(messages, service, user_id):
    """Hard delete messages"""
    body = {'ids': [m['id'] for m in messages]}
    req = service.users().messages().batchDelete(userId=user_id, body=body)
    execute(req)
    print(f'Deleted: {len(messages)} messages')


def trash_messages(messages, service, user_id):
    """Move messages to trash"""
    for msg in messages:
        req = service.users().messages().trash(userId=user_id, id=msg['id'])
        execute(req)
    print(f'Trashed: {len(messages)} messages')


def get_messages(service, user_id, query):
    """Get the list of messages"""
    kwargs = dict(userId=user_id, q=query, maxResults=10000)
    req = service.users().messages().list(**kwargs)
    resp = execute(req)
    estimate = 0
    while 'nextPageToken' in resp:
        yield resp.get('messages', [])

        kwargs['pageToken'] = resp['nextPageToken']
        req = service.users().messages().list(**kwargs)
        resp = execute(req)

        if estimate != resp["resultSizeEstimate"]:
            estimate = resp["resultSizeEstimate"]
            print(f'An estimated {estimate} messages found in this block.')

    yield resp.get('messages', [])


def process_messages(args, service, messages):
    """Process a batch of messages"""
    if not args.do or args.verbose:
        print_messages(messages)

    if not args.do:
        return

    if args.trash:
        trash_messages(messages, service, USER_ID)
    else:
        delete_messages(messages, service, USER_ID)


def main(args):
    """Main entry point"""
    credentials = get_creds()
    http = credentials.authorize(httplib2.Http())
    service = discovery.build('gmail', 'v1', http=http)

    tally = 0
    for messages in get_messages(service, USER_ID, args.query):
        if not messages:
            print('Recieved no new messages. Breaking main loop.')
            break

        process_messages(args, service, messages)

        tally += len(messages)

        print(f'Total: {tally}')

    print(f'Total Deleted Messages: {tally}')


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser(
        description="Bulk Delete Gmail Messages",
        fromfile_prefix_chars='@',
        parents=[tools.argparser])
    PARSER.add_argument(
        "query",
        help="pass ARG to the program",
        nargs='?',
        metavar="ARG")
    PARSER.add_argument(
        "-v",
        "--verbose",
        help="increase output verbosity",
        action="store_true")
    PARSER.add_argument(
        "-d",
        "--do",
        help="Pass this to actually delete the messages. Else it will show stats.",
        action="store_true")
    PARSER.add_argument(
        "-t",
        "--trash",
        help="Send messages to trash instead of hard deleting",
        action="store_true")
    ARGS = PARSER.parse_args()

    # Setup logging
    if ARGS.verbose:
        LOGLEVEL = logging.DEBUG
    else:
        LOGLEVEL = logging.INFO

    logging.basicConfig(format="%(levelname)s: %(message)s", level=LOGLEVEL)

    try:
        main(ARGS)
    except KeyboardInterrupt:
        logging.info("Process interrupted by user")
    except SystemExit:
        pass
    except:
        logging.exception("An error occurred in main process")
