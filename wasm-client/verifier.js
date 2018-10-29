const depositsHelper = require('./depositsHelper')
const fs = require('fs')
const contract = require('./contractHelper')
const toTaskInfo = require('./util/toTaskInfo')
const toSolutionInfo = require('./util/toSolutionInfo')
const setupVM = require('./util/setupVM')
const midpoint = require('./util/midpoint')
const waitForBlock = require('./util/waitForBlock')
const recovery = require('./recovery')
const assert = require('assert')

const fsHelpers = require('./fsHelpers')

const zeroes = "0000000000000000000000000000000000000000000000000000000000000000"

// const merkleComputer = require(__dirname + "/merkle-computer")('./../wasm-client/ocaml-offchain/interpreter/wasm')

const contractsConfig = require('./util/contractsConfig')

function setup(web3) {
    return (async () => {
	const httpProvider = web3.currentProvider
	const config = await contractsConfig(web3)
        let incentiveLayer = await contract(httpProvider, config['incentiveLayer'])
        let fileSystem = await contract(httpProvider, config['fileSystem'])
        let disputeResolutionLayer = await contract(httpProvider, config['interactive'])
        let tru = await contract(httpProvider, config['tru'])
        return [incentiveLayer, fileSystem, disputeResolutionLayer, tru]
    })()
}

function writeFile(fname, buf) {
    return new Promise(function (cont, err) { fs.writeFile(fname, buf, function (err, res) { cont() }) })
}

const solverConf = { error: false, error_location: 0, stop_early: -1, deposit: 1 }

module.exports = {
    init: async (web3, account, logger, mcFileSystem, test = false, recover = -1, throttle = 1) => {
        let tasks = {}
        let games = {}
            
        logger.log({
            level: 'info',
            message: `Verifier initialized`
        })

        let [incentiveLayer, fileSystem, disputeResolutionLayer, tru] = await setup(web3)

        const config = await contractsConfig(web3)
        const WAIT_TIME = config.WAIT_TIME || 0

        let helpers = fsHelpers.init(fileSystem, web3, mcFileSystem, logger, incentiveLayer, account)

        const clean_list = []
        let game_list = []
        let task_list = []

        let bn = await web3.eth.getBlockNumber()

        let recovery_mode = recover > 0
        let events = []
        const RECOVERY_BLOCKS = recover

        function addEvent(evC, handler) {
            let ev = recovery_mode ? evC({}, {fromBlock:Math.max(0,bn-RECOVERY_BLOCKS)}) : evC()
            clean_list.push(ev)
            ev.watch(async (err, result) => {
                // console.log(result)
                if (result && recovery_mode) {
                    events.push({event:result, handler})
                    console.log("Recovering", result.event, "at block", result.blockNumber)
                }
                else if (result) {
                    try {
                        await handler(result)
                    }
                    catch (e) {
                        logger.error(`VERIFIER: Error while handling event ${JSON.stringify(result)}: ${e}`)
                    }
                }
                else console.log(err)
            })
        }

        //INCENTIVE

        //Solution committed event
        addEvent(incentiveLayer.SolutionsCommitted, async result => {

            logger.log({
                level: 'info',
                message: `Solution has been posted`
            })

            let taskID = result.args.taskID
            // let storageAddress = result.args.storageAddress
            let minDeposit = result.args.minDeposit
            let solverHash0 = result.args.solutionHash0
            let solverHash1 = result.args.solutionHash1
            logger.info("Getting info")
            let taskInfo = toTaskInfo(await incentiveLayer.getTaskInfo.call(taskID))
            taskInfo.taskID = taskID

            if (Object.keys(tasks).length <= throttle) {
                // let storageType = result.args.storageType.toNumber()

                logger.info("Setting up VM")
                let vm = await helpers.setupVMWithFS(taskInfo)

                logger.info("Executing task")
                let interpreterArgs = []
                solution = await vm.executeWasmTask(interpreterArgs)

                logger.log({
                    level: 'info',
                    message: `Executed task ${taskID}. Checking solutions`
                })

                task_list.push(taskID)

                tasks[taskID] = {
                    solverHash0: solverHash0,
                    solverHash1: solverHash1,
                    solutionHash: solution.hash,
                    vm: vm,
                    minDeposit: minDeposit,
                }

                let deposit = minDeposit

                deposit = deposit.toString(16)

                deposit = zeroes.substr(0, 64-deposit.length) + deposit

                console.log("Deposit:", deposit)

                if ((solverHash0 != solution.hash) ^ test) {

                    let intent = helpers.makeSecret(solution.hash + taskID).substr(0, 62) + "00"
                    // console.log("intent", intent)
                    tasks[taskID].intent0 = "0x" + intent
                    let hash_str = taskID + intent + account.substr(2) + solverHash0.substr(2) + solverHash1.substr(2) + deposit
                    await incentiveLayer.commitChallenge(web3.utils.soliditySha3(hash_str), { from: account, gas: 350000 })

                    logger.log({
                        level: 'info',
                        message: `Challenged solution for task ${taskID}`
                    })

                }

                if ((solverHash1 != solution.hash) ^ test) {

                    let intent = helpers.makeSecret(solution.hash + taskID).substr(0, 62) + "01"
                    tasks[taskID].intent1 = "0x" + intent
                    // console.log("intent", intent)
                    let hash_str = taskID + intent + account.substr(2) + solverHash0.substr(2) + solverHash1.substr(2) + deposit
                    await incentiveLayer.commitChallenge(web3.utils.soliditySha3(hash_str), { from: account, gas: 350000 })

                    logger.log({
                        level: 'info',
                        message: `Challenged solution for task ${taskID}`
                    })

                }

            }
        })

        addEvent(incentiveLayer.EndChallengePeriod, async result => {
            let taskID = result.args.taskID
            let taskData = tasks[taskID]

            if (!taskData) return

            let deposit = taskData.minDeposit.toString(16)

            console.log("Deposit:", deposit)

            await depositsHelper(web3, incentiveLayer, tru, account, deposit)
            if (taskData.intent0) {
                await incentiveLayer.revealIntent(taskID, taskData.solverHash0, taskData.solverHash1, taskData.intent0, deposit, { from: account, gas: 1000000 })
            } else if (taskData.intent1) {
                await incentiveLayer.revealIntent(taskID, taskData.solverHash0, taskData.solverHash1, taskData.intent1, deposit, { from: account, gas: 1000000 })
            } else {
                throw `intent0 nor intent1 were truthy for task ${taskID}`
            }

            logger.log({
                level: 'info',
                message: `Revealing challenge intent for ${taskID}`
            })

        })

        addEvent(incentiveLayer.JackpotTriggered, async result => {
            let taskID = result.args.taskID
            // let jackpotID = result.args.jackpotID
            let taskData = tasks[taskID]

            if (!taskData) return
            logger.info("Triggered jackpot!!!")

            let lst = await incentiveLayer.getJackpotReceivers.call(taskID)

            console.log("jackpot receivers", lst)

            for (let i = 0; i < lst.length; i++) {
                if (lst[i].toLowerCase() == account.toLowerCase()) {
                    logger.info("Receiving jackpot")
                    let lst = await incentiveLayer.getJackpotStakes.call(taskID, {from: account, gas: 1000000})
                    console.log("Stakes", lst, i)
                    let res = await incentiveLayer.debugJackpotPayment.call(taskID, i, {from: account, gas: 1000000})
                    console.log("Payent", res)
                    await incentiveLayer.receiveJackpotPayment(taskID, i, {from: account, gas: 1000000})
                }
            }

        })

        addEvent(incentiveLayer.ReceivedJackpot, async (result) => {
            let recv = result.args.receiver
            let amount = result.args.amount
            logger.info(`${recv} got jackpot ${amount.toString(10)}`)
        })

        addEvent(incentiveLayer.VerificationCommitted, async result => {
        })

        addEvent(incentiveLayer.TaskFinalized, async (result) => {
            let taskID = result.args.taskID	   
	    
            if (tasks[taskID]) {
                await incentiveLayer.unbondDeposit(taskID, {from: account, gas: 100000})
		        delete tasks[taskID]
                logger.log({
                    level: 'info',
                    message: `Task ${taskID} finalized. Tried to unbond deposits.`
                  })

            }

        })

        addEvent(incentiveLayer.SlashedDeposit, async (result) => {
            let addr = result.args.account

            if (account.toLowerCase() == addr.toLowerCase()) {
                logger.info("Oops, I was slashed, hopefully this was a test")
            }

        })

        // DISPUTE

        addEvent(disputeResolutionLayer.StartChallenge, async result => {
            let challenger = result.args.c

            if (challenger.toLowerCase() == account.toLowerCase()) {
                let gameID = result.args.gameID

                game_list.push(gameID)

                let taskID = await disputeResolutionLayer.getTask.call(gameID)

                games[gameID] = {
                    prover: result.args.prover,
                    taskID: taskID
                }
            }
        })

        addEvent(disputeResolutionLayer.Queried, async result => {
        })
        
        addEvent(disputeResolutionLayer.Reported, async result => {
                let gameID = result.args.gameID

            if (games[gameID]) {

                let lowStep = result.args.idx1.toNumber()
                let highStep = result.args.idx2.toNumber()
                let taskID = games[gameID].taskID

                logger.log({
                    level: 'info',
                    message: `Report received game: ${gameID} low: ${lowStep} high: ${highStep}`
                })

                let stepNumber = midpoint(lowStep, highStep)

                let reportedStateHash = await disputeResolutionLayer.getStateAt.call(gameID, stepNumber)

                let stateHash = await tasks[taskID].vm.getLocation(stepNumber, tasks[taskID].interpreterArgs)

                let num = reportedStateHash == stateHash ? 1 : 0

                await disputeResolutionLayer.query(
                    gameID,
                    lowStep,
                    highStep,
                    num,
                    { from: account }
                )

            }
        })

        addEvent(disputeResolutionLayer.PostedPhases, async result => {
            let gameID = result.args.gameID

            if (games[gameID]) {

                logger.log({
                    level: 'info',
                    message: `Phases posted for game: ${gameID}`
                })

                let lowStep = result.args.idx1
                let phases = result.args.arr

                let taskID = games[gameID].taskID

                if (test) {
                    await disputeResolutionLayer.selectPhase(gameID, lowStep, phases[3], 3, { from: account })
                } else {

                    let states = (await tasks[taskID].vm.getStep(lowStep, tasks[taskID].interpreterArgs)).states

                    for (let i = 0; i < phases.length; i++) {
                        if (states[i] != phases[i]) {
                            await disputeResolutionLayer.selectPhase(
                                gameID,
                                lowStep,
                                phases[i],
                                i,
                                { from: account }
                            )
                            return
                        }
                    }
                }

            }
        })

        let busy_table = {}
        function busy(id) {
            return busy_table[id] && Date.now() < busy_table[id]
        }

        function working(id) {
            busy_table[id] = Date.now() + WAIT_TIME
        }

        async function handleTimeouts(taskID) {
            // let deposit = await incentiveLayer.getBondedDeposit.call(taskID, account)
            // console.log("Verifier deposit", deposit.toNumber(), account)

            if (busy(taskID)) return

            if (await incentiveLayer.solverLoses.call(taskID, {from: account})) {

                working(taskID)
                logger.log({
                    level: 'info',
                    message: `Winning verification game for task ${taskID}`
                })

                await incentiveLayer.solverLoses(taskID, {from: account})

            }
            if (await incentiveLayer.isTaskTimeout.call(taskID, {from: account})) {

                working(taskID)
                logger.log({
                    level: 'info',
                    message: `Timeout in task ${taskID}`
                })

                await incentiveLayer.taskTimeout(taskID, {from: account})

            }
        }

        async function handleGameTimeouts(gameID) {
            // console.log("Verifier game timeout")
            if (busy(gameID)) return
            working(gameID)
            if (await disputeResolutionLayer.gameOver.call(gameID)) {

                logger.log({
                    level: 'info',
                    message: `Triggering game over, game: ${gameID}`
                })

                await disputeResolutionLayer.gameOver(gameID, { from: account })
            }
        }

        async function recoverTask(taskID) {
            let taskInfo = toTaskInfo(await incentiveLayer.getTaskInfo.call(taskID))
            if (!tasks[taskID]) tasks[taskID] = {}
            tasks[taskID].taskInfo = taskInfo
            taskInfo.taskID = taskID

            logger.log({
                level: 'info',
                message: `RECOVERY: Verifying task ${taskID}`
            })

            let vm = await helpers.setupVMWithFS(taskInfo)

            assert(vm != undefined, "vm is undefined")

            let interpreterArgs = []
            let solution = await vm.executeWasmTask(interpreterArgs)
            tasks[taskID].solution = solution
            tasks[taskID].vm = vm
        }

        async function recoverGame(gameID) {
            let taskID = await disputeResolutionLayer.getTask.call(gameID)

            if (!tasks[taskID]) logger.error(`FAILURE: haven't recovered task ${taskID} for game ${gameID}`)

            logger.log({
                level: 'info',
                message: `RECOVERY: Solution to task ${taskID} has been challenged`
            })

            games[gameID] = {
                taskID: taskID
            }
        }

        let ival = setInterval(() => {
            task_list.forEach(async t => {
                try {
                    await handleTimeouts(t)
                }
                catch (e) {
                    console.log(e)
                    logger.error(`Error while handling timeouts of task ${t}: ${e.toString()}`)
                }
            })
            game_list.forEach(async g => {
                try {
                    await handleGameTimeouts(g)
                }
                catch (e) {
                    console.log(e)
                    logger.error(`Error while handling timeouts of game ${g}: ${e.toString()}`)
                }
            })
            if (recovery_mode) {
                recovery_mode = false
                recovery.analyze(account, events, recoverTask, recoverGame, disputeResolutionLayer, incentiveLayer, game_list, task_list, true)
            }
        }, 1000)

        return () => {
            try {
                let empty = data => { }
                clearInterval(ival)
                clean_list.forEach(ev => ev.stopWatching(empty))
            }
            catch (e) {
                console.log("Umm")
            }
        }
    }
}
