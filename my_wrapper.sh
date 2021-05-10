#!/bin/bash

set -m

/ieam/trigger.sh 
#/ieam/dev.sh

#sleep 15 

#su - node-red -c "node-red --userDir /data flows.json"

fg %1
