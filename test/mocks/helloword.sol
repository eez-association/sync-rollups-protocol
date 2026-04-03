// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HelloWorldL2 — Lives on L2, provides the audience word
/// @dev Deployed on L2. The word can be set by anyone (demo purposes).
///      L1 calls getWord() synchronously via EEZ cross-chain composability.
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
/// @dev Deployed on L1. Calls L2's getWord() via a CrossChainProxy.
///      The proxy is created by Rollups.createCrossChainProxy(helloL2Address, rollupId).
///      When helloL2World() is called, the proxy transparently routes getWord()
///      to L2 and returns the result — all in ONE synchronous execution.
///
///      This is the core EEZ value proposition: no message passing, no callbacks,
///      no waiting. Just call L2 like it's a local contract.
contract HelloWorldL1 {
    /// @notice The proxy address for the L2 contract (set at deploy time)
    IHelloWorldL2 public immutable l2Proxy;

    /// @notice The last greeting built by helloL2World()
    string public lastGreeting;

    /// @notice Emitted when a new greeting is built
    event HelloEEZ(string greeting);

    constructor(address _l2Proxy) {
        l2Proxy = IHelloWorldL2(_l2Proxy);
    }

    /// @notice Build a greeting using a word from L2 — synchronous cross-chain call
    /// @return greeting The complete greeting string
    function helloL2World() external returns (string memory greeting) {
        // This call goes to L2 via the proxy — synchronously!
        string memory word = l2Proxy.getWord();

        // Build the greeting on L1 with the L2 word
        greeting = string(abi.encodePacked("Hello ", word, "! This is EEZ."));

        // Store and emit
        lastGreeting = greeting;
        emit HelloEEZ(greeting);
    }
}