#!/usr/bin/env python
import argparse
import dateutil.parser
import dateutil.tz
import getpass
import json
import logging
import os.path
import re
import requests
import subprocess
import sys

log = logging.getLogger()

def get_prs(date, repo, user, password):
    """Get all PRs from the repo that were merged past or at the given date"""
    pull_requests_resp = requests.get("https://api.github.com/repos/Unified/%s/pulls?state=closed" % (repo), auth=(user, password))
    if pull_requests_resp.status_code != 200:
        log.error("An error occurred making API call to get PRs: Code: %d Message: %s", pull_requests_resp.status_code, pull_requests_resp.json())
        sys.exit(1)

    pr_data = []
    pull_requests = pull_requests_resp.json()
    for pull_request in pull_requests:
        merged_at_str = pull_request.get("merged_at")
        if not merged_at_str:
            continue
        merged_at_time = dateutil.parser.parse(merged_at_str).astimezone(dateutil.tz.tzlocal())
        if merged_at_time.date() >= dateutil.parser.parse(date).date():
            pr_data.append(pull_request)

    return pr_data


def get_pr_tickets(date, user, password):
    """Get all tickets from commit messages that were merged into the current branch
    past the given date"""
    repo = subprocess.getoutput('basename `git rev-parse --show-toplevel`')
    prs = get_prs(date, repo, user, password)
    pr_numbers = sorted([pr["number"] for pr in prs])

    commits = [requests.get("https://api.github.com/repos/Unified/%s/pulls/%d/commits" % (repo, pr_num), auth=(user, password)) for pr_num in pr_numbers]
    output = {
        '_all_pr_data': prs,
        'tickets': set(),
        'num_commits_per_pr': {},
        'no_message': [],
        'invalid_message': []
    }
    for idx, pull_commits_resp in enumerate(commits):
        if pull_commits_resp.status_code != 200:
            log.error("An error occurred making API call to get commits: Code: %d Message: %s", pull_commits_resp.status_code, pull_commits_resp.json())
            sys.exit(1)

        pull_commits = pull_commits_resp.json()
        output['num_commits_per_pr'][pr_numbers[idx]] = len(pull_commits)
        for commit in pull_commits:
            try:
                commit_data = commit.get('commit', {})
                commit_msg = commit_data.get('message')
                if not commit_msg:
                    output['no_message'].append(commit)
                    continue

                ticket_matches = re.findall(r"\b([A-Z]{2,5}\-[0-9]{1,5})\b", commit_msg)
                if not ticket_matches:
                    output['invalid_message'].append(commit)
                    continue

                output['tickets'].update(ticket_matches)
            except:
                log.exception("An error occurred processing commit: %s", json.dumps(commit, sort_keys=True, indent=4, separators=(',', ': ')))
                sys.exit(1)

    pr_output = {}
    for idx, pr in enumerate(pr_numbers):
        pr_output[pr] = commits[idx].json()

    output['_prs_and_commits'] = pr_output

    return output


def get_jira_data(tickets, jira_user, jira_password):
    """Matches up ticket data with whats in JIRA"""
    jira_data = {}
    for ticket in tickets:
        ticket_resp = requests.get("https://unified.jira.com/rest/api/latest/issue/" + ticket, auth=(jira_user, jira_password))
        if ticket_resp.status_code != 200:
            jira_data[ticket] = "An error occurred getting this ticket info from JIRA"
        else:
            jira_data[ticket] = ticket_resp.json()
    return jira_data


def get_tag_date(tag):
    """Get the date that a tag was added to a git repo"""
    tags_data = subprocess.getoutput('git log --tags --simplify-by-decoration --pretty="format:%ai %d"')
    for tag_data in tags_data.split("\n"):
        if "tag: %s" % tag in tag_data:
            return tag_data.split(" ")[0]
    log.error("Could not find tag %s", tag)
    sys.exit(1)


def resolve_jira_tickets(tickets, all_tickets, jira_user, jira_password):
    """Resolve the jira data to the tickets from the commits and PRs"""
    jira_data = get_jira_data(tickets, jira_user, jira_password)

    tickets_with_resolutions = {}
    for ticket in tickets:
        jira_ticket = jira_data[ticket]
        if not isinstance(jira_ticket, dict):
            log.warning('Could not get JIRA info for ticket: %s. Message: %s', ticket, jira_ticket)
            continue

        fields = jira_ticket.get('fields', {})
        if not fields:
            continue

        ticket_data = {}
        ticket_data['status'] = fields.get('status', {}).get('name', 'unknown')

        linked_issues = []
        links = fields.get('issuelinks', [])
        for link in links:
            outIssue = link.get('outwardIssue', {}).get('key')
            if outIssue and outIssue not in all_tickets:
                linked_issues.append(outIssue)
        if linked_issues:
            all_linked_data, linked_data = resolve_jira_tickets(linked_issues, linked_issues+all_tickets, jira_user, jira_password)
            jira_data.update(all_linked_data)
            ticket_data['linked_issues'] = linked_data
        tickets_with_resolutions[ticket] = ticket_data

    return jira_data, tickets_with_resolutions


def get_all_ticket_data(date, github_user, github_password, jira_user, jira_password):
    """Gets all of the ticket data since the given date"""
    output = get_pr_tickets(date, github_user, github_password)
    output['tickets'] = sorted(list(output['tickets']))
    if jira_user and jira_password:
        jira_data, ticket_resolutions = resolve_jira_tickets(output['tickets'], output['tickets'], jira_user, jira_password)

        output["_all_jira_data"] = jira_data
        output['tickets_with_resolutions'] = ticket_resolutions
    return output


def setup_args(args):
    """Set up all of the args given to the command line"""
    if not os.path.isdir(os.path.abspath("./.git")):
        log.error("You must run this from a git repo root folder")
        sys.exit(1)

    is_up_to_date = subprocess.getoutput('git remote update; git status -uno')
    if 'Your branch is up-to-date' not in is_up_to_date:
        log.error("Your branch is out of date - rerun this after you pull")
        sys.exit(1)

    date = args.date
    if not date:
        if not args.tag:
            log.error("Must specify either the explicit date to find PR tickets from, or a git tag that will serve as the start date.")
            sys.exit(1)
        else:
            date = get_tag_date(args.tag)
            log.warning("Getting every commit since tag %s date: %s", args.tag, date)
    else:
        log.warning("Getting every commit since date: %s", date)

    github_user = args.github_user
    if not github_user:
        log.error("Must specify a git user")
        sys.exit(1)

    log.warning("%s - make sure this is the right branch you want to run from!", subprocess.getoutput('git rev-parse --abbrev-ref HEAD'))

    github_password = args.github_password
    if not github_password:
        github_password = getpass.getpass("Enter github password for user %s: " % github_user)

    jira_user = args.jira_user
    jira_password = args.jira_password
    if not jira_user:
        log.warning("No jira user specified, will not match up to JIRA.")
    elif not jira_password:
        jira_password = getpass.getpass("Enter jira password for user %s: " % jira_user)

    return date, github_user, github_password, jira_user, jira_password


def create_jira_ticket(proj_id, title, description, jira_user, jira_password):
    """Creates a new JIRA ticket in the project with the given ID"""
    payload = {
        "fields": {
            "project": {
                "key": proj_id
            },
            "summary": title,
            "description": description,
            "issuetype": {
                "name": "Technical Task"
            }
        }
    }
    create_resp = requests.post("https://unified.jira.com/rest/api/latest/issue/", data=json.dumps(payload), auth=(jira_user, jira_password), headers={"Content-Type": "application/json"})
    if create_resp.status_code != 201 and create_resp.status_code != 200:
        log.error("An error occurred creating a new ticket in project %s: [%s] %s", proj_id, create_resp.status_code, create_resp.content)
    return create_resp.json()


def link_to_jira_ticket(link_to, tickets, jira_user, jira_password):
    """Links the given tickets to the link_to ticket in jira"""
    for ticket in tickets:
        payload = {
            "type": {
                "name": "Relate",
                "inward": "is related to",
                "outward": "related to",
            },
            "inwardIssue": {
                "key": link_to
            },
            "outwardIssue": {
                "key": ticket
            },
            "comment": {
                "body": "Automatically linked issue %s by script" % (ticket)
            }
        }
        ticket_resp = requests.post("https://unified.jira.com/rest/api/latest/issueLink/", data=json.dumps(payload), auth=(jira_user, jira_password), headers={"Content-Type": "application/json"})
        if ticket_resp.status_code != 201:
            log.error("An error occurred linking ticket issue %s: [%s] %s", ticket, ticket_resp.status_code, ticket_resp.content)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="""
                                     Get all of the ticket numbers from commits in PRs made since the specified date.
                                     Must either be explicitly given a date, or given a tag and the tag date will be used.
                                     Output as JSON with tickets and error messages.""")
    parser.add_argument('--all-data', '-a', action="store_true", dest='all', help='Output all of the retrieved data')
    parser.add_argument('--tag', '-t', dest='tag', help='Get all PRs since tag')
    parser.add_argument('--date', '-d', dest='date', help='The date to start looking for PRs - like 2016-01-28')
    parser.add_argument('--github-user', '-g', dest='github_user', help='The github api user to use')
    parser.add_argument('--github-password', '-G', dest='github_password', help='The github api password to use')
    parser.add_argument('--jira-user', '-j', dest='jira_user', help='The jira api user to use')
    parser.add_argument('--jira-password', '-J', dest='jira_password', help='The jira api password to use')
    parser.add_argument('--link-to', '-l', dest='link', help='A ticket to link all of the PR tickets to')
    parser.add_argument('--create-and-link', '-c', dest='create_and_link',
                        help='A JIRA project ID to create a new ticket in and link the issues to. Example: CCRB,ASPM,etc.')
    parser.add_argument('--create-ticket-title', '-T', dest='create_title', help='The title of the ticket to use when creating a new ticket')
    parser.add_argument('--create-ticket-description', '-D', dest='create_desc', help='The description of the ticket to use when creating a new ticket')
    args = parser.parse_args()

    date, github_user, github_password, jira_user, jira_password = setup_args(args)

    output = get_all_ticket_data(date, github_user, github_password, jira_user, jira_password)

    if args.create_and_link or args.link:
        if args.create_and_link:
            create_data = create_jira_ticket(args.create_and_link, args.create_title, args.create_desc, jira_user, jira_password)
            output["created_ticket"] = create_data
            ticket = create_data["key"]
            log.warning("Created ticket: %s", ticket)
        else:
            ticket = args.link
        link_to_jira_ticket(ticket, output['tickets'], jira_user, jira_password)

    if args.all:
        print(json.dumps(output, sort_keys=True, indent=4, separators=(',', ': ')))
    elif 'tickets_with_resolutions' in output:
        print(json.dumps(output['tickets_with_resolutions'], sort_keys=True, indent=4, separators=(',', ': ')))
    else:
        print(json.dumps(output['tickets'], sort_keys=True, indent=4, separators=(',', ': ')))

    sys.exit(0)
