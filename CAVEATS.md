# Caveats

## Edge Cases

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution was not loaded into the execution table vs. the underlying L2 call actually reverting. Both cases bubble up as a revert from the proxy.
