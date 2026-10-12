// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {RevertHookTest} from "test/hook/RevertHook.t.sol";
import {LimitedRedeemERC4626Vault} from "test/automators/utils/LimitedRedeemERC4626Vault.sol";

/// @notice PoC: the hook-side AUTO_LEND path still redeems the position's whole share balance in one
///         call (RevertHookAutoLendActions.autoLendWithdraw / autoLendForceExit). The standalone
///         AutoLend was fixed for exactly this (V4LE-96: redeem min(shares, maxRedeem), hand residual
///         shares to the owner); the hook was not. With a lend vault whose maxRedeem is below the
///         recorded shares (V4Vault at high utilization, any ERC4626 with a withdrawal limit):
///           1. the triggered withdrawal reverts inside its try/catch, the trigger node is consumed
///              and the position stays lent with no automatic retry;
///           2. the owner's escape hatch autoLendForceExit reverts outright - not even the
///              redeemable part can be recovered, and the shares cannot be taken out as shares.
contract PocHookAutoLendRedeemLimit is RevertHookTest {
    using EasyPosm for IPositionManager;

    LimitedRedeemERC4626Vault limitedVault0;
    uint256 lendTokenId;

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp
        });
    }

    function _setUpLentPosition() internal returns (uint256 shares) {
        hook.setMaxTicksFromOracle(1000);

        // the hook's token0 lend vault enforces a withdrawal limit (a standard ERC4626 behaviour)
        limitedVault0 = new LimitedRedeemERC4626Vault(IERC20(Currency.unwrap(currency0)), "Limited T0", "lT0");
        hook.setAutoLendVault(Currency.unwrap(currency0), limitedVault0);

        int24 s = poolKey.tickSpacing;
        int24 lower = _getTickLower(tickStart, s) - s;
        int24 upper = _getTickLower(tickStart, s) + s;
        uint128 liquidity = 50e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        (lendTokenId,) = positionManager.mint(
            poolKey, lower, upper, liquidity, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        hook.setPositionConfig(
            lendTokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_LEND,
                autoCollectMode: RevertHookState.AutoCollectMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoExitSwapOnLowerTrigger: true,
                autoExitSwapOnUpperTrigger: true,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: 0,
                autoRangeUpperDelta: 0,
                autoLendToleranceTick: 60,
                autoLeverageTargetBps: 0
            })
        );
        IERC721(address(positionManager)).setApprovalForAll(address(hook), true);

        // price falls below the range: the hook removes the liquidity and lends token0
        _swap(true, 20e17);
        (,,, address lentToken, uint256 lentShares,,,) = hook.positionStates(lendTokenId);
        assertEq(lentToken, Currency.unwrap(currency0), "token0 lent");
        assertGt(lentShares, 0, "shares recorded");
        assertEq(positionManager.getPositionLiquidity(lendTokenId), 0, "liquidity moved to the lend vault");
        assertEq(limitedVault0.balanceOf(address(hook)), lentShares, "hook custodies the shares");
        return lentShares;
    }

    function testPoC_triggeredWithdrawFailsAndForceExitIsBricked() public {
        uint256 shares = _setUpLentPosition();

        // the vault can currently honour only half of the hook's shares
        limitedVault0.setRedeemLimit(shares / 2);
        assertEq(limitedVault0.maxRedeem(address(hook)), shares / 2);

        // 1) price returns to the range: the withdraw trigger fires, the full redeem reverts inside
        //    the hook's try/catch, the node is consumed and the position stays lent
        _swap(false, 20e17);
        (,,,, uint256 sharesAfter,,,) = hook.positionStates(lendTokenId);
        assertEq(sharesAfter, shares, "withdraw failed - nothing redeemed");
        assertEq(positionManager.getPositionLiquidity(lendTokenId), 0, "position not re-entered");

        // 2) the owner's escape hatch also redeems everything and reverts, although half is redeemable
        vm.expectRevert(bytes("ERC4626: redeem more than max"));
        hook.autoLendForceExit(lendTokenId);

        // owner holds nothing - neither the redeemable assets nor the shares themselves
        assertEq(limitedVault0.balanceOf(address(this)), 0, "owner received no shares");
        assertEq(limitedVault0.balanceOf(address(hook)), shares, "all shares stuck in the hook");
    }

    function testPoC_lockLastsAsLongAsTheLimit() public {
        uint256 shares = _setUpLentPosition();

        // even a limit of shares - 1 (99.99...% redeemable) blocks every exit path
        limitedVault0.setRedeemLimit(shares - 1);
        vm.expectRevert(bytes("ERC4626: redeem more than max"));
        hook.autoLendForceExit(lendTokenId);

        // funds only come back once the vault can pay out the full recorded balance in one call
        limitedVault0.setRedeemLimit(type(uint256).max);
        uint256 before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        hook.autoLendForceExit(lendTokenId);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), before, "exit works only without a limit");
    }
}
