


#!/bin/bash

nohup \
  ./runSpeed.sh \
  -t "tests/" \
  -c "nethermind,geth,reth,erigon,besu,ethrex" \
  -r 8 \
  -o "results/speed" \
  -s 1,10,100,500,1000,1500 \
  > output.log 2>&1 &
