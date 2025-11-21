const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("EverEcho Full Contract Suite", function () {
    let deployer, user1, user2, judge;
    let EOCHO, eocho, Registry, registry, Market, market;

    beforeEach(async function () {
        [deployer, user1, user2, judge] = await ethers.getSigners();

        // Deploy EOCHO Token
        EOCHO = await ethers.getContractFactory("EOCHO");
        eocho = await EOCHO.deploy();
        await eocho.waitForDeployment();

        // Deploy UserRegistry
        Registry = await ethers.getContractFactory("UserRegistry");
        registry = await Registry.deploy(eocho.target);
        await registry.waitForDeployment();

        // Grant registry permission to mint EOCHO
        await eocho.grantRole(await eocho.MINTER_ROLE(), registry.target);

        // Deploy Marketplace
        Market = await ethers.getContractFactory("Marketplace");
        market = await Market.deploy(eocho.target, registry.target);
        await market.waitForDeployment();

        // Grant judge role
        await market.grantRole(await market.DISPUTE_JUDGE(), judge.address);

        // Give user1 & user2 some EOCHO to use marketplace
        await eocho.mint(user1.address, ethers.parseEther("200"));
        await eocho.mint(user2.address, ethers.parseEther("200"));
    });

    // ----------------------------------------------------
    // 1. USER REGISTRY
    // ----------------------------------------------------
    it("should allow a user to register and receive 100 EOCHO", async function () {
        const balanceBefore = await eocho.balanceOf(user1.address);

        await registry.connect(user1)
            .registerIfNeeded("Alice", "Shanghai", ["happy", "kind"]);

        const user = await registry.getUser(user1.address);

        expect(user.wallet).to.equal(user1.address);
        expect(user.whiteListed).to.equal(true);

        const balanceAfter = await eocho.balanceOf(user1.address);
        expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("100"));
    });

    // ----------------------------------------------------
    // 2. EXCHANGE GIFT TASKS
    // ----------------------------------------------------
    it("should create, match, deliver & complete an exchange gift task", async function () {

        // Approve tokens
        await eocho.connect(user1).approve(market.target, ethers.parseEther("20"));
        await eocho.connect(user2).approve(market.target, ethers.parseEther("20"));

        // User1 create task
        const taskId = await market
            .connect(user1)
            .createExchangeTask("Beijing", "0x1234", ["Book", "Coffee"]);
        
        // Get ID from emitted event
        const receipt = await taskId.wait();
        const event = receipt.logs[0].args;
        const id = event.id;

        // User2 match
        await market.connect(user2).requestMatch(id);

        // User1 approve match
        await market.connect(user1).approveMatch(id);

        // Both enter delivery
        await market.connect(user1).enterDelivery(id, "TRACK123");
        await market.connect(user2).enterDelivery(id, "TRACK456");

        // Both confirm
        await market.connect(user1).confirmDelivery(id);
        await market.connect(user2).confirmDelivery(id);

        const task = await market.getExchangeTask(id);

        expect(task.state).to.equal(4); // Completed
    });

    // ----------------------------------------------------
    // 3. HELP TASKS
    // ----------------------------------------------------
    it("should create help task, accept it, and complete it", async function () {
        const stake = ethers.parseEther("20");

        // Approve
        await eocho.connect(user1).approve(market.target, stake);

        // User1 create help task
        const tx = await market
            .connect(user1)
            .createHelpTask(1, "Fix my laptop", stake);

        const receipt = await tx.wait();
        const helpId = receipt.logs[0].args.id;

        // User2 accepts task
        await market.connect(user2).acceptHelpTask(helpId);

        const before = await eocho.balanceOf(user2.address);

        // User2 completes task
        await market.connect(user2).completeHelpTask(helpId);

        const after = await eocho.balanceOf(user2.address);

        expect(after - before).to.equal(stake);
    });

    // ----------------------------------------------------
    // 4. DISPUTE RESOLUTION
    // ----------------------------------------------------
    it("should allow judge to resolve a dispute and reward winner", async function () {
        const stake = ethers.parseEther("20");

        // Approvals
        await eocho.connect(user1).approve(market.target, stake)
