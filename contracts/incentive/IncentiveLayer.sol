pragma solidity ^0.4.18;

import "./DepositsManager.sol";
import "./TRU.sol";
import "../dispute/Filesystem.sol";
import "./ExchangeRateOracle.sol";
import "./RewardsManager.sol";

import "../interface/IGameMaker.sol";
import "../interface/IDisputeResolutionLayer.sol";

interface Callback {
    function solved(bytes32 taskID, bytes32[] files) external;
    function cancelled(bytes32 taskID) external;
}

contract IncentiveLayer is DepositsManager, RewardsManager {

    uint private numTasks = 0;
    uint private forcedErrorThreshold = 1000000; // should mean 100000/1000000 probability
    uint private taxMultiplier = 5;

    uint constant TIMEOUT = 100;

    enum CodeType {
        WAST,
        WASM,
        INTERNAL
    }

    enum StorageType {
        IPFS,
        BLOCKCHAIN
    }

    struct VMParameters {
        uint8 stackSize;
        uint8 memorySize;
        uint8 callSize;
        uint8 globalsSize;
        uint8 tableSize;
    }

    event DepositBonded(bytes32 taskID, address account, uint amount);
    event JackpotTriggered(bytes32 taskID, uint jackpotID);
    event DepositUnbonded(bytes32 taskID, address account, uint amount);
    event SlashedDeposit(bytes32 taskID, address account, address opponent, uint amount);
    event TaskCreated(bytes32 taskID, uint minDeposit, uint blockNumber, uint reward, uint tax, CodeType codeType, StorageType storageType, string storageAddress);
    event SolverSelected(bytes32 indexed taskID, address solver, bytes32 taskData, uint minDeposit, bytes32 randomBitsHash);
    event SolutionsCommitted(bytes32 taskID, uint minDeposit, CodeType codeType, StorageType storageType, string storageAddress, bytes32 solutionHash0, bytes32 solutionHash1);
    event SolutionRevealed(bytes32 taskID, uint randomBits);
    // event TaskStateChange(bytes32 taskID, uint state);
    event VerificationCommitted(bytes32 taskID, address verifier, uint jackpotID, uint solutionID, uint index);
    event SolverDepositBurned(address solver, bytes32 taskID);
    event VerificationGame(address indexed solver, uint currentChallenger); 
    event PayReward(address indexed solver, uint reward);

    event EndRevealPeriod(bytes32 taskID);
    event EndChallengePeriod(bytes32 taskID);
    event TaskFinalized(bytes32 taskID);

    enum State { TaskInitialized, SolverSelected, SolutionCommitted, ChallengesAccepted, IntentsRevealed, SolutionRevealed, TaskFinalized, TaskTimeout }
    enum Status { Uninitialized, Challenged, Unresolved, SolverWon, ChallengerWon }//For dispute resolution
    
    struct RequiredFile {
        bytes32 nameHash;
        StorageType fileStorage;
        bytes32 fileId;
    }

    struct Task {
        address owner;
        address selectedSolver;
        uint minDeposit;
        uint reward;
        uint tax;
        bytes32 initTaskHash;
        mapping(address => bytes32) challenges;
        State state;
        bytes32 blockhash;
        bytes32 randomBitsHash;
        mapping(address => uint) bondedDeposits;
        uint randomBits;
        uint finalityCode; // 0 => not finalized, 1 => finalized, 2 => forced error occurred
        uint jackpotID;
        uint cost;
        CodeType codeType;
        StorageType storageType;
        string storageAddress;
        
        bool requiredCommitted;
        RequiredFile[] uploads;
        
        uint lastBlock; // Used to check timeout
        uint challengePeriod;
    }

    struct Solution {
        bytes32 solutionHash0;
        bytes32 solutionHash1;
        bool solution0Correct;
        address[] solution0Challengers;
        address[] solution1Challengers;
        uint[] stakes;
        address[] allChallengers;
        address currentChallenger;
        bool solverConvicted;
        bytes32 currentGame;
        
        bytes32 dataHash;
        bytes32 sizeHash;
        bytes32 nameHash;
        uint totalStake;
    }

    mapping(bytes32 => Task) private tasks;
    mapping(bytes32 => Solution) private solutions;
    mapping(bytes32 => VMParameters) private vmParams;

    ExchangeRateOracle oracle;
    address disputeResolutionLayer; //using address type because in some cases it is IGameMaker, and others IDisputeResolutionLayer
    Filesystem fs;
    TRU tru;

    constructor (address _TRU, address _exchangeRateOracle, address _disputeResolutionLayer, address fs_addr) 
        DepositsManager(_TRU)
        RewardsManager(_TRU)
        public 
    {
        disputeResolutionLayer = _disputeResolutionLayer;
        oracle = ExchangeRateOracle(_exchangeRateOracle);
        fs = Filesystem(fs_addr);
        tru = TRU(_TRU);

    }

    function getBalance(address addr) public view returns (uint) {
        return tru.balanceOf(addr);
    }

    // @dev – locks up part of the a user's deposit into a task.
    // @param taskID – the task id.
    // @param account – the user's address.
    // @param amount – the amount of deposit to lock up.
    // @return – the user's deposit bonded for the task.
    function bondDeposit(bytes32 taskID, address account, uint amount) private returns (uint) {
        Task storage task = tasks[taskID];
        require(deposits[msg.sender] >= amount);
        deposits[account] = deposits[account].sub(amount);
        task.bondedDeposits[account] = task.bondedDeposits[account].add(amount);
        emit DepositBonded(taskID, account, amount);
        return task.bondedDeposits[account];
    }

    // @dev – unlocks a user's bonded deposits from a task.
    // @param taskID – the task id.
    // @param account – the user's address.
    // @return – the user's deposit which was unbonded from the task.
    function unbondDeposit(bytes32 taskID) public returns (uint) {
        Task storage task = tasks[taskID];
        require(task.state == State.TaskFinalized || task.state == State.TaskTimeout);
        uint bondedDeposit = task.bondedDeposits[msg.sender];
        delete task.bondedDeposits[msg.sender];
        deposits[msg.sender] = deposits[msg.sender].add(bondedDeposit);
        emit DepositUnbonded(taskID, msg.sender, bondedDeposit);
        
        return bondedDeposit;
    }

    // @dev – punishes a user by moving their bonded deposits for a task into the jackpot.
    // @param taskID – the task id.
    // @param account – the user's address.
    // @return – the updated jackpot amount.
    function slashDeposit(bytes32 taskID, address account, address opponent) private returns (uint) {
        Task storage task = tasks[taskID];
        uint bondedDeposit = task.bondedDeposits[account];
        uint toOpponent = bondedDeposit/10;

        emit SlashedDeposit(taskID, account, opponent, bondedDeposit);
        if (bondedDeposit == 0) return 0;

        delete task.bondedDeposits[account];
        if (bondedDeposit > toOpponent + task.cost*2) {
            increaseJackpot(bondedDeposit - toOpponent - task.cost*2);
            deposits[task.owner] += task.cost*2;
        }
        deposits[opponent] += toOpponent;
        return bondedDeposit;
    }

    // @dev – returns the user's bonded deposits for a task.
    // @param taskID – the task id.
    // @param account – the user's address.
    // @return – the user's bonded deposits for a task.
    function getBondedDeposit(bytes32 taskID, address account) constant public returns (uint) {
        return tasks[taskID].bondedDeposits[account];
    }

    function defaultParameters(bytes32 taskID) internal {
        VMParameters storage params = vmParams[taskID];
        params.stackSize = 14;
        params.memorySize = 16;
        params.globalsSize = 8;
        params.tableSize = 8;
        params.callSize = 10;
    }

    // @dev – taskGiver creates tasks to be solved.
    // @param minDeposit – the minimum deposit required for engaging with a task as a solver or verifier.
    // @param reward - the payout given to solver
    // @param taskData – tbd. could be hash of the wasm file on a filesystem.
    // @param numBlocks – the number of blocks to adjust for task difficulty
    // @return – boolean
    function createTaskAux(bytes32 initTaskHash, CodeType codeType, StorageType storageType, string storageAddress, uint maxDifficulty, uint reward) internal returns (bytes32) {
        // Get minDeposit required by task
        uint minDeposit = oracle.getMinDeposit(maxDifficulty);
        require(minDeposit > 0);
	    require(reward > 0);
        
        bytes32 id = keccak256(abi.encodePacked(initTaskHash, codeType, storageType, storageAddress, maxDifficulty, reward, numTasks));
        numTasks.add(1);

        Task storage t = tasks[id];
        t.owner = msg.sender;
        t.minDeposit = minDeposit;
        t.reward = reward;

        t.tax = minDeposit * taxMultiplier;
        t.cost = reward + t.tax;
        
        require(deposits[msg.sender] >= reward + t.tax);
        deposits[msg.sender] = deposits[msg.sender].sub(reward + t.tax);
    
        depositReward(id, reward, t.tax);
        increaseJackpot(t.tax);
        
        t.initTaskHash = initTaskHash;
        t.codeType = codeType;
        t.storageType = storageType;
        t.storageAddress = storageAddress;
        
        t.lastBlock = block.number;
        return id;
    }

    // @dev – taskGiver creates tasks to be solved.
    // @param minDeposit – the minimum deposit required for engaging with a task as a solver or verifier.
    // @param reward - the payout given to solver
    // @param taskData – tbd. could be hash of the wasm file on a filesystem.
    // @param numBlocks – the number of blocks to adjust for task difficulty
    // @return – boolean
    function createTask(bytes32 initTaskHash, CodeType codeType, StorageType storageType, string storageAddress, uint maxDifficulty, uint reward) public returns (bytes32) {
        bytes32 id = createTaskAux(initTaskHash, codeType, storageType, storageAddress, maxDifficulty, reward);
        defaultParameters(id);
	    commitRequiredFiles(id);
        
        return id;
    }

    function createTaskWithParams(bytes32 initTaskHash, CodeType codeType, StorageType storageType, string storageAddress, uint maxDifficulty, uint reward,
                                  uint8 stack, uint8 mem, uint8 globals, uint8 table, uint8 call) public returns (bytes32) {
        bytes32 id = createTaskAux(initTaskHash, codeType, storageType, storageAddress, maxDifficulty, reward);
        VMParameters storage param = vmParams[id];
        require(stack > 5 && mem > 5 && globals > 5 && table > 5 && call > 5);
        require(stack < 30 && mem < 30 && globals < 30 && table < 30 && call < 30);
        param.stackSize = stack;
        param.memorySize = mem;
        param.globalsSize = globals;
        param.tableSize = table;
        param.callSize = call;
        
        return id;
    }

    function requireFile(bytes32 id, bytes32 hash, StorageType st) public {
        Task storage t = tasks[id];
        require (!t.requiredCommitted && msg.sender == t.owner);
        t.uploads.push(RequiredFile(hash, st, 0));
    }
    
    function commitRequiredFiles(bytes32 id) public {
        Task storage t = tasks[id];
        require (msg.sender == t.owner);
        t.requiredCommitted = true;
        emit TaskCreated(id, t.minDeposit, t.lastBlock, t.reward, t.tax, t.codeType, t.storageType, t.storageAddress);
    }
    
    function getUploadNames(bytes32 id) public view returns (bytes32[]) {
        RequiredFile[] storage lst = tasks[id].uploads;
        bytes32[] memory arr = new bytes32[](lst.length);
        for (uint i = 0; i < arr.length; i++) arr[i] = lst[i].nameHash;
        return arr;
    }

    function getUploadTypes(bytes32 id) public view returns (StorageType[]) {
        RequiredFile[] storage lst = tasks[id].uploads;
        StorageType[] memory arr = new StorageType[](lst.length);
        for (uint i = 0; i < arr.length; i++) arr[i] = lst[i].fileStorage;
        return arr;
    }
    
    // @dev – solver registers for tasks, if first to register than automatically selected solver
    // 0 -> 1
    // @param taskID – the task id.
    // @param randomBitsHash – hash of random bits to commit to task
    // @return – boolean
    function registerForTask(bytes32 taskID, bytes32 randomBitsHash) public returns(bool) {
        Task storage t = tasks[taskID];
        
        require(!(t.owner == 0x0));
        require(t.state == State.TaskInitialized);
        require(t.selectedSolver == 0x0);
        
        bondDeposit(taskID, msg.sender, t.minDeposit);
        t.selectedSolver = msg.sender;
        t.randomBitsHash = randomBitsHash;
        t.state = State.SolverSelected;
        t.lastBlock = block.number;

        // Burn task giver's taxes now that someone has claimed the task
        /*
        deposits[t.owner] = deposits[t.owner].sub(t.tax);
        token.burn(t.tax);
        */

        emit SolverSelected(taskID, msg.sender, t.initTaskHash, t.minDeposit, t.randomBitsHash);
        return true;
    }

    // @dev – selected solver submits a solution to the exchange
    // 1 -> 2
    // @param taskID – the task id.
    // @param solutionHash0 – the hash of the solution (could be true or false solution)
    // @param solutionHash1 – the hash of the solution (could be true or false solution)
    // @return – boolean
    function commitSolution(bytes32 taskID, bytes32 solutionHash0, bytes32 solutionHash1) public returns (bool) {
        Task storage t = tasks[taskID];
        require(t.selectedSolver == msg.sender);
        require(t.state == State.SolverSelected);
        require(solutionHash0 != solutionHash1);
        // require(block.number < t.taskCreationBlockNumber.add(TIMEOUT));
        Solution storage s = solutions[taskID];
        s.solutionHash0 = solutionHash0;
        s.solutionHash1 = solutionHash1;
        s.solverConvicted = false;
        t.state = State.SolutionCommitted;
        t.lastBlock = block.number;
        t.challengePeriod = block.number; // Start of challenge period
        emit SolutionsCommitted(taskID, t.minDeposit, t.codeType, t.storageType, t.storageAddress, solutionHash0, solutionHash1);
        return true;
    }

    // @dev – selected solver revealed his random bits prematurely
    // @param taskID – The task id.
    // @param randomBits – bits whose hash is the commited randomBitsHash of this task
    // @return – boolean
    function prematureReveal(bytes32 taskID, uint originalRandomBits) public returns (bool) {
        Task storage t = tasks[taskID];
        require(t.state == State.SolverSelected);
        // require(block.number < t.taskCreationBlockNumber.add(TIMEOUT));
        require(t.randomBitsHash == keccak256(abi.encodePacked(originalRandomBits)));

        slashDeposit(taskID, t.selectedSolver, msg.sender);
        
        // Reset task data to selected another solver
        t.state = State.TaskInitialized;
        t.selectedSolver = 0x0;
        t.lastBlock = block.number;
        emit TaskCreated(taskID, t.minDeposit, t.lastBlock, t.reward, 1, t.codeType, t.storageType, t.storageAddress);

        return true;
    }        

    function cancelTask(bytes32 taskID) public {
        Task storage t = tasks[taskID];
        t.state = State.TaskTimeout;
        delete t.selectedSolver;
        if (!t.owner.call(abi.encodeWithSignature("cancel(bytes32)", taskID))) {
        }
    }

    function taskTimeout(bytes32 taskID) public {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        uint g_timeout = IDisputeResolutionLayer(disputeResolutionLayer).timeoutBlock(s.currentGame);
        require(block.number > g_timeout);
        require(block.number > t.lastBlock.add(TIMEOUT*2));
        require(t.state != State.TaskTimeout);
        require(t.state != State.TaskFinalized);
        slashDeposit(taskID, t.selectedSolver, s.currentChallenger);
        cancelTask(taskID);
    }

    function isTaskTimeout(bytes32 taskID) public view returns (bool) {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        uint g_timeout = IDisputeResolutionLayer(disputeResolutionLayer).timeoutBlock(s.currentGame);
        if (block.number <= g_timeout) return false;
        if (t.state == State.TaskTimeout) return false;
        if (t.state == State.TaskFinalized) return false;
        if (block.number <= t.lastBlock.add(TIMEOUT*2)) return false;
        return true;
    }

    function solverLoses(bytes32 taskID) public returns (bool) {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        if (IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.ChallengerWon)) {
            slashDeposit(taskID, t.selectedSolver, s.currentChallenger);
            cancelTask(taskID);
            return s.currentChallenger == msg.sender;
        }
        return false;
    }

    mapping (bytes32 => uint) challenges;

    // @dev – verifier submits a challenge to the solution provided for a task
    // verifiers can call this until task giver changes state or timeout
    // @param taskID – the task id.
    // @param intentHash – submit hash of even or odd number to designate which solution is correct/incorrect.
    // @return – boolean
    function commitChallenge(bytes32 hash) public returns (bool) {
        require(challenges[hash] == 0);
        challenges[hash] = block.number;
        return true;
    }

    function endChallengePeriod(bytes32 taskID) public returns (bool) {
        Task storage t = tasks[taskID];
        if (t.state != State.SolutionCommitted || !(t.challengePeriod + TIMEOUT < block.number)) return false;
        
        t.state = State.ChallengesAccepted;
        emit EndChallengePeriod(taskID);
        t.lastBlock = block.number;
        t.blockhash = blockhash(block.number-1);

        return true;
    }

    function endRevealPeriod(bytes32 taskID) public returns (bool) {
        Task storage t = tasks[taskID];
        if (t.state != State.ChallengesAccepted || !(t.lastBlock + TIMEOUT < block.number)) return false;
        
        t.state = State.IntentsRevealed;
        emit EndRevealPeriod(taskID);
        t.lastBlock = block.number;

        return true;
    }

    // @dev – verifiers can call this until task giver changes state or timeout
    // @param taskID – the task id.
    // @param intent – submit 0 to challenge solution0, 1 to challenge solution1, anything else challenges both
    // @return – boolean
    function revealIntent(bytes32 taskID, bytes32 solution0, bytes32 solution1, uint intent, uint deposit) public returns (bool) {
        uint cblock = challenges[keccak256(abi.encodePacked(taskID, intent, msg.sender, solution0, solution1, deposit))];
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        require(t.state == State.ChallengesAccepted);
        require(t.challengePeriod + TIMEOUT > cblock);
        require(cblock != 0);
        require(deposit >= t.minDeposit);
        uint solution = intent%2;
        bondDeposit(taskID, msg.sender, deposit);
        // Intent determines which solution the verifier is betting is deemed incorrect
        if (solution == 0) s.solution0Challengers.push(msg.sender);
        else s.solution1Challengers.push(msg.sender);
        uint position = s.allChallengers.length;
        s.allChallengers.push(msg.sender);
        s.stakes.push(deposit);
        s.totalStake += deposit;

        delete tasks[taskID].challenges[msg.sender];
        emit VerificationCommitted(taskID, msg.sender, tasks[taskID].jackpotID, solution, position);
        return true;
    }

    // @dev – solver reveals which solution they say is the correct one
    // 4 -> 5
    // @param taskID – the task id.
    // @param solution0Correct – determines if solution0Hash is the correct solution
    // @param originalRandomBits – original random bits for sake of commitment.
    // @return – boolean
    function revealSolution(bytes32 taskID, uint originalRandomBits, bytes32 codeHash, bytes32 sizeHash, bytes32 nameHash, bytes32 dataHash) public {
        Task storage t = tasks[taskID];
        require(t.randomBitsHash == keccak256(abi.encodePacked(originalRandomBits)));
        require(t.state == State.IntentsRevealed);
        require(t.selectedSolver == msg.sender);
        
        Solution storage s = solutions[taskID];
        s.solution0Correct = originalRandomBits % 2 == 0;
        
        bytes32 intended = s.solution0Correct ? s.solutionHash0 : s.solutionHash1;
        s.nameHash = nameHash;
        s.sizeHash = sizeHash;
        s.dataHash = dataHash;
        
        require(keccak256(abi.encodePacked(codeHash, sizeHash, nameHash, dataHash)) == intended);
        
        if (s.solution0Correct) s.solution1Challengers.length = 0;
        else s.solution0Challengers.length = 0;

        if (isForcedError(t.randomBits, t.blockhash)) { // this if statement will make this function tricky to test
            rewardJackpot(taskID);
        }

        t.state = State.SolutionRevealed;
        t.randomBits = originalRandomBits;
        emit SolutionRevealed(taskID, originalRandomBits);
        t.lastBlock = block.number;
    }

    function isForcedError(uint randomBits, bytes32 bh) internal view returns (bool) {
        return (uint(keccak256(abi.encodePacked(randomBits, bh)))%1000000 < forcedErrorThreshold);
    }

    function rewardJackpot(bytes32 taskID) internal {
        Task storage t = tasks[taskID];
        t.jackpotID = finalizeJackpot();
        // setJackpotReceivers(s.allChallengers, s.totalStake);
        emit JackpotTriggered(taskID, t.jackpotID);

        // payReward(taskID, t.owner);//Still compensating solver even though solution wasn't thoroughly verified, task giver recommended to not use solution
    }

    // verifier should be responsible for calling this first
    function canRunVerificationGame(bytes32 taskID) public view returns (bool) {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        if (t.state != State.SolutionRevealed) return false;
        if (s.solution0Challengers.length + s.solution1Challengers.length == 0) return false;
        return (s.currentGame == 0 || IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon));
    }
    
    function runVerificationGame(bytes32 taskID) public {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        
        require(t.state == State.SolutionRevealed);
        require(s.currentGame == 0 || IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon));

        if (IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon)) {
            slashDeposit(taskID, s.currentChallenger, t.selectedSolver);
        }
        
        if (s.solution0Challengers.length > 0) {
            s.currentChallenger = s.solution0Challengers[s.solution0Challengers.length-1];
            verificationGame(taskID, t.selectedSolver, s.currentChallenger, s.solutionHash0);
            s.solution0Challengers.length -= 1;
        } else if (s.solution1Challengers.length > 0) {
            s.currentChallenger = s.solution1Challengers[s.solution1Challengers.length-1];
            verificationGame(taskID, t.selectedSolver, s.currentChallenger, s.solutionHash1);
            s.solution1Challengers.length -= 1;
        }
        // emit VerificationGame(t.selectedSolver, s.currentChallenger);
        t.lastBlock = block.number;
    }

    function verificationGame(bytes32 taskID, address solver, address challenger, bytes32 solutionHash) internal {
        Task storage t = tasks[taskID];
        uint size = 1;
        bytes32 gameID = IGameMaker(disputeResolutionLayer).make(taskID, solver, challenger, t.initTaskHash, solutionHash, size, TIMEOUT);
        solutions[taskID].currentGame = gameID;
    }
    
    function uploadFile(bytes32 id, uint num, bytes32 file_id, bytes32[] name_proof, bytes32[] data_proof, uint file_num) public returns (bool) {
        Task storage t = tasks[id];
        Solution storage s = solutions[id];
        RequiredFile storage file = t.uploads[num];
        require(checkProof(fs.getRoot(file_id), s.dataHash, data_proof, file_num));
        require(checkProof(fs.getNameHash(file_id), s.nameHash, name_proof, file_num));
        
        file.fileId = file_id;
        return true;
    }
    
    function getLeaf(bytes32[] proof, uint loc) internal pure returns (uint) {
        require(proof.length >= 2);
        if (loc%2 == 0) return uint(proof[0]);
        else return uint(proof[1]);
    }
    
    function getRoot(bytes32[] proof, uint loc) internal pure returns (bytes32) {
        require(proof.length >= 2);
        bytes32 res = keccak256(abi.encodePacked(proof[0], proof[1]));
        for (uint i = 2; i < proof.length; i++) {
            loc = loc/2;
            if (loc%2 == 0) res = keccak256(abi.encodePacked(res, proof[i]));
            else res = keccak256(abi.encodePacked(proof[i], res));
        }
        require(loc < 2); // This should be runtime error, access over bounds
        return res;
    }
    
    function checkProof(bytes32 hash, bytes32 root, bytes32[] proof, uint loc) internal pure returns (bool) {
        return uint(hash) == getLeaf(proof, loc) && root == getRoot(proof, loc);
    }

    function finalizeTask(bytes32 taskID) public {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];

        require(t.state == State.SolutionRevealed);
        require(s.solution0Challengers.length + s.solution1Challengers.length == 0 && (s.currentGame == 0 || IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon)));

        if (IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon)) {
            slashDeposit(taskID, s.currentChallenger, t.selectedSolver);
        }

        bytes32[] memory files = new bytes32[](t.uploads.length);
        for (uint i = 0; i < t.uploads.length; i++) {
            require(t.uploads[i].fileId != 0);
            files[i] = t.uploads[i].fileId;
        }

        t.state = State.TaskFinalized;
        t.finalityCode = 1; // Task has been completed

        payReward(taskID, t.selectedSolver);
        if (!t.owner.call(abi.encodeWithSignature("solved(bytes32,bytes32[])", taskID, files))) {
        }
        emit TaskFinalized(taskID);
        // Callback(t.owner).solved(taskID, files);
    }
    
    function isFinalized(bytes32 taskID) public view returns (bool) {
        Task storage t = tasks[taskID];
        return (t.state == State.TaskFinalized);
    }
    
    function canFinalizeTask(bytes32 taskID) public view returns (bool) {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        
        if (t.state != State.SolutionRevealed) return false;

        if (!(s.solution0Challengers.length + s.solution1Challengers.length == 0 && (s.currentGame == 0 || IDisputeResolutionLayer(disputeResolutionLayer).status(s.currentGame) == uint(Status.SolverWon)))) return false;

        for (uint i = 0; i < t.uploads.length; i++) {
           if (t.uploads[i].fileId == 0) return false;
        }
        
        return true;
    }

    function getTaskFinality(bytes32 taskID) public view returns (uint) {
        return tasks[taskID].finalityCode;
    }

    function getVMParameters(bytes32 taskID) public view returns (uint8, uint8, uint8, uint8, uint8) {
        VMParameters storage params = vmParams[taskID];
        return (params.stackSize, params.memorySize, params.globalsSize, params.tableSize, params.callSize);
    }

    function getTaskInfo(bytes32 taskID) public view returns (address, bytes32, CodeType, StorageType, string, bytes32) {
	    Task storage t = tasks[taskID];
        return (t.owner, t.initTaskHash, t.codeType, t.storageType, t.storageAddress, taskID);
    }

    function getSolutionInfo(bytes32 taskID) public view returns(bytes32, bytes32, bytes32, bytes32, CodeType, StorageType, string, address) {
        Task storage t = tasks[taskID];
        Solution storage s = solutions[taskID];
        return (taskID, s.solutionHash0, s.solutionHash1, t.initTaskHash, t.codeType, t.storageType, t.storageAddress, t.selectedSolver);
    }

    // Handling jackpots

    struct Jackpot {
        uint finalAmount;
        uint amount;
        address[] challengers;
        uint redeemedCount;
        uint totalStake;
    }

    event ReceivedJackpot(address receiver, uint amount);

    mapping(uint => Jackpot) jackpots;//keeps track of versions of jackpots

    uint internal currentJackpotID;
    event JackpotIncreased(uint amount);

    // @dev – returns the current jackpot
    // @return – the jackpot.
    function getJackpotAmount() view public returns (uint) {
        return jackpots[currentJackpotID].amount;
    }

    function getCurrentJackpotID() view public returns (uint) {
        return currentJackpotID;
    }

    //// @dev – allows a uer to donate to the jackpot.
    function increaseJackpot(uint _amount) public payable {
        jackpots[currentJackpotID].amount = jackpots[currentJackpotID].amount.add(_amount);
        emit JackpotIncreased(_amount);
    } 

    function finalizeJackpot() internal returns (uint) {
        currentJackpotID = currentJackpotID + 1;
        return currentJackpotID - 1;
    }

    function getJackpotReceivers(bytes32 taskID) public view returns (address[]) {
        Solution storage s = solutions[taskID];
        return s.allChallengers;
    }

    function getJackpotStakes(bytes32 taskID) public view returns (uint[]) {
        Solution storage s = solutions[taskID];
        return s.stakes;
    }

    function debugJackpotPayment(bytes32 taskID, uint index) public view returns (uint, uint, uint, uint, uint) {
        Task storage t = tasks[taskID];
        Jackpot storage j = jackpots[t.jackpotID];
        Solution storage s = solutions[taskID];

        if (s.totalStake == 0) return;

        uint amount = j.amount*s.stakes[index]/s.totalStake;
        return (amount, j.amount, s.stakes[index], s.totalStake, tru.balanceOf(this));
    }

    function receiveJackpotPayment(bytes32 taskID, uint index) public {
        Task storage t = tasks[taskID];
        Jackpot storage j = jackpots[t.jackpotID];
        Solution storage s = solutions[taskID];
        require(s.allChallengers[index] == msg.sender);
        if (s.totalStake == 0) return;

        uint amount = j.amount*s.stakes[index]/s.totalStake;
        //transfer jackpot payment
        // token.mint(msg.sender, amount);
        if (amount == 0) return;
        tru.transfer(msg.sender, amount);
        emit ReceivedJackpot(msg.sender, amount /*, j.finalAmount */);
    }

}
