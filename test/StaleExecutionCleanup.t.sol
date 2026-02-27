// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    Rollups,
    Action,
    ActionType,
    Execution,
    StateDelta,
    StateCommitment
} from "../src/Rollups.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";

/// @notice Mock verifier that always returns true
contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @title StaleExecutionCleanupTest
/// @notice Tests for the stale execution cleanup mechanism
/// @dev Verifies that expired, state-mismatched executions can be permissionlessly removed
contract StaleExecutionCleanupTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds a single execution for a rollup with given states
    function _buildExecution(
        uint256 rollupId,
        bytes32 currentState,
        bytes32 newState
    ) internal view returns (Execution[] memory) {
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(this),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(this),
            sourceRollup: rollupId,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        return executions;
    }

    /// @dev Returns the actionHash from a built execution
    function _getActionHash(
        Execution[] memory executions
    ) internal pure returns (bytes32) {
        return executions[0].actionHash;
    }

    /*//////////////////////////////////////////////////////////////
                    BLOCK LOADED TRACKING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that blockLoaded is recorded when executions are loaded
    function test_BlockLoadedIsTracked() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );

        rollups.loadL2Executions(executions, "proof");

        bytes32 actionHash = _getActionHash(executions);
        assertEq(
            rollups.getExecutionBlockLoaded(actionHash, 0),
            block.number,
            "Block loaded should be recorded"
        );
    }

    /// @notice Verifies execution count view works
    function test_GetExecutionCount() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );

        bytes32 actionHash = _getActionHash(executions);
        assertEq(rollups.getExecutionCount(actionHash), 0, "Should start at 0");

        rollups.loadL2Executions(executions, "proof");
        assertEq(
            rollups.getExecutionCount(actionHash),
            1,
            "Should be 1 after load"
        );
    }

    /// @notice Verifies multiple loads to same actionHash track independently
    function test_MultipleLoadsTrackedIndependently() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory exec1 = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new1")
        );
        bytes32 actionHash = _getActionHash(exec1);

        // First load at block 100
        vm.roll(100);
        rollups.loadL2Executions(exec1, "proof");
        assertEq(
            rollups.getExecutionCount(actionHash),
            1,
            "Count after first load"
        );

        // Second load at block 200
        vm.roll(200);
        rollups.loadL2Executions(exec1, "proof");
        assertEq(
            rollups.getExecutionCount(actionHash),
            2,
            "Count after second load"
        );

        // Verify each was tracked at the correct block
        assertEq(
            rollups.getExecutionBlockLoaded(actionHash, 0),
            100,
            "First load at block 100"
        );
        assertEq(
            rollups.getExecutionBlockLoaded(actionHash, 1),
            200,
            "Second load at block 200"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     CLEANUP FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cleanup removes stale executions whose state no longer matches
    function test_CleanupRemovesStaleExecutions() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");
        assertEq(rollups.getExecutionCount(actionHash), 1);

        // Advance rollup state so the loaded execution becomes stale
        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("advanced"));

        // Advance past MAX_EXECUTION_AGE
        vm.roll(block.number + 257);

        // Anyone can call cleanup
        vm.prank(bob);
        rollups.cleanupStaleExecutions(actionHash, 0);

        assertEq(
            rollups.getExecutionCount(actionHash),
            0,
            "Stale execution should be removed"
        );
    }

    /// @notice Cleanup emits the correct event
    function test_CleanupEmitsEvent() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("advanced"));
        vm.roll(block.number + 257);

        vm.expectEmit(true, false, false, true);
        emit Rollups.StaleExecutionsCleaned(actionHash, 1);
        rollups.cleanupStaleExecutions(actionHash, 0);
    }

    /// @notice Cleanup reverts if no stale executions exist
    function test_CleanupRevertsIfNothingToClean() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        // State still matches AND not expired — nothing to clean
        vm.expectRevert(Rollups.NoStaleExecutions.selector);
        rollups.cleanupStaleExecutions(actionHash, 0);
    }

    /// @notice Cleanup DOES remove executions that have expired, even if they still match current state
    function test_CleanupRemovesExpiredMatchingExecutions() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        // State still matches, but we advance past expiry
        vm.roll(block.number + 257);

        rollups.cleanupStaleExecutions(actionHash, 0);

        // Execution should be removed because it expired (TTL semantics)
        assertEq(rollups.getExecutionCount(actionHash), 0);
    }

    /// @notice Cleanup does NOT remove executions that haven't expired yet
    function test_CleanupRevertsIfNotExpired() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        // Advance state but NOT past expiry
        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("advanced"));
        vm.roll(block.number + 100); // only 100 blocks, need 256

        vm.expectRevert(Rollups.NoStaleExecutions.selector);
        rollups.cleanupStaleExecutions(actionHash, 0);
    }

    /// @notice Custom maxAge parameter works
    function test_CleanupWithCustomMaxAge() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("advanced"));

        // Only advance 11 blocks, use maxAge=10
        vm.roll(block.number + 11);

        rollups.cleanupStaleExecutions(actionHash, 10);
        assertEq(rollups.getExecutionCount(actionHash), 0);
    }

    /// @notice Cleanup selective removal handles multiple executions properly
    function test_CleanupSelectiveRemoval() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // First execution — will expire
        Execution[] memory executions1 = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new1")
        );
        bytes32 actionHash = _getActionHash(executions1);
        rollups.loadL2Executions(executions1, "proof");

        // Advance block so the first is older, but not yet expired
        vm.roll(block.number + 50);

        // Second execution — will NOT expire
        Execution[] memory executions2 = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new2")
        );
        rollups.loadL2Executions(executions2, "proof2");

        // Validate both are loaded under the same actionHash
        assertEq(rollups.getExecutionCount(actionHash), 2);

        // Advance 210 blocks: first execution is 260 blocks old (expired)
        // second execution is 210 blocks old (not expired)
        vm.roll(block.number + 210);

        rollups.cleanupStaleExecutions(actionHash, 0);

        assertEq(
            rollups.getExecutionCount(actionHash),
            1,
            "Only expired execution should be removed"
        );
    }

    /// @notice Cleanup is fully permissionless
    function test_CleanupIsPermissionless() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildExecution(
            rollupId,
            bytes32(0),
            keccak256("new")
        );
        bytes32 actionHash = _getActionHash(executions);

        rollups.loadL2Executions(executions, "proof");

        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("advanced"));
        vm.roll(block.number + 257);

        // Random address can call cleanup
        address randomAddress = makeAddr("random_cleanup_bot");
        vm.prank(randomAddress);
        rollups.cleanupStaleExecutions(actionHash, 0);

        assertEq(rollups.getExecutionCount(actionHash), 0);
    }

    /// @notice Cleanup on empty array reverts
    function test_CleanupOnEmptyArrayReverts() public {
        bytes32 fakeHash = keccak256("nonexistent");

        vm.expectRevert(Rollups.NoStaleExecutions.selector);
        rollups.cleanupStaleExecutions(fakeHash, 0);
    }
}
