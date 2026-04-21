// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HelloWorldL2 — Lives on L2, provides the audience word
contract HelloWorldL2 {
    string public word;

    constructor(string memory _word) {
        word = _word;
    }

    function setWord(string memory _word) external {
        word = _word;
    }

    function getWord() external returns (string memory) {
        return word;
    }
}

/// @title IHelloWorldL2 — Interface for the L2 contract
interface IHelloWorldL2 {
    function getWord() external returns (string memory);
}

/// @title HelloWorldL1 — Lives on L1, orchestrates the cross-chain greeting
contract HelloWorldL1 {
    IHelloWorldL2 public immutable l2Proxy;
    string public lastGreeting;

    event HelloEEZ(string greeting);

    constructor(address _l2Proxy) {
        l2Proxy = IHelloWorldL2(_l2Proxy);
    }

    function helloL2World() external returns (string memory greeting) {
        string memory word = l2Proxy.getWord();
        greeting = string(abi.encodePacked("Hello ", word, "! This is EEZ."));
        lastGreeting = greeting;
        emit HelloEEZ(greeting);
    }
}
