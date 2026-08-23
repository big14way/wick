import { useEffect, useMemo, useRef, useState } from "react";
import { createPublicClient, http, formatUnits, type Log } from "viem";
import { wickAbi } from "./abi";
import { config, networks, activeNetworkKey, switchNetwork } from "./config";
import { Candle } from "./Candle";
import { Trade, useWallet } from "./Trade";

const client = createPublicClient({ transport: http(config.rpcUrl) });

type PoolState = {
  epochStart: bigint;
  revealedClose: bigint;
  phase: number;
  epochCount: bigint;
  snapshotTick: number;
  lastTick: number;
  volEma: number;
};

type OrderEvt = { block: bigint; zeroForOne: boolean; amountIn: bigint; owner: string; claimId: bigint };
type FeeEvt = { fee: number; roundTrip: boolean; origin: string };
type EpochEvt = {
  epochId: bigint;
  startBlock: bigint;
  closeBlock: bigint;
  in0: bigint;
  in1: bigint;
  out1For0: bigint;
  out0For1: bigint;
  refund0: bigint;
  refund1: bigint;
};
type Fees = { base: number; perTick: number; batch: number };

const short = (a: string) => `${a.slice(0, 6)}..${a.slice(-4)}`;
const fmt0 = (v: bigint) => trim(formatUnits(v, config.token0Decimals));
const fmt1 = (v: bigint) => trim(formatUnits(v, config.token1Decimals));
const trim = (s: string) => {
  const n = Number(s);
  if (n === 0) return "0";
  return n >= 1000 ? n.toLocaleString("en-US", { maximumFractionDigits: 0 }) : n >= 1 ? n.toFixed(3) : n.toFixed(5);
};
const explorer = config.explorerUrl;

export default function App() {
  const wallet = useWallet();
  const [activityTab, setActivityTab] = useState<"orders" | "fees">("orders");
  const [blockNumber, setBlockNumber] = useState<bigint>(0n);
  const [pool, setPool] = useState<PoolState | null>(null);
  const [minSpan, setMinSpan] = useState<bigint>(1n);
  const [maxSpan, setMaxSpan] = useState<bigint>(1n);
  const [fees, setFees] = useState<Fees | null>(null);
  const [orders, setOrders] = useState<OrderEvt[]>([]);
  const [feeEvents, setFeeEvents] = useState<FeeEvt[]>([]);
  const [epochs, setEpochs] = useState<EpochEvt[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Log scan is incremental: remember where the last sweep ended and only
  // read forward from there, keeping events accumulated across ticks.
  const scanFrom = useRef<bigint>(config.deployBlock);
  const seen = useRef<Set<string>>(new Set());
  const acc = useRef<{ orders: OrderEvt[]; fees: FeeEvt[]; epochs: EpochEvt[] }>({ orders: [], fees: [], epochs: [] });

  useEffect(() => {
    let stop = false;

    const readStatics = async () => {
      const [mn, mx, base, perTick, batch] = await Promise.all([
        client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "minSpan" }),
        client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "maxSpan" }),
        client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "instantBaseFee" }),
        client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "volFeePerTick" }),
        client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "batchFee" }),
      ]);
      if (stop) return;
      setMinSpan(mn);
      setMaxSpan(mx);
      setFees({ base: Number(base), perTick: Number(perTick), batch: Number(batch) });
    };

    const tick = async () => {
      try {
        const [bn, ps] = await Promise.all([
          client.getBlockNumber(),
          client.readContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "pools",
            args: [config.poolId],
          }),
        ]);
        if (stop) return;
        setBlockNumber(bn);
        setPool({
          epochStart: ps[0],
          revealedClose: ps[1],
          phase: Number(ps[2]),
          epochCount: BigInt(ps[3]),
          snapshotTick: Number(ps[5]),
          lastTick: Number(ps[6]),
          volEma: Number(ps[8]),
        });

        // Backfill in bounded chunks so public RPC log range limits and rate
        // limits cannot fail the whole sweep. Progress survives a failed chunk
        // because scanFrom only advances after a successful read.
        const CHUNK = 9500n; // sepolia.unichain.org caps eth_getLogs at 10000 blocks
        while (scanFrom.current <= bn) {
          const to = scanFrom.current + CHUNK - 1n < bn ? scanFrom.current + CHUNK - 1n : bn;
          const logs = await client.getLogs({
            address: config.hookAddress,
            events: wickAbi.filter((x) => x.type === "event"),
            fromBlock: scanFrom.current,
            toBlock: to,
          });
          if (stop) return;
          digest(logs as (Log & { eventName: string; args: Record<string, unknown> })[]);
          scanFrom.current = to + 1n;
        }
        setError(null);
      } catch (e) {
        if (!stop) setError(e instanceof Error ? e.message : String(e));
      }
    };

    const digest = (logs: (Log & { eventName: string; args: Record<string, unknown> })[]) => {
      const a = acc.current;
      for (const l of logs) {
        const key = `${l.transactionHash}:${l.logIndex}`;
        if (seen.current.has(key)) continue;
        seen.current.add(key);
        const g = l.args;
        if ((g.poolId as string | undefined)?.toLowerCase() !== config.poolId.toLowerCase()) continue;
        if (l.eventName === "OrderPlaced") {
          a.orders.push({
            block: g.blockNumber as bigint,
            zeroForOne: g.zeroForOne as boolean,
            amountIn: g.amountIn as bigint,
            owner: g.owner as string,
            claimId: g.claimId as bigint,
          });
        } else if (l.eventName === "InstantFeeCharged") {
          a.fees.push({ fee: Number(g.fee), roundTrip: g.roundTrip as boolean, origin: g.origin as string });
        } else if (l.eventName === "EpochSettled") {
          a.epochs.push({
            epochId: BigInt(g.epochId as bigint),
            startBlock: g.startBlock as bigint,
            closeBlock: g.closeBlock as bigint,
            in0: g.in0 as bigint,
            in1: g.in1 as bigint,
            out1For0: g.out1For0 as bigint,
            out0For1: g.out0For1 as bigint,
            refund0: g.refund0 as bigint,
            refund1: g.refund1 as bigint,
          });
        }
      }
      setOrders([...a.orders].reverse());
      setFeeEvents([...a.fees].reverse());
      setEpochs([...a.epochs].reverse());
    };

    readStatics().catch(() => undefined);
    tick();
    const id = setInterval(tick, config.pollMs);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, []);

  const totals = useMemo(() => {
    let v0 = 0n;
    let v1 = 0n;
    for (const o of orders) o.zeroForOne ? (v0 += o.amountIn) : (v1 += o.amountIn);
    return { n: orders.length, v0, v1 };
  }, [orders]);

  const orderSettled = (block: bigint) => epochs.some((e) => e.startBlock <= block && block <= e.closeBlock);

  const instantFeeNow = fees && pool ? fees.base + fees.perTick * pool.volEma : null;

  return (
    <div className="shell">
      <header className="mast">
        <div className="brand">
          <div className="wordmark">
            Wick<span className="dot">.</span>
          </div>
          <div className="tagline">Candle auction settlement for Uniswap v4</div>
        </div>
        <div className="mast-right">
          <span className={config.randomness.kind === "vrf" ? "rand-chip vrf" : "rand-chip"}>
            {config.randomness.kind === "vrf" ? "Chainlink VRF" : "Blockhash demo"}
          </span>
          <label className="net-chip">
            <span className="pulse" aria-hidden="true" />
            <select
              className="net-select"
              value={activeNetworkKey}
              onChange={(e) => switchNetwork(e.target.value)}
              aria-label="Network"
            >
              {Object.values(networks).map((n) => (
                <option key={n.key} value={n.key}>
                  {n.label}
                </option>
              ))}
            </select>
          </label>
          <span className="block-chip mono">#{blockNumber.toString()}</span>
          {wallet.account ? (
            wallet.wrongChain ? (
              <button className="btn" onClick={wallet.switchChain}>
                Switch network
              </button>
            ) : (
              <span className="account-chip mono">{short(wallet.account)}</span>
            )
          ) : (
            <button className="btn connect" onClick={wallet.connect} disabled={!wallet.hasProvider}>
              {wallet.hasProvider ? "Connect wallet" : "No wallet found"}
            </button>
          )}
        </div>
      </header>

      {error && (
        <div className="notice">
          <b>RPC read failed.</b> {error.slice(0, 160)}
        </div>
      )}

      <div className="kpis">
        <div className="kpi">
          <div className="k">Protected orders</div>
          <div className="v">{totals.n}</div>
          <div className="c">custodied or settled, all time</div>
        </div>
        <div className="kpi">
          <div className="k">Protected volume</div>
          <div className="v">
            {fmt0(totals.v0)} <span className="unit">{config.token0Symbol}</span>
          </div>
          <div className="c">
            plus {fmt1(totals.v1)} {config.token1Symbol} the other way
          </div>
        </div>
        <div className="kpi">
          <div className="k">Instant swaps</div>
          <div className="v">{feeEvents.length}</div>
          <div className="c">priced by the volatility fee</div>
        </div>
        <div className="kpi">
          <div className="k">Instant fee now</div>
          <div className="v">{instantFeeNow !== null ? `${(instantFeeNow / 10000).toFixed(2)}%` : "..."}</div>
          <div className="c">
            {pool && fees ? `${(fees.base / 10000).toFixed(2)}% base + ${pool.volEma} vol ticks` : "reading"}
          </div>
        </div>
      </div>

      <div className="grid">
        <div className="stack stack-left">
          <Trade
            wallet={wallet}
            orders={orders}
            lastTick={pool?.lastTick ?? 0}
            volEma={pool?.volEma ?? 0}
            fees={fees}
            maxSpan={maxSpan}
          />
        </div>

        <div className="stack">
          <section className="card">
            <div className="card-head">
              <h2>The candle</h2>
              {pool && (
                <span className={`phase-chip ${["phase-open", "phase-drawing", "phase-revealed"][pool.phase]}`}>
                  {["Open", "Drawing", "Revealed"][pool.phase]}
                </span>
              )}
            </div>
            <p className="card-sub">
              Not price candles. A candle auction: the batch closes at a random block inside the window, so there is no
              deadline to snipe.
            </p>
            {pool ? (
              <>
                <Candle
                  phase={pool.phase}
                  epochStart={pool.epochStart}
                  minSpan={minSpan}
                  maxSpan={maxSpan}
                  currentBlock={blockNumber}
                  revealedClose={pool.revealedClose}
                />
                <div className="stat-inline">
                  <div className="stat">
                    <div className="k">Epoch start</div>
                    <div className="v mono">{pool.epochStart === 0n ? "idle" : `#${pool.epochStart.toString()}`}</div>
                  </div>
                  <div className="stat">
                    <div className="k">Window ends</div>
                    <div className="v mono">
                      {pool.epochStart === 0n ? "idle" : `#${(pool.epochStart + maxSpan - 1n).toString()}`}
                    </div>
                  </div>
                  <div className="stat">
                    <div className="k">Epochs settled</div>
                    <div className="v mono">{pool.epochCount.toString()}</div>
                  </div>
                  <div className="stat">
                    <div className="k">Volatility EMA</div>
                    <div className="v mono">{pool.volEma} ticks</div>
                  </div>
                </div>
              </>
            ) : (
              <div className="empty">Waiting for the first read.</div>
            )}
          </section>

          <section className="card">
            <div className="card-head">
              <h2>Activity</h2>
              <div className="mini-tabs" role="tablist">
                <button
                  role="tab"
                  aria-selected={activityTab === "orders"}
                  className={activityTab === "orders" ? "mini-tab on" : "mini-tab"}
                  onClick={() => setActivityTab("orders")}
                >
                  Protected orders <span className="n">{orders.length}</span>
                </button>
                <button
                  role="tab"
                  aria-selected={activityTab === "fees"}
                  className={activityTab === "fees" ? "mini-tab on" : "mini-tab"}
                  onClick={() => setActivityTab("fees")}
                >
                  Instant fees <span className="n">{feeEvents.length}</span>
                </button>
              </div>
            </div>
            {activityTab === "orders" ? (
              <div className="feed">
                {orders.length === 0 && (
                  <div className="empty">No protected orders yet. Place one from the swap card.</div>
                )}
                {orders.slice(0, 40).map((o, i) => (
                  <div className="feed-row" key={i}>
                    <span className={o.zeroForOne ? "dir zfo" : "dir ofz"}>
                      {o.zeroForOne ? config.token0Symbol : config.token1Symbol}
                      <svg width="12" height="10" viewBox="0 0 12 10" aria-hidden="true">
                        <path d="M1 5h9M7 1.5 10.5 5 7 8.5" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round" />
                      </svg>
                      {o.zeroForOne ? config.token1Symbol : config.token0Symbol}
                    </span>
                    <span className="mono amt">{o.zeroForOne ? fmt0(o.amountIn) : fmt1(o.amountIn)}</span>
                    <a className="mono blk" href={`${explorer}/block/${o.block}`} target="_blank" rel="noreferrer">
                      #{o.block.toString()}
                    </a>
                    <a className="mono who" href={`${explorer}/address/${o.owner}`} target="_blank" rel="noreferrer">
                      {short(o.owner)}
                    </a>
                    <span className={orderSettled(o.block) ? "state settled" : "state pending"}>
                      {orderSettled(o.block) ? "Settled" : "In candle"}
                    </span>
                  </div>
                ))}
              </div>
            ) : (
              <div className="fee-chips">
                {feeEvents.length === 0 && (
                  <div className="empty">No instant swaps yet. Pick the Instant lane on the swap card.</div>
                )}
                {feeEvents.slice(0, 24).map((f, i) => (
                  <span
                    key={i}
                    className={f.roundTrip ? "chip rt" : "chip"}
                    title={f.roundTrip ? "Same block round trip surcharge applied" : "Volatility priced fee"}
                  >
                    {(f.fee / 10000).toFixed(2)}%{f.roundTrip ? " round trip" : ""}
                  </span>
                ))}
              </div>
            )}
          </section>

          <section className="card">
            <div className="card-head">
              <h2>Settled epochs</h2>
              <span className="count-chip">{epochs.length}</span>
            </div>
            <div className="feed">
              {epochs.length === 0 && <div className="empty">Nothing settled yet. Light a candle first.</div>}
              {epochs.map((e) => {
                const filled0 = e.in0 - e.refund0;
                const p1per0 = filled0 > 0n ? Number(formatUnits(e.out1For0, 18)) / Number(formatUnits(filled0, 18)) : null;
                const fill0 = e.in0 > 0n ? Number(((e.in0 - e.refund0) * 100n) / e.in0) : null;
                const fill1 = e.in1 > 0n ? Number(((e.in1 - e.refund1) * 100n) / e.in1) : null;
                return (
                  <div className="epoch-card" key={e.epochId.toString()}>
                    <div className="head">
                      <span className="id">Epoch {e.epochId.toString()}</span>
                      <span className="mono range">
                        <a href={`${explorer}/block/${e.startBlock}`} target="_blank" rel="noreferrer">
                          #{e.startBlock.toString()}
                        </a>{" "}
                        to{" "}
                        <a href={`${explorer}/block/${e.closeBlock}`} target="_blank" rel="noreferrer">
                          #{e.closeBlock.toString()}
                        </a>
                      </span>
                    </div>
                    {p1per0 !== null && (
                      <div className="clearing">
                        Cleared at <b className="mono">{p1per0.toFixed(5)}</b> {config.token1Symbol} per{" "}
                        {config.token0Symbol}
                      </div>
                    )}
                    <div className="nums">
                      <span>
                        {config.token0Symbol} in <b>{fmt0(e.in0)}</b>
                        {fill0 !== null && <i>{fill0}% filled</i>}
                      </span>
                      <span>
                        {config.token1Symbol} in <b>{fmt1(e.in1)}</b>
                        {fill1 !== null && <i>{fill1}% filled</i>}
                      </span>
                      <span>
                        Refunds <b>{fmt0(e.refund0)}</b> / <b>{fmt1(e.refund1)}</b>
                      </span>
                    </div>
                  </div>
                );
              })}
            </div>
          </section>

        </div>
      </div>

      <footer className="foot">
        <div className="foot-links">
          <a href={`${explorer}/address/${config.hookAddress}`} target="_blank" rel="noreferrer">
            WickHook
          </a>
          <a href={`${explorer}/address/${config.randomness.address}`} target="_blank" rel="noreferrer">
            {config.randomness.kind === "vrf" ? "ChainlinkVRFProvider" : "BlockhashProvider"}
          </a>
          <a href={`${explorer}/address/${config.routerAddress}`} target="_blank" rel="noreferrer">
            Swap router
          </a>
          <a href={`${explorer}/address/${config.poolKey.currency0}`} target="_blank" rel="noreferrer">
            {config.token0Symbol}
          </a>
          <a href={`${explorer}/address/${config.poolKey.currency1}`} target="_blank" rel="noreferrer">
            {config.token1Symbol}
          </a>
        </div>
        <div className="foot-note">
          Built on Uniswap v4 hooks for the Atrium UHI10 hookathon.{" "}
          {config.randomness.kind === "vrf"
            ? "Candle close randomness on this chain comes from Chainlink VRF 2.5, the production path."
            : "This chain draws the candle close from a blockhash provider because Chainlink VRF does not serve it; the same hook runs on Base Sepolia with real VRF 2.5, switchable above."}
        </div>
      </footer>
    </div>
  );
}
