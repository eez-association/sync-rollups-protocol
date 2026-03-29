// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        counter++;
        return counter;
    }
}

contract RevertCounter {
    uint256 public counter;

    function increment() external returns (uint256) {
        revert("always reverts");
    }
}

contract SafeCounterAndProxy {
    Counter public target;
    uint256 public targetCounter;
    uint256 public counter;
    bool public lastCallFailed;

    constructor(Counter _target) {
        target = _target;
    }

    function incrementProxy() external {
        try target.increment() returns (uint256 val) {
            targetCounter = val;
        } catch {
            lastCallFailed = true;
        }
        counter++;
    }
}

contract CounterAndProxy {
    Counter public target;
    uint256 public targetCounter;
    uint256 public counter;

    constructor(Counter _target) {
        target = _target;
    }

    function incrementProxy() external {
        targetCounter = target.increment();
        counter++;
    }
}
