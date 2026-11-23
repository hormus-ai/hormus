// HormusAgentVaultV2 tests: runs the contract in a local EVM (@ethereumjs/vm) against mocks of USDG, WETH,
// Uniswap v3 SwapRouter02, Uniswap v4 PoolManager and a Pons bonding curve.
// Run: npm test (in contracts/). Set SOLC_VERSION=v0.8.24+commit.e11b9ed9 to compile with the exact deploy compiler.
import solcBase from 'solc'; import fs from 'node:fs';
import { VM } from '@ethereumjs/vm'; import { Address, hexToBytes, bytesToHex } from '@ethereumjs/util';
import { Interface, AbiCoder, Wallet, keccak256, toUtf8Bytes, solidityPacked, zeroPadValue, concat } from 'ethers';

const solc = process.env.SOLC_VERSION ? await new Promise((ok, no) => solcBase.loadRemoteVersion(process.env.SOLC_VERSION, (e, s) => e ? no(e) : ok(s))) : solcBase;
const SRC = new URL('../HormusAgentVaultV2.sol', import.meta.url);
const input = { language: 'Solidity', sources: { 'V.sol': { content: fs.readFileSync(SRC, 'utf8') }, 'M.sol': { content: fs.readFileSync(new URL('./Mocks.sol', import.meta.url), 'utf8') } },
  settings: { evmVersion: 'shanghai', optimizer: { enabled: true, runs: 200 }, outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } } } };
const out = JSON.parse(solc.compile(JSON.stringify(input)));
let bad = false; for (const e of out.errors || []) { console.log(e.severity.toUpperCase(), e.formattedMessage.split('\n').slice(0, 3).join(' ')); if (e.severity === 'error') bad = true; }
if (bad) process.exit(1);
const C = n => out.contracts[n === 'HormusAgentVaultV2' ? 'V.sol' : 'M.sol'][n];
const V = C('HormusAgentVaultV2');
console.log('compiler', solc.version(), '· runtime size', V.evm.deployedBytecode.object.length / 2, 'bytes (limit 24576)');

const vm = await VM.create(); const ac = AbiCoder.defaultAbiCoder();
const A = n => new Address(hexToBytes('0x' + n.toString(16).padStart(40, '0')));
const W = k => new Wallet(keccak256(toUtf8Bytes(k)));
const aliceW = W('alice'), bobW = W('bob');
const ALICE = Address.fromString(aliceW.address), BOB = Address.fromString(bobW.address);
const OWNER = A(0xa1), EXEC = A(0xe1), MALLORY = A(0xbad);
let NOW = 1_800_000_000n;
async function blockOpts() { const { Block } = await import('@ethereumjs/block'); return Block.fromBlockData({ header: { timestamp: NOW, number: 1n, gasLimit: 30_000_000n } }, { common: vm.common }); }
async function deploy(c, args = '0x') { const r = await vm.evm.runCall({ caller: OWNER, data: hexToBytes('0x' + c.evm.bytecode.object + args.slice(2)), gasLimit: 30_000_000n, block: await blockOpts() }); if (r.execResult.exceptionError) throw r.execResult.exceptionError; return r.createdAddress; }
async function call(to, iface, fn, args, from = ALICE, value = 0n) {
  const r = await vm.evm.runCall({ caller: from, to, data: hexToBytes(iface.encodeFunctionData(fn, args)), gasLimit: 8_000_000n, value, skipBalance: true, block: await blockOpts() });
  if (r.execResult.exceptionError) { const rv = bytesToHex(r.execResult.returnValue); let reason = 'revert'; try { reason = ac.decode(['string'], '0x' + rv.slice(10))[0]; } catch {} return { err: reason }; }
  const d = iface.decodeFunctionResult(fn, bytesToHex(r.execResult.returnValue)); return d.length === 1 ? d[0] : d;
}
const I = c => new Interface(c.abi);
const vi = I(V), ti = I(C('MockERC20')), wi = I(C('MockWETH')), ri = I(C('MockRouter02')), pi = I(C('MockPoolManager')), ci = I(C('MockPonsCurve'));
const S = x => x.toString(), U = n => BigInt(n) * 1_000_000n, ZERO = '0x0000000000000000000000000000000000000000';

const usdg = await deploy(C('MockERC20')), weth = await deploy(C('MockWETH')), tok = await deploy(C('MockERC20')), meme = await deploy(C('MockERC20')), junk = await deploy(C('MockERC20'));
const router = await deploy(C('MockRouter02')), pm = await deploy(C('MockPoolManager'));
const curve = await deploy(C('MockPonsCurve'), ac.encode(['address'], [S(meme)])), fakeCurve = await deploy(C('MockPonsCurve'), ac.encode(['address'], [S(junk)]));
const vault = await deploy(V, ac.encode(['address', 'address', 'address', 'address'], [S(usdg), S(router), S(weth), S(pm)]));
const V_ = S(vault);
for (const f of [[weth, wi], [pm, pi], [curve, ci]]) await call(f[0], f[1], 'fund', [], OWNER, 10n ** 24n);

let pass = 0, fail = 0; const ok = (n, c) => { if (c) pass++; else fail++; console.log((c ? 'PASS ' : 'FAIL ') + n); };
const isErr = (r, e) => r && r.err === e;
const agent = keccak256(toUtf8Bytes('agent-1')), agent2 = keccak256(toUtf8Bytes('agent-2'));
const p1 = (a, f, b) => solidityPacked(['address', 'uint24', 'address'], [S(a), f, S(b)]);
const p2 = (a, b, c) => solidityPacked(['address', 'uint24', 'address', 'uint24', 'address'], [S(a), 100, S(b), 3000, S(c)]);
const key = (x, y) => { const [c0, c1] = BigInt(S(x)) < BigInt(S(y)) ? [S(x), S(y)] : [S(y), S(x)]; return [c0, c1, 3000, 60, ZERO]; };
const NOKEY = [ZERO, ZERO, 0, 0, ZERO];
const R3 = path => [0, path, NOKEY, ZERO];
const R4 = (k, leg = '0x') => [1, leg, k, ZERO];
const RP = (c, leg) => [2, leg, NOKEY, S(c)];
const pos = (u, a, t) => call(vault, vi, 'positions', [S(u), a, S(t)]);
const MAXU128 = (1n << 128n) - 1n, MAXU64 = (1n << 64n) - 1n;

// ---------- setup and user-chosen limits ----------
await call(usdg, ti, 'mint', [S(ALICE), U(10000)]); await call(usdg, ti, 'approve', [V_, U(10000)]);
await call(usdg, ti, 'mint', [S(BOB), U(1000)]); await call(usdg, ti, 'approve', [V_, U(1000)], BOB);
ok('deposit 5000', !(await call(vault, vi, 'deposit', [U(5000)])).err);
ok('bob deposits 500', !(await call(vault, vi, 'deposit', [U(500)], BOB)).err);
ok('large budget, max order = whole budget, no daily limit', !(await call(vault, vi, 'allocate', [agent, U(3000), U(3000), MAXU128])).err);
ok('max order above budget rejected', isErr(await call(vault, vi, 'allocate', [agent2, U(10), U(11), U(11)]), 'INVALID_LIMITS'));
ok('second agent: budget 100, max 10, day 25', !(await call(vault, vi, 'allocate', [agent2, U(100), U(10), U(25)])).err);
await call(vault, vi, 'setExecutor', [S(EXEC)], OWNER);
ok('executor blocked before user enables auto-trade', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(5), 1n, R3(p2(usdg, weth, tok))], EXEC), 'AUTO_TRADE_OFF'));
ok('auto-trade expiry in the past rejected', isErr(await call(vault, vi, 'setAutoTrade', [agent, NOW - 1n]), 'INVALID_EXPIRY'));
ok('auto-trade until switched off (no time limit)', !(await call(vault, vi, 'setAutoTrade', [agent, MAXU64])).err);
ok('auto-trade one year ahead accepted', !(await call(vault, vi, 'setAutoTrade', [agent2, NOW + 365n * 86400n])).err);

// ---------- who may buy what ----------
ok('token on no list rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(5), 1n, R3(p2(usdg, weth, tok))], EXEC), 'TOKEN_NOT_ALLOWED'));
ok('non-executor cannot trade', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(5), 1n, R3(p2(usdg, weth, tok))], MALLORY), 'NOT_EXECUTOR'));
await call(vault, vi, 'setTokensAllowed', [[S(tok)], true], OWNER);
ok('owner list: v3 buy 10 USDG -> 20 TOK', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(10), U(19), R3(p2(usdg, weth, tok))], EXEC)).err && (await pos(ALICE, agent, tok)) === U(20));
ok('v3 path must end in the token', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(1), 1n, R3(p1(usdg, 3000, junk))], EXEC), 'INVALID_PATH'));
ok('v3 middle hop must be WETH', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(1), 1n, R3(p2(usdg, junk, tok))], EXEC), 'INVALID_HOP'));
ok('minOut 0 rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(1), 0n, R3(p2(usdg, weth, tok))], EXEC), 'INVALID_AMOUNTS'));
ok('cannot buy USDG or WETH as the token', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(weth), U(1), 1n, R3(p1(usdg, 3000, weth))], EXEC), 'INVALID_TOKEN'));

ok('user list: alice allows JUNK herself', !(await call(vault, vi, 'setMyTokens', [[S(junk)], true])).err);
ok('alice agent may buy JUNK now', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(junk), U(5), 1n, R3(p1(usdg, 3000, junk))], EXEC)).err);
await call(vault, vi, 'allocate', [agent, U(100), U(100), MAXU128], BOB); await call(vault, vi, 'setAutoTrade', [agent, MAXU64], BOB);
ok("alice's list does not apply to bob", isErr(await call(vault, vi, 'agentBuy', [S(BOB), agent, S(junk), U(5), 1n, R3(p1(usdg, 3000, junk))], EXEC), 'TOKEN_NOT_ALLOWED'));
ok('canBuy view: alice yes, bob no', (await call(vault, vi, 'canBuy', [S(ALICE), agent, S(junk)])) === true && (await call(vault, vi, 'canBuy', [S(BOB), agent, S(junk)])) === false);

// gasless allow by signature (Allow & buy from Telegram)
const domain = { name: 'HormusAgentVaultV2', version: '2', chainId: vm.common.chainId(), verifyingContract: V_ };
const types = { AllowTokens: [{ name: 'user', type: 'address' }, { name: 'tokensHash', type: 'bytes32' }, { name: 'allowed', type: 'bool' }, { name: 'nonce', type: 'uint256' }, { name: 'deadline', type: 'uint256' }] };
const thash = list => keccak256(concat(list.map(t => zeroPadValue(S(t), 32))));
const sign = async (w, user, list, allowed, nonce, deadline) => w.signTypedData(domain, types, { user: S(user), tokensHash: thash(list), allowed, nonce, deadline });
const dl = NOW + 3600n;
const sigBob = await sign(bobW, BOB, [junk], true, 0n, dl);
ok('signature from someone else rejected', isErr(await call(vault, vi, 'setMyTokensBySig', [S(BOB), [S(junk)], true, dl, await sign(aliceW, BOB, [junk], true, 0n, dl)], EXEC), 'BAD_SIGNATURE'));
ok('bob allows JUNK by gasless signature (sent by executor)', !(await call(vault, vi, 'setMyTokensBySig', [S(BOB), [S(junk)], true, dl, sigBob], EXEC)).err);
ok('same signature cannot be replayed', isErr(await call(vault, vi, 'setMyTokensBySig', [S(BOB), [S(junk)], true, dl, sigBob], EXEC), 'BAD_SIGNATURE'));
ok('signature for other tokens rejected', isErr(await call(vault, vi, 'setMyTokensBySig', [S(BOB), [S(tok)], true, dl, await sign(bobW, BOB, [junk], true, 1n, dl)], EXEC), 'BAD_SIGNATURE'));
ok('expired signature rejected', isErr(await call(vault, vi, 'setMyTokensBySig', [S(BOB), [S(tok)], true, NOW - 1n, await sign(bobW, BOB, [tok], true, 1n, NOW - 1n)], EXEC), 'SIGNATURE_EXPIRED'));
ok('bob agent may buy JUNK now', !(await call(vault, vi, 'agentBuy', [S(BOB), agent, S(junk), U(5), 1n, R3(p1(usdg, 3000, junk))], EXEC)).err);

// degen mode
const odd = await deploy(C('MockERC20'));
ok('unlisted token rejected before degen mode', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(odd), U(5), 1n, R3(p1(usdg, 3000, odd))], EXEC), 'TOKEN_NOT_ALLOWED'));
ok('alice switches degen mode on', !(await call(vault, vi, 'setAgentMode', [agent, true])).err);
ok('degen: any token can be bought', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(odd), U(5), 1n, R3(p1(usdg, 3000, odd))], EXEC)).err);
ok("degen is per agent (alice's agent-2 still blocked)", isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(odd), U(5), 1n, R3(p1(usdg, 3000, odd))], EXEC), 'TOKEN_NOT_ALLOWED'));

// ---------- limits ----------
ok('above max order rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(tok), U(11), 1n, R3(p2(usdg, weth, tok))], EXEC), 'ABOVE_MAX_ORDER'));
ok('buy 10 + 10 within daily 25', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(tok), U(10), 1n, R3(p2(usdg, weth, tok))], EXEC)).err && !(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(tok), U(10), 1n, R3(p2(usdg, weth, tok))], EXEC)).err);
ok('daily limit enforced', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(tok), U(10), 1n, R3(p2(usdg, weth, tok))], EXEC), 'ABOVE_DAILY_LIMIT'));
NOW += 86400n;
ok('next day the daily limit resets', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent2, S(tok), U(10), 1n, R3(p2(usdg, weth, tok))], EXEC)).err);
await call(router, ri, 'setSteal', [true]);
ok('router paying elsewhere fails (TOO_LITTLE_RECEIVED)', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(tok), U(1), 1n, R3(p2(usdg, weth, tok))], EXEC), 'TOO_LITTLE_RECEIVED'));
await call(router, ri, 'setSteal', [false]);

// ---------- Uniswap v4 ----------
const usdgPool = key(usdg, meme), wethPool = key(weth, meme), ethPool = [ZERO, S(meme), 3000, 60, ZERO];
let before = await pos(ALICE, agent, meme);
ok('v4 USDG pool: buy 10 USDG -> 30 MEME', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(10), U(30), R4(usdgPool)], EXEC)).err && (await pos(ALICE, agent, meme)) - before === U(30));
before = await pos(ALICE, agent, meme);
ok('v4 WETH pool: USDG->WETH (x2) then x3 = 60 MEME', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(10), U(60), R4(wethPool, p1(usdg, 500, weth))], EXEC)).err && (await pos(ALICE, agent, meme)) - before === U(60));
before = await pos(ALICE, agent, meme);
ok('v4 native ETH pool: USDG->WETH->ETH then swap = 60 MEME', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(10), U(60), R4(ethPool, p1(usdg, 500, weth))], EXEC)).err && (await pos(ALICE, agent, meme)) - before === U(60));
ok('v4 pool without the token rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, R4(key(usdg, tok))], EXEC), 'INVALID_POOL'));
ok('v4 pool against another token rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, R4(key(tok, meme), p1(usdg, 500, weth))], EXEC), 'INVALID_POOL'));
ok('v4 WETH leg must be USDG->WETH, 1 hop', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, R4(wethPool, p2(usdg, weth, weth))], EXEC), 'INVALID_PATH'));
await call(pm, pi, 'setGreedy', [true]);
ok('v4 pool asking for more than the order is rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, R4(usdgPool)], EXEC), 'BAD_V4_DELTA'));
await call(pm, pi, 'setGreedy', [false]);
ok('nobody but the PoolManager can call unlockCallback', isErr(await call(vault, vi, 'unlockCallback', [ac.encode(['tuple(address,address,uint24,int24,address)', 'bool', 'uint256'], [usdgPool, true, 1n])], MALLORY), 'NOT_POOL_MANAGER'));
await call(pm, pi, 'setRate', [1n, 2n]); await call(router, ri, 'setRate', [1n, 1n]);
let usdgBefore = (await call(vault, vi, 'agentState', [S(ALICE), agent]))[0][0];
ok('v4 sell 60 MEME -> 30 ETH -> 30 USDG back into the budget', !(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(meme), U(60), U(30), R4(ethPool, p1(weth, 500, usdg))], EXEC)).err
  && (await call(vault, vi, 'agentState', [S(ALICE), agent]))[0][0] - usdgBefore === U(30));
ok('v4 sell to USDG pool', !(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(meme), U(20), U(10), R4(usdgPool)], EXEC)).err);
await call(pm, pi, 'setRate', [3n, 1n]); await call(router, ri, 'setRate', [2n, 1n]);

// ---------- Pons curve ----------
before = await pos(ALICE, agent, meme);
ok('Pons curve buy: 1 USDG -> 2 WETH -> 2 ETH -> 2000 MEME', !(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), 1_000_000n, 2_000_000_000n, RP(curve, p1(usdg, 500, weth))], EXEC)).err && (await pos(ALICE, agent, meme)) - before === 2_000_000_000n);
ok("curve whose token() is another token rejected", isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, RP(fakeCurve, p1(usdg, 500, weth))], EXEC), 'INVALID_CURVE'));
ok('an address with no code is not a curve', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, RP(A(0x1234), p1(usdg, 500, weth))], EXEC), 'INVALID_CURVE'));
await call(curve, ci, 'setRefund', [true]);
ok('curve that refunds part of the ETH is rejected', isErr(await call(vault, vi, 'agentBuy', [S(ALICE), agent, S(meme), U(1), 1n, RP(curve, p1(usdg, 500, weth))], EXEC), 'CURVE_REFUND'));
await call(curve, ci, 'setRefund', [false]);
usdgBefore = (await call(vault, vi, 'agentState', [S(ALICE), agent]))[0][0];
ok('Pons curve sell: 2000 MEME -> 2 ETH -> 4 USDG', !(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(meme), 2_000_000_000n, 4_000_000n, RP(curve, p1(weth, 500, usdg))], EXEC)).err
  && (await call(vault, vi, 'agentState', [S(ALICE), agent]))[0][0] - usdgBefore === 4_000_000n);
ok('Pons sell leg must be WETH->USDG', isErr(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(meme), 1n, 1n, RP(curve, p1(usdg, 500, weth))], EXEC), 'INVALID_PATH'));

// ---------- exits, pause, ETH safety ----------
ok('sell more than the position rejected', isErr(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(tok), U(10000), 1n, R3(p2(tok, weth, usdg))], EXEC), 'INSUFFICIENT_POSITION'));
const direct = await vm.evm.runCall({ caller: MALLORY, to: vault, value: 1n, skipBalance: true, gasLimit: 100000n, block: await blockOpts() });
ok('plain ETH sent to the vault is refused', !!direct.execResult.exceptionError);
ok('owner pause blocks the executor', !(await call(vault, vi, 'setPaused', [true], OWNER)).err && isErr(await call(vault, vi, 'agentSell', [S(ALICE), agent, S(tok), U(1), 1n, R3(p2(tok, weth, usdg))], EXEC), 'PAUSED'));
ok('compat depositsPaused() mirrors paused', (await call(vault, vi, 'depositsPaused', [])) === true);
ok('user switches auto-trade off while paused', !(await call(vault, vi, 'setAutoTrade', [agent, 0n])).err);
const tokHeld = await pos(ALICE, agent, tok);
ok('user withdraws a position while paused', tokHeld > 0n && !(await call(vault, vi, 'withdrawPosition', [agent, S(tok), tokHeld, S(ALICE)])).err && (await call(tok, ti, 'balanceOf', [S(ALICE)])) === tokHeld);
ok('user releases both budgets while paused', !(await call(vault, vi, 'deallocate', [agent])).err && !(await call(vault, vi, 'deallocate', [agent2])).err);
const dep = await call(vault, vi, 'deposited', [S(ALICE)]);
ok('user withdraws all USDG while paused', !(await call(vault, vi, 'withdraw', [dep, S(ALICE)])).err && (await call(vault, vi, 'deposited', [S(ALICE)])) === 0n);
ok("bob's USDG is untouched by alice's activity", (await call(vault, vi, 'deposited', [S(BOB)])) === U(495));
ok('mallory cannot set executor or allowlist', isErr(await call(vault, vi, 'setExecutor', [S(MALLORY)], MALLORY), 'NOT_OWNER') && isErr(await call(vault, vi, 'setTokensAllowed', [[S(odd)], true], MALLORY), 'NOT_OWNER'));
ok('two-step ownership', !(await call(vault, vi, 'transferOwnership', [S(BOB)], OWNER)).err && isErr(await call(vault, vi, 'acceptOwnership', [], MALLORY), 'NOT_PENDING_OWNER') && !(await call(vault, vi, 'acceptOwnership', [], BOB)).err);
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
