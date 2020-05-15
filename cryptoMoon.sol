pragma solidity ^0.5.0;

// CryptoMoon smart contract
//The main idea of this contract is to keep it simple but efficient. 
//The rules are as follows :
// - At the start of the game the contract chooses a ticket price from 0.01 to 0.1 ETH (a participant limit currently set to 100 is editable by the owner if the game has not yet started - thx to the currentState variable)
// - During the game the players can buy maximum 10 tickets (defined by var : maxTicketPerUser). The more tickets a user buy, the more chances he will have to win the jackpot. For instance if a user buy 2 tickets he will have 2% chance of winning (because participantLimit is set to 100). 
// - When the number of tickets bought reaches the participants limit the smart contract will call the random.org API by invoking the generateIntegers function in the range [0 - users.length - 1].
// - The random number obtained represents the position of the winning ticket. It means if you buy a ticket at position 55 and if the random number is 55 you win the ETH jackpot created by the sum of all tickets.
//Here is a concrete example :
//  The smart contract starts the game and chooses randomly a the ticket price at 0.08 ETH (participants limit is set to 100 by default during contract creation). 
//  You buy the tickets number 3, 10 and 22 (represented by address payable[] users;) -> You have 3% chance of winning the jackpot. 
//  When 100 tickets are sold (participantLimit reaches) -> the smart contract trigger random.org API ang get the random number 22. 
//  You WIN the jackpot set to 8 ETH (totalBet variable) (0,08 ETH * 100) (minus house fee actually set to 3% -> Yes I'm not volunteer sorry :sunglasses:). 
//  You open a bottle of Champagne in my honor and the smart contract restarts the game with the terminate() method

import "github.com/provable-things/ethereum-api/blob/master/oraclizeAPI_0.5.sol";

contract cryptoMoonContract is usingOraclize{
    //The game can have 3 states 
    // - Created : Nobody has bought a ticket yet -> At this moment the owner can edit ticket price & participantLimit if required
    // - Running : The game is locked in running mode, the only thing which can stop is to wait for the number of tickets bought == participantLimit
    // - Waiting : The game is waiting for oraclize to respond with the random number from random.org API
    enum State { Created, Running, Waiting }
    // users : an array which represents the tickets bought by different user
    // For each ticket bought the address of the player is added 
    address payable[] users;
    // admin : contains owner public address
    address payable admin;
    //totalBet : the total amount purchased with tickets
    uint public totalBet = 0;
    //ticketPrice : minimum price per ticket
    uint public ticketPrice = 0;
    //participantLimit : the minimum number of players before the game choose a winner by triggering random.org API to get a random number
    uint public participantLimit = 100;
    //currentState : current state of the game as described above
    State public currentState;
    //usersBet : a map which contains the total amount of wei spend by user by gameIndex
    mapping(uint => mapping(address => uint)) usersBet;
    //gameIndex : game index
    uint public gameIndex = 0;
    //validIds : used for validating oraclize query ids
    mapping(bytes32 => bool) validIds; 
    //gasLimitForOraclize : gas limit for Oraclize callback
    uint public gasLimitForOraclize = 1000000; 
    //gasPriceForOraclize : gas limit for Oraclize callback
    uint public gasPriceForOraclize = 3000000000;// 3 Gwei
    //gasLimitsForOraclize : contains the gas limits depending on ticket price
    uint[3] public gasLimitsForOraclize; 
    //lastWinnerIndex : last winner index from random.rog API
    uint public lastWinnerIndex = 0;
    //maxTicketPerUser : Maximum tickets buyable per user per game
    uint public maxTicketPerUser = 10;
    
    //Events
    //event payout : triggered when a player has won the jackpot
    event payout(address target, uint amount);
    //event ticketBought : triggered when a user has bought a ticket
    event ticketBought(address addressFrom, uint value);
    //event gameStart : triggered when the game restarts or when the owner change the ticket price or the participantLimit
    event gameStart(uint ticketPrice, uint participantLimit);
    //event gameWaiting : triggered when the game is waiting for the random number (random winner index)
    event gameWaiting();
    
    //CONSTANT
    //Random.org encrypted key 
    string constant RANDOM_ORG_API_KEY = "BIYEtIOoJ1rJSQ1m0MrnWjdmw4Yr7Bnmu8CdvInMMDJMSsl/ytm0iFVIwBmObX3dxPShZdQt5akS5j0V+pLQ/RamH8PSwKnE/FtVeXptpSTxGoFjRsSCY6nYECKQ5mDPGbbgppNLlXsLftZv+pjPu3q86gbk";
   
   
    modifier onlyIf(bool _condition) {
        require(_condition);
        _;
    }
   
    modifier inState(State _state) {
        require(currentState == _state);
        _;
    }

    constructor(uint _participantLimit) public {
        admin = msg.sender;
        participantLimit = _participantLimit;
        gasLimitsForOraclize[0] = 700000;
        gasLimitsForOraclize[1] = 1500000;
        gasLimitsForOraclize[2] = 2000000;
        oraclize_setCustomGasPrice(gasPriceForOraclize * 1 wei); 
        reset();
    }
    
    /***********************
        GAME METHODS
    ***********************/
    
    //buyTicket() : A method to buy a ticket only if the tx value >= ticketPrice & users count < participantLimit
    function buyTicket() public payable onlyIf(msg.value >= ticketPrice) onlyIf(users.length < participantLimit) {
        //A player can buy mutliple tickets in one transaction if he wants
        uint numberOfTickets = msg.value / ticketPrice;
        uint ticketsAlreadyOwn = (usersBet[gameIndex][msg.sender] / ticketPrice);
        
        require((numberOfTickets + ticketsAlreadyOwn) <= maxTicketPerUser);
        
        for (uint i=0; i<numberOfTickets ; i++){
            //For each ticket we add the player address in the users map
            users.push(msg.sender);
        }
        
        //After the first ticket bought the game state change to State.Running -> ticketPrice & participantLimit are no more editable by the owner
        if(currentState == State.Created){
            currentState = State.Running;
        }
       
        //total bet for all users during a single game
        totalBet += msg.value;
        //For each user we save the total value he bet
        usersBet[gameIndex][msg.sender] += msg.value;
        
        //Emit ticketBought event
        emit ticketBought(msg.sender, msg.value);
        
        //When the number of tickets bought reach the participanLimit and if the game is not waiting for a random number, we trigger the getRandomNumber method
        if (users.length >= participantLimit && currentState != State.Waiting) {
            getRandomNumber();
        }
    }
   
    function terminate(uint _winnerRandomIndex) private inState(State.Waiting) {
        // Take 3% for the house
        uint houseFee = (totalBet / 100.0) * 3;
        // Pay the rest to the winner
        uint payoutToWinner = totalBet - houseFee;
       
        //Select the random winner
        address payable winner = users[_winnerRandomIndex];
        //Pay the random winner
        winner.transfer(payoutToWinner);
        //Pay the house
        admin.transfer(houseFee);
        
        //Emit payout event
        emit payout(winner, payoutToWinner);
        
        gameIndex++;
        
        //Reset the game
        reset();
    }
   
    function reset() private{
        totalBet = 0;
        //Reset users array
        users.length = 0;
        //Reset the state to State.Created, owner can edit participantLimit & minimum bet if need during this state
        currentState = State.Created;
        //Pseudo random ticket price in wei - It's not mandatory to get a true random number for this case because ticket price is not as sensitive as the winnerRandomIndex
        ticketPrice = ((uint(blockhash(block.number-1)) % 10) + 1) * 10000000000000000;
        //Calcule gas limit for oraclize depending on ticket price
        calculateGasLimitForOraclize();
        //Emit gameStart event because config has changed
        emit gameStart(ticketPrice, participantLimit);
    }
    
    /***********************
        GET RANDOM NUMBER
    ***********************/
    
    //getRandomNumber() : Query Random.org with Oraclize to get random number
    function getRandomNumber() private onlyIf(users.length >= participantLimit && currentState != State.Waiting) {
        //Only get a random number once with currentState == Waiting
        currentState = State.Waiting;
        
        //emit event waiting winner
        emit gameWaiting();
        
        //Call Random.org api with Oraclize
        //The gas are paid by the contract balance -> fed by the owner with feedBalance() method
        string memory data =  strConcat("[URL] ['json(https://api.random.org/json-rpc/1/invoke).result.random.data.0', '\\n{\"jsonrpc\": \"2.0\", \"method\": \"generateSignedIntegers\", \"params\": { \"apiKey\": \"${[decrypt] ",RANDOM_ORG_API_KEY,"}\", \"n\": 1, \"min\": 0, \"max\": ", integerToString(users.length - 1) ,", \"replacement\": true, \"base\": 10${[identity] \"}\"}, \"id\": 14215${[identity] \"}\"}']");
        bytes32 queryId = oraclize_query( "nested", data, gasLimitForOraclize);
        
        //Add query id to mapping
        validIds[queryId] = true;
    }
    
    // Callback function for Oraclize once it retreives the data 
    // We only allow Oraclize to call this method with msg.sender >= oraclize_cbAddress()
    function __callback(bytes32 _queryId, string memory _result, bytes memory  _proof) public onlyIf(msg.sender >= oraclize_cbAddress()){
        //Validate the id
        require(validIds[_queryId]);
        
        //parse random number, result is of the form: [99]
        lastWinnerIndex = parseInt(_result);
        terminate(lastWinnerIndex);

        // reset mapping of this id to false
        // this ensures the callback for a given queryId never called twice
        validIds[_queryId] = false;
    }
    
    /***************
        GET/SET
    ***************/
   
    //A method to edit ticket price if needed - Only the owner can call it and only if currentState == State.Created
    function setTicketPrice(uint _ticketPriceInWei) public onlyIf(msg.sender == admin) onlyIf(currentState == State.Created){
        ticketPrice = _ticketPriceInWei;
        calculateGasLimitForOraclize();
        //Emit gameStart event because config has changed
        emit gameStart(ticketPrice, participantLimit);
    }
    
    function calculateGasLimitForOraclize() private {
        if(ticketPrice <= 30000000000000000){
            gasLimitForOraclize = gasLimitsForOraclize[0];
        }else if(ticketPrice <= 80000000000000000){
            gasLimitForOraclize = gasLimitsForOraclize[1];
        }else{
            gasLimitForOraclize = gasLimitsForOraclize[2];
        }
    }
   
    //A method to edit participantLimit if needed - Only the owner can call it and only if currentState == State.Created
    function setParticipantLimit(uint _limit) public onlyIf(msg.sender == admin) onlyIf(currentState == State.Created){
        participantLimit = _limit;
        //Emit gameStart event because config has changed
        emit gameStart(ticketPrice, participantLimit);
    }
    
    //A method to edit gasLimitForOraclize if needed
    function setGasLimitForOzaclize(uint _gasLimit, uint _index) public onlyIf(msg.sender == admin){
        gasLimitForOraclize = _gasLimit;
        gasLimitsForOraclize[_index] = _gasLimit;
    }
    
    //A method to edit gasLimitForOraclize if needed
    function setGasPriceForOzaclize(uint _gasPrice) public onlyIf(msg.sender == admin){
        oraclize_setCustomGasPrice(_gasPrice * 1 wei);
        gasPriceForOraclize = _gasPrice;
    }
    
    //A method to edit maxTicketPerUser / Game
    function setMaxTicketPerUser(uint _maxTicketPerUser) public onlyIf(msg.sender == admin) onlyIf(currentState == State.Created){
        maxTicketPerUser = _maxTicketPerUser;
    }
    
    
    //A method to get all curent users in this game
    function getUsers() public view returns (address payable[] memory) {
       return users;
    }
    
    //A method to get all curent users bet in this game
    function getUserBet(address addr) public view returns (uint) {
       return usersBet[gameIndex][addr];
    }
    
    //Get total contract balance
    function getContractBalance() public view returns (uint){
        return address(this).balance;    
    }
    
    /*******************
        OWNER METHODS
    *******************/
    
    //Method to add admin own funds
    //For instance to be sure we have enough gas to pay Oraclize calls
    function addOwnerFunds() public payable onlyIf(msg.sender == admin){
        
    }
    
    //Unlock the situation if Oraclize call fail due to not enough gas -> admin must provide funds + set currentState == State.Running and call getRandomNumber()
    function forceGetRandomNumber() public payable onlyIf(msg.sender == admin) onlyIf(currentState != State.Running){
        currentState = State.Running;
        getRandomNumber();
    }
    
    // Send funds to admin when destroy only if game is not running
    function destroy() public onlyIf(msg.sender == admin) onlyIf(currentState != State.Running){ // so funds not locked in contract forever
        selfdestruct(admin); 
    }
    
    /***************
        UTILS
    ***************/
    function integerToString(uint _i) internal pure returns (string memory) {
      
      if (_i == 0) {
         return "0";
      }
      uint j = _i;
      uint len;
      
      while (j != 0) {
         len++;
         j /= 10;
      }
      bytes memory bstr = new bytes(len);
      uint k = len - 1;
      
      while (_i != 0) {
         bstr[k--] = byte(uint8(48 + _i % 10));
         _i /= 10;
      }
      return string(bstr);
   }
}

