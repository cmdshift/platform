#!/bin/sh

trap 'echo -e "\nSIGTERM, exiting"; exit 0' TERM INT

echo "job started"

sleep 10 & wait $!

echo "done"
