#!/bin/bash
# Contains functions for working with dates and times

# Define a timestamp function
timestamp_ms() {
  if which 'python' &> /dev/null; then
	  python -c 'import time; print(int(time.time()*1000))'
  else
	  date +"%s000"
  fi
}

timestamp() {
  date +"%s"
}
