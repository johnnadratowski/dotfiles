#!/usr/bin/python
import os
import shutil
import sys
import time

HOST_FILE = os.environ.get('HOST_FILE', "/etc/hosts")


def get_hosts():
    """
    Gets the hosts file data
    """

    with open(HOST_FILE, 'r') as f:
        output_file = f.readlines()
        output = []

        for line in output_file:
            data = {'line': line}

            parts = line.partition('#')
            data['comment'] = parts[2]

            if not parts[0] or not parts[0].strip():
                output.append(data)
                continue

            columns = parts[0].strip().split()
            data['ip'] = columns[0]
            data['hosts'] = columns[1:]

            output.append(data)

    return output


def col_widths():
    """
    Gets all of the widths for each column of hosts
    """
    cols = []
    for x in HOSTS:
        if not 'ip' in x or not x['ip']:
            continue
        columns = [x['ip']] + x['hosts']

        # Set up options for formatting hosts
        for idx, column in enumerate(columns):
            length = len(column) + 1

            # Determine max length of each column we're going to output
            if len(cols) == idx:
                cols.append(length)
            elif cols[idx] < length:
                cols[idx] = length
    return cols


def add_hosts(ip, hosts):
    """
    Adds hosts to the host file
    """
    try:
        cur = next(d for d in HOSTS if d['ip'] == ip)
        cur['hosts'] = list(set(hosts + cur['hosts']))
    except StopIteration:
        cur = dict(ip=ip, hosts=hosts, comment='', line='')
        HOSTS.append(cur)


def remove_host(host):
    """
    Removes hosts to the host file
    """
    for h in HOSTS:
        if 'ip' in h and h['ip'] == host:
            HOSTS.remove(h)
        elif 'hosts' in h:
            for hostname in h['hosts']:
                if hostname == host:
                    h['hosts'].remove(host)


def write_hosts():
    """
    Write out hosts file
    """
    shutil.copy(HOST_FILE, "/tmp/hosts." + str(int(time.time())) + ".bak")

    with file(HOST_FILE, 'w') as f:
        widths = col_widths()
        output_lines = []
        for host in HOSTS:
            if 'ip' not in host:
                output_lines.append(host['line'].strip())
                continue

            line = host['ip'].ljust(widths[0])
            for idx, h in enumerate(host['hosts']):
                line += " " + h.ljust(widths[idx + 1])

            if 'comment' in host and host['comment']:
                line += " #" + host['comment']

            output_lines.append(line)

        f.writelines("\n".join(output_lines))


if __name__ == "__main__":

    HOSTS = get_hosts()

    for a in sys.argv:
        if a.startswith("-a="):
            _, _, add_host_str = a.partition("=")
            ip, _, hosts = add_host_str.partition("=")
            hosts = hosts.split(',')
            add_hosts(ip, hosts)
        elif a.startswith("-r="):
            _, _, remove_host_str = a.partition("=")
            remove_host(remove_host_str.split(','))

    write_hosts()
