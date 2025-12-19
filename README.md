# Genesis Init Benchmarks

## Running the Benchmarks

Running speed benchmarks:

```
./runSpeed.sh \
  -t "tests/" \
  -c "nethermind,geth,reth,erigon,besu,ethrex" \
  -r 8 \
  -o "results/speed" \
  -s 1,10,100,500,1000,1500
```

Running memory benchmarks:

```
./runMemory.sh \
  -t "tests/" \
  -c "nethermind,geth,reth,erigon,besu,ethrex" \
  -r 8 \
  -o "results/memory" \
  -s 1,10,100,500,1000,1500
```

