import { useCallback, useEffect, useState } from "react";
import {
  createWalletClient,
  createPublicClient,
  custom,
  http,
  defineChain,
  parseUnits,
  formatUnits,
  encodeAbiParameters,
  type Address,
} from "viem";
import { wickAbi, erc20Abi, routerAbi } from "./abi";
import { config } from "./config";

const chain = defineChain({
  id: config.chainId,
  name: config.chainName,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [config.rpcUrl] } },
  blockExplorers: { default: { name: "explorer", url: config.explorerUrl } },
});

const publicClient = createPublicClient({ chain, transport: http(config.rpcUrl) });

type Eip1193 = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, cb: (arg: unknown) => void) => void;
};
const eth = () => (window as { ethereum?: Eip1193 }).ethereum;

// The provider actually connected: the injected wallet, or a WalletConnect
// session for mobile wallets when no extension is present.
let activeProvider: Eip1193 | null = null;
const provider = () => activeProvider ?? eth();

async function walletConnectProvider(): Promise<Eip1193> {
  const { EthereumProvider } = await import("@walletconnect/ethereum-provider");
  const p = await EthereumProvider.init({
    projectId: config.walletConnectProjectId,
    chains: [config.chainId],
    showQrModal: true,
    rpcMap: { [config.chainId]: config.rpcUrl },
    metadata: {
      name: "Wick",
      description: "Candle auction settlement for Uniswap v4",
      url: window.location.origin,
      icons: [],
    },
  });
  await p.enable();
  return p as unknown as Eip1193;
}

export type Wallet = {
  account: Address | null;
  wrongChain: boolean;
  hasProvider: boolean;
  connect: () => Promise<void>;
  switchChain: () => Promise<void>;
};

export function useWallet(): Wallet {
  const [account, setAccount] = useState<Address | null>(null);
  const [wrongChain, setWrongChain] = useState(false);
  const hasProvider = typeof window !== "undefined" && (!!eth() || !!config.walletConnectProjectId);

  const syncChain = useCallback(async () => {
    const p = provider();
    if (!p) return;
    const id = (await p.request({ method: "eth_chainId" })) as string;
    setWrongChain(parseInt(id, 16) !== config.chainId);
  }, []);

  const listen = useCallback(
    (p: Eip1193) => {
      p.on?.("accountsChanged", (accs) => setAccount(((accs as string[])[0] as Address) ?? null));
      p.on?.("chainChanged", () => syncChain());
      p.on?.("disconnect", () => setAccount(null));
    },
    [syncChain],
  );

  const connect = useCallback(async () => {
    let p = eth();
    if (!p && config.walletConnectProjectId) {
      p = await walletConnectProvider();
    }
    if (!p) return;
    activeProvider = p;
    listen(p);
    const accounts = (await p.request({ method: "eth_requestAccounts" })) as string[];
    setAccount((accounts[0] as Address) ?? null);
    await syncChain();
  }, [listen, syncChain]);

  const switchChain = useCallback(async () => {
    const p = provider();
    if (!p) return;
    const hexId = `0x${config.chainId.toString(16)}`;
    try {
      await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
    } catch (e) {
      if ((e as { code?: number }).code === 4902) {
        await p.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: hexId,
              chainName: config.chainName,
              nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
              rpcUrls: [config.rpcUrl],
              blockExplorerUrls: [config.explorerUrl],
            },
          ],
        });
      }
    }
    await syncChain();
  }, [syncChain]);

  useEffect(() => {
    const p = eth();
    if (!p) return;
    listen(p);
    // Pick up an already authorized injected account without prompting.
    p.request({ method: "eth_accounts" })
      .then((accs) => {
        const a = (accs as string[])[0];
        if (a) {
          activeProvider = p;
          setAccount(a as Address);
          syncChain();
        }
      })
      .catch(() => undefined);
  }, [listen, syncChain]);

  return { account, wrongChain, hasProvider, connect, switchChain };
}

type OrderIn = { block: bigint; zeroForOne: boolean; owner: string; claimId: bigint };
type Claim = { block: bigint; zeroForOne: boolean; claimId: bigint; balance: bigint; settled: boolean };
type Fees = { base: number; perTick: number; batch: number };

// Turn raw node errors into something a person can act on.
const friendly = (e: unknown) => {
  const m = e instanceof Error ? e.message : String(e);
  if (/nonce too low|replacement transaction underpriced/i.test(m))
    return "Another transaction from this wallet landed first and stole the nonce. Retry the swap; it will go through.";
  if (/user rejected|denied/i.test(m)) return "Transaction rejected in the wallet.";
  if (/insufficient funds/i.test(m)) return "Not enough ETH in the wallet for gas.";
  return m.slice(0, 200);
};

const fmtAmt = (v: bigint, d: number) => {
  const n = Number(formatUnits(v, d));
  return n >= 1000 ? n.toLocaleString("en-US", { maximumFractionDigits: 2 }) : n.toFixed(n >= 1 ? 4 : 6);
};

export function Trade({
  wallet,
  orders,
  lastTick,
  volEma,
  fees,
  maxSpan,
}: {
  wallet: Wallet;
  orders: OrderIn[];
  lastTick: number;
  volEma: number;
  fees: Fees | null;
  maxSpan: bigint;
}) {
  const { account, wrongChain } = wallet;
  const [zeroForOne, setZeroForOne] = useState(true);
  const [lane, setLane] = useState<"protected" | "instant">("protected");
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [status, setStatus] = useState<{ kind: "ok" | "err"; text: string; tx?: string } | null>(null);
  const [claims, setClaims] = useState<Claim[]>([]);
  const [balances, setBalances] = useState<{ b0: bigint; b1: bigint } | null>(null);

  const walletClient = () => {
    const p = provider();
    if (!p) throw new Error("No wallet connected.");
    return createWalletClient({ chain, transport: custom(p) });
  };

  // Balances for the connected wallet, refreshed with the block poll cadence.
  useEffect(() => {
    if (!account) {
      setBalances(null);
      return;
    }
    let stop = false;
    const read = async () => {
      const [b0, b1] = await Promise.all([
        publicClient.readContract({
          address: config.poolKey.currency0,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [account],
        }),
        publicClient.readContract({
          address: config.poolKey.currency1,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [account],
        }),
      ]);
      if (!stop) setBalances({ b0, b1 });
    };
    read().catch(() => undefined);
    const id = setInterval(() => read().catch(() => undefined), config.pollMs);
    return () => {
      stop = true;
      clearInterval(id);
    };
  }, [account]);

  // Open claims for the connected wallet, derived from the order feed.
  useEffect(() => {
    if (!account) {
      setClaims([]);
      return;
    }
    let stop = false;
    (async () => {
      const mine = new Map<string, OrderIn>();
      for (const o of orders) {
        if (o.owner.toLowerCase() !== account.toLowerCase()) continue;
        mine.set(o.claimId.toString(), o);
      }
      const out: Claim[] = [];
      for (const o of mine.values()) {
        const [balance, epochId] = await Promise.all([
          publicClient.readContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "balanceOf",
            args: [account, o.claimId],
          }),
          publicClient.readContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "epochOfBlock",
            args: [config.poolId, o.block],
          }),
        ]);
        if (balance > 0n)
          out.push({ block: o.block, zeroForOne: o.zeroForOne, claimId: o.claimId, balance, settled: epochId !== 0 });
      }
      if (!stop) setClaims(out.sort((a, b) => (a.block > b.block ? -1 : 1)));
    })().catch(() => undefined);
    return () => {
      stop = true;
    };
  }, [account, orders]);

  const inSymbol = zeroForOne ? config.token0Symbol : config.token1Symbol;
  const outSymbol = zeroForOne ? config.token1Symbol : config.token0Symbol;
  const inDecimals = zeroForOne ? config.token0Decimals : config.token1Decimals;
  const outDecimals = zeroForOne ? config.token1Decimals : config.token0Decimals;
  const inToken = zeroForOne ? config.poolKey.currency0 : config.poolKey.currency1;
  const inBalance = balances ? (zeroForOne ? balances.b0 : balances.b1) : null;

  // Price estimate from the pool's last recorded tick. Display only.
  const price1Per0 = Math.pow(1.0001, lastTick);
  const parsedAmount = (() => {
    try {
      return amount ? parseUnits(amount, inDecimals) : 0n;
    } catch {
      return null; // malformed input
    }
  })();
  const instantFeeBps = fees ? fees.base + fees.perTick * volEma : null;
  const estimateOut = (() => {
    if (!parsedAmount || parsedAmount <= 0n) return null;
    const inNum = Number(formatUnits(parsedAmount, inDecimals));
    let out = zeroForOne ? inNum * price1Per0 : inNum / price1Per0;
    if (lane === "instant" && instantFeeBps !== null) out *= 1 - instantFeeBps / 1e6;
    if (lane === "protected" && fees) out *= 1 - fees.batch / 1e6;
    return out;
  })();

  const insufficient = inBalance !== null && parsedAmount !== null && parsedAmount > inBalance;

  const cta = !account
    ? { label: "Connect wallet", action: wallet.connect, disabled: false }
    : wrongChain
      ? { label: `Switch to ${config.chainName}`, action: wallet.switchChain, disabled: false }
      : parsedAmount === null
        ? { label: "Invalid amount", action: async () => undefined, disabled: true }
        : parsedAmount === 0n
          ? { label: "Enter an amount", action: async () => undefined, disabled: true }
          : insufficient
            ? { label: `Insufficient ${inSymbol} balance`, action: async () => undefined, disabled: true }
            : {
                label: lane === "protected" ? "Place protected order" : "Swap now",
                action: () => swap(),
                disabled: !!busy,
              };

  const swap = async () => {
    if (!account || !parsedAmount || parsedAmount <= 0n) return;
    setStatus(null);
    try {
      const wc = walletClient();
      const allowance = await publicClient.readContract({
        address: inToken,
        abi: erc20Abi,
        functionName: "allowance",
        args: [account, config.routerAddress],
      });
      if (allowance < parsedAmount) {
        setBusy(`Approving ${inSymbol}`);
        const approveTx = await wc.writeContract({
          address: inToken,
          abi: erc20Abi,
          functionName: "approve",
          args: [config.routerAddress, 2n ** 256n - 1n],
          account,
        });
        await publicClient.waitForTransactionReceipt({ hash: approveTx });
      }
      setBusy(lane === "protected" ? "Placing order" : "Swapping");
      const hookData = lane === "protected" ? "0x" : encodeAbiParameters([{ type: "uint8" }], [1]);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const tx = await wc.writeContract({
        address: config.routerAddress,
        abi: routerAbi,
        functionName: "swapExactTokensForTokens",
        args: [parsedAmount, 0n, zeroForOne, config.poolKey, hookData as `0x${string}`, account, deadline],
        account,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
      if (receipt.status !== "success") throw new Error("Transaction reverted.");
      setAmount("");
      setStatus({
        kind: "ok",
        text:
          lane === "protected"
            ? `Order custodied in block ${receipt.blockNumber}. It clears at the candle close price.`
            : "Filled at the current dynamic fee.",
        tx,
      });
    } catch (e) {
      setStatus({ kind: "err", text: friendly(e) });
    } finally {
      setBusy(null);
    }
  };

  const claimAction = async (c: Claim) => {
    if (!account) return;
    setStatus(null);
    try {
      const wc = walletClient();
      setBusy(c.settled ? "Redeeming" : "Cancelling");
      const tx = c.settled
        ? await wc.writeContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "redeem",
            args: [config.poolKey, c.block, c.zeroForOne, account],
            account,
          })
        : await wc.writeContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "cancel",
            args: [config.poolKey, c.block, c.zeroForOne],
            account,
          });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
      if (receipt.status !== "success") throw new Error("Transaction reverted.");
      setStatus({ kind: "ok", text: c.settled ? "Redeemed to your wallet." : "Cancelled and refunded.", tx });
    } catch (e) {
      setStatus({ kind: "err", text: friendly(e) });
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="card swap-card">
      <div className="seg-tabs" role="tablist">
        <button
          role="tab"
          aria-selected={lane === "protected"}
          className={lane === "protected" ? "seg on" : "seg"}
          onClick={() => setLane("protected")}
        >
          Protected
        </button>
        <button
          role="tab"
          aria-selected={lane === "instant"}
          className={lane === "instant" ? "seg on" : "seg"}
          onClick={() => setLane("instant")}
        >
          Instant
        </button>
      </div>
      <div className="lane-hint">
        {lane === "protected"
          ? "Held in custody, cleared at one uniform price when the candle closes. Sandwich proof."
          : "Fills immediately at a volatility priced fee. Same block round trips pay a surcharge."}
      </div>

      <div className="swap-box">
        <div className="box-top">
          <span>You pay</span>
          {account && inBalance !== null && (
            <span className="bal">
              Balance {fmtAmt(inBalance, inDecimals)}
              <button className="link-btn" onClick={() => setAmount(formatUnits(inBalance, inDecimals))}>
                Max
              </button>
            </span>
          )}
        </div>
        <div className="box-main">
          <input
            className="amt-input"
            value={amount}
            inputMode="decimal"
            placeholder="0"
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
          />
          <span className="token-pill">{inSymbol}</span>
        </div>
      </div>

      <div className="flip-row">
        <button className="flip-btn" aria-label="Reverse direction" onClick={() => setZeroForOne((v) => !v)}>
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
            <path d="M7 2v10M3.5 8.5 7 12l3.5-3.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </div>

      <div className="swap-box">
        <div className="box-top">
          <span>You receive {lane === "protected" ? "at the close" : ""}</span>
        </div>
        <div className="box-main">
          <span className={estimateOut ? "amt-est" : "amt-est zero"}>
            {estimateOut ? estimateOut.toFixed(outDecimals >= 6 ? 5 : outDecimals) : "0"}
          </span>
          <span className="token-pill">{outSymbol}</span>
        </div>
        {lane === "protected" && (
          <div className="box-note">Estimate at the current pool price. The candle close price is what settles.</div>
        )}
      </div>

      <div className="detail-rows">
        <div className="detail">
          <span>Fee</span>
          <span className="mono">
            {lane === "instant"
              ? instantFeeBps !== null
                ? `${(instantFeeBps / 10000).toFixed(2)}% dynamic (${(fees!.base / 10000).toFixed(2)}% base + volatility)`
                : "reading"
              : fees
                ? `${(fees.batch / 10000).toFixed(2)}% batch at settlement`
                : "reading"}
          </span>
        </div>
        <div className="detail">
          <span>Execution</span>
          <span className="mono">
            {lane === "instant" ? "immediate" : `uniform price, closes within ${maxSpan.toString()} blocks`}
          </span>
        </div>
        <div className="detail">
          <span>Close randomness</span>
          <a
            className="mono"
            href={`${config.explorerUrl}/address/${config.randomness.address}`}
            target="_blank"
            rel="noreferrer"
          >
            {config.randomness.kind === "vrf" ? "Chainlink VRF 2.5" : "Blockhash (testnet demo)"}
          </a>
        </div>
      </div>

      <button className="cta" disabled={cta.disabled} onClick={() => cta.action()}>
        {busy ?? cta.label}
      </button>

      {status && (
        <div className={status.kind === "ok" ? "tx-note ok" : "tx-note err"}>
          {status.text}{" "}
          {status.tx && (
            <a href={`${config.explorerUrl}/tx/${status.tx}`} target="_blank" rel="noreferrer">
              View transaction
            </a>
          )}
        </div>
      )}

      {account && claims.length > 0 && (
        <div className="claims">
          <h3>Your open claims</h3>
          {claims.map((c) => (
            <div className="claim-row" key={c.claimId.toString()}>
              <div>
                <div className="pair">
                  {c.zeroForOne
                    ? `${config.token0Symbol} to ${config.token1Symbol}`
                    : `${config.token1Symbol} to ${config.token0Symbol}`}
                </div>
                <div className="meta mono">
                  {fmtAmt(c.balance, c.zeroForOne ? config.token0Decimals : config.token1Decimals)} in, block{" "}
                  {c.block.toString()}
                </div>
              </div>
              <span className={c.settled ? "state settled" : "state pending"}>
                {c.settled ? "Settled" : "In candle"}
              </span>
              <button className="btn small" disabled={!!busy} onClick={() => claimAction(c)}>
                {c.settled ? "Redeem" : "Cancel"}
              </button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
