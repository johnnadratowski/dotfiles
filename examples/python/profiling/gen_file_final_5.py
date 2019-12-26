#!/usr/bin/python
import sys, traceback

DATA = b'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.'

def gen_file(size, filename):
    outfile = open(filename, mode='a')
    num_data, remainder = divmod(size, len(DATA))
    str_data = DATA.decode('utf-8')
    for i in range(num_data):
        outfile.write(str_data)
    if remainder > 0:
        outfile.write(str_data[:remainder])
    return

if __name__ == "__main__":
    try:
        gen_file(int(sys.argv[1]), sys.argv[2])
        sys.exit(0)
    except Exception as e:
        traceback.print_exc()
        sys.exit(1)
