/// tinlake_manager.sol -- Tinlake dss adapter

// 2020 Lucas Vogelsang <lucas@centrifuge.io>,
// 2020 Martin Lundfall <martin.lundfall@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;

interface GemLike {
    function decimals() external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
    function totalSupply() external returns (uint256);
    function balanceOf(address) external returns (uint256);
}

interface JoinLike {
    function join(address,uint256) external;
    function exit(address,uint256) external;
}

interface EndLike {
    function debt() external returns (uint256);
}

interface RedeemLike {
    function redeemOrder(uint256) external;
    function disburse(uint256) external returns (uint256,uint256,uint256,uint256);
}

interface VatLike {
    function urns(bytes32,address) external returns (uint256,uint256);
    function ilks(bytes32) external returns (uint256,uint256,uint256,uint256,uint256);
    function live() external returns(uint);
}

interface MIP21UrnLike {
    function lock(uint256 wad) external;
    function free(uint256 wad) external;
    // n.b. DAI can only go to the output conduit
    function draw(uint256 wad) external;
    // n.b. anyone can wipe
    function wipe(uint256 wad) external;
    function quit() external;
}

// This contract is essentially a merge of
// a join and a cdp-manager.

// It manages only one urn, which can be liquidated in two stages:
// 1) In the first stage, set safe = false and call
// pool.disburse() to try to recover as much dai as possible.

// 2) After the first liquidation period has completed, we either managed to redeem
// enough dai to wipe off all cdp debt, or this debt needs to be written off
// and addded to the sin.

// Note that the internal gem created as a result of `join` through this manager is
// not only DROP as an ERC20 balance in this contract, but also what's currently
// undergoing redemption from the Tinlake pool.

contract TinlakeManager {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth {
        require(live, "TinlakeMgr/not-live");
        wards[usr] = 1;
        emit Rely(usr);
    }
    function deny(address usr) external auth {
        require(live, "TinlakeMgr/not-live");
        wards[usr] = 0;
        emit Deny(usr);
    }
    modifier auth {
        require(wards[msg.sender] == 1, "TinlakeMgr/not-authorized");
        _;
    }

    modifier operatorOnly {
        require(msg.sender == operator, "TinlakeMgr/operator-only");
        _;
    }

    // Events
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Draw(uint256 wad);
    event Wipe(uint256 wad);
    event Join(uint256 wad);
    event Exit(uint256 wad);
    event SetOperator(address indexed usr);
    event Tell(uint256 wad);
    event Unwind(uint256 payBack);
    event Sink(uint256 tab);
    event Recover(uint256 recovered, uint256 payBack);
    event Cage();
    event File(bytes32 indexed what, address indexed data);
    event Migrate(address indexed dst);

    // The operator manages the cdp, but is not authorized to call kick or cage.
    address public operator;

    bool public safe; // Soft liquidation not triggered
    bool public glad; // Write-off not triggered
    bool public live; // Global settlement not triggered

    uint256 public tab;  // Dai written off
    bytes32 public ilk; // name of the collateral type

    // --- Contracts ---
    // dss components
    VatLike public vat;
    GemLike public dai;
    EndLike public end;
    address public vow;
    JoinLike public daiJoin;

    // Tinlake components
    GemLike      public gem;
    GemLike      public rwaToken;
    RedeemLike   public pool;

    // MIP21 RWAUrn
    MIP21UrnLike public urn;

    uint256 public constant dec = 18;

    address public tranche;

    constructor(address dai_,      address rwaToken_,
                address drop_,     address pool_,
                address operator_, address tranche_,
                address end_,      bytes32 ilk_
                ) public {

        dai = GemLike(dai_);
        end = EndLike(end_);
        gem = GemLike(drop_);
        rwaToken = GemLike(rwaToken_);


        require(gem.decimals() == dec, "TinlakeMgr/decimals-dont-match");
        require(rwaToken.decimals() == dec, "TinlakeMgr/decimals-dont-match");
        pool = RedeemLike(pool_);

        ilk = ilk_;
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        operator = operator_;

        safe = true;
        glad = true;
        // mgr is live after lock() call
        live = false;

        // rwaUrn allowance for rwaToken
        rwaToken.approve(address(urn), uint(-1));
        tranche = tranche_;
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = add(x, sub(y, 1)) / y;
    }
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x > y ? y : x;
    }


    // moves the rwaToken into the vault
    // requires that mgr contract holds the rwaToken
    function lock(uint wad) public operatorOnly {
        require(vat.live() == 1, "TinlakeManager/mkr-in-ES");
        urn.lock(wad);
        live = true;
    }

    // --- Vault Operation---
    // join & exit move the gem directly into/from the urn
    function join(uint256 wad) public operatorOnly {
        require(safe && live, "TinlakeManager/bad-state");
        require(int256(wad) >= 0, "TinlakeManager/overflow");
        gem.transferFrom(msg.sender, address(this), wad);
        emit Join(wad);
    }

    // transfers DROP into the MGR
    function exit(uint256 wad) public operatorOnly {
        require(safe && live, "TinlakeManager/bad-state");
        require(wad <= 2 ** 255, "TinlakeManager/overflow");
        gem.transfer(msg.sender, wad);
        emit Exit(wad);
    }

    // draw & wipe call daiJoin.exit/join immediately
    function draw(uint256 wad) public operatorOnly {
        require(safe && live, "TinlakeManager/bad-state");
        urn.draw(wad);
        dai.transferFrom(address(this), msg.sender, wad);
        emit Draw(wad);
    }

    function wipe(uint256 wad) public operatorOnly {
        require(safe && live, "TinlakeManager/bad-state");
        dai.transferFrom(msg.sender, address(this), wad);
        urn.wipe(wad);
        emit Wipe(wad);
    }

    function free(uint256 wad)  public operatorOnly {
        urn.quit();
    }

    // --- Administration ---
    function setOperator(address newOperator) external operatorOnly  {
        operator = newOperator;
        emit SetOperator(newOperator);
    }

    function migrate(address dst) public auth  {
        dai.approve(dst, uint256(-1));
        gem.approve(dst, uint256(-1));
        live = false;
        emit Migrate(dst);
    }

    function file(bytes32 what, address data) public auth {
        emit File(what, data);
        if (what == "daiJoin") daiJoin = JoinLike(data);
        else if (what == "end")  end = EndLike(data);
        else if (what == "urn") {
            urn = MIP21UrnLike(data);
            dai.approve(data, uint256(-1));
        }
        else revert("Vat/file-unrecognized-param");
    }

    // --- Liquidation ---
    // triggers a soft liquidation of the DROP collateral
    // a redeemOrder is submitted to receive DAI back
    function tell() public auth {
        require(safe, "TinlakeManager/not-safe");
        uint256 ink = gem.balanceOf(address(this));
        safe = false;
        gem.approve(tranche, ink);
        pool.redeemOrder(ink);
        emit Tell(ink);
    }

    // triggers the payout of a DROP redemption
    // method can be called multiple times after the liquidation until all
    // DROP tokens are redeemed
    function unwind(uint256 endEpoch) public {
        require(!safe && glad && live, "TinlakeManager/not-soft-liquidation");
        (uint256 redeemed, , ,uint256 remainingDrop) = pool.disburse(endEpoch);
        // here we use the urn instead of address(this)
        (, uint256 art) = vat.urns(ilk, address(urn));

        (, uint256 rate, , ,) = vat.ilks(ilk);
        uint256 cdptab = mul(art, rate);
        uint256 payBack = min(redeemed, divup(cdptab, RAY));

        urn.wipe(payBack);

        // Return possible remainder to the owner
        dai.transfer(operator, dai.balanceOf(address(this)));
        emit Unwind(payBack);
    }

    // --- Write-off ---
    // method should be called before RwaLiquidationOracle.cull()
    function sink() public auth {
        require(!safe && glad && live, "TinlakeManager/bad-state");
        (, uint256 art) = vat.urns(ilk, address(urn));
        require(art <= 2 ** 255, "TinlakeManager/overflow");
        (, uint256 rate, , ,) = vat.ilks(ilk);

        tab = mul(rate, art);
        glad = false;
        emit Sink(tab);
    }

    function recover(uint256 endEpoch) public {
        require(!glad, "TinlakeManager/not-written-off");

        (uint256 recovered, , ,) = pool.disburse(endEpoch);
        uint256 payBack;
        if (end.debt() == 0) {
            payBack = min(recovered, tab / RAY);
            daiJoin.join(address(vow), payBack);
            tab = sub(tab, mul(payBack, RAY));
        }
        dai.transfer(operator, dai.balanceOf(address(this)));
        emit Recover(recovered, payBack);
    }

    function cage() external {
        require(!glad, "TinlakeManager/bad-state");
        require(wards[msg.sender] == 1 || vat.live() == 0, "TinlakeManager/not-authorized");
        live = false;
        emit Cage();
    }
}
