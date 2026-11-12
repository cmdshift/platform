#!/bin/sh

trap 'echo -e "\nSIGTERM, exiting"; exit 0' TERM INT

echo "api started"

httpd -f -p 3000 -h /var/www & wait $!
