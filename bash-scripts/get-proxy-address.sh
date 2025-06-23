#!/bin/bash
# Finds latest proxy address across all chains
find broadcast/DeployProxy.s.sol -name "run-latest.json" -exec jq -r '.returns."0".value' {} \; 2>/dev/null 