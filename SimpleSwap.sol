// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title SimpleSwap - A decentralized ERC20 token exchange and liquidity pool
/// @author Milena Quirico
/// @notice Allows users to provide liquidity and swap tokens in a decentralized manner
/// @dev Implements constant product AMM model with 0.3% fee
contract SimpleSwap is ReentrancyGuard {

    /// @notice Struct to hold token reserves in a pair
    /// @dev Uses uint128 for gas-efficient storage
    struct Reserves {
        uint128 reserveA; ///< Reserve of token A
        uint128 reserveB; ///< Reserve of token B
    }

    /// @notice Holds data related to liquidity and balances for each token pair
    struct LiquidityData {
        uint totalSupply; ///< Total supply of liquidity tokens for this pair
        mapping(address => uint) balance; ///< Liquidity token balance for each user
        Reserves reserves; ///< Current reserves for this token pair
    }

    /// @notice Mapping of token pairs to their liquidity data
    mapping(address => mapping(address => LiquidityData)) public pairs;

    /// @notice Emitted when liquidity is added to a pair
    /// @param TokenA Address of token A
    /// @param TokenB Address of token B
    /// @param provider Liquidity provider address
    /// @param amountA Amount of token A provided
    /// @param amountB Amount of token B provided
    /// @param liquidity Amount of liquidity tokens issued
    event LiquidityAdded(
        address indexed TokenA,
        address indexed TokenB,
        address indexed provider,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    /// @notice Emitted when liquidity is removed from a pair
    /// @param TokenA Address of token A
    /// @param TokenB Address of token B
    /// @param provider Liquidity provider address
    /// @param amountA Amount of token A returned
    /// @param amountB Amount of token B returned
    /// @param liquidity Amount of liquidity tokens burned
    event LiquidityRemoved(
        address indexed TokenA,
        address indexed TokenB,
        address indexed provider,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    /// @notice Emitted when a token swap occurs
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @param trader Address of the user making the swap
    /// @param amountIn Input token amount
    /// @param amountOut Output token amount
    event TokensSwapped(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed trader,
        uint amountIn,
        uint amountOut
    );

    /// @notice Adds liquidity to a token pair
    /// @param TokenA Address of token A
    /// @param TokenB Address of token B
    /// @param amountADesired Desired amount of token A to add
    /// @param amountBDesired Desired amount of token B to add
    /// @param amountAMin Minimum acceptable amount of token A
    /// @param amountBMin Minimum acceptable amount of token B
    /// @param to Address receiving liquidity tokens
    /// @param deadline Timestamp after which transaction is invalid
    /// @return amountA Final amount of token A added
    /// @return amountB Final amount of token B added
    /// @return liquidity Liquidity tokens minted
    function addLiquidity(
        address TokenA,
        address TokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant returns (uint amountA, uint amountB, uint liquidity) {
        require(block.timestamp <= deadline, "Expired");
        require(TokenA != TokenB, "Identical tokens");
        require(amountADesired > 0 && amountBDesired > 0, "Invalid amounts");

        IERC20(TokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(TokenB).transferFrom(msg.sender, address(this), amountBDesired);

        LiquidityData storage pair = pairs[TokenA][TokenB];

        uint128 reserveA = pair.reserves.reserveA;
        uint128 reserveB = pair.reserves.reserveB;

        if (pair.totalSupply == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
            liquidity = _sqrt(amountA * amountB);
        } else {
            uint amountBOptimal = (amountADesired * reserveB) / reserveA;
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Slippage B");
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                uint amountAOptimal = (amountBDesired * reserveA) / reserveB;
                require(amountAOptimal >= amountAMin, "Slippage A");
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
            liquidity = (amountA * pair.totalSupply) / reserveA;
        }

        require(amountA >= amountAMin && amountB >= amountBMin, "Slippage");

        pair.reserves.reserveA += uint128(amountA);
        pair.reserves.reserveB += uint128(amountB);
        pair.totalSupply += liquidity;
        pair.balance[to] += liquidity;

        emit LiquidityAdded(TokenA, TokenB, to, amountA, amountB, liquidity);
    }

    /// @notice Removes liquidity from a token pair
    /// @param TokenA Address of token A
    /// @param TokenB Address of token B
    /// @param liquidity Amount of liquidity tokens to burn
    /// @param amountAMin Minimum token A expected
    /// @param amountBMin Minimum token B expected
    /// @param to Address receiving the tokens
    /// @param deadline Deadline for executing the transaction
    /// @return amountA Token A amount returned
    /// @return amountB Token B amount returned
    function removeLiquidity(
        address TokenA,
        address TokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant returns (uint amountA, uint amountB) {
        require(block.timestamp <= deadline, "Expired");
        require(liquidity > 0, "Zero liquidity");

        LiquidityData storage pair = pairs[TokenA][TokenB];
        require(pair.balance[msg.sender] >= liquidity, "Insufficient balance");

        uint128 reserveA = pair.reserves.reserveA;
        uint128 reserveB = pair.reserves.reserveB;

        amountA = (liquidity * reserveA) / pair.totalSupply;
        amountB = (liquidity * reserveB) / pair.totalSupply;

        require(amountA >= amountAMin && amountB >= amountBMin, "Slippage");

        pair.reserves.reserveA -= uint128(amountA);
        pair.reserves.reserveB -= uint128(amountB);
        pair.totalSupply -= liquidity;
        pair.balance[msg.sender] -= liquidity;

        IERC20(TokenA).transfer(to, amountA);
        IERC20(TokenB).transfer(to, amountB);

        emit LiquidityRemoved(TokenA, TokenB, msg.sender, amountA, amountB, liquidity);
    }

    /// @notice Swaps an exact amount of tokens
    /// @param amountIn Exact input token amount
    /// @param amountOutMin Minimum output token amount
    /// @param path Token swap route [tokenIn, tokenOut]
    /// @param to Recipient address
    /// @param deadline Expiration timestamp
    /// @return amounts Array of input and output amounts
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external nonReentrant returns (uint[] memory amounts) {
        require(block.timestamp <= deadline, "Expired");
        require(path.length == 2, "Invalid path");
        require(amountIn > 0, "Zero input");

        address tokenIn = path[0];
        address tokenOut = path[1];

        LiquidityData storage pair = pairs[tokenIn][tokenOut];

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint amountOut = getAmountOut(amountIn, pair.reserves.reserveA, pair.reserves.reserveB);
        require(amountOut >= amountOutMin, "Slippage");

        pair.reserves.reserveA += uint128(amountIn);
        pair.reserves.reserveB -= uint128(amountOut);

        IERC20(tokenOut).transfer(to, amountOut);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;

        emit TokensSwapped(tokenIn, tokenOut, msg.sender, amountIn, amountOut);
    }

    /// @notice Returns the price of tokenA in terms of tokenB
    /// @param TokenA Address of token A
    /// @param TokenB Address of token B
    /// @return price Current price, scaled to 18 decimals
    function getPrice(address TokenA, address TokenB) external view returns (uint price) {
        Reserves memory reserves = pairs[TokenA][TokenB].reserves;
        require(reserves.reserveA > 0 && reserves.reserveB > 0, "Zero reserves");
        price = (uint(reserves.reserveA) * 1e18) / reserves.reserveB;
    }

    /// @notice Calculates output amount given an input using constant product formula
    /// @dev Includes a 0.3% fee
    /// @param amountIn Input token amount
    /// @param reserveIn Reserve of input token
    /// @param reserveOut Reserve of output token
    /// @return amountOut Calculated output token amount
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure returns (uint amountOut) {
        require(amountIn > 0, "Zero input");
        require(reserveIn > 0 && reserveOut > 0, "Invalid reserves");

        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Internal function to compute square root
    /// @dev Used to calculate initial liquidity token supply
    /// @param x Input value
    /// @return y Square root of x
    function _sqrt(uint x) internal pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
