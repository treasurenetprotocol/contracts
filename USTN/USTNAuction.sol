// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.6;

import "contracts/governanceInterface.sol";
import "contracts/USTNInterface.sol";

interface USTNFInterface{
    function auctionOver(address bider, uint tokens, uint a, uint b)external returns(bool);
}

contract USTNAuction{
    //_extractStatus 1: not extracted 2: extracted
    event auctionDetail(uint n, uint _time, address bider, uint _highValue, uint _extractStatus);
    //_status 1:start 2:ing 3:over
    event auctionStatus(uint n, uint _time, uint _auction, uint _startValue, uint _highValue, uint _overTime, uint _status);
    event personalAuction(address _user, uint n, uint _sales);

    struct auctions{
        uint sales;
        uint startValue;
        uint nowValue;
        uint timeOver;
        uint state;
        uint debt;
    }
    
    auctions[] auctionList;
    
    struct auctionbider{
        uint time;
        address bider;
        uint value;
    }

    mapping(uint => address) bider;
    mapping(uint => mapping(address => uint)) bidValue;
    mapping(uint => auctionbider[]) bidUsers;
    mapping(uint => mapping(address => bool)) _bider;
    uint bidDuration = 1 days;

    USTNInterface USTNget;
    USTNFInterface USTNFget;
    governanceInterface verifyAddress;

    constructor(address governanceAddress) {
        verifyAddress = governanceInterface(governanceAddress);
    }

    modifier onlyContract(string memory _name) {
        require(verifyAddress.checkTargetSenderContractGroup(_name, msg.sender), "USTNAuction: Only Contract");
        _;
    }

    modifier onlyUser(string memory _name){
        require(verifyAddress.checkTargetSenderGroup(_name, msg.sender), "USTNAuction: Only FoundationManager can use this function.");
        _;
    }

    //Set the related OSM contract address
    function setUSTN(address newAddress)public onlyUser("FoundationManager") returns(bool result){
        USTNget = USTNInterface(newAddress);
        
        return true;
    }

    //Set the related USTNFinance contract address
    function setUSTNFinance(address newAddress)public onlyUser("FoundationManager") returns(bool result){
        USTNFget = USTNFInterface(newAddress);
        
        return true;
    }

    //Set the related governance contract address
    function setGovernance(address newGovernance)public onlyUser("FoundationManager") returns(bool result){
        verifyAddress = governanceInterface(newGovernance);
        
        return true;
    }

    //Auction listing operation, triggered by USTNFinance contract
    //mortgage is the number of UNITs in the auction, debt is the starting auction price, and _debt is the interest generated by the loan
    function auctionStart(uint mortgage, uint debt, uint _debt)public onlyContract("USTNFinance") returns(auctions memory){
        auctions memory auction;
        auction.sales = mortgage;
        auction.startValue = debt;
        auction.nowValue = debt;
        auction.timeOver = block.timestamp + bidDuration;
        auction.state = 1;
        auction.debt = _debt;
        auctionList.push(auction);
        
        emit auctionStatus(auctionList.length - 1, block.timestamp, mortgage, debt, 0, block.timestamp + bidDuration, 1);
        return auction;
    }

    //Query the information of all auction items
    function queryAuctions()public view returns(auctions[] memory){
        return auctionList;
    }

    //The winner of the n th auction item and the auction price of the winner
    function queryBider(uint n)public view returns(address, uint){
        return (bider[n], bidValue[n][bider[n]]);
    }

    function isbider(uint n, address pAddr)internal view returns(bool){
        return _bider[n][pAddr];
    }

    //Bidding function, the n th auction item, the USTN of the bidAmount amount
    function bid(uint n, uint bidAmount)public returns(bool){
        require(auctionList[n].timeOver > block.timestamp, "USTNAuction: auction is over");
        require(auctionList[n].nowValue < (bidValue[n][msg.sender] + bidAmount), "USTNAuction: bid is not enough");
        require(USTNget.bidCost(msg.sender, bidAmount), "USTNAuction: USTN is not enough");
        if(!isbider(n, msg.sender)){
            _bider[n][msg.sender]=true;

            auctionbider memory bi;
            bi.time = block.timestamp;
            bi.bider = msg.sender;
            bi.value = bidAmount;
            bidUsers[n].push(bi);
        }

        bider[n] = msg.sender;
        auctionList[n].nowValue = bidValue[n][msg.sender] + bidAmount;
        bidValue[n][msg.sender] += bidAmount;  
        
        emit auctionDetail(n, block.timestamp, msg.sender, bidValue[n][msg.sender], 1);
        emit auctionStatus(n, block.timestamp, auctionList[n].sales, auctionList[n].startValue , auctionList[n].nowValue, auctionList[n].timeOver, 2);
        return true;
    }

    //Retrieve the USTN bid for the n th auction item, which can only be called when it is not currently the highest price
    function bidWithdrawal(uint n)public returns(bool){
        require(bider[n] != msg.sender,"USTNAuction: you are owner of bid");
        require(bidValue[n][msg.sender] > 0,"USTNAuction: no USTN on bid");
        require(USTNget.bidBack(msg.sender, bidValue[n][msg.sender]), "USTNAuction: bidBack failed");
        bidValue[n][msg.sender] = 0;
        
        emit auctionDetail(n, block.timestamp, msg.sender, bidValue[n][msg.sender], 2);
        return true;
    }

    //Get the n th auction item and update the corresponding status at the same time
    function getAuction(uint n)public returns(bool){
        require(auctionList[n].state != 2,"USTNAuction: auction is not over");
        require(auctionList[n].timeOver < block.timestamp, "USTNAuction: auction is not over");
        require(bider[n] == msg.sender, "USTNAuction: you are not owner of bid");
        USTNFget.auctionOver(msg.sender, auctionList[n].sales, auctionList[n].debt, auctionList[n].startValue - auctionList[n].debt);
        USTNget.burn(verifyAddress.getAddress("AuctionManager"), auctionList[n].startValue);
        auctionList[n].state = 2;
        
        emit auctionStatus(n, block.timestamp, auctionList[n].sales, auctionList[n].startValue , auctionList[n].nowValue, auctionList[n].timeOver, 3);
        emit personalAuction(msg.sender, n, auctionList[n].sales);
        return true;
    }

    //Get the addresses of all users who have participated in the bidding of the n th auction item
    function getAuctionBider(uint n)public view returns(auctionbider[] memory){
        return bidUsers[n];
    }

    //Update the status, when the auction time ends and there is no bid
    //FoundationManager can update the time of the auction item and restart the auction
    function upgradeState()public onlyUser("FoundationManager") returns(bool){
        for(uint a=0; a < auctionList.length;a++){
            if(auctionList[a].timeOver < block.timestamp && bider[a]==address(0)){
                auctionList[a].timeOver = block.timestamp + bidDuration;
                emit auctionStatus(a, block.timestamp, auctionList[a].sales, auctionList[a].startValue, 0, block.timestamp + bidDuration, 1);
            }
        }
        return true;
    }
}
