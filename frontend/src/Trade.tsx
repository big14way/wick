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

export type OwnedOrder = { block: bigint; zeroForOne: boolean; claimId: bigint };
type Claim = OwnedOrder & { balance: bigint; settled: boolean };

const short = (a: string) => `${a.slice(0, 6)}..${a.slice(-4)}`;

export function Trade({ orders }: { orders: { block: bigint; zeroForOne: boolean; owner: string; claimId: bigint }[] }) {
  const [account, setAccount] = useState<Address | null>(null);
  const [wrongChain, setWrongChain] = useState(false);
  const [zeroForOne, setZeroForOne] = useState(true);
  const [lane, setLane] = useState<"protected" | "instant">("protected");
  const [amount, setAmount] = useState("1");
  const [busy, setBusy] = useState<string | null>(null);
  const [status, setStatus] = useState<{ kind: "ok" | "err"; text: string; tx?: string } | null>(null);
  const [claims, setClaims] = useState<Claim[]>([]);

  const walletClient = () => {
    const provider = eth();
    if (!provider) throw new Error("No injected wallet found. Install MetaMask or a compatible wallet.");
    return createWalletClient({ chain, transport: custom(provider) });
  };

  const syncChain = useCallback(async () => {
    const provider = eth();
    if (!provider) return;
    const id = (await provider.request({ method: "eth_chainId" })) as string;
    setWrongChain(parseInt(id, 16) !== config.chainId);
  }, []);

  const connect = async () => {
    setStatus(null);
    try {
      const provider = eth();
      if (!provider) throw new Error("No injected wallet found. Install MetaMask or a compatible wallet.");
      const accounts = (await provider.request({ method: "eth_requestAccounts" })) as string[];
      setAccount(accounts[0] as Address);
      await syncChain();
    } catch (e) {
      setStatus({ kind: "err", text: e instanceof Error ? e.message : String(e) });
    }
  };

  const switchChain = async () => {
    const provider = eth();
    if (!provider) return;
    const hexId = `0x${config.chainId.toString(16)}`;
    try {
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
    } catch (e) {
      const code = (e as { code?: number }).code;
      if (code === 4902) {
        await provider.request({
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
  };

  useEffect(() => {
    const provider = eth();
    if (!provider?.on) return;
    provider.on("accountsChanged", (accs) => setAccount(((accs as string[])[0] as Address) ?? null));
    provider.on("chainChanged", () => syncChain());
  }, [syncChain]);

  // Refresh the connected wallet's claims from the order feed.
  useEffect(() => {
    if (!account) {
      setClaims([]);
      return;
    }
    let stop = false;
    (async () => {
      const mine = new Map<string, OwnedOrder>();
      for (const o of orders) {
        if (o.owner.toLowerCase() !== account.toLowerCase()) continue;
        mine.set(o.claimId.toString(), { block: o.block, zeroForOne: o.zeroForOne, claimId: o.claimId });
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
        if (balance > 0n) out.push({ ...o, balance, settled: epochId !== 0 });
      }
      if (!stop) setClaims(out.sort((a, b) => (a.block > b.block ? -1 : 1)));
    })().catch(() => undefined);
    return () => {
      stop = true;
    };
  }, [account, orders]);

  const inToken = zeroForOne ? config.poolKey.currency0 : config.poolKey.currency1;
  const inSymbol = zeroForOne ? config.token0Symbol : config.token1Symbol;
  const outSymbol = zeroForOne ? config.token1Symbol : config.token0Symbol;
  const inDecimals = zeroForOne ? config.token0Decimals : config.token1Decimals;

  const swap = async () => {
    if (!account) return;
    setStatus(null);
    try {
      const amountIn = parseUnits(amount, inDecimals);
      if (amountIn <= 0n) throw new Error("Enter an amount above zero.");
      const wallet = walletClient();

      const allowance = await publicClient.readContract({
        address: inToken,
        abi: erc20Abi,
        functionName: "allowance",
        args: [account, config.routerAddress],
      });
      if (allowance < amountIn) {
        setBusy(`approving ${inSymbol}`);
        const approveTx = await wallet.writeContract({
          address: inToken,
          abi: erc20Abi,
          functionName: "approve",
          args: [config.routerAddress, 2n ** 256n - 1n],
          account,
        });
        await publicClient.waitForTransactionReceipt({ hash: approveTx });
      }

      setBusy(lane === "protected" ? "placing protected order" : "swapping instant");
      const hookData =
        lane === "protected" ? "0x" : encodeAbiParameters([{ type: "uint8" }], [1]);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const tx = await wallet.writeContract({
        address: config.routerAddress,
        abi: routerAbi,
        functionName: "swapExactTokensForTokens",
        args: [amountIn, 0n, zeroForOne, config.poolKey, hookData as `0x${string}`, account, deadline],
        account,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
      if (receipt.status !== "success") throw new Error("Transaction reverted.");
      setStatus({
        kind: "ok",
        text:
          lane === "protected"
            ? `Order custodied in block ${receipt.blockNumber}. It settles at the candle close.`
            : "Instant swap filled at the dynamic fee.",
        tx,
      });
    } catch (e) {
      setStatus({ kind: "err", text: (e instanceof Error ? e.message : String(e)).slice(0, 220) });
    } finally {
      setBusy(null);
    }
  };

  const claimAction = async (c: Claim) => {
    if (!account) return;
    setStatus(null);
    try {
      const wallet = walletClient();
      setBusy(c.settled ? "redeeming" : "cancelling");
      const tx = c.settled
        ? await wallet.writeContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "redeem",
            args: [config.poolKey, c.block, c.zeroForOne, account],
            account,
          })
        : await wallet.writeContract({
            address: config.hookAddress,
            abi: wickAbi,
            functionName: "cancel",
            args: [config.poolKey, c.block, c.zeroForOne],
            account,
          });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
      if (receipt.status !== "success") throw new Error("Transaction reverted.");
      setStatus({ kind: "ok", text: c.settled ? "Redeemed. Tokens are in your wallet." : "Cancelled and refunded.", tx });
    } catch (e) {
      setStatus({ kind: "err", text: (e instanceof Error ? e.message : String(e)).slice(0, 220) });
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="panel">
      <h2>Trade</h2>

      {!account && (
        <button className="btn primary" onClick={connect}>
          Connect wallet
        </button>
      )}

      {account && (
        <>
          <div className="wallet-row">
            <span className="mono">{short(account)}</span>
            {wrongChain ? (
              <button className="btn" onClick={switchChain}>
                Switch to {config.chainName}
              </button>
            ) : (
              <span className="chip">{config.chainName}</span>
            )}
          </div>

          <div className="trade-form">
            <div className="field-row">
              <button className={zeroForOne ? "btn toggle on" : "btn toggle"} onClick={() => setZeroForOne(true)}>
                {config.token0Symbol} to {config.token1Symbol}
              </button>
              <button className={!zeroForOne ? "btn toggle on" : "btn toggle"} onClick={() => setZeroForOne(false)}>
                {config.token1Symbol} to {config.token0Symbol}
              </button>
            </div>

            <div className="field-row">
              <button
                className={lane === "protected" ? "btn toggle on" : "btn toggle"}
                onClick={() => setLane("protected")}
              >
                Protected
              </button>
              <button className={lane === "instant" ? "btn toggle on" : "btn toggle"} onClick={() => setLane("instant")}>
                Instant
              </button>
            </div>

            <div className="field-row">
              <input
                className="amount"
                value={amount}
                inputMode="decimal"
                onChange={(e) => setAmount(e.target.value)}
                placeholder="amount"
              />
              <span className="chip">{inSymbol}</span>
            </div>

            <button className="btn primary" disabled={!!busy || wrongChain} onClick={swap}>
              {busy ??
                (lane === "protected" ? `Place protected order for ${outSymbol}` : `Swap instantly to ${outSymbol}`)}
            </button>
            <div className="sub">
              {lane === "protected"
                ? "Input is custodied and settles at one uniform price when the candle closes. Sandwich proof by construction."
                : "Executes now at the volatility priced fee. Round trips in the same block pay a surcharge."}
            </div>
          </div>

          <div className="claims">
            <h3>Your claims</h3>
            {claims.length === 0 && <div className="empty">No open claims. Protected orders show up here.</div>}
            {claims.map((c) => (
              <div className="row" key={c.claimId.toString()}>
                <span className={c.zeroForOne ? "dir zfo" : "dir ofz"}>
                  {c.zeroForOne
                    ? `${config.token0Symbol} to ${config.token1Symbol}`
                    : `${config.token1Symbol} to ${config.token0Symbol}`}
                </span>
                <span className="mono">
                  {formatUnits(c.balance, c.zeroForOne ? config.token0Decimals : config.token1Decimals)} in, block{" "}
                  {c.block.toString()}
                </span>
                <button className="btn small" disabled={!!busy} onClick={() => claimAction(c)}>
                  {c.settled ? "Redeem" : "Cancel"}
                </button>
              </div>
            ))}
          </div>
        </>
      )}

      {status && (
        <div className={status.kind === "ok" ? "notice ok" : "notice"}>
          {status.text}{" "}
          {status.tx && (
            <a href={`${config.explorerUrl}/tx/${status.tx}`} target="_blank" rel="noreferrer">
              view tx
            </a>
          )}
        </div>
      )}
    </section>
  );
}
