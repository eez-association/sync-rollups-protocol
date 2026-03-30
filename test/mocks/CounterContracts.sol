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

/// @notice Wraps CounterAndProxy to create scope depth [0,0] in cross-chain tests.
contract NestedCaller {
    CounterAndProxy public target;
    uint256 public counter;

    constructor(CounterAndProxy _target) {
        target = _target;
    }

    function callNested() external {
        target.incrementProxy();
        counter++;
    }
}

/// @notice Calls increment() on two Counter proxies sequentially — produces sibling scopes [0],[1].
contract CallTwoProxies {
    Counter public target1;
    Counter public target2;

    constructor(Counter _target1, Counter _target2) {
        target1 = _target1;
        target2 = _target2;
    }

    function callBoth() external {
        target1.increment();
        target2.increment();
    }
}
