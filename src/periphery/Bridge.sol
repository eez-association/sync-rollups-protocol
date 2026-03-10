// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICrossChainManager} from "../ICrossChainManager.sol";
import {WrappedToken} from "./WrappedToken.sol";

/// @title Bridge
/// @notice Periphery contract for bridging ETH and ERC20 tokens between L1 and L2
/// @dev Deployed at the same CREATE2 address on both chains. Uses a lock-and-mint model:
///      native tokens are locked on the source chain, and a WrappedToken is minted on the
///      destination. Burning wrapped tokens releases the native tokens on the origin chain.
///
///      Security model: inbound functions (mintWrappedTokens, releaseTokens) validate that
///      msg.sender is the expected CrossChainProxy for this bridge. The execution table
///      (ZK-proven entries) provides the primary security guarantee.
contract Bridge {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice The cross-chain manager contract (Rollups on L1, CrossChainManagerL2 on L2)
    ICrossChainManager public immutable MANAGER;

    /// @notice This chain's rollup ID (0 for L1 mainnet)
    uint256 public immutable ROLLUP_ID;

    /// @notice Mapping: originalToken => originalRollupId => wrappedToken address
    mapping(address originalToken => mapping(uint256 originalRollupId => address wrappedToken)) public wrappedTokens;

    /// @notice Quick lookup for whether an address is a bridge-deployed WrappedToken
    mapping(address token => bool isWrapped) public isWrappedToken;

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error NotWrappedToken(address token);
    error ProxyCallFailed(bytes reason);
    error UnauthorizedCaller();

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event EtherBridged(address indexed sender, uint256 indexed rollupId, uint256 amount);
    event TokensLocked(address indexed token, address indexed sender, uint256 indexed rollupId, uint256 amount);
    event WrappedTokensBurned(address indexed wrappedToken, address indexed sender, uint256 indexed originalRollupId, uint256 amount);
    event TokensReleased(address indexed token, address indexed to, uint256 amount);
    event WrappedTokensMinted(address indexed wrappedToken, address indexed to, uint256 amount);
    event WrappedTokenDeployed(
        address indexed wrappedToken, address indexed originalToken, uint256 indexed originalRollupId
    );

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @param manager_ The cross-chain manager address
    /// @param rollupId_ This chain's rollup ID (0 = L1 mainnet)
    constructor(address manager_, uint256 rollupId_) {
        MANAGER = ICrossChainManager(manager_);
        ROLLUP_ID = rollupId_;
    }

    // ══════════════════════════════════════════════
    //  OUTBOUND — user-facing bridge operations
    // ══════════════════════════════════════════════

    /// @notice Bridge ETH to msg.sender on the destination rollup
    /// @dev Creates a proxy for (msg.sender, rollupId) if needed, then forwards ETH to it.
    ///      The proxy's fallback triggers executeCrossChainCall on the manager, which matches
    ///      a pre-loaded execution entry and accounts for the ether via state deltas.
    /// @param rollupId The destination rollup ID
    function bridgeEther(uint256 rollupId) external payable {
        if (msg.value == 0) revert ZeroAmount();

        address proxy = _ensureCorssChainProxyCreated(msg.sender, rollupId);
        (bool success, bytes memory reason) = proxy.call{value: msg.value}("");
        if (!success) revert ProxyCallFailed(reason);

        emit EtherBridged(msg.sender, rollupId, msg.value);
    }

    /// @notice Bridge native ERC20 tokens to the destination rollup
    /// @dev Locks tokens in this contract, then calls the bridge proxy on the destination
    ///      to mint WrappedTokens for the recipient. Token metadata (name, symbol, decimals)
    ///      is read from the token and included in the cross-chain call so the destination
    ///      can deploy a matching WrappedToken on first bridge.
    /// @param token The ERC20 token to bridge
    /// @param amount The amount to bridge
    /// @param rollupId The destination rollup ID
    function bridgeTokens(address token, uint256 amount, uint256 rollupId) external {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        // Lock tokens in this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Read token metadata for WrappedToken deployment on destination
        (string memory name, string memory symbol, uint8 tokenDecimals) = _readTokenMetadata(token);

        // Call bridge' (our proxy on the destination) → cross-chain → mintWrappedTokens on dest
        address bridgeProxy = _ensureCorssChainProxyCreated(address(this), rollupId);
        (bool success, bytes memory reason) = bridgeProxy.call(
            abi.encodeCall(
                this.mintWrappedTokens,
                (token, ROLLUP_ID, msg.sender, amount, string.concat("Bridged ", name), string.concat("b", symbol), tokenDecimals)
            )
        );
        if (!success) revert ProxyCallFailed(reason);

        emit TokensLocked(token, msg.sender, rollupId, amount);
    }

    /// @notice Burn wrapped tokens and release the native tokens on the origin chain
    /// @dev Burns the WrappedTokens from msg.sender, then calls the bridge proxy on the
    ///      origin chain to release the locked native tokens.
    /// @param wrappedToken The WrappedToken address to burn
    /// @param amount The amount to burn and release
    function bridgeWrappedTokens(address wrappedToken, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!isWrappedToken[wrappedToken]) revert NotWrappedToken(wrappedToken);

        WrappedToken wrapped = WrappedToken(wrappedToken);
        address originalToken = wrapped.ORIGINAL_TOKEN();
        uint256 originalRollupId = wrapped.ORIGINAL_ROLLUP_ID();

        // Burn wrapped tokens from the sender
        wrapped.burn(msg.sender, amount);

        // Call bridge' on the origin chain → cross-chain → releaseTokens there
        address bridgeProxy = _ensureCorssChainProxyCreated(address(this), originalRollupId);
        (bool success, bytes memory reason) = bridgeProxy.call(
            abi.encodeCall(this.releaseTokens, (originalToken, msg.sender, amount, ROLLUP_ID))
        );
        if (!success) revert ProxyCallFailed(reason);

        emit WrappedTokensBurned(wrappedToken, msg.sender, originalRollupId, amount);
    }

    // ══════════════════════════════════════════════
    //  INBOUND — called via cross-chain execution
    // ══════════════════════════════════════════════

    /// @notice Mint wrapped tokens for a recipient (called by the source chain's bridge via cross-chain)
    /// @dev Deploys a new WrappedToken via CREATE2 on first call for a given (originalToken, originalRollupId).
    ///      Subsequent calls reuse the existing WrappedToken and only mint.
    /// @param originalToken The token address on the source chain
    /// @param originalRollupId The rollup ID where the native token lives
    /// @param to The recipient address
    /// @param amount The amount to mint
    /// @param name The token name (used only on first deployment)
    /// @param symbol The token symbol (used only on first deployment)
    /// @param tokenDecimals The token decimals (used only on first deployment)
    function mintWrappedTokens(
        address originalToken,
        uint256 originalRollupId,
        address to,
        uint256 amount,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    ) external {
        _requireBridgeProxy(originalRollupId);

        address wrapped = _getOrDeployWrapped(originalToken, originalRollupId, name, symbol, tokenDecimals);
        WrappedToken(wrapped).mint(to, amount);

        emit WrappedTokensMinted(wrapped, to, amount);
    }

    /// @notice Release locked native tokens to a recipient (called by the destination chain's bridge via cross-chain)
    /// @param token The native token to release
    /// @param to The recipient address
    /// @param amount The amount to release
    /// @param sourceRollupId The rollup ID of the caller (used for proxy validation)
    function releaseTokens(address token, address to, uint256 amount, uint256 sourceRollupId) external {
        _requireBridgeProxy(sourceRollupId);

        IERC20(token).safeTransfer(to, amount);

        emit TokensReleased(token, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Compute the deterministic address of a WrappedToken before deployment
    /// @param originalToken The native token address on the origin chain
    /// @param originalRollupId The origin rollup ID
    /// @return The predicted WrappedToken address on this chain
    /// @notice Get the WrappedToken address for a given (originalToken, originalRollupId) pair
    /// @dev Returns address(0) if the token has not been bridged yet.
    ///      CREATE2 address depends on constructor args (name/symbol/decimals), so prediction
    ///      before first bridge is not possible. Use this mapping after first bridge.
    function getWrappedToken(address originalToken, uint256 originalRollupId) external view returns (address) {
        return wrappedTokens[originalToken][originalRollupId];
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Validates that msg.sender is the CrossChainProxy representing this bridge from `sourceRollupId`.
    ///      The proxy address is deterministic (CREATE2), so we can compute the expected address and compare.
    ///      An attacker cannot deploy at the same address since CREATE2 is controlled by the manager.
    function _requireBridgeProxy(uint256 sourceRollupId) internal view {
        address expectedProxy = MANAGER.computeCrossChainProxyAddress(address(this), sourceRollupId, block.chainid);
        if (msg.sender != expectedProxy) revert UnauthorizedCaller();
    }

    /// @dev Returns an existing WrappedToken or deploys a new one via CREATE2.
    function _getOrDeployWrapped(
        address originalToken,
        uint256 originalRollupId,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    ) internal returns (address wrappedAddr) {
        wrappedAddr = wrappedTokens[originalToken][originalRollupId];
        if (wrappedAddr != address(0)) return wrappedAddr;

        bytes32 salt = keccak256(abi.encodePacked(originalToken, originalRollupId));
        WrappedToken wrapped = new WrappedToken{salt: salt}(
            bytes(name).length > 0 ? name : "Bridged Token",
            bytes(symbol).length > 0 ? symbol : "bTKN",
            tokenDecimals,
            address(this),
            originalToken,
            originalRollupId
        );

        wrappedAddr = address(wrapped);
        wrappedTokens[originalToken][originalRollupId] = wrappedAddr;
        isWrappedToken[wrappedAddr] = true;

        emit WrappedTokenDeployed(wrappedAddr, originalToken, originalRollupId);
    }

    /// @dev Ensures a CrossChainProxy exists for (addr, rollupId), creating it if needed.
    function _ensureCorssChainProxyCreated(address addr, uint256 rollupId) internal returns (address proxy) {
        proxy = MANAGER.computeCrossChainProxyAddress(addr, rollupId, block.chainid);
        if (proxy.code.length == 0) {
            MANAGER.createCrossChainProxy(addr, rollupId);
        }
    }

    /// @dev Best-effort metadata read. Falls back to defaults for non-standard tokens.
    function _readTokenMetadata(address token)
        internal
        view
        returns (string memory name, string memory symbol, uint8 tokenDecimals)
    {
        try IERC20Metadata(token).name() returns (string memory n) {
            name = n;
        } catch {
            name = "Unknown Token";
        }
        try IERC20Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = "TKN";
        }
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            tokenDecimals = d;
        } catch {
            tokenDecimals = 18;
        }
    }

    /// @notice Accept ETH (needed for receiving ETH from cross-chain releases)
    receive() external payable {}
}
