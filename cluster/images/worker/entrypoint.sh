#!/bin/sh

trap 'echo -e "\nSIGTERM, exiting"; exit 0' TERM INT

echo "worker started"

while :; do
  echo "tick"
  sleep 1 &
  wait $!
done
