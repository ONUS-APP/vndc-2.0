// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract USDT is ERC20, ERC20Burnable, ERC20Permit {
    constructor()
        ERC20("USDT", "USDT")
        ERC20Permit("USDT")
    {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
