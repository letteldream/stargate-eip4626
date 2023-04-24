//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import "./interfaces/IStargateRouter.sol";
import "./interfaces/IStargateFarm.sol";
import "./interfaces/IStargatePool.sol";
import "./interfaces/IExchange.sol";

error INVALID_INPUT();

abstract contract StargateWrapper is ERC4626 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStargatePool;

    /// @notice Underlying Token
    IERC20 public immutable token;
    /// @notice Stargate Token
    IERC20 public immutable stgToken;
    /// @notice Stargate Pool
    IStargatePool public immutable lpToken;
    /// @notice Stargate Router
    IStargateRouter public immutable stargateRouter;
    /// @notice Stargate Farm
    IStargateFarm public immutable stargateFarm;
    /// @notice Exchange
    IExchange public immutable exchange;
    /// @notice Stargate Farm Id
    uint256 public immutable farmId;
    /// @notice Stargate Pool Id
    uint256 public immutable poolId;

    /*********************************/
    /*           INITIALIZE          */
    /*********************************/

    constructor(
        IERC20 _token,
        IERC20 _stgToken,
        IStargatePool _lpToken,
        IStargateRouter _stargateRouter,
        IStargateFarm _stargateFarm,
        IExchange _exchange,
        uint256 _poolId,
        uint256 _farmId
    ) ERC4626(_token) {
        if (_lpToken.token() != address(_token)) revert INVALID_INPUT();

        token = _token;
        stgToken = _stgToken;
        lpToken = _lpToken;
        stargateRouter = _stargateRouter;
        stargateFarm = _stargateFarm;
        exchange = _exchange;
        poolId = _poolId;
        farmId = _farmId;
    }

    /*********************************/
    /*            INTERNAL           */
    /*********************************/

    function _amountLDtoLP(
        uint256 _amountLD
    ) internal view returns (uint256 _amountLP) {
        uint256 _amountSD = _amountLDtoSD(_amountLD);
        _amountLP =
            (_amountSD * lpToken.totalSupply()) /
            lpToken.totalLiquidity();
    }

    function _amountLDtoSD(
        uint256 _amountLD
    ) internal view returns (uint256 _amountSD) {
        _amountSD = _amountLD / lpToken.convertRate();
    }

    function _deposit(uint256 _amount) internal {
        if (_amount == 0 || _amountLDtoSD(_amount) == 0) return;

        // Add Liquidity
        token.safeApprove(address(stargateRouter), _amount);
        stargateRouter.addLiquidity(poolId, _amount, address(this));

        uint256 lpBalance = lpToken.balanceOf(address(this));

        // LP Stake
        lpToken.safeApprove(address(stargateFarm), lpBalance);
        stargateFarm.deposit(farmId, lpBalance);
    }

    function _deposit(
        address _caller,
        address _receiver,
        uint256 _assets,
        uint256 _shares
    ) internal virtual override {
        if (_assets == 0 || _amountLDtoSD(_assets) == 0) return;

        // Transfer Token
        token.safeTransferFrom(_caller, address(this), _assets);

        // Deposit Token
        _deposit(_assets);

        // Mint Shares
        _mint(_receiver, _shares);

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    function _withdraw(uint256 _amount) internal returns (uint256) {
        uint256 balance = token.balanceOf(address(this));

        // Unstake & Remove Liquidity
        if (_amount > balance) {
            uint256 lpToRemove = _amountLDtoLP(_amount - balance);
            (uint256 lpAmount, ) = stargateFarm.userInfo(farmId, address(this));

            if (lpToRemove > lpAmount) {
                lpToRemove = lpAmount;
            }

            if (lpToRemove > 0) {
                _withdrawFromFarm(lpToRemove);
                // _sellReward();
                balance = token.balanceOf(address(this));
            }

            if (balance < _amount) {
                _amount = balance;
            } else if (balance > _amount) {
                _deposit(balance - _amount);
            }
        }

        return _amount;
    }

    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _assets,
        uint256 _shares
    ) internal virtual override {
        // Burn Shares
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }
        _burn(_owner, _shares);

        // Withdraw Token
        _assets = _withdraw(_assets);

        // Transfer Token
        token.safeTransfer(_receiver, _assets);

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    function _withdrawFromFarm(uint256 _lpAmount) internal {
        stargateFarm.withdraw(farmId, _lpAmount);
        stargateRouter.instantRedeemLocal(
            uint16(poolId),
            _lpAmount,
            address(this)
        );
        uint remainLp = lpToken.balanceOf(address(this));
        if (remainLp != 0) {
            lpToken.safeApprove(address(stargateFarm), remainLp);
            stargateFarm.deposit(farmId, remainLp);
        }
    }

    function _compound() internal {
        _deposit(_sellReward());
    }

    function _sellReward() internal returns (uint256 received) {
        uint256 stgBalance = stgToken.balanceOf(address(this));

        if (stgBalance != 0) {
            stgToken.transfer(address(exchange), stgBalance);
            received = exchange.swap(
                stgBalance,
                address(stgToken),
                address(token),
                address(this)
            );
        }
    }

    /*********************************/
    /*             PUBLIC            */
    /*********************************/

    function compound() external {
        stargateFarm.withdraw(farmId, 0);

        _compound();
    }

    /*********************************/
    /*              VIEW             */
    /*********************************/

    function totalAssets() public view virtual override returns (uint256) {
        (uint256 lpAmount, ) = stargateFarm.userInfo(farmId, address(this));
        uint256 stakedTokenAmount = IStargatePool(address(lpToken))
            .amountLPtoLD(lpAmount);

        return token.balanceOf(address(this)) + stakedTokenAmount;
    }
}
