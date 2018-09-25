const StandardERC223 = artifacts.require('StandardERC223');
const SettingsRegistry = artifacts.require('SettingsRegistry');
const GringottsBank = artifacts.require('GringottsBank');

const gasPrice = 22000000000;
const COIN = 10 ** 18;

contract('Gringotts Bank test', async(accounts) => {
    let deployer = accounts[0];
    let investor = accounts[1];
    let bank;
    let registry;
    let ring;
    let kton;

    before('deploy and configure', async() => {
        // get contract from deployed version
        bank     = await GringottsBank.deployed();
        registry = await SettingsRegistry.deployed();

        ring = StandardERC223.at(await bank.ring_.call())
        kton = StandardERC223.at(await bank.kryptonite_.call())

        console.log('Bank address: ', bank.address);
        console.log('registry address: ', registry.address);
        console.log('RING address: ', ring.address);
        console.log('KTON address: ', kton.address);

        // give some ring to investor
        await ring.mint(investor, 10000 * COIN, { from:deployer } );
    })

    it('bank setting should be same as registry initialization', async() => {
        let bank_unit_interest = await registry.uintOf(await bank.UINT_BANK_UNIT_INTEREST.call());
        let bank_penalty_multiplier = await registry.uintOf(await bank.UINT_BANK_PENALTY_MULTIPLIER.call());

        assert.equal(bank_unit_interest, 1015 * 10**15)
        assert.equal(bank_penalty_multiplier, 3)
    })

    it('should return correct amount of KTON', async() => {
        // deposit 100 RING for 1 month
        await ring.contract.transfer['address,uint256,bytes']( bank.address, 100 * COIN, web3.toHex(1), { from: investor });
        // let ktonAmount = await kton.balanceOf(investor);
        //
        // assert.equal(ktonAmount, 199);
        // using the way to call overloaded functions.
        //let tx = ring.contract.transfer['address,uint256,bytes'](bank.address, 100 * 10**18, "0x1", {from:deployer});
        //console.log(tx);
        //await tx;

        //let balance = await kton.balanceOf.call(deployer);
        //console.log(balance.toNumber());
        //assert.equal(balance.toNumber(), 100 , "returned unexpected kton");
    })

    it('should deduct correct amount of penalty', async() => {
    })

    // need help with timecop
    it('should be able to redeem back all ring when due', async() => {
    })

    it('test bytesToUint256', async() => {
    })

})