import { useEffect, useMemo, useState } from "react";
import { createPublicClient, http, formatUnits, type Log } from "viem";
import { wickAbi } from "./abi";
import { config } from "./config";
import { Candle } from "./Candle";

const client = createPublicClient({ transport: http(config.rpcUrl) });

type PoolState = {
  epochStart: bigint;
  revealedClose: bigint;
  phase: number;
  epochCount: bigint;
  snapshotTick: number;
  volEma: number;
};

type OrderEvt = { block: bigint; zeroForOne: boolean; amountIn: bigint; owner: string };
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

const short = (a: string) => `${a.slice(0, 6)}..${a.slice(-4)}`;
const fmt0 = (v: bigint) => trim(formatUnits(v, config.token0Decimals));
const fmt1 = (v: bigint) => trim(formatUnits(v, config.token1Decimals));
const trim = (s: string) => {
  const n = Number(s);
  return n >= 1000 ? n.toFixed(0) : n >= 1 ? n.toFixed(3) : n.toFixed(5);
};

export default function App() {
  const [blockNumber, setBlockNumber] = useState<bigint>(0n);
  const [pool, setPool] = useState<PoolState | null>(null);
  const [minSpan, setMinSpan] = useState<bigint>(1n);
  const [maxSpan, setMaxSpan] = useState<bigint>(1n);
  const [orders, setOrders] = useState<OrderEvt[]>([]);
  const [fees, setFees] = useState<FeeEvt[]>([]);
  const [epochs, setEpochs] = useState<EpochEvt[]>([]);
  const [error, setError] = useState<string | null>(null);

  const configured =
    config.hookAddress !== "0x0000000000000000000000000000000000000000" &&
    config.poolId !== "0x0000000000000000000000000000000000000000000000000000000000000000";

  useEffect(() => {
    if (!configured) return;
    let stop = false;

    const tick = async () => {
      try {
        const [bn, ps, mn, mx] = await Promise.all([
          client.getBlockNumber(),
          client.readContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "pools",
            args: [config.poolId],
          }),
          client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "minSpan" }),
          client.readContract({ address: config.hookAddress, abi: wickAbi, functionName: "maxSpan" }),
        ]);
        if (stop) return;
        setBlockNumber(bn);
        setMinSpan(mn);
        setMaxSpan(mx);
        setPool({
          epochStart: ps[0],
          revealedClose: ps[1],
          phase: Number(ps[2]),
          epochCount: BigInt(ps[3]),
          snapshotTick: Number(ps[5]),
          volEma: Number(ps[8]),
        });

        const logs = await client.getLogs({
          address: config.hookAddress,
          events: wickAbi.filter((x) => x.type === "event"),
          args: { poolId: config.poolId } as never,
          fromBlock: config.deployBlock,
          toBlock: bn,
        });
        if (stop) return;
        digest(logs as (Log & { eventName: string; args: Record<string, unknown> })[]);
        setError(null);
      } catch (e) {
        if (!stop) setError(e instanceof Error ? e.message : String(e));
      }
    };

    const digest = (logs: (Log & { eventName: string; args: Record<string, unknown> })[]) => {
      const o: OrderEvt[] = [];
      const f: FeeEvt[] = [];
      const ep: EpochEvt[] = [];
      for (const l of logs) {
        const a = l.args;
        if (l.eventName === "OrderPlaced") {
          o.push({
            block: a.blockNumber as bigint,
            zeroForOne: a.zeroForOne as boolean,
            amountIn: a.amountIn as bigint,
            owner: a.owner as string,
          });
        } else if (l.eventName === "InstantFeeCharged") {
          f.push({ fee: Number(a.fee), roundTrip: a.roundTrip as boolean, origin: a.origin as string });
        } else if (l.eventName === "EpochSettled") {
          ep.push({
            epochId: BigInt(a.epochId as bigint),
            startBlock: a.startBlock as bigint,
            closeBlock: a.closeBlock as bigint,
            in0: a.in0 as bigint,
            in1: a.in1 as bigint,
            out1For0: a.out1For0 as bigint,
            out0For1: a.out0For1 as bigint,
            refund0: a.refund0 as bigint,
            refund1: a.refund1 as bigint,
          });
        }
      }
      setOrders(o.reverse());
      setFees(f.reverse());
      setEpochs(ep.reverse());
    };

    tick();
    const id = setInterval(tick, config.pollMs);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, [configured]);

  const protectedTotals = useMemo(() => {
    let n = orders.length;
    let v0 = 0n;
    let v1 = 0n;
    for (const o of orders) o.zeroForOne ? (v0 += o.amountIn) : (v1 += o.amountIn);
    return { n, v0, v1 };
  }, [orders]);

  const phaseName = pool ? ["Open", "Drawing", "Revealed"][pool.phase] : "";
  const phaseClass = pool ? ["phase-open", "phase-drawing", "phase-revealed"][pool.phase] : "";

  return (
    <div className="shell">
      <header className="mast">
        <div>
          <div className="wordmark">
            Wick<span className="dot">.</span>
          </div>
          <div className="tagline">Candle auction settlement for Uniswap v4. Sandwiches starve here.</div>
        </div>
        <div className="tagline">
          block <span style={{ fontFamily: "Fraunces, serif", fontSize: 16 }}>{blockNumber.toString()}</span>
        </div>
      </header>

      {!configured && (
        <div className="notice">
          <b>Not connected yet.</b> Deploy the hook, then set hookAddress, poolId and deployBlock in
          src/config.ts. The dashboard starts reading on its own after that.
        </div>
      )}

      {error && (
        <div className="notice">
          <b>RPC read failed.</b> {error.slice(0, 200)}
        </div>
      )}

      <div className="grid">
        <div className="stack">
          <section className="panel">
            <h2>The candle</h2>
            {pool && (
              <>
                <Candle
                  phase={pool.phase}
                  epochStart={pool.epochStart}
                  minSpan={minSpan}
                  maxSpan={maxSpan}
                  currentBlock={blockNumber}
                  revealedClose={pool.revealedClose}
                />
                <div style={{ textAlign: "center" }}>
                  <span className={`phase-chip ${phaseClass}`}>{phaseName}</span>
                </div>
                <div className="stat-rows">
                  <div className="stat">
                    <div className="k">Epoch start</div>
                    <div className="v">{pool.epochStart.toString()}</div>
                  </div>
                  <div className="stat">
                    <div className="k">Window ends</div>
                    <div className="v">
                      {pool.epochStart === 0n ? "idle" : (pool.epochStart + maxSpan - 1n).toString()}
                    </div>
                  </div>
                  <div className="stat">
                    <div className="k">Epochs settled</div>
                    <div className="v">{pool.epochCount.toString()}</div>
                  </div>
                  <div className="stat">
                    <div className="k">Volatility EMA</div>
                    <div className="v">{pool.volEma} ticks</div>
                  </div>
                </div>
              </>
            )}
            {!pool && <div className="empty">Waiting for the first read.</div>}
          </section>
        </div>

        <div className="stack">
          <section className="panel">
            <h2>Two lanes</h2>
            <div className="lane-split">
              <div className="lane">
                <div className="name">Protected</div>
                <div className="desc">Custody now, one uniform price at the candle close. No sandwich possible.</div>
                <div className="big">{protectedTotals.n}</div>
                <div className="sub">
                  orders held. {fmt0(protectedTotals.v0)} {config.token0Symbol} and {fmt1(protectedTotals.v1)}{" "}
                  {config.token1Symbol} in custody or settled.
                </div>
              </div>
              <div className="lane instant">
                <div className="name">Instant</div>
                <div className="desc">Trade now, pay the anti MEV premium. Every pip goes to LPs.</div>
                <div className="big">{fees.length}</div>
                <div className="sub">instant swaps priced. Round trips in the same block pay a surcharge.</div>
                <div className="fee-chips">
                  {fees.slice(0, 12).map((f, i) => (
                    <span key={i} className={f.roundTrip ? "chip rt" : "chip"}>
                      {(f.fee / 10000).toFixed(2)}%{f.roundTrip ? " rt" : ""}
                    </span>
                  ))}
                </div>
              </div>
            </div>
          </section>

          <section className="panel">
            <h2>Order feed</h2>
            <div className="feed">
              {orders.length === 0 && <div className="empty">No protected orders yet.</div>}
              {orders.slice(0, 40).map((o, i) => (
                <div className="row" key={i}>
                  <span className={o.zeroForOne ? "dir zfo" : "dir ofz"}>
                    {o.zeroForOne
                      ? `${config.token0Symbol} to ${config.token1Symbol}`
                      : `${config.token1Symbol} to ${config.token0Symbol}`}
                  </span>
                  <span className="mono">
                    {o.zeroForOne ? fmt0(o.amountIn) : fmt1(o.amountIn)} in block {o.block.toString()}
                  </span>
                  <span className="who mono">{short(o.owner)}</span>
                </div>
              ))}
            </div>
          </section>

          <section className="panel">
            <h2>Settled epochs</h2>
            <div className="feed">
              {epochs.length === 0 && <div className="empty">Nothing settled yet. Light a candle first.</div>}
              {epochs.map((e) => (
                <div className="epoch-card" key={e.epochId.toString()}>
                  <div className="head">
                    <span className="id">Epoch {e.epochId.toString()}</span>
                    <span className="mono" style={{ color: "var(--caption)" }}>
                      blocks {e.startBlock.toString()} to {e.closeBlock.toString()}
                    </span>
                  </div>
                  <div className="nums">
                    <span>
                      in0 <b>{fmt0(e.in0)}</b>
                    </span>
                    <span>
                      in1 <b>{fmt1(e.in1)}</b>
                    </span>
                    <span>
                      out1 for 0 side <b>{fmt1(e.out1For0)}</b>
                    </span>
                    <span>
                      out0 for 1 side <b>{fmt0(e.out0For1)}</b>
                    </span>
                    <span>
                      refund0 <b>{fmt0(e.refund0)}</b>
                    </span>
                    <span>
                      refund1 <b>{fmt1(e.refund1)}</b>
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
