// Copyright (C) 2020 Centrifuge
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

pragma solidity =0.5.12;
import "ds-test/test.sol";

import "./mock.sol";
import { Dai } from "dss/dai.sol";
import "./auth.sol";


contract DaiJoinMock is Mock, Auth {

    Dai dai;

    constructor(address dai_) public {
        wards[msg.sender] = 1;
        dai = Dai(dai_);
    }

    function join(address usr, uint wad) external {
        dai.burn(msg.sender, wad);
    }

    function exit(address usr, uint wad) external {
        dai.mint(usr, wad);
    }
}
